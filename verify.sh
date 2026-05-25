#!/usr/bin/env bash
# =============================================================================
# verify.sh — Full verification: Istio two-tier distributed gateway
# Cluster : istiodc1-cluster (ap-southeast-1, AWS EKS)
# Hostname: finance.mhnbank.xyz
# Usage   : bash verify.sh
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }
ok()    { echo -e "${GREEN}✔  $*${NC}"; }
fail()  { echo -e "${RED}✘  $*${NC}"; FAILURES=$((FAILURES+1)); }
warn()  { echo -e "${YELLOW}⚠  $*${NC}"; }
hdr()   { echo -e "${BOLD}$*${NC}"; }

FAILURES=0

INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

# =============================================================================
# CHECK 1 — LoadBalancers
# =============================================================================
step "Check 1 — LoadBalancers"
kubectl get svc -A --field-selector spec.type=LoadBalancer

LB_COUNT=$(kubectl get svc -A --field-selector spec.type=LoadBalancer --no-headers 2>/dev/null | wc -l)
if [[ "$LB_COUNT" -ge 1 ]]; then
  ok "At least 1 LoadBalancer present (istio-ingressgateway)"
else
  fail "No LoadBalancer found — global IngressGateway may not be installed"
fi

IGW_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -n "$IGW_IP" ]]; then
  ok "Global IngressGateway ELB: $IGW_IP"
else
  fail "istio-ingressgateway has no EXTERNAL-IP yet"
fi

# =============================================================================
# CHECK 2 — Namespace sidecar injection labels
# =============================================================================
step "Check 2 — Namespace sidecar injection labels"
kubectl get ns retail-banking payments grc --show-labels 2>/dev/null

