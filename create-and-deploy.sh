#!/usr/bin/env bash
# =============================================================================
# create-and-deploy.sh
# Full pipeline: create EKS cluster → deploy Istio two-tier distributed
# API gateway → JWT-based traffic routing (Keycloak + OAuth2 Proxy).
#
# Cluster : istiodc1-cluster  (ap-southeast-1, AWS EKS 1.29)
# Hostnames: finance.mhnbank.xyz  (API gateway)
#            auth.mhnbank.xyz     (Keycloak)
# Istio   : 1.29.2
#
# Usage:
#   bash create-and-deploy.sh              # full run (EKS create + deploy)
#   bash create-and-deploy.sh --skip-eks   # skip EKS creation (cluster exists)
#
# Prerequisites:
#   aws       — AWS CLI v2, credentials configured
#   eksctl    — https://eksctl.io
#   kubectl   — 1.29+
#   helm      — v3.x
#   istioctl  — 1.29.2  (install below if missing)
#   jq        — for JWT claim parsing in the test section
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }
ok()    { echo -e "${GREEN}✔  $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠  $*${NC}"; }
die()   { echo -e "${RED}✘  $*${NC}"; exit 1; }
info()  { echo -e "   $*"; }

# ── Config ───────────────────────────────────────────────────────────────────
CLUSTER_NAME="istiodc1-cluster"
REGION="ap-southeast-1"
K8S_VERSION="1.29"
NODE_TYPE="m5.large"
NODE_MIN=2
NODE_MAX=4
NODE_DESIRED=3
ISTIO_VERSION="1.29.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_EKS=false
for arg in "$@"; do
  [[ "$arg" == "--skip-eks" ]] && SKIP_EKS=true
done

cd "$SCRIPT_DIR"

# =============================================================================
# STEP 0 — Prerequisite check
# =============================================================================
step "Step 0 — Checking prerequisites"

MISSING=()
for cmd in aws eksctl kubectl helm jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd: $(command -v "$cmd")"
  else
    warn "$cmd not found"
    MISSING+=("$cmd")
  fi
done

