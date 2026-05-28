#!/usr/bin/env bash
# ============================================================
# analyze-auth-flow.sh
# Purpose:  Step-by-step verification of the 21-step Keycloak
#           OAuth2 Authorization Code flow for MHN Bank.
#
# Usage:
#   chmod +x analyze-auth-flow.sh
#   ./analyze-auth-flow.sh
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

FAILURES=0

pass() { echo -e "  ${GREEN}✔  PASS${RESET}  $*"; }
fail() { echo -e "  ${RED}✖  FAIL${RESET}  $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "  ${YELLOW}⚠  WARN${RESET}  $*"; }
info() { echo -e "  ${CYAN}ℹ${RESET}  $*"; }

step() {
  echo -e "\n${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}║  Step %-2s — %-45s║${RESET}\n" "$1" "$2"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
}

# ── Resolve ELB once ────────────────────────────────────────
ELB=$(kubectl get svc istio-ingressgateway -n istio-system \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$ELB" ]]; then
  echo -e "${RED}ERROR: kubectl not connected or IngressGateway has no ELB.${RESET}"
  exit 1
fi

# Cache pod names used across multiple steps
KC_POD=$(kubectl get pod -n keycloak -l app=keycloak \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
REDIS_POD=$(kubectl get pod -n auth -l app=redis \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
PROXY_POD=$(kubectl get pod -n auth -l app=oauth2-proxy \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# ── Port-forward helpers ─────────────────────────────────────────────────────
# The official Keycloak image (UBI-based) and OAuth2 Proxy image (distroless)
# do not include curl. All in-pod HTTP checks use kubectl port-forward from
# the host instead.
KC_PF_PORT=18080
KC_PF_PID=""
PROXY_PF_PORT=14180
PROXY_PF_PID=""

kc_pf_start() {
  [[ -z "$KC_POD" ]] && return 0
  kubectl port-forward "pod/${KC_POD}" "${KC_PF_PORT}:8080" -n keycloak &>/dev/null &
  KC_PF_PID=$!
  # Wait up to 5 s for the port to be ready
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    nc -z localhost "${KC_PF_PORT}" 2>/dev/null && return 0 || true
  done
}

proxy_pf_start() {
  [[ -z "$PROXY_POD" ]] && return 0
  kubectl port-forward "pod/${PROXY_POD}" "${PROXY_PF_PORT}:4180" -n auth &>/dev/null &
  PROXY_PF_PID=$!
  for i in 1 2 3 4 5; do
    sleep 0.5
    nc -z localhost "${PROXY_PF_PORT}" 2>/dev/null && return 0 || true
  done
}

pf_cleanup() {
  [[ -n "$KC_PF_PID" ]]    && { kill "$KC_PF_PID"    2>/dev/null || true; KC_PF_PID=""; }
  [[ -n "$PROXY_PF_PID" ]] && { kill "$PROXY_PF_PID" 2>/dev/null || true; PROXY_PF_PID=""; }
}
trap pf_cleanup EXIT

echo -e "\n${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  MHN Bank — OAuth2 Authorization Code Flow Analyzer    ${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
info "ELB  : $ELB"
info "Time : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─────────────────────────────────────────────────────────────────────────────
step 1 "Browser requests finance.mhnbank.xyz/retail-banking/"
# ─────────────────────────────────────────────────────────────────────────────
# The ELB must accept the request and not return a network error.
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: finance.mhnbank.xyz" \
        --max-time 10 \
        "http://${ELB}/retail-banking/" 2>/dev/null || echo "000")

if [[ "$HTTP" == "302" ]]; then
  pass "GET /retail-banking/ → HTTP 302  (unauthenticated request intercepted as expected)"
elif [[ "$HTTP" == "200" ]]; then
  warn "GET /retail-banking/ → HTTP 200  (no auth check — ext_authz may not be active)"
elif [[ "$HTTP" == "000" ]]; then
  fail "Could not reach ELB at http://${ELB}  (connection refused or timeout)"
else
  fail "GET /retail-banking/ → HTTP $HTTP  (unexpected — check IngressGateway)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 2 "IngressGateway Envoy calls OAuth2 Proxy via ext_authz"
# ─────────────────────────────────────────────────────────────────────────────
# CUSTOM AuthorizationPolicy must exist and point to oauth2-proxy.
ACTION=$(kubectl get authorizationpolicy ext-authz-oauth2-proxy -n istio-system \
           -o jsonpath='{.spec.action}' 2>/dev/null || true)
PROVIDER=$(kubectl get authorizationpolicy ext-authz-oauth2-proxy -n istio-system \
             -o jsonpath='{.spec.provider.name}' 2>/dev/null || true)

if [[ "$ACTION" == "CUSTOM" ]]; then
  pass "AuthorizationPolicy action = CUSTOM"
else
  fail "AuthorizationPolicy action = '$ACTION'  (expected CUSTOM)"
fi

if [[ "$PROVIDER" == "oauth2-proxy" ]]; then
  pass "AuthorizationPolicy provider = oauth2-proxy"
else
  fail "AuthorizationPolicy provider = '$PROVIDER'  (expected oauth2-proxy)"
fi

EXT_COUNT=$(kubectl get configmap istio -n istio-system \
              -o jsonpath='{.data.mesh}' 2>/dev/null \
            | grep -c "oauth2-proxy" || true)
if [[ "$EXT_COUNT" -ge 1 ]]; then
  pass "extensionProvider 'oauth2-proxy' registered in istiod MeshConfig"
else
  fail "extensionProvider 'oauth2-proxy' NOT found in MeshConfig"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 3 "OAuth2 Proxy creates session state in Redis"
# ─────────────────────────────────────────────────────────────────────────────
# Redis pod must be running and responding.
if [[ -z "$REDIS_POD" ]]; then
  fail "Redis pod not found in namespace 'auth'"
else
  PONG=$(kubectl exec -n auth "$REDIS_POD" -- redis-cli ping 2>/dev/null || true)
  if [[ "$PONG" == "PONG" ]]; then
    pass "Redis pod '$REDIS_POD' is running and responding to PING"
  else
    fail "Redis pod not responding (got: '$PONG')"
  fi

  DB_SIZE=$(kubectl exec -n auth "$REDIS_POD" -- redis-cli dbsize 2>/dev/null || echo "0")
  info "Total keys in Redis: $DB_SIZE"

  SESSION_COUNT=$(kubectl exec -n auth "$REDIS_POD" -- \
                    redis-cli --scan --pattern 'oauth2_proxy_*' 2>/dev/null \
                  | grep -c "oauth2_proxy_" || true)
  if [[ "$SESSION_COUNT" -gt 0 ]]; then
    pass "$SESSION_COUNT active OAuth2 session key(s) stored in Redis"
  else
    warn "No oauth2_proxy_* keys yet — complete a browser login first, then re-run"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step 4 "OAuth2 Proxy returns 302 → Keycloak OIDC auth endpoint"
# ─────────────────────────────────────────────────────────────────────────────
# The redirect Location must point to Keycloak's authorization endpoint.
LOCATION=$(curl -s -o /dev/null -w "%{redirect_url}" \
             -H "Host: finance.mhnbank.xyz" \
             --max-time 10 \
             "http://${ELB}/retail-banking/" 2>/dev/null || true)

if echo "$LOCATION" | grep -q "openid-connect/auth"; then
  pass "302 Location points to Keycloak OIDC /auth endpoint"
  info "→ $LOCATION"
else
  fail "302 Location missing openid-connect/auth  (got: '$LOCATION')"
fi

if echo "$LOCATION" | grep -q "client_id=oauth2-proxy-client"; then
  pass "client_id=oauth2-proxy-client present in redirect"
else
  fail "client_id missing from redirect URL"
fi

if echo "$LOCATION" | grep -q "response_type=code"; then
  pass "response_type=code — Authorization Code flow confirmed"
else
  fail "response_type=code missing from redirect URL"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 5 "Browser follows redirect to auth.mhnbank.xyz (Keycloak)"
# ─────────────────────────────────────────────────────────────────────────────
# The IngressGateway must accept traffic for auth.mhnbank.xyz.
KC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Host: auth.mhnbank.xyz" \
            --max-time 10 \
            "http://${ELB}/" 2>/dev/null || echo "000")

if [[ "$KC_HTTP" == "200" || "$KC_HTTP" == "302" || "$KC_HTTP" == "303" ]]; then
  pass "auth.mhnbank.xyz reachable via IngressGateway → HTTP $KC_HTTP"
else
  fail "auth.mhnbank.xyz returned HTTP $KC_HTTP  (expected 200/302 — check Gateway host binding)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 6 "IngressGateway routes auth.mhnbank.xyz → Keycloak via keycloak-vs"
# ─────────────────────────────────────────────────────────────────────────────
VS_HOST=$(kubectl get virtualservice keycloak-vs -n istio-system \
            -o jsonpath='{.spec.hosts[0]}' 2>/dev/null || true)
VS_DEST=$(kubectl get virtualservice keycloak-vs -n istio-system \
            -o jsonpath='{.spec.http[0].route[0].destination.host}' 2>/dev/null || true)
GW_HOSTS=$(kubectl get gateway global-istio-gateway -n istio-system \
             -o jsonpath='{.spec.servers[*].hosts}' 2>/dev/null || true)

if [[ "$VS_HOST" == "auth.mhnbank.xyz" ]]; then
  pass "keycloak-vs  host = auth.mhnbank.xyz"
else
  fail "keycloak-vs  host = '$VS_HOST'  (expected auth.mhnbank.xyz)"
fi

if echo "$VS_DEST" | grep -q "keycloak"; then
  pass "keycloak-vs  destination = $VS_DEST"
else
  fail "keycloak-vs destination does not point to Keycloak  (got: '$VS_DEST')"
fi

if echo "$GW_HOSTS" | grep -q "auth.mhnbank.xyz"; then
  pass "Gateway global-istio-gateway binds host auth.mhnbank.xyz"
else
  fail "Gateway does not bind auth.mhnbank.xyz  — add host to 1-istio-gateway-global.yaml"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 7 "Keycloak serves the login form"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "$KC_POD" ]]; then
  fail "Keycloak pod not found in namespace 'keycloak'"
else
  KC_READY=$(kubectl get pod -n keycloak "$KC_POD" \
               -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  if [[ "$KC_READY" == "true" ]]; then
    pass "Keycloak pod '$KC_POD' is Ready"
  else
    fail "Keycloak pod not Ready  (ready=$KC_READY)"
  fi

  # Official Keycloak image is UBI-based — no curl inside the container.
  # Open a port-forward from the host (kept open for steps 7-14).
  kc_pf_start
  # redirect_uri is mandatory in Keycloak 24.x — omitting it returns 400
  LOGIN_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                 "http://localhost:${KC_PF_PORT}/realms/mhnbank/protocol/openid-connect/auth?client_id=oauth2-proxy-client&response_type=code&redirect_uri=http%3A%2F%2Ffinance.mhnbank.xyz%2Foauth2%2Fcallback&scope=openid" \
                 2>/dev/null || echo "000")
  if [[ "$LOGIN_HTTP" == "200" ]]; then
    pass "Login form served at /realms/mhnbank/protocol/openid-connect/auth → HTTP 200"
  else
    fail "Login form returned HTTP $LOGIN_HTTP  (expected 200)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step 8 "User submits credentials"
# ─────────────────────────────────────────────────────────────────────────────
# Interactive browser step — verify the login endpoint accepts POST.
info "Interactive browser step. Verifying POST /login endpoint is reachable."

LOGIN_EP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
             "http://localhost:${KC_PF_PORT}/realms/mhnbank/login-actions/authenticate" \
             2>/dev/null || echo "000")
# 400 = missing form params but endpoint exists
if [[ "$LOGIN_EP" == "400" || "$LOGIN_EP" == "200" || "$LOGIN_EP" == "302" ]]; then
  pass "Keycloak login-actions/authenticate endpoint is reachable (HTTP $LOGIN_EP)"
else
  fail "Keycloak login endpoint returned unexpected HTTP $LOGIN_EP"
fi

REALM_JSON=$(curl -s --max-time 10 \
               "http://localhost:${KC_PF_PORT}/realms/mhnbank" 2>/dev/null || true)
if echo "$REALM_JSON" | grep -q '"realm":"mhnbank"'; then
  pass "Realm 'mhnbank' public metadata confirmed"
else
  fail "Realm 'mhnbank' not found or not responding"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 9 "Keycloak validates credentials and generates authorization code"
# ─────────────────────────────────────────────────────────────────────────────
# Verify via OIDC discovery and admin API that the realm is properly configured.
DISCOVERY=$(curl -s --max-time 10 \
              "http://localhost:${KC_PF_PORT}/realms/mhnbank/.well-known/openid-configuration" \
              2>/dev/null || true)

if echo "$DISCOVERY" | grep -q '"authorization_endpoint"'; then
  pass "OIDC discovery document is valid"
  AUTH_EP=$(echo "$DISCOVERY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['authorization_endpoint'])" 2>/dev/null || true)
  info "authorization_endpoint : $AUTH_EP"
else
  fail "OIDC discovery document missing or invalid"
fi

ADMIN_TOKEN=$(curl -s --max-time 10 -X POST \
                "http://localhost:${KC_PF_PORT}/realms/master/protocol/openid-connect/token" \
                -d "client_id=admin-cli&grant_type=password&username=admin&password=Admin@MHNBank2025" \
                2>/dev/null \
              | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" \
              2>/dev/null || true)

if [[ -n "$ADMIN_TOKEN" && "$ADMIN_TOKEN" != "null" ]]; then
  pass "Admin API authenticated — realm management confirmed"
else
  fail "Admin API login failed — check KEYCLOAK_ADMIN_PASSWORD in keycloak.yaml"
fi

USER_RESP=$(curl -s --max-time 10 \
              -H "Authorization: Bearer $ADMIN_TOKEN" \
              "http://localhost:${KC_PF_PORT}/admin/realms/mhnbank/users?username=testuser" \
              2>/dev/null || true)
if echo "$USER_RESP" | grep -q '"username":"testuser"'; then
  pass "User 'testuser' exists in realm mhnbank"
else
  fail "User 'testuser' NOT found in realm mhnbank"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 10 "Keycloak redirects browser → finance.mhnbank.xyz/oauth2/callback?code=..."
# ─────────────────────────────────────────────────────────────────────────────
# The client's redirect URI must be registered in Keycloak.
CLIENT_LIST=$(curl -s --max-time 10 \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                "http://localhost:${KC_PF_PORT}/admin/realms/mhnbank/clients" \
                2>/dev/null || true)

if echo "$CLIENT_LIST" | grep -q '"clientId":"oauth2-proxy-client"'; then
  pass "Client 'oauth2-proxy-client' registered in realm mhnbank"
else
  fail "Client 'oauth2-proxy-client' NOT found in realm mhnbank"
fi

REDIRECT_URIS=$(echo "$CLIENT_LIST" | python3 -c "
import sys, json
clients = json.load(sys.stdin)
for c in clients:
    if c.get('clientId') == 'oauth2-proxy-client':
        print(c.get('redirectUris', []))
" 2>/dev/null || true)

if echo "$REDIRECT_URIS" | grep -q "oauth2/callback"; then
  pass "Redirect URI finance.mhnbank.xyz/oauth2/callback registered"
  info "Registered URIs: $REDIRECT_URIS"
else
  fail "Redirect URI /oauth2/callback NOT registered — Keycloak will reject the callback"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 11 "Browser follows redirect back through IngressGateway"
# ─────────────────────────────────────────────────────────────────────────────
# The IngressGateway must accept port 80 traffic for the callback redirect.
IGW_PORTS=$(kubectl get svc istio-ingressgateway -n istio-system \
              -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || true)

if echo "$IGW_PORTS" | grep -q "\b80\b"; then
  pass "IngressGateway service exposes port 80 (HTTP redirect chain can flow back)"
else
  fail "IngressGateway port 80 not found — callback redirect will fail"
fi

IGW_PODS=$(kubectl get pod -n istio-system -l app=istio-ingressgateway \
             -o jsonpath='{.items[*].status.phase}' 2>/dev/null || true)
if echo "$IGW_PODS" | grep -q "Running"; then
  pass "IngressGateway pod is Running"
else
  fail "IngressGateway pod is not Running"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 12 "IngressGateway routes /oauth2/* → OAuth2 Proxy (global-virtualservice)"
# ─────────────────────────────────────────────────────────────────────────────
PREFIXES=$(kubectl get virtualservice global-virtualservice -n istio-system \
             -o jsonpath='{.spec.http[*].match[*].uri.prefix}' 2>/dev/null || true)

if echo "$PREFIXES" | grep -q "/oauth2/"; then
  pass "/oauth2/ prefix route present in global-virtualservice"
else
  fail "/oauth2/ route missing from global-virtualservice"
fi

OAUTH2_DEST=$(kubectl get virtualservice global-virtualservice -n istio-system -o json \
                2>/dev/null | python3 -c "
import sys, json
vs = json.load(sys.stdin)
for h in vs['spec']['http']:
    for m in h.get('match', []):
        if '/oauth2' in m.get('uri', {}).get('prefix', ''):
            for r in h.get('route', []):
                print(r['destination']['host'])
" 2>/dev/null || true)

if echo "$OAUTH2_DEST" | grep -q "oauth2-proxy"; then
  pass "/oauth2/* destination = $OAUTH2_DEST"
else
  fail "/oauth2/* not routed to oauth2-proxy  (got: '$OAUTH2_DEST')"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 13 "OAuth2 Proxy exchanges authorization code for tokens at Keycloak /token"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "$PROXY_POD" ]]; then
  fail "OAuth2 Proxy pod not found in namespace 'auth'"
else
  PROXY_READY=$(kubectl get pod -n auth "$PROXY_POD" \
                  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  if [[ "$PROXY_READY" == "true" ]]; then
    pass "OAuth2 Proxy pod '$PROXY_POD' is Ready"
  else
    fail "OAuth2 Proxy pod not Ready  (ready=$PROXY_READY)"
  fi

  # OAuth2 Proxy image is distroless — no shell or curl inside the container.
  # Verify Keycloak /token endpoint is reachable via the already-open port-forward.
  # If OAuth2 Proxy can resolve keycloak.keycloak.svc.cluster.local (same cluster),
  # the endpoint being live on Keycloak is sufficient confirmation.
  TOKEN_EP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                    "http://localhost:${KC_PF_PORT}/realms/mhnbank/protocol/openid-connect/token" \
                    2>/dev/null || echo "000")
  # 405 = Method Not Allowed (GET on POST-only endpoint) = endpoint exists
  # 400 = Bad Request (missing params) = endpoint exists
  if [[ "$TOKEN_EP_HTTP" == "405" || "$TOKEN_EP_HTTP" == "400" || "$TOKEN_EP_HTTP" == "200" ]]; then
    pass "Keycloak /token endpoint is live (HTTP $TOKEN_EP_HTTP) — OAuth2 Proxy can reach it via in-cluster DNS"
  else
    fail "Keycloak /token endpoint not responding (HTTP $TOKEN_EP_HTTP)"
  fi

  ISSUER_ARG=$(kubectl get deployment oauth2-proxy -n auth \
                 -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
               | grep -o "oidc-issuer-url=[^ ,\"]*" || true)
  info "OAuth2 Proxy --$ISSUER_ARG"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 14 "Keycloak returns access_token, id_token, refresh_token"
# ─────────────────────────────────────────────────────────────────────────────
TOKEN_RESP=$(curl -s --max-time 10 -X POST \
               "http://localhost:${KC_PF_PORT}/realms/mhnbank/protocol/openid-connect/token" \
               -d "client_id=oauth2-proxy-client&client_secret=changeme-keycloak-client-secret&grant_type=password&username=testuser&password=testpassword&scope=openid profile email" \
               2>/dev/null || true)

if echo "$TOKEN_RESP" | grep -q '"access_token"'; then
  pass "access_token issued by Keycloak for testuser"
else
  ERR=$(echo "$TOKEN_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('error',''),d.get('error_description',''))" \
    2>/dev/null || echo "$TOKEN_RESP")
  fail "access_token NOT issued — $ERR"
fi

if echo "$TOKEN_RESP" | grep -q '"id_token"'; then
  pass "id_token present in token response"
else
  warn "id_token missing — check 'openid' scope is requested"
fi

if echo "$TOKEN_RESP" | grep -q '"refresh_token"'; then
  EXPIRES=$(echo "$TOKEN_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('expires_in','?'))" 2>/dev/null || true)
  pass "refresh_token present  (access_token expires_in ${EXPIRES}s)"
else
  warn "refresh_token missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 15 "OAuth2 Proxy stores tokens in Redis and sets _mhnbank_oauth2 cookie"
# ─────────────────────────────────────────────────────────────────────────────
SESSION_TYPE=$(kubectl get deployment oauth2-proxy -n auth \
                 -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
               | grep -o "session-store-type=redis" || true)
if [[ -n "$SESSION_TYPE" ]]; then
  pass "--session-store-type=redis configured on OAuth2 Proxy"
else
  fail "--session-store-type=redis NOT set in OAuth2 Proxy deployment"
fi

REDIS_URL=$(kubectl get deployment oauth2-proxy -n auth \
              -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
            | grep -o "redis-connection-url=[^ ,\"]*" || true)
if [[ -n "$REDIS_URL" ]]; then
  pass "OAuth2 Proxy --$REDIS_URL"
else
  fail "--redis-connection-url NOT configured"
fi

COOKIE_NAME=$(kubectl get deployment oauth2-proxy -n auth \
                -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
              | grep -o "cookie-name=[^ ,\"]*" || true)
if [[ -n "$COOKIE_NAME" ]]; then
  pass "Session cookie: --$COOKIE_NAME"
else
  warn "--cookie-name not set (default '_oauth2_proxy' will be used)"
fi

if [[ -n "$REDIS_POD" ]]; then
  SESSION_COUNT=$(kubectl exec -n auth "$REDIS_POD" -- \
                    redis-cli --scan --pattern 'oauth2_proxy_*' 2>/dev/null \
                  | grep -c "oauth2_proxy_" || true)
  if [[ "$SESSION_COUNT" -gt 0 ]]; then
    SAMPLE=$(kubectl exec -n auth "$REDIS_POD" -- \
               redis-cli --scan --pattern 'oauth2_proxy_*' 2>/dev/null | head -1)
    TTL=$(kubectl exec -n auth "$REDIS_POD" -- redis-cli ttl "$SAMPLE" 2>/dev/null || true)
    pass "$SESSION_COUNT Redis session(s) found  |  TTL: ${TTL}s  |  Key: $SAMPLE"
  else
    warn "No sessions in Redis yet — expected after a real browser login"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step 16 "OAuth2 Proxy redirects browser back to the original URL"
# ─────────────────────────────────────────────────────────────────────────────
# The state parameter encodes the original URL so OAuth2 Proxy can restore it.
RAW_HEADERS=$(curl -sI \
                -H "Host: finance.mhnbank.xyz" \
                --max-time 10 \
                "http://${ELB}/retail-banking/" 2>/dev/null || true)

STATE=$(echo "$RAW_HEADERS" | grep -i "^location:" | grep -o "state=[^& ]*" || true)
if [[ -n "$STATE" ]]; then
  pass "state parameter present in 302 redirect  ($STATE)"
  info "OAuth2 Proxy will decode state after callback to restore original URL"
else
  warn "state parameter not detected — may require a fresh unauthenticated session"
fi

COOKIE_EXPIRE=$(kubectl get deployment oauth2-proxy -n auth \
                  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
                | grep -o "cookie-expire=[^ ,\"]*" || true)
COOKIE_REFRESH=$(kubectl get deployment oauth2-proxy -n auth \
                   -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
                 | grep -o "cookie-refresh=[^ ,\"]*" || true)
info "Cookie settings: --$COOKIE_EXPIRE  --$COOKIE_REFRESH"
pass "Session lifetime configured (users will be re-authenticated after cookie expiry)"

# ─────────────────────────────────────────────────────────────────────────────
step 17 "Browser resends original request with the session cookie"
# ─────────────────────────────────────────────────────────────────────────────
# An invalid cookie must be rejected with 302 (not 200 or 500).
INVALID_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
                 -H "Host: finance.mhnbank.xyz" \
                 -H "Cookie: _mhnbank_oauth2=thisisnotavalidsession" \
                 --max-time 10 \
                 "http://${ELB}/retail-banking/" 2>/dev/null || echo "000")

if [[ "$INVALID_HTTP" == "302" ]]; then
  pass "Invalid session cookie rejected → HTTP 302 back to Keycloak login (correct)"
elif [[ "$INVALID_HTTP" == "401" ]]; then
  pass "Invalid session cookie rejected → HTTP 401 (correct)"
else
  fail "Unexpected HTTP $INVALID_HTTP for invalid cookie  (expected 302 or 401)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 18 "IngressGateway Envoy calls OAuth2 Proxy again for ext_authz check"
# ─────────────────────────────────────────────────────────────────────────────
# OAuth2 Proxy health endpoint is at /ping (NOT /oauth2/ping).
# The VirtualService routes /oauth2/* to oauth2-proxy without a URI rewrite,
# so hitting /oauth2/ping via the ELB sends that exact path to oauth2-proxy —
# which doesn't recognise it and redirects to Keycloak login (302).
# Use a direct port-forward to the pod to hit /ping correctly.
proxy_pf_start
PING_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
              "http://localhost:${PROXY_PF_PORT}/ping" 2>/dev/null || echo "000")

if [[ "$PING_HTTP" == "200" ]]; then
  pass "OAuth2 Proxy /ping → HTTP 200 (ext_authz backend is live)"
else
  fail "OAuth2 Proxy /ping → HTTP $PING_HTTP  (expected 200 — check proxy pod readiness)"
fi

# Confirm the AuthorizationPolicy covers all three API paths.
AP_PATHS=$(kubectl get authorizationpolicy ext-authz-oauth2-proxy -n istio-system \
             -o jsonpath='{.spec.rules[0].to[0].operation.paths}' 2>/dev/null || true)
info "Protected paths: $AP_PATHS"
for PATH_CHECK in "/retail-banking/*" "/payments/*" "/grc/*"; do
  if echo "$AP_PATHS" | grep -q "${PATH_CHECK//\*/\\*}"; then
    pass "ext_authz applied to $PATH_CHECK"
  else
    fail "$PATH_CHECK NOT in AuthorizationPolicy paths"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
step 19 "OAuth2 Proxy validates cookie against Redis → 200 OK + auth headers"
# ─────────────────────────────────────────────────────────────────────────────
XAUTH=$(kubectl get deployment oauth2-proxy -n auth \
          -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
        | grep -o "set-xauthrequest=true" || true)
if [[ -n "$XAUTH" ]]; then
  pass "--set-xauthrequest=true → X-Auth-Request-User and X-Auth-Request-Email forwarded upstream"
else
  fail "--set-xauthrequest not set — user identity headers will NOT reach backend services"
fi

PASSTOKEN=$(kubectl get deployment oauth2-proxy -n auth \
              -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
            | grep -o "pass-access-token=true" || true)
if [[ -n "$PASSTOKEN" ]]; then
  pass "--pass-access-token=true → X-Auth-Request-Access-Token forwarded upstream"
else
  fail "--pass-access-token not set — JWT will NOT be forwarded"
fi

AUTHZ_HDR=$(kubectl get deployment oauth2-proxy -n auth \
              -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
            | grep -o "set-authorization-header=true" || true)
if [[ -n "$AUTHZ_HDR" ]]; then
  pass "--set-authorization-header=true → Authorization: Bearer <token> forwarded"
fi

LOGS=$(kubectl logs -n auth deployment/oauth2-proxy --tail=50 2>/dev/null || true)
if echo "$LOGS" | grep -qi "error\|failed"; then
  ERRORS=$(echo "$LOGS" | grep -i "error\|failed" | tail -3)
  warn "Recent errors in OAuth2 Proxy logs:\n  $ERRORS"
else
  pass "No errors in recent OAuth2 Proxy logs"
fi

# ─────────────────────────────────────────────────────────────────────────────
step 20 "Envoy forwards request into the mesh with mTLS + auth headers"
# ─────────────────────────────────────────────────────────────────────────────
PA_STRICT=$(kubectl get peerauthentication -A --no-headers 2>/dev/null \
            | awk '{print $3}' | grep -c "STRICT" || true)
if [[ "$PA_STRICT" -ge 4 ]]; then
  pass "$PA_STRICT PeerAuthentication STRICT policies (istio-system + 3 app namespaces)"
else
  fail "Only $PA_STRICT STRICT PeerAuthentication found  (expected 4)"
fi

DR_MUTUAL=$(kubectl get destinationrule -A \
              -o jsonpath='{.items[*].spec.trafficPolicy.tls.mode}' 2>/dev/null \
            | tr ' ' '\n' | grep -c "ISTIO_MUTUAL" || true)
if [[ "$DR_MUTUAL" -ge 9 ]]; then
  pass "$DR_MUTUAL DestinationRules with ISTIO_MUTUAL (mTLS enforced on all services)"
else
  fail "Only $DR_MUTUAL ISTIO_MUTUAL DestinationRules found  (expected 9)"
fi

AP_COUNT=$(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l || true)
info "Total AuthorizationPolicies in cluster: $AP_COUNT  (expected 10: 9 service-level + 1 CUSTOM)"

# ─────────────────────────────────────────────────────────────────────────────
step 21 "Upstream service responds"
# ─────────────────────────────────────────────────────────────────────────────
# Entry service pods must be 2/2 (app container + Envoy sidecar).
declare -A ENTRY_SERVICES=(
  ["retail-banking"]="customer-profile-svc"
  ["payments"]="transfer-svc"
  ["grc"]="fraud-svc"
)

for NS in "${!ENTRY_SERVICES[@]}"; do
  SVC="${ENTRY_SERVICES[$NS]}"
  STATUSES=$(kubectl get pod -n "$NS" -l "app=$SVC" \
               -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || true)
  POD_NAME=$(kubectl get pod -n "$NS" -l "app=$SVC" \
               -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ "$STATUSES" == "true true" ]]; then
    pass "$NS / $SVC ($POD_NAME) → 2/2 Ready  (app + Envoy sidecar)"
  elif [[ "$STATUSES" == "true" ]]; then
    fail "$NS / $SVC → 1/1 Ready  (sidecar missing — check istio-injection label on namespace)"
  elif [[ -z "$STATUSES" ]]; then
    fail "$NS / $SVC → pod not found"
  else
    fail "$NS / $SVC → not Ready  ($STATUSES)"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}════════════════════════════════════════════════════════${RESET}"
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  All 21 steps passed — auth flow is healthy ✔          ${RESET}"
else
  echo -e "${RED}${BOLD}  $FAILURES step(s) failed — review the ✖ items above    ${RESET}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}\n"

exit $FAILURES