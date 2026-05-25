#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Full deployment: Istio two-tier distributed gateway + observability
# Cluster : istiodc1-cluster (ap-southeast-1, AWS EKS)
# Hostname: finance.mhnbank.xyz
# Istio   : 1.29.2
# Usage   : bash deploy.sh
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }
ok()    { echo -e "${GREEN}✔  $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠  $*${NC}"; }
die()   { echo -e "${RED}✘  $*${NC}"; exit 1; }

# ── Config ───────────────────────────────────────────────────────────────────
CLUSTER_NAME="istiodc1-cluster"
REGION="ap-southeast-1"
ISTIO_VERSION="1.29.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Prerequisite check ────────────────────────────────────────────────────────
step "Checking prerequisites"
for cmd in aws kubectl helm istioctl; do
  if ! command -v "$cmd" &>/dev/null; then
    die "$cmd not found. Install it and re-run."
  fi
  ok "$cmd found: $(command -v "$cmd")"
done

ISTIOCTL_VER=$(istioctl version --remote=false 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ "$ISTIOCTL_VER" != "$ISTIO_VERSION" ]]; then
  warn "istioctl version is $ISTIOCTL_VER, expected $ISTIO_VERSION"
  warn "Install with: curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -"
  warn "Then: sudo mv ./istio-${ISTIO_VERSION}/bin/istioctl /usr/local/bin/istioctl"
fi

cd "$SCRIPT_DIR"

# =============================================================================
# STEP 0 — Connect to EKS
# =============================================================================
step "Step 0 — Connect to EKS cluster"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
kubectl config current-context
echo ""
kubectl get nodes
ok "EKS cluster connected"

# =============================================================================
# STEP 1 — Helm repos
# =============================================================================
step "Step 1 — Add/update Helm repositories"
helm repo add istio              https://istio-release.storage.googleapis.com/charts          2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts         2>/dev/null || true
helm repo add kiali              https://kiali.org/helm-charts                               2>/dev/null || true
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
step "Step 3 — Install istiod (control plane)"
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

echo "Waiting for AWS ELB to assign EXTERNAL-IP (up to 3 min)..."
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
  warn "ELB not yet provisioned — continue and check later with:"
  warn "kubectl get svc istio-ingressgateway -n istio-system"
fi

# =============================================================================
# STEP 6 — Per-namespace IngressGateways (ClusterIP)
# =============================================================================
step "Step 6 — Install per-namespace IngressGateways (ClusterIP)"

helm upgrade --install retail-banking-ingressgateway istio/gateway \
  -n retail-banking \
  --version "$ISTIO_VERSION" \
  -f helm-values/retail-banking-ingress-values.yaml \
  --wait
ok "retail-banking-ingressgateway installed"

helm upgrade --install payments-ingressgateway istio/gateway \
  -n payments \
  --version "$ISTIO_VERSION" \
  -f helm-values/payments-ingress-values.yaml \
  --wait
ok "payments-ingressgateway installed"

helm upgrade --install grc-ingressgateway istio/gateway \
  -n grc \
  --version "$ISTIO_VERSION" \
  -f helm-values/grc-ingress-values.yaml \
  --wait
ok "grc-ingressgateway installed"

echo ""
echo "Namespace gateway service types:"
kubectl get svc -n retail-banking retail-banking-ingressgateway -o jsonpath='{.spec.type}' && echo " (retail-banking)"
kubectl get svc -n payments       payments-ingressgateway       -o jsonpath='{.spec.type}' && echo " (payments)"
kubectl get svc -n grc            grc-ingressgateway            -o jsonpath='{.spec.type}' && echo " (grc)"

# =============================================================================
# STEP 7 — Global Gateway CR + mTLS + VirtualService + DestinationRules + AuthZ
# =============================================================================
step "Step 7 — Apply Istio policy resources"

kubectl apply -f 1-istio-gateway-global.yaml
ok "Global Gateway CR applied"

kubectl apply -f 2-mtls-peer-authentication.yaml
ok "PeerAuthentication STRICT applied"

kubectl apply -f 3-global-virtualservice.yaml
ok "Global VirtualService applied"

kubectl apply -f 4-mtls-destination-rules.yaml
ok "DestinationRules (ISTIO_MUTUAL) applied"

kubectl apply -f 5-authorization-policies.yaml
ok "AuthorizationPolicies applied"

echo ""
echo "PeerAuthentication policies:"
kubectl get peerauthentication -A

echo ""
echo "DestinationRules:"
kubectl get destinationrule -A

echo ""
echo "AuthorizationPolicies:"
kubectl get authorizationpolicy -A

# =============================================================================
# STEP 8 — Domain app resources
# =============================================================================
step "Step 8 — Deploy domain app resources"

# Namespaces first (idempotent)
kubectl apply -f apps/retail-banking/namespace.yaml
kubectl apply -f apps/payments/namespace.yaml
kubectl apply -f apps/risk-compliance/namespace.yaml

# All domain resources
kubectl apply -f apps/retail-banking/
kubectl apply -f apps/payments/
kubectl apply -f apps/risk-compliance/