# istioctl — install automatically if missing
if command -v istioctl &>/dev/null; then
  ISTIOCTL_VER=$(istioctl version --remote=false 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  ok "istioctl: $(command -v istioctl)  (version $ISTIOCTL_VER)"
  if [[ "$ISTIOCTL_VER" != "$ISTIO_VERSION" ]]; then
    warn "istioctl version $ISTIOCTL_VER ≠ expected $ISTIO_VERSION — installing correct version"
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh -
    sudo mv "./istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
    rm -rf "./istio-${ISTIO_VERSION}"
    ok "istioctl ${ISTIO_VERSION} installed"
  fi
else
  warn "istioctl not found — installing ${ISTIO_VERSION}"
  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh -
  sudo mv "./istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
  rm -rf "./istio-${ISTIO_VERSION}"
  ok "istioctl ${ISTIO_VERSION} installed"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  echo -e "${RED}Missing tools: ${MISSING[*]}${NC}"
  echo ""
  echo "Install guides:"
  echo "  aws    : https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  echo "  eksctl : curl --silent --location https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_\$(uname -s)_amd64.tar.gz | tar xz -C /usr/local/bin"
  echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
  echo "  helm   : https://helm.sh/docs/intro/install/"
  echo "  jq     : sudo apt-get install jq  (or brew install jq)"
  die "Install missing tools and re-run."
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
  die "AWS credentials not configured. Run: aws configure"
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ok "AWS account: $AWS_ACCOUNT  region: $REGION"

# =============================================================================
# EKS-1 — Create EKS cluster
# =============================================================================
if [[ "$SKIP_EKS" == "true" ]]; then
  step "EKS-1 — Skipping EKS cluster creation (--skip-eks)"
  info "Connecting to existing cluster $CLUSTER_NAME"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  kubectl config current-context
  kubectl get nodes
  ok "Connected to existing cluster"
else
  step "EKS-1 — Create EKS cluster: $CLUSTER_NAME"

  # Write eksctl cluster config to a temp file
  EKSCTL_CFG=$(mktemp /tmp/eksctl-cfg-XXXXXX.yaml)
  cat > "$EKSCTL_CFG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
  tags:
    project: istio-distributed-gateway
    owner: mhnbank

iam:
  withOIDC: true

managedNodeGroups:
  - name: ng-system
    instanceType: ${NODE_TYPE}
    minSize: ${NODE_MIN}
    maxSize: ${NODE_MAX}
    desiredCapacity: ${NODE_DESIRED}
    volumeSize: 50
    amiFamily: AmazonLinux2
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
    labels:
      role: system
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
EOF

  echo "eksctl cluster config:"
  cat "$EKSCTL_CFG"
  echo ""
  echo "Creating EKS cluster... (takes ~15-20 min)"
  eksctl create cluster -f "$EKSCTL_CFG"
  rm -f "$EKSCTL_CFG"

  # Update kubeconfig
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  kubectl config current-context
  echo ""
  kubectl get nodes -o wide
  ok "EKS cluster $CLUSTER_NAME created and kubeconfig updated"
fi

# =============================================================================
# STEP 1 — Helm repos
# =============================================================================
step "Step 1 — Add/update Helm repositories"
helm repo add istio               https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts  2>/dev/null || true
helm repo add kiali               https://kiali.org/helm-charts                       2>/dev/null || true
helm repo update
ok "Helm repos ready"

# =============================================================================
# STEP 2 — Istio base (CRDs)
# =============================================================================
step "Step 2 — Install Istio base (CRDs)"
helm upgrade --install istio-base istio/base \
  -n istio-system --create-namespace \
  --version "$ISTIO_VERSION" \
  -f helm-values/istio-base-values.yaml \
  --wait
kubectl get crd | grep -c istio | xargs -I{} echo "{} Istio CRDs installed"
ok "istio-base installed"

# =============================================================================
# STEP 3 — istiod (control plane)
# =============================================================================
step "Step 3 — Install istiod (control plane + OAuth2 Proxy extensionProvider)"
helm upgrade --install istiod istio/istiod \
  -n istio-system \
  --version "$ISTIO_VERSION" \
  -f helm-values/istiod-values.yaml \
  --wait
kubectl rollout status deployment/istiod -n istio-system --timeout=120s
ok "istiod running"

# =============================================================================
# STEP 4 — Domain namespaces (sidecar injection enabled)
# =============================================================================
step "Step 4 — Create domain namespaces with sidecar injection"
kubectl apply -f 0-istio-namespaces-domains.yaml
kubectl get ns retail-banking payments grc --show-labels | grep istio-injection
ok "Namespaces ready"

# =============================================================================
# STEP 5 — Global IngressGateway (the single LoadBalancer)
# =============================================================================
step "Step 5 — Install global IngressGateway (LoadBalancer)"
helm upgrade --install istio-ingressgateway istio/gateway \
  -n istio-system \
  --version "$ISTIO_VERSION" \
  -f helm-values/istio-ingress-values.yaml \
  --wait

echo "Waiting for AWS ELB to assign hostname (up to 3 min)..."
INGRESS_HOST=""
for i in $(seq 1 36); do
  INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$INGRESS_HOST" ]]; then
    ok "ELB provisioned: $INGRESS_HOST"
    break
  fi
  echo -n "."
  sleep 5
done
if [[ -z "${INGRESS_HOST:-}" ]]; then
  warn "ELB not yet provisioned — continuing; check later:"
  warn "  kubectl get svc istio-ingressgateway -n istio-system"
fi

# =============================================================================
# STEP 6 — Per-namespace IngressGateways (ClusterIP)
# =============================================================================
step "Step 6 — Install per-namespace IngressGateways (ClusterIP)"

helm upgrade --install retail-banking-ingressgateway istio/gateway \
  -n retail-banking --version "$ISTIO_VERSION" \
  -f helm-values/retail-banking-ingress-values.yaml --wait
ok "retail-banking-ingressgateway installed"

helm upgrade --install payments-ingressgateway istio/gateway \
  -n payments --version "$ISTIO_VERSION" \
  -f helm-values/payments-ingress-values.yaml --wait
ok "payments-ingressgateway installed"

helm upgrade --install grc-ingressgateway istio/gateway \
  -n grc --version "$ISTIO_VERSION" \
  -f helm-values/grc-ingress-values.yaml --wait
ok "grc-ingressgateway installed"

echo ""
kubectl get svc -n retail-banking retail-banking-ingressgateway -o jsonpath='{.spec.type}' && echo " (retail-banking)"
kubectl get svc -n payments       payments-ingressgateway       -o jsonpath='{.spec.type}' && echo " (payments)"
kubectl get svc -n grc            grc-ingressgateway            -o jsonpath='{.spec.type}' && echo " (grc)"

# =============================================================================
# STEP 6b — Keycloak Identity Provider
# =============================================================================
step "Step 6b — Deploy Keycloak (Identity Provider)"
kubectl apply -f apps/keycloak/namespace.yaml
# realm-import.yaml includes: mhnbank realm, oauth2-proxy-client,
# retail-banking-api / payments-api / grc-api (client_credentials + domain claim)
kubectl apply -f apps/keycloak/realm-import.yaml
kubectl apply -f apps/keycloak/keycloak.yaml

echo "Waiting for Keycloak to be ready (realm import takes ~2-3 min)..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=300s
ok "Keycloak ready"

KEYCLOAK_IP=$(kubectl get svc keycloak -n keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
ok "Keycloak ClusterIP: $KEYCLOAK_IP"

# =============================================================================
# STEP 6c — Istio Gateway + VirtualServices (must precede OAuth2 Proxy)
# =============================================================================
# OAuth2 Proxy calls auth.mhnbank.xyz at pod startup for OIDC discovery.
# Routing must be in place before the OAuth2 Proxy pod initialises.
step "Step 6c — Apply Istio Gateway CR + VirtualServices"

kubectl apply -f 1-istio-gateway-global.yaml
ok "Global Gateway CR applied (finance.mhnbank.xyz + auth.mhnbank.xyz on :80/:443)"

kubectl apply -f 3-global-virtualservice.yaml
ok "Global VirtualService applied (JWT claim routing + path routing + /oauth2/)"

kubectl apply -f 3b-keycloak-virtualservice.yaml
ok "Keycloak VirtualService applied (auth.mhnbank.xyz → keycloak:80)"

echo ""
warn "DNS PREREQUISITE:"
warn "  finance.mhnbank.xyz  CNAME → ${INGRESS_HOST:-<ELB hostname from Step 5>}"
warn "  auth.mhnbank.xyz     CNAME → ${INGRESS_HOST:-<ELB hostname from Step 5>}"
warn "OAuth2 Proxy resolves auth.mhnbank.xyz for OIDC discovery."
warn "If DNS is not configured yet, OAuth2 Proxy will CrashLoopBackOff."
echo ""
warn "ACTION REQUIRED — verify these values before OAuth2 Proxy starts:"
warn "  apps/auth/oauth2-proxy-secret.yaml:"
warn "    OAUTH2_PROXY_CLIENT_SECRET  — must match Keycloak client 'oauth2-proxy-client' secret"
warn "    OAUTH2_PROXY_COOKIE_SECRET  — exactly 32 raw chars, e.g.:"
warn "      python3 -c \"import secrets,base64; print(base64.b64encode(secrets.token_bytes(32)).decode()[:32])\""
echo ""

# =============================================================================
# STEP 6d — OAuth2 Proxy + Redis (ext_authz backend)
# =============================================================================
step "Step 6d — Deploy OAuth2 Proxy + Redis"
kubectl apply -f apps/auth/namespace.yaml
kubectl apply -f apps/auth/redis.yaml
kubectl apply -f apps/auth/oauth2-proxy-secret.yaml
kubectl apply -f apps/auth/oauth2-proxy.yaml

# Force restart so new secret values are always picked up
kubectl rollout restart deployment/oauth2-proxy -n auth

echo "Waiting for Redis..."
kubectl rollout status deployment/redis -n auth --timeout=60s
ok "Redis ready"

echo "Waiting for OAuth2 Proxy (OIDC discovery ~30s)..."
kubectl rollout status deployment/oauth2-proxy -n auth --timeout=120s
ok "OAuth2 Proxy ready"

kubectl get pods -n auth

# =============================================================================
# STEP 6e — JWT RequestAuthentication
# =============================================================================
# Validates Bearer JWT from Keycloak API clients at the global IngressGateway.
# Extracts the 'domain' claim into @request.auth.claims.domain for VS routing.
step "Step 6e — Apply JWT RequestAuthentication"
kubectl apply -f 7-request-authentication.yaml
ok "RequestAuthentication jwt-keycloak applied (issuer: http://auth.mhnbank.xyz/realms/mhnbank)"

echo ""
echo "JWT acquisition for API clients:"
info "  # retail-banking-api client:"
info "  curl -s -X POST http://auth.mhnbank.xyz/realms/mhnbank/protocol/openid-connect/token \\"
info "    -d 'client_id=retail-banking-api&client_secret=retail-banking-api-secret&grant_type=client_credentials' \\"
info "    | jq -r '.access_token'"

# =============================================================================
# STEP 6f — JWT CORS EnvoyFilters
# =============================================================================
# Filter 1: bypass_cors_preflight — skip JWT validation for OPTIONS requests.
# Filter 2: Lua filter — return 200 + CORS headers for OPTIONS at the edge.
step "Step 6f — Apply JWT CORS EnvoyFilters"
kubectl apply -f 8-jwt-cors-envoyfilter.yaml
ok "EnvoyFilter jwt-bypass-cors-preflight applied"
ok "EnvoyFilter cors-preflight-response applied"

# Restart OAuth2 Proxy to ensure --skip-jwt-bearer-tokens=true is active.
# The arg is already in oauth2-proxy.yaml; this restart guarantees the
# pod running in-cluster reflects the current Deployment spec.
echo "Restarting OAuth2 Proxy to activate --skip-jwt-bearer-tokens=true..."
kubectl rollout restart deployment/oauth2-proxy -n auth
kubectl rollout status deployment/oauth2-proxy -n auth --timeout=120s
ok "OAuth2 Proxy restarted with JWT bearer token bypass enabled"

# =============================================================================
# STEP 7 — mTLS + DestinationRules + AuthorizationPolicies
# =============================================================================
step "Step 7 — Apply mTLS + DestinationRules + AuthorizationPolicies"

kubectl apply -f 2-mtls-peer-authentication.yaml
ok "PeerAuthentication STRICT applied"

kubectl apply -f 4-mtls-destination-rules.yaml
ok "DestinationRules (ISTIO_MUTUAL) applied"

kubectl apply -f 5-authorization-policies.yaml
ok "AuthorizationPolicies (service-level SPIFFE RBAC) applied"

kubectl apply -f 6-api-access-control.yaml
ok "CUSTOM AuthorizationPolicy (OAuth2 Proxy ext_authz) applied"

echo ""
kubectl get peerauthentication -A
echo ""
kubectl get destinationrule -A
echo ""
kubectl get authorizationpolicy -A
echo ""
kubectl get virtualservice -A

# =============================================================================
# STEP 8 — Domain app resources
# =============================================================================
step "Step 8 — Deploy domain app workloads"

kubectl apply -f apps/retail-banking/namespace.yaml
kubectl apply -f apps/payments/namespace.yaml
kubectl apply -f apps/risk-compliance/namespace.yaml

kubectl apply -f apps/retail-banking/
kubectl apply -f apps/payments/
kubectl apply -f apps/risk-compliance/

echo "Waiting for domain pods..."
kubectl rollout status deployment/customer-profile-svc -n retail-banking --timeout=180s
kubectl rollout status deployment/account-svc          -n retail-banking --timeout=60s
kubectl rollout status deployment/bank-statement-svc   -n retail-banking --timeout=60s
kubectl rollout status deployment/transfer-svc         -n payments       --timeout=180s
kubectl rollout status deployment/payment-gateway-svc  -n payments       --timeout=60s
kubectl rollout status deployment/fx-svc               -n payments       --timeout=60s
kubectl rollout status deployment/fraud-svc            -n grc            --timeout=180s
kubectl rollout status deployment/audit-svc            -n grc            --timeout=60s
kubectl rollout status deployment/sanction-svc         -n grc            --timeout=60s
ok "All domain pods running"

echo ""
echo "Pod status (expect 2/2 for sidecar injection):"
kubectl get pods -n retail-banking
kubectl get pods -n payments
kubectl get pods -n grc

# =============================================================================
# STEP 9 — Prometheus
# =============================================================================
step "Step 9 — Install Prometheus"
helm upgrade --install prometheus prometheus-community/prometheus \
  -n istio-system \
  -f helm-values/prometheus-values.yaml \
  --wait
kubectl rollout status deployment/prometheus-server -n istio-system --timeout=120s
ok "Prometheus running"

# =============================================================================
# STEP 10 — Kiali
# =============================================================================
step "Step 10 — Install Kiali operator + CR"
helm upgrade --install kiali-operator kiali/kiali-operator \
  -n kiali-operator --create-namespace \
  -f helm-values/kiali-values.yaml \
  --wait

echo "Waiting for Kiali pod in istio-system (up to 3 min)..."
for i in $(seq 1 36); do
  KIALI_READY=$(kubectl get pod -n istio-system -l app=kiali \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  [[ "$KIALI_READY" == "true" ]] && { ok "Kiali pod ready"; break; }
  echo -n "."
  sleep 5
done

KIALI_HOST=$(kubectl get svc kiali -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
ok "Kiali URL: http://${KIALI_HOST}:20001/kiali"

# =============================================================================
# STEP 11 — Verification summary
# =============================================================================
step "Step 11 — Verification summary"

echo ""
echo -e "${BOLD}LoadBalancers${NC}"
kubectl get svc -A --field-selector spec.type=LoadBalancer

echo ""
echo -e "${BOLD}Namespace injection labels${NC}"
kubectl get ns retail-banking payments grc --show-labels | grep istio-injection

echo ""
echo -e "${BOLD}Pods with sidecars (expect 2/2)${NC}"
kubectl get pods -n retail-banking
kubectl get pods -n payments
kubectl get pods -n grc

echo ""
echo -e "${BOLD}PeerAuthentication (expect STRICT)${NC}"
kubectl get peerauthentication -A

echo ""
echo -e "${BOLD}RequestAuthentication (JWT)${NC}"
kubectl get requestauthentication -A

echo ""
echo -e "${BOLD}EnvoyFilters (CORS bypass)${NC}"
kubectl get envoyfilter -A

echo ""
echo -e "${BOLD}AuthorizationPolicies${NC}"
kubectl get authorizationpolicy -A

echo ""
echo -e "${BOLD}VirtualServices${NC}"
kubectl get virtualservice -A

# =============================================================================
# STEP 12 — Path-based traffic test (browser / OAuth2 Proxy flow)
# =============================================================================
step "Step 12 — Path-based traffic test"

INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -z "$INGRESS_HOST" ]]; then
  warn "ELB hostname not yet assigned — skipping traffic tests."
  warn "Re-run manually once ELB is ready."
else
  echo "ELB: $INGRESS_HOST"

  test_path() {
    local label=$1 path=$2 expect_code=${3:-200}
    echo ""
    echo "── $label ──"
    HTTP_CODE=$(curl -s -o /tmp/gw_response -w "%{http_code}" --max-time 10 \
      -H "Host: finance.mhnbank.xyz" "http://${INGRESS_HOST}${path}" || echo "000")
    echo "HTTP $HTTP_CODE"
    jq . /tmp/gw_response 2>/dev/null || cat /tmp/gw_response
    if [[ "$HTTP_CODE" == "$expect_code" ]]; then
      ok "$label → $HTTP_CODE"
    else
      warn "$label returned HTTP $HTTP_CODE (expected $expect_code)"
    fi
  }

  echo "Waiting 15s for xDS config to propagate..."
  sleep 15

  test_path "retail-banking (path)"  "/retail-banking/"
  test_path "payments (path)"        "/payments/"
  test_path "grc (path)"             "/grc/"
  test_path "catch-all /"            "/"
fi

# =============================================================================
# STEP 13 — JWT-based traffic routing test (API / machine client flow)
# =============================================================================
step "Step 13 — JWT-based traffic routing test"

if [[ -z "${INGRESS_HOST:-}" ]]; then
  warn "ELB hostname not yet assigned — skipping JWT tests."
else
  echo ""
  info "Testing client-credentials grant → JWT claim routing"
  info "Each domain API client carries a hardcoded 'domain' claim that"
  info "Istio extracts into @request.auth.claims.domain for VS routing."
  echo ""

  jwt_test() {
    local domain=$1 client_id=$2 client_secret=$3
    echo "── JWT routing: $domain ──"

    # Obtain token from Keycloak via client-credentials grant.
    # Uses in-cluster DNS via kubectl exec on a debug pod to avoid needing
    # external DNS for auth.mhnbank.xyz at test time.
    TOKEN_JSON=$(curl -s --max-time 15 \
      -X POST "http://${INGRESS_HOST}/realms/mhnbank/protocol/openid-connect/token" \
      -H "Host: auth.mhnbank.xyz" \
      -d "client_id=${client_id}&client_secret=${client_secret}&grant_type=client_credentials" \
      2>/dev/null || echo "{}")

    ACCESS_TOKEN=$(echo "$TOKEN_JSON" | jq -r '.access_token // empty' 2>/dev/null || echo "")

    if [[ -z "$ACCESS_TOKEN" ]]; then
      warn "$domain: failed to obtain JWT from Keycloak"
      info "  Token response: $TOKEN_JSON"
      info "  Ensure DNS for auth.mhnbank.xyz points to: $INGRESS_HOST"
      return
    fi

    ok "$domain: JWT acquired (${#ACCESS_TOKEN} chars)"

    # Decode the domain claim from the JWT payload (middle segment)
    DOMAIN_CLAIM=$(echo "$ACCESS_TOKEN" | cut -d'.' -f2 | \
      # pad base64 to multiple of 4
      awk '{ n=length($0)%4; if(n==2) $0=$0"=="; else if(n==3) $0=$0"="; print }' | \
      base64 -d 2>/dev/null | jq -r '.domain // empty' 2>/dev/null || echo "")
    info "  JWT domain claim: ${DOMAIN_CLAIM:-<not found>}"

    # Route via JWT claim (no path prefix needed — VirtualService matches on header)
    HTTP_CODE=$(curl -s -o /tmp/jwt_response -w "%{http_code}" --max-time 10 \
      -H "Host: finance.mhnbank.xyz" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "http://${INGRESS_HOST}/" 2>/dev/null || echo "000")
    echo "  Routed to $domain namespace: HTTP $HTTP_CODE"
    jq . /tmp/jwt_response 2>/dev/null || cat /tmp/jwt_response 2>/dev/null || true

    if [[ "$HTTP_CODE" == "200" ]]; then
      ok "$domain JWT routing → 200 OK"
    else
      warn "$domain JWT routing returned HTTP $HTTP_CODE"
      info "  Expected 200 — check VirtualService and RequestAuthentication:"
      info "    kubectl get requestauthentication -n istio-system -o yaml"
      info "    istioctl proxy-config routes \$(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}') -n istio-system"
    fi
    echo ""
  }

  jwt_test "retail-banking" "retail-banking-api" "retail-banking-api-secret"
  jwt_test "payments"       "payments-api"       "payments-api-secret"
  jwt_test "grc"            "grc-api"            "grc-api-secret"

  # ── CORS preflight test ──────────────────────────────────────────────────
  echo "── CORS preflight (OPTIONS) ──"
  OPTIONS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X OPTIONS \
    -H "Host: finance.mhnbank.xyz" \
    -H "Origin: https://spa.mhnbank.xyz" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Authorization,Content-Type" \
    "http://${INGRESS_HOST}/" 2>/dev/null || echo "000")
  if [[ "$OPTIONS_CODE" == "200" ]]; then
    ok "CORS preflight → 200 (Lua EnvoyFilter working)"
  else
    warn "CORS preflight returned HTTP $OPTIONS_CODE (expected 200)"
    info "  Check EnvoyFilter cors-preflight-response in istio-system"
  fi
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  MHN Bank — Istio Distributed API Gateway — Deployment Complete ${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Global IngressGateway ELB${NC}  : http://${INGRESS_HOST:-<pending>}"
KIALI_HOST=$(kubectl get svc kiali -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
echo -e "  ${BOLD}Kiali dashboard${NC}            : http://${KIALI_HOST}:20001/kiali"
echo ""
echo -e "  ${BOLD}DNS records required:${NC}"
echo -e "    finance.mhnbank.xyz  CNAME  ${INGRESS_HOST:-<ELB hostname>}"
echo -e "    auth.mhnbank.xyz     CNAME  ${INGRESS_HOST:-<ELB hostname>}"
echo ""
echo -e "  ${BOLD}Path routing (browser / OAuth2 Proxy):${NC}"
echo -e "    http://finance.mhnbank.xyz/retail-banking/  → retail-banking namespace"
echo -e "    http://finance.mhnbank.xyz/payments/        → payments namespace"
echo -e "    http://finance.mhnbank.xyz/grc/             → grc namespace"
echo ""
echo -e "  ${BOLD}JWT routing (API clients — client_credentials grant):${NC}"
echo -e "    TOKEN=\$(curl -s -X POST http://auth.mhnbank.xyz/realms/mhnbank/protocol/openid-connect/token \\"
echo -e "      -d 'client_id=retail-banking-api&client_secret=retail-banking-api-secret&grant_type=client_credentials' \\"
echo -e "      | jq -r '.access_token')"
echo -e "    curl -H 'Authorization: Bearer \$TOKEN' http://finance.mhnbank.xyz/"
echo -e "    # → routed to retail-banking namespace (domain claim in JWT)"
echo ""
echo -e "  ${BOLD}mTLS verification:${NC}"
echo -e "    istioctl x describe pod \$(kubectl get pod -n retail-banking -l app=customer-profile-svc -o jsonpath='{.items[0].metadata.name}') -n retail-banking"
echo ""
echo -e "  ${BOLD}Diagnostics:${NC}"
echo -e "    IGW=\$(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
echo -e "    istioctl proxy-config routes \$IGW -n istio-system"
echo -e "    kubectl logs -n istio-system deploy/istio-ingressgateway --tail=50"