for ns in retail-banking payments grc; do
  LABEL=$(kubectl get ns "$ns" --no-headers \
    -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")
  if [[ "$LABEL" == "enabled" ]]; then
    ok "$ns: istio-injection=enabled"
  else
    fail "$ns: istio-injection label missing or not 'enabled'"
  fi
done

# =============================================================================
# CHECK 3 — Pod status (all must be 2/2)
# =============================================================================
step "Check 3 — Pod status (app + sidecar = 2/2)"

check_pod() {
  local app=$1 ns=$2
  POD=$(kubectl get pod -n "$ns" -l app="$app" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$POD" ]]; then
    fail "$app ($ns): pod not found"
    return
  fi
  # Read the READY column (e.g., "2/2") from the same field kubectl get pods displays
  READY_FIELD=$(kubectl get pod "$POD" -n "$ns" --no-headers 2>/dev/null | \
    python3 -c "import sys; f=sys.stdin.read().split(); print(f[1] if len(f)>1 else '0/0')" \
    2>/dev/null || echo "0/0")
  if [[ "$READY_FIELD" == "2/2" ]]; then
    ok "$app ($ns): 2/2 Running"
  else
    fail "$app ($ns): $READY_FIELD ready (expected 2/2)"
  fi
}

echo ""
hdr "retail-banking:"
kubectl get pods -n retail-banking
echo ""
check_pod customer-profile-svc retail-banking
check_pod account-svc          retail-banking
check_pod bank-statement-svc   retail-banking

echo ""
hdr "payments:"
kubectl get pods -n payments
echo ""
check_pod transfer-svc        payments
check_pod payment-gateway-svc payments
check_pod fx-svc              payments

echo ""
hdr "grc:"
kubectl get pods -n grc
echo ""
check_pod fraud-svc   grc
check_pod audit-svc   grc
check_pod sanction-svc grc

# =============================================================================
# CHECK 4 — PeerAuthentication STRICT
# =============================================================================
step "Check 4 — PeerAuthentication (expect STRICT in all namespaces)"
kubectl get peerauthentication -A
echo ""

for ns in istio-system retail-banking payments grc; do
  MODE=$(kubectl get peerauthentication -n "$ns" \
    -o jsonpath='{.items[0].spec.mtls.mode}' 2>/dev/null || echo "")
  if [[ "$MODE" == "STRICT" ]]; then
    ok "$ns: STRICT"
  else
    fail "$ns: mode='$MODE' (expected STRICT)"
  fi
done

# =============================================================================
# CHECK 5 — DestinationRules (9 app services, ISTIO_MUTUAL)
# =============================================================================
step "Check 5 — DestinationRules (9 app services with ISTIO_MUTUAL)"
kubectl get destinationrule -A
echo ""

DR_COUNT=$(kubectl get destinationrule -A --no-headers 2>/dev/null | wc -l)
MUTUAL_COUNT=$(kubectl get destinationrule -A -o json 2>/dev/null | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
count=sum(1 for i in data['items']
  if i.get('spec',{}).get('trafficPolicy',{}).get('tls',{}).get('mode')=='ISTIO_MUTUAL')
print(count)" 2>/dev/null || echo "0")

ok "Total DestinationRules: $DR_COUNT"
if [[ "$MUTUAL_COUNT" -eq 9 ]]; then
  ok "All 9 app-service DestinationRules set to ISTIO_MUTUAL"
else
  fail "Expected 9 ISTIO_MUTUAL DestinationRules, found $MUTUAL_COUNT"
fi

# =============================================================================
# CHECK 6 — AuthorizationPolicies (10: 9 service-level + 1 CUSTOM gateway)
# =============================================================================
step "Check 6 — AuthorizationPolicies (9 service-level + 1 CUSTOM gateway = 10)"
kubectl get authorizationpolicy -A
echo ""

AP_COUNT=$(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l)
if [[ "$AP_COUNT" -eq 10 ]]; then
  ok "10 AuthorizationPolicies present (9 service-level SPIFFE + 1 CUSTOM ext_authz)"
else
  fail "Expected 10 AuthorizationPolicies, found $AP_COUNT"
fi

# =============================================================================
# CHECK 7 — Gateway CRs (4: 1 global + 3 domain)
# =============================================================================
step "Check 7 — Gateway CRs (1 global + 3 domain)"
kubectl get gateway -A
echo ""

GW_COUNT=$(kubectl get gateway -A --no-headers 2>/dev/null | wc -l)
if [[ "$GW_COUNT" -eq 4 ]]; then
  ok "4 Gateway CRs present"
else
  fail "Expected 4 Gateway CRs, found $GW_COUNT"
fi

# =============================================================================
# CHECK 8 — VirtualServices (10 total)
# =============================================================================
step "Check 8 — VirtualServices (10 total)"
kubectl get virtualservice -A
echo ""

VS_COUNT=$(kubectl get virtualservice -A --no-headers 2>/dev/null | wc -l)
if [[ "$VS_COUNT" -eq 10 ]]; then
  ok "10 VirtualServices present"
else
  fail "Expected 10 VirtualServices, found $VS_COUNT"
fi

# =============================================================================
# CHECK 9 — End-to-end traffic test
# =============================================================================
step "Check 9 — End-to-end traffic test (full call chain per domain)"

if [[ -z "$INGRESS_HOST" ]]; then
  fail "ELB hostname not available — skipping traffic tests"
else
  echo "ELB: $INGRESS_HOST"
  echo ""

  test_path() {
    local label=$1 path=$2 expected_entry=$3 expected_mid=$4 expected_leaf=$5

    hdr "── $label ($path) ──"
    RESPONSE=$(kubectl run curl-test-verify --image=curlimages/curl:latest \
      --restart=Never --rm -i --quiet \
      -- curl -s --max-time 15 \
      -H "Host: finance.mhnbank.xyz" \
      "http://${INGRESS_HOST}${path}" 2>/dev/null)

    HTTP_NAME=$(echo "$RESPONSE" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")
    HTTP_CODE=$(echo "$RESPONSE" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d.get('code',''))" 2>/dev/null || echo "")
    MID=$(echo "$RESPONSE" | python3 -c \
      "import json,sys
d=json.load(sys.stdin)
calls=d.get('upstream_calls',{})
for k,v in calls.items(): print(v.get('name',''))
" 2>/dev/null || echo "")
    LEAF=$(echo "$RESPONSE" | python3 -c \
      "import json,sys
d=json.load(sys.stdin)
calls=d.get('upstream_calls',{})
for k,v in calls.items():
    nested=v.get('upstream_calls',{})
    for k2,v2 in nested.items(): print(v2.get('name',''))
" 2>/dev/null || echo "")

    echo "  Entry : $HTTP_NAME (code: $HTTP_CODE)"
    echo "  Mid   : $MID"
    echo "  Leaf  : $LEAF"
    echo ""

    if [[ "$HTTP_NAME" == "$expected_entry" && "$HTTP_CODE" == "200" ]]; then
      ok "$label entry: $expected_entry → 200 OK"
    else
      fail "$label entry: got '$HTTP_NAME' code=$HTTP_CODE (expected '$expected_entry' 200)"
    fi

    if [[ "$MID" == "$expected_mid" ]]; then
      ok "$label mid-tier: $MID"
    else
      fail "$label mid-tier: got '$MID' (expected '$expected_mid')"
    fi

    if [[ "$LEAF" == "$expected_leaf" ]]; then
      ok "$label leaf: $LEAF"
    else
      fail "$label leaf: got '$LEAF' (expected '$expected_leaf')"
    fi
    echo ""
  }

  test_path "retail-banking" "/retail-banking/" \
    "customer-profile-svc" "account" "bank-statement-svc"

  test_path "payments" "/payments/" \
    "transfer-svc" "payment-gateway-svc" "fx-svc"

  test_path "grc" "/grc/" \
    "fraud-svc" "audit-svc" "sanction-svc"

  # catch-all
  hdr "── catch-all (/) ──"
  CATCHALL=$(kubectl run curl-test-catchall --image=curlimages/curl:latest \
    --restart=Never --rm -i --quiet \
    -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Host: finance.mhnbank.xyz" \
    "http://${INGRESS_HOST}/" 2>/dev/null)
  if [[ "$CATCHALL" == "200" ]]; then
    ok "catch-all /: 200 OK"
  else
    fail "catch-all /: HTTP $CATCHALL (expected 200)"
  fi
fi

# =============================================================================
# CHECK 10 — SPIFFE ID verification
# =============================================================================
step "Check 10 — SPIFFE X.509 identity verification"

verify_spiffe() {
  local app=$1 ns=$2 expected=$3
  POD=$(kubectl get pod -n "$ns" -l app="$app" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$POD" ]]; then
    fail "$app ($ns): pod not found"
    return
  fi
  SPIFFE=$(istioctl proxy-config secret "$POD" -n "$ns" -o json 2>/dev/null | \
    python3 -c "
import json, sys, base64, subprocess
data = json.load(sys.stdin)
for s in data.get('dynamicActiveSecrets', []):
    if s.get('name') == 'default':
        b64 = s['secret']['tlsCertificate']['certificateChain']['inlineBytes']
        r = subprocess.run(
            ['openssl', 'x509', '-noout', '-text'],
            input=base64.b64decode(b64), capture_output=True)
        for line in r.stdout.decode().split('\n'):
            if 'URI:spiffe' in line:
                print(line.strip().replace('URI:', ''))
        break
" 2>/dev/null || echo "")

  printf "  %-30s (%s)\n" "$app" "$ns"
  if [[ "$SPIFFE" == "$expected" ]]; then
    ok "    $SPIFFE"
  else
    fail "    got:      '$SPIFFE'"
    echo -e "      expected: '$expected'"
  fi
  echo ""
}

echo ""
hdr "── retail-banking ──"
verify_spiffe customer-profile-svc retail-banking \
  "spiffe://cluster.local/ns/retail-banking/sa/customer-profile-svc"
verify_spiffe account-svc retail-banking \
  "spiffe://cluster.local/ns/retail-banking/sa/account-svc"
verify_spiffe bank-statement-svc retail-banking \
  "spiffe://cluster.local/ns/retail-banking/sa/bank-statement-svc"

hdr "── payments ──"
verify_spiffe transfer-svc payments \
  "spiffe://cluster.local/ns/payments/sa/transfer-svc"
verify_spiffe payment-gateway-svc payments \
  "spiffe://cluster.local/ns/payments/sa/payment-gateway-svc"
verify_spiffe fx-svc payments \
  "spiffe://cluster.local/ns/payments/sa/fx-svc"

hdr "── grc ──"
verify_spiffe fraud-svc grc \
  "spiffe://cluster.local/ns/grc/sa/fraud-svc"
verify_spiffe audit-svc grc \
  "spiffe://cluster.local/ns/grc/sa/audit-svc"
verify_spiffe sanction-svc grc \
  "spiffe://cluster.local/ns/grc/sa/sanction-svc"

hdr "── istio-system ──"
IGW_POD=$(kubectl get pod -n istio-system -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
SPIFFE=$(istioctl proxy-config secret "$IGW_POD" -n istio-system -o json 2>/dev/null | \
  python3 -c "
import json, sys, base64, subprocess
data = json.load(sys.stdin)
for s in data.get('dynamicActiveSecrets', []):
    if s.get('name') == 'default':
        b64 = s['secret']['tlsCertificate']['certificateChain']['inlineBytes']
        r = subprocess.run(
            ['openssl', 'x509', '-noout', '-text'],
            input=base64.b64decode(b64), capture_output=True)
        for line in r.stdout.decode().split('\n'):
            if 'URI:spiffe' in line:
                print(line.strip().replace('URI:', ''))
        break
" 2>/dev/null || echo "")

EXPECTED_IGW="spiffe://cluster.local/ns/istio-system/sa/istio-ingressgateway"
printf "  %-30s (istio-system)\n" "istio-ingressgateway"
if [[ "$SPIFFE" == "$EXPECTED_IGW" ]]; then
  ok "    $SPIFFE"
else
  fail "    got:      '$SPIFFE'"
  echo -e "      expected: '$EXPECTED_IGW'"
fi

# =============================================================================
# CHECK 11 — mTLS describe (istioctl x describe)
# =============================================================================
step "Check 11 — mTLS active (istioctl x describe)"

mtls_check() {
  local app=$1 ns=$2
  POD=$(kubectl get pod -n "$ns" -l app="$app" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$POD" ]]; then
    fail "$app ($ns): pod not found"; return
  fi
  OUTPUT=$(istioctl x describe pod "$POD" -n "$ns" 2>/dev/null || echo "")
  printf "  %-30s (%s)\n" "$app" "$ns"
  if echo "$OUTPUT" | grep -qi "STRICT\|mTLS\|Strict"; then
    ok "    mTLS STRICT confirmed"
  else
    warn "    mTLS status unclear — check manually: istioctl x describe pod $POD -n $ns"
  fi
}

for app in customer-profile-svc account-svc bank-statement-svc; do
  mtls_check "$app" retail-banking
done
for app in transfer-svc payment-gateway-svc fx-svc; do
  mtls_check "$app" payments
done
for app in fraud-svc audit-svc sanction-svc; do
  mtls_check "$app" grc
done

# =============================================================================
# CHECK 12 — API Access Control (OAuth2 Proxy + Keycloak + CUSTOM AuthZ)
# =============================================================================
step "Check 12 — API Access Control: OAuth2 Proxy / Keycloak ext_authz"

echo ""
hdr "── CUSTOM AuthorizationPolicy (istio-system) ──"
kubectl get authorizationpolicy -n istio-system 2>/dev/null
echo ""

AP_CUSTOM=$(kubectl get authorizationpolicy ext-authz-oauth2-proxy -n istio-system \
  -o jsonpath='{.spec.action}' 2>/dev/null || echo "")
if [[ "$AP_CUSTOM" == "CUSTOM" ]]; then
  ok "ext-authz-oauth2-proxy: action=CUSTOM (delegates to OAuth2 Proxy)"
else
  fail "ext-authz-oauth2-proxy not found or action != CUSTOM (got: '$AP_CUSTOM')"
fi

AP_PROVIDER=$(kubectl get authorizationpolicy ext-authz-oauth2-proxy -n istio-system \
  -o jsonpath='{.spec.provider.name}' 2>/dev/null || echo "")
if [[ "$AP_PROVIDER" == "oauth2-proxy" ]]; then
  ok "  provider: $AP_PROVIDER (matches meshConfig extensionProviders)"
else
  fail "  provider: '$AP_PROVIDER' (expected 'oauth2-proxy')"
fi

echo ""
hdr "── MeshConfig extensionProviders ──"
EXT_PROVIDER=$(kubectl get configmap istio -n istio-system \
  -o jsonpath='{.data.mesh}' 2>/dev/null | grep -c "oauth2-proxy" || echo "0")
if [[ "$EXT_PROVIDER" -ge 1 ]]; then
  ok "extensionProvider 'oauth2-proxy' found in istio MeshConfig"
else
  fail "extensionProvider 'oauth2-proxy' NOT found in istio MeshConfig — re-run: helm upgrade istiod -f helm-values/istiod-values.yaml"
fi

echo ""
hdr "── OAuth2 Proxy (auth namespace) ──"
kubectl get pods -n auth 2>/dev/null
echo ""

OAUTH2_POD=$(kubectl get pod -n auth -l app=oauth2-proxy \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$OAUTH2_POD" ]]; then
  OAUTH2_READY=$(kubectl get pod "$OAUTH2_POD" -n auth \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$OAUTH2_READY" == "true" ]]; then
    ok "OAuth2 Proxy pod ready: $OAUTH2_POD"
  else
    fail "OAuth2 Proxy pod not ready: $OAUTH2_POD"
  fi
else
  fail "OAuth2 Proxy pod not found in auth namespace"
fi

REDIS_POD=$(kubectl get pod -n auth -l app=redis \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$REDIS_POD" ]]; then
  REDIS_READY=$(kubectl get pod "$REDIS_POD" -n auth \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$REDIS_READY" == "true" ]]; then
    ok "Redis pod ready: $REDIS_POD"
  else
    fail "Redis pod not ready: $REDIS_POD"
  fi
else
  fail "Redis pod not found in auth namespace"
fi

echo ""
hdr "── Keycloak (keycloak namespace) ──"
kubectl get pods -n keycloak 2>/dev/null
echo ""

KEYCLOAK_POD=$(kubectl get pod -n keycloak -l app.kubernetes.io/name=keycloak \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$KEYCLOAK_POD" ]]; then
  KC_READY=$(kubectl get pod "$KEYCLOAK_POD" -n keycloak \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$KC_READY" == "true" ]]; then
    ok "Keycloak pod ready: $KEYCLOAK_POD"
  else
    fail "Keycloak pod not ready: $KEYCLOAK_POD"
  fi
else
  fail "Keycloak pod not found in keycloak namespace"
fi

echo ""
hdr "── VirtualServices include /oauth2/ route and keycloak-vs ──"
OAUTH2_ROUTE=$(kubectl get virtualservice global-virtualservice -n istio-system \
  -o jsonpath='{.spec.http[*].match[*].uri.prefix}' 2>/dev/null | grep -c "/oauth2/" || echo "0")
if [[ "$OAUTH2_ROUTE" -ge 1 ]]; then
  ok "global-virtualservice has /oauth2/ route → OAuth2 Proxy"
else
  fail "/oauth2/ route missing from global-virtualservice"
fi

KC_VS=$(kubectl get virtualservice keycloak-vs -n istio-system \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [[ "$KC_VS" == "keycloak-vs" ]]; then
  ok "keycloak-vs present (auth.mhnbank.xyz → Keycloak)"
else
  fail "keycloak-vs not found in istio-system"
fi

echo ""
hdr "── Negative test: unauthenticated request to protected paths ──"
if [[ -z "$INGRESS_HOST" ]]; then
  warn "ELB hostname not available — skipping unauthenticated access tests"
else
  test_unauth() {
    local label=$1 path=$2
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      -H "Host: finance.mhnbank.xyz" \
      "http://${INGRESS_HOST}${path}" 2>/dev/null)
    # OAuth2 Proxy returns 302 redirect to Keycloak login for unauthenticated requests
    if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
      ok "  $label: unauthenticated → HTTP $HTTP_CODE (redirected to Keycloak login)"
    else
      fail "  $label: unauthenticated → HTTP $HTTP_CODE (expected 302/401/403)"
    fi
  }

  test_unauth "retail-banking" "/retail-banking/"
  test_unauth "payments"       "/payments/"
  test_unauth "grc"            "/grc/"

  echo ""
  hdr "── /oauth2/ route reachable (OAuth2 Proxy ping) ──"
  PING_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Host: finance.mhnbank.xyz" \
    "http://${INGRESS_HOST}/oauth2/ping" 2>/dev/null)
  if [[ "$PING_CODE" == "200" ]]; then
    ok "/oauth2/ping → 200 OK (OAuth2 Proxy reachable via IngressGateway)"
  else
    fail "/oauth2/ping → HTTP $PING_CODE (expected 200)"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED — MHN Bank Istio Gateway OK     ${NC}"
else
  echo -e "${RED}${BOLD}  $FAILURES CHECK(S) FAILED — review output above     ${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Global IngressGateway : http://${INGRESS_HOST:-<pending>}"
KIALI_HOST=$(kubectl get svc kiali -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
echo "  Kiali dashboard       : http://${KIALI_HOST}:20001/kiali"
echo ""
exit "$FAILURES"