echo "Waiting for pods to reach Running state (up to 3 min)..."
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
step "Step 9 — Install Prometheus (istio-system)"
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
  if [[ "$KIALI_READY" == "true" ]]; then
    ok "Kiali pod ready"
    break
  fi
  echo -n "."
  sleep 5
done

KIALI_HOST=$(kubectl get svc kiali -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
echo ""
ok "Kiali URL: http://${KIALI_HOST}:20001/kiali"

# =============================================================================
# STEP 11 — Verification summary
# =============================================================================
step "Step 11 — Verification summary"

echo ""
echo -e "${BOLD}1. LoadBalancers${NC}"
kubectl get svc -A --field-selector spec.type=LoadBalancer

echo ""
echo -e "${BOLD}2. Namespace injection labels${NC}"
kubectl get ns retail-banking payments grc --show-labels | grep istio-injection

echo ""
echo -e "${BOLD}3. Pods with sidecars (expect 2/2)${NC}"
kubectl get pods -n retail-banking -o wide
kubectl get pods -n payments       -o wide
kubectl get pods -n grc            -o wide

echo ""
echo -e "${BOLD}4. PeerAuthentication (expect STRICT everywhere)${NC}"
kubectl get peerauthentication -A

echo ""
echo -e "${BOLD}5. DestinationRules${NC}"
kubectl get destinationrule -A

echo ""
echo -e "${BOLD}6. AuthorizationPolicies${NC}"
kubectl get authorizationpolicy -A

echo ""
echo -e "${BOLD}7. Gateway CRs${NC}"
kubectl get gateway -A

echo ""
echo -e "${BOLD}8. VirtualServices${NC}"
kubectl get virtualservice -A

# =============================================================================
# STEP 12 — End-to-end traffic test
# =============================================================================
step "Step 12 — End-to-end traffic test"

INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -z "$INGRESS_HOST" ]]; then
  warn "ELB hostname not yet assigned — skipping traffic test."
  warn "Re-run manually once the ELB is ready:"
  warn "  export INGRESS_HOST=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  warn "  curl -si -H 'Host: finance.mhnbank.xyz' http://\${INGRESS_HOST}/retail-banking/"
else
  echo "ELB: $INGRESS_HOST"

  # Helper — shows HTTP status + raw body, then pretty-prints if JSON
  test_path() {
    local label=$1 path=$2
    echo ""
    echo "── $label ──"
    HTTP_CODE=$(curl -s -o /tmp/gw_response -w "%{http_code}" --max-time 10 \
      -H "Host: finance.mhnbank.xyz" "http://${INGRESS_HOST}${path}")
    echo "HTTP $HTTP_CODE"
    if jq . /tmp/gw_response 2>/dev/null; then
      : # JSON printed by jq
    else
      cat /tmp/gw_response   # show raw response when not JSON
    fi
    if [[ "$HTTP_CODE" == "200" ]]; then
      ok "$label → 200 OK"
    else
      warn "$label returned HTTP $HTTP_CODE — see diagnostics below if unexpected"
    fi
  }

  # Give Envoy a moment to sync xDS config after all resources applied
  echo "Waiting 10s for xDS config to propagate..."
  sleep 10

  test_path "retail-banking" "/retail-banking/"
  test_path "payments"       "/payments/"
  test_path "grc"            "/grc/"
  test_path "catch-all /"    "/"

  # ── Diagnostics (always shown — useful to confirm routing is wired) ──
  echo ""
  echo -e "${BOLD}Diagnostics — run these if any path returned non-200:${NC}"
  echo ""
  echo "  # Check Envoy route config on global IngressGateway:"
  echo "  IGW_POD=\$(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
  echo "  istioctl proxy-config routes \$IGW_POD -n istio-system"
  echo ""
  echo "  # Tail IngressGateway access log (shows upstream errors):"
  echo "  kubectl logs -n istio-system deploy/istio-ingressgateway -f"
  echo ""
  echo "  # Check AuthorizationPolicy denials on entry services:"
  echo "  kubectl logs -n retail-banking deploy/customer-profile-svc -c istio-proxy | grep -i 'rbac\|denied' | tail -5"
  echo "  kubectl logs -n payments deploy/transfer-svc -c istio-proxy | grep -i 'rbac\|denied' | tail -5"
  echo "  kubectl logs -n grc deploy/fraud-svc -c istio-proxy | grep -i 'rbac\|denied' | tail -5"
  echo ""
  echo "  # Verify mTLS on customer-profile-svc:"
  echo "  istioctl x describe pod \$(kubectl get pod -n retail-banking -l app=customer-profile-svc -o jsonpath='{.items[0].metadata.name}') -n retail-banking"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Deployment complete — MHN Bank Istio Gateway       ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Global IngressGateway : http://${INGRESS_HOST:-<pending>}"
KIALI_HOST=$(kubectl get svc kiali -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
echo "  Kiali dashboard       : http://${KIALI_HOST}:20001/kiali"
echo ""
echo "  mTLS verify:"
echo "    istioctl x describe pod \$(kubectl get pod -n retail-banking -l app=customer-profile-svc -o jsonpath='{.items[0].metadata.name}') -n retail-banking"
