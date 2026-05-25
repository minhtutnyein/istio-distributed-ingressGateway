# Distributed API Gateway — Istio + mTLS (Distributed Gateway Pattern)

This project implements a **two-tier distributed API gateway** using **Istio service mesh with mutual TLS (mTLS)** on AWS EKS. A single internet-facing global IngressGateway receives all external traffic and forwards to per-namespace IngressGateways. All service-to-service communication inside the mesh is secured with SPIFFE X.509 certificates issued by istiod, and access is enforced per-service via `AuthorizationPolicy`.

| Parameter | Value |
|---|---|
| Cluster | `istiodc1-cluster` |
| Region | `ap-southeast-1` |
| Cloud | AWS EKS |
| Global Hostname | `finance.mhnbank.xyz` |
| Istio Version | `1.29.2` |
| Istio Control Plane Namespace | `istio-system` |

---

## Architecture
![alt text](assets/Istio-Distributed-Gateway-Architecture.png)


### Two-Tier Gateway Traffic-Flow Design

```mermaid
flowchart TB
  C([Client / Internet])

  subgraph sys [istio-system]
    LB["Istio IngressGateway
    Type: LoadBalancer
    finance.mhnbank.xyz"]
    GVS["global-virtualservice
    /retail-banking/* → rewrite /
    /payments/*       → rewrite /
    /grc/*            → rewrite /"]
  end

  subgraph rb [retail-banking — mTLS STRICT]
    RBGW["retail-banking-ingressgateway
    ClusterIP :80"]
    RBCR["retail-banking-gateway CR
    retail-banking-vs"]
    CPSVC["customer-profile-svc :8081  ← entry"]
    ASVC["account-svc :8082"]
    BSSVC["bank-statement-svc :8083"]
  end

  subgraph py [payments — mTLS STRICT]
    PYGW["payments-ingressgateway
    ClusterIP :80"]
    PYCR["payments-gateway CR
    payments-vs"]
    TRSVC["transfer-svc :7071  ← entry"]
    PGSVC["payment-gateway-svc :7072"]
    FXSVC["fx-svc :7073"]
  end

  subgraph grc [grc — mTLS STRICT]
    GRCGW["grc-ingressgateway
    ClusterIP :80"]
    GRCCR["grc-gateway CR
    grc-vs"]
    FRDSVC["fraud-svc :6061  ← entry"]
    AUDSVC["audit-svc :6062"]
    SANSVC["sanction-svc :6063"]
  end

  C --> LB --> GVS

  GVS -->|"/retail-banking/*"| RBGW --> RBCR --> CPSVC
  CPSVC -->|mTLS| ASVC -->|mTLS| BSSVC

  GVS -->|"/payments/*"| PYGW --> PYCR --> TRSVC
  TRSVC -->|mTLS| PGSVC -->|mTLS| FXSVC

  GVS -->|"/grc/*"| GRCGW --> GRCCR --> FRDSVC
  FRDSVC -->|mTLS| AUDSVC -->|mTLS| SANSVC
```

---

## Key Design Principles

| Concern | Implementation |
|---|---|
| External entry point | Single `istio-ingressgateway` LoadBalancer in `istio-system` |
| Namespace isolation | Per-namespace `ClusterIP` IngressGateway (`retail-banking`, `payments`, `grc`) |
| Two-tier routing | Global VS → namespace GW → namespace VS → app service |
| Service identity | SPIFFE X.509 SVIDs issued by `istiod` (trust domain: `cluster.local`) |
| mTLS enforcement | `PeerAuthentication` STRICT mesh-wide + per-namespace |
| Client-side mTLS | `DestinationRule` with `tls.mode: ISTIO_MUTUAL` per service |
| Access control | `AuthorizationPolicy` per service — namespace GW SA is the only allowed entry-point caller |
| Routing | Istio `Gateway` + `VirtualService` at both global and namespace tiers |
| Observability | Envoy access logs + Prometheus metrics + Kiali service graph dashboard |

---

## File Structure

### Root — Istio control plane & global routing

| File | Purpose |
|---|---|
| `0-istio-namespaces-domains.yaml` | Domain namespace declarations with `istio-injection: enabled` |
| `1-istio-gateway-global.yaml` | Istio `Gateway` resource — binds global IngressGateway to `finance.mhnbank.xyz` |
| `2-mtls-peer-authentication.yaml` | `PeerAuthentication` STRICT policies for all namespaces |
| `3-global-virtualservice.yaml` | Global `VirtualService` — routes path prefixes to namespace IngressGateways |
| `4-mtls-destination-rules.yaml` | `DestinationRule` for every service — client-side mTLS mode |
| `5-authorization-policies.yaml` | `AuthorizationPolicy` — RBAC via SPIFFE principal per service |

### Domain apps — per namespace

| File | Purpose |
|---|---|
| `apps/*/namespace.yaml` | Namespace with `istio-injection: enabled` label |
| `apps/*/gateway.yaml` | **Namespace-scoped** `Gateway` CR — binds to the namespace IngressGateway |
| `apps/*/virtualservice.yaml` | Namespace `VirtualService` — bound to namespace gateway, routes to entry service |
| `apps/*/traffic-policy.yaml` | Traffic policy `VirtualService` — retries + timeouts for internal calls |
| `apps/*/<service>.yaml` | Deployment + Service + ServiceAccount |

> The GRC domain app files live under `apps/risk-compliance/` (Kubernetes namespace is `grc`).

### Helm values

| File | Purpose |
|---|---|
| `helm-values/istio-base-values.yaml` | `istio/base` values — Istio CRDs |
| `helm-values/istiod-values.yaml` | `istio/istiod` values — control plane |
| `helm-values/istio-ingress-values.yaml` | `istio/gateway` values — global IngressGateway (LoadBalancer) |
| `helm-values/retail-banking-ingress-values.yaml` | `istio/gateway` values — `retail-banking` namespace gateway (ClusterIP) |
| `helm-values/payments-ingress-values.yaml` | `istio/gateway` values — `payments` namespace gateway (ClusterIP) |
| `helm-values/grc-ingress-values.yaml` | `istio/gateway` values — `grc` namespace gateway (ClusterIP) |
| `helm-values/prometheus-values.yaml` | `prometheus-community/prometheus` values — metrics scraping for Istio mesh |
| `helm-values/kiali-values.yaml` | Kiali observability dashboard values |

### Scripts

| File | Purpose |
|---|---|
| `deploy.sh` | Full automated deployment — Steps 0–12 (Istio, gateways, apps, Prometheus, Kiali, traffic test) |
| `verify.sh` | Full automated verification — 11 checks covering pods, mTLS, AuthZ, SPIFFE, and traffic |

---

## Deployment Order

### Automated

```bash
# Connect to EKS first, then run the full deployment script
aws eks update-kubeconfig --name istiodc1-cluster --region ap-southeast-1
bash deploy.sh
```

### Manual step-by-step

```bash
# Step 0 — Connect to EKS
aws eks update-kubeconfig --name istiodc1-cluster --region ap-southeast-1

# Step 1 — Add Helm repos
helm repo add istio               https://istio-release.storage.googleapis.com/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kiali               https://kiali.org/helm-charts
helm repo update

# Step 2 — Install Istio base (CRDs)
helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
  --version 1.29.2 -f helm-values/istio-base-values.yaml

# Step 3 — Install istiod (control plane)
helm upgrade --install istiod istio/istiod -n istio-system --wait \
  --version 1.29.2 -f helm-values/istiod-values.yaml

# Step 4 — Create namespaces + enable sidecar injection
kubectl apply -f 0-istio-namespaces-domains.yaml

# Step 5 — Install global IngressGateway (the single internet-facing LoadBalancer)
helm upgrade --install istio-ingressgateway istio/gateway -n istio-system \
  --version 1.29.2 -f helm-values/istio-ingress-values.yaml

# Step 6 — Install per-namespace IngressGateways (internal ClusterIP)
helm upgrade --install retail-banking-ingressgateway istio/gateway -n retail-banking \
  --version 1.29.2 -f helm-values/retail-banking-ingress-values.yaml

helm upgrade --install payments-ingressgateway istio/gateway -n payments \
  --version 1.29.2 -f helm-values/payments-ingress-values.yaml

helm upgrade --install grc-ingressgateway istio/gateway -n grc \
  --version 1.29.2 -f helm-values/grc-ingress-values.yaml

# Step 7 — Deploy Istio global Gateway CR + mTLS policies + VirtualService
kubectl apply -f 1-istio-gateway-global.yaml
kubectl apply -f 2-mtls-peer-authentication.yaml
kubectl apply -f 3-global-virtualservice.yaml
kubectl apply -f 4-mtls-destination-rules.yaml
kubectl apply -f 5-authorization-policies.yaml

# Step 8 — Deploy domain app resources (namespace Gateway CRs, VSes, Deployments)
kubectl apply -f apps/retail-banking/
kubectl apply -f apps/payments/
kubectl apply -f apps/risk-compliance/

# Step 9 — Install Prometheus (metrics backend for Kiali)
helm upgrade --install prometheus prometheus-community/prometheus \
  -n istio-system -f helm-values/prometheus-values.yaml --wait

# Step 10 — Install Kiali operator + CR
helm upgrade --install kiali-operator kiali/kiali-operator \
  -n kiali-operator --create-namespace \
  -f helm-values/kiali-values.yaml --wait
```

---

## Traffic Flow

```
finance.mhnbank.xyz
  → Global IngressGateway (LoadBalancer, istio-system)
  → global-virtualservice (path match + URI rewrite to /)
      /retail-banking/* → retail-banking-ingressgateway (ClusterIP, retail-banking ns)
                           → retail-banking-gateway CR + retail-banking-vs
                           → customer-profile-svc:8081  ← entry point
                               ↳ [mTLS] account-svc:8082
                                         ↳ [mTLS] bank-statement-svc:8083

      /payments/*       → payments-ingressgateway (ClusterIP, payments ns)
                           → payments-gateway CR + payments-vs
                           → transfer-svc:7071           ← entry point
                               ↳ [mTLS] payment-gateway-svc:7072
                                         ↳ [mTLS] fx-svc:7073

      /grc/*            → grc-ingressgateway (ClusterIP, grc ns)
                           → grc-gateway CR + grc-vs
                           → fraud-svc:6061              ← entry point
                               ↳ [mTLS] audit-svc:6062
                                         ↳ [mTLS] sanction-svc:6063
```

All intra-mesh arrows are Envoy-to-Envoy mTLS connections authenticated by SPIFFE certificates issued by istiod.

---

## SPIFFE Identity & AuthorizationPolicy

Each service account receives a SPIFFE identity:
```
spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>
```

**AuthorizationPolicy call chain:**

| Namespace | Caller principal | Target service |
|---|---|---|
| `retail-banking` | `cluster.local/ns/retail-banking/sa/retail-banking-ingressgateway` | `customer-profile-svc` (entry) |
| `retail-banking` | `cluster.local/ns/retail-banking/sa/customer-profile-svc` | `account-svc` |
| `retail-banking` | `cluster.local/ns/retail-banking/sa/account-svc` | `bank-statement-svc` |
| `payments` | `cluster.local/ns/payments/sa/payments-ingressgateway` | `transfer-svc` (entry) |
| `payments` | `cluster.local/ns/payments/sa/transfer-svc` | `payment-gateway-svc` |
| `payments` | `cluster.local/ns/payments/sa/payment-gateway-svc` | `fx-svc` |
| `grc` | `cluster.local/ns/grc/sa/grc-ingressgateway` | `fraud-svc` (entry) |
| `grc` | `cluster.local/ns/grc/sa/fraud-svc` | `audit-svc` |
| `grc` | `cluster.local/ns/grc/sa/audit-svc` | `sanction-svc` |

---

## Verification Commands

### Automated

```bash
bash verify.sh
```

### Manual checks

```bash
# 1. Confirm only 1 external LoadBalancer (global gateway)
kubectl get svc -A --field-selector spec.type=LoadBalancer

# 2. Namespace gateways are ClusterIP
kubectl get svc -n retail-banking retail-banking-ingressgateway
kubectl get svc -n payments payments-ingressgateway
kubectl get svc -n grc grc-ingressgateway

# 3. All pods show 2/2 (app + sidecar)
kubectl get pods -n retail-banking
kubectl get pods -n payments
kubectl get pods -n grc

# 4. PeerAuthentication STRICT everywhere
kubectl get peerauthentication -A

# 5. All Gateway CRs present
kubectl get gateway -A

# 6. All VirtualServices present
kubectl get virtualservice -A

# 7. DestinationRules with ISTIO_MUTUAL
kubectl get destinationrule -A

# 8. AuthorizationPolicies active
kubectl get authorizationpolicy -A

# 9. End-to-end traffic test
INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s -H "Host: finance.mhnbank.xyz" http://${INGRESS_HOST}/retail-banking/
curl -s -H "Host: finance.mhnbank.xyz" http://${INGRESS_HOST}/payments/
curl -s -H "Host: finance.mhnbank.xyz" http://${INGRESS_HOST}/grc/

# 10. Verify mTLS between services
istioctl x describe pod \
  $(kubectl get pod -n retail-banking -l app=account-svc -o jsonpath='{.items[0].metadata.name}') \
  -n retail-banking
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `RBAC: access denied` on entry service | Namespace GW SA name mismatch | Verify actual SA: `kubectl get pod -n retail-banking -l app=retail-banking-ingressgateway -o jsonpath='{.items[0].spec.serviceAccountName}'` and update `5-authorization-policies.yaml` |
| `503` from namespace gateway | Namespace VS not bound to correct gateway selector label | Confirm `apps/*/gateway.yaml` selector matches the gateway pod label (`istio: retail-banking-ingressgateway`) |
| Pod shows `1/1` not `2/2` | Namespace missing `istio-injection=enabled` | Re-apply `0-istio-namespaces-domains.yaml` then restart pods: `kubectl rollout restart deploy -n <ns>` |
| Namespace IngressGateway not found | Helm install skipped or failed | Run the Step 6 `helm install` commands; verify with `kubectl get pods -n <ns> -l app=<ns>-ingressgateway` |
| Global VS sends to wrong host | Copy-paste error in destination host FQDN | Verify `3-global-virtualservice.yaml` destinations end in `.svc.cluster.local` with correct namespace |
| `301 Moved Permanently` with double-slash | Path prefix missing trailing slash | Use `/retail-banking/`, `/payments/`, `/grc/` (with trailing slash) in global VS match |
| IngressGateway has no `EXTERNAL-IP` | AWS ELB still provisioning | Wait 2–3 min; check EC2 → Load Balancers in AWS console |
| Kiali `lookup prometheus … no such host` | Prometheus not installed in `istio-system` | Install Prometheus: `helm upgrade --install prometheus prometheus-community/prometheus -n istio-system -f helm-values/prometheus-values.yaml` |

---

## Test Cases

### Path Routing

#### TC-04: Retail Banking path routing

```bash
curl -s -H "Host: finance.mhnbank.xyz" http://${ELB_HOSTNAME}/retail-banking/ | jq .
```

**Expected call chain:** IngressGateway → `customer-profile-svc:8081` → `account-svc:8082` → `bank-statement-svc:8083`

---

#### TC-05: Payments path routing

```bash
curl -s -H "Host: finance.mhnbank.xyz" http://${ELB_HOSTNAME}/payments/ | jq .
```

**Expected call chain:** IngressGateway → `transfer-svc:7071` → `payment-gateway-svc:7072` → `fx-svc:7073`

---

#### TC-06: GRC path routing

```bash
curl -s -H "Host: finance.mhnbank.xyz" http://${ELB_HOSTNAME}/grc/ | jq .
```

**Expected call chain:** IngressGateway → `fraud-svc:6061` → `audit-svc:6062` → `sanction-svc:6063`

---

### mTLS Verification

#### TC-07: mTLS is enforced (STRICT mode)

```bash
# Confirm PeerAuthentication is STRICT in all namespaces
kubectl get peerauthentication -A

# Verify mutual TLS for a specific pod
istioctl x describe pod \
  $(kubectl get pod -n retail-banking -l app=customer-profile-svc -o jsonpath='{.items[0].metadata.name}') \
  -n retail-banking
```

**Expected:** `mTLS: YES` in the istioctl output. All traffic between services uses ISTIO_MUTUAL.

---

### SPIFFE Identity Verification

Each microservice has a unique SPIFFE identity derived from its Kubernetes ServiceAccount:

| Service | Namespace | SPIFFE ID |
|---|---|---|
| `istio-ingressgateway` | `istio-system` | `spiffe://cluster.local/ns/istio-system/sa/istio-ingressgateway` |
| `retail-banking-ingressgateway` | `retail-banking` | `spiffe://cluster.local/ns/retail-banking/sa/retail-banking-ingressgateway` |
| `payments-ingressgateway` | `payments` | `spiffe://cluster.local/ns/payments/sa/payments-ingressgateway` |
| `grc-ingressgateway` | `grc` | `spiffe://cluster.local/ns/grc/sa/grc-ingressgateway` |
| `customer-profile-svc` | `retail-banking` | `spiffe://cluster.local/ns/retail-banking/sa/customer-profile-svc` |
| `account-svc` | `retail-banking` | `spiffe://cluster.local/ns/retail-banking/sa/account-svc` |
| `bank-statement-svc` | `retail-banking` | `spiffe://cluster.local/ns/retail-banking/sa/bank-statement-svc` |
| `transfer-svc` | `payments` | `spiffe://cluster.local/ns/payments/sa/transfer-svc` |
| `payment-gateway-svc` | `payments` | `spiffe://cluster.local/ns/payments/sa/payment-gateway-svc` |
| `fx-svc` | `payments` | `spiffe://cluster.local/ns/payments/sa/fx-svc` |
| `fraud-svc` | `grc` | `spiffe://cluster.local/ns/grc/sa/fraud-svc` |
| `audit-svc` | `grc` | `spiffe://cluster.local/ns/grc/sa/audit-svc` |
| `sanction-svc` | `grc` | `spiffe://cluster.local/ns/grc/sa/sanction-svc` |

#### TC-08: Verify SPIFFE certificate (SAN URI) for each service

**Using `istioctl proxy-config secret` (recommended):**

```bash
verify_spiffe() {
  local app=$1 ns=$2
  POD=$(kubectl get pod -n "$ns" -l app="$app" -o jsonpath='{.items[0].metadata.name}')
  echo "=== $app ($ns) ==="
  istioctl proxy-config secret "$POD" -n "$ns" -o json \
    | jq -r '
        .dynamicActiveSecrets[]
        | select(.name == "default")
        | .secret.tlsCertificate.certificateChain.inlineBytes
      ' \
    | base64 -d \
    | openssl x509 -noout -text \
    | grep "URI:spiffe"
}

# retail-banking
verify_spiffe customer-profile-svc retail-banking
verify_spiffe account-svc          retail-banking
verify_spiffe bank-statement-svc   retail-banking

# payments
verify_spiffe transfer-svc         payments
verify_spiffe payment-gateway-svc  payments
verify_spiffe fx-svc               payments

# grc
verify_spiffe fraud-svc            grc
verify_spiffe audit-svc            grc
verify_spiffe sanction-svc         grc
```

**Expected output per service (example for `customer-profile-svc`):**
```
=== customer-profile-svc (retail-banking) ===
                URI:spiffe://cluster.local/ns/retail-banking/sa/customer-profile-svc
```

---

#### TC-09: Verify SPIFFE identity using `istioctl x describe`

```bash
# Shows peer identity, mTLS status, and applied policies for each pod
for app in customer-profile-svc account-svc bank-statement-svc; do
  POD=$(kubectl get pod -n retail-banking -l app=$app -o jsonpath='{.items[0].metadata.name}')
  echo "=== $app ==="
  istioctl x describe pod "$POD" -n retail-banking | grep -E "SPIFFE|mTLS|Identity|Service Account"
done

for app in transfer-svc payment-gateway-svc fx-svc; do
  POD=$(kubectl get pod -n payments -l app=$app -o jsonpath='{.items[0].metadata.name}')
  echo "=== $app ==="
  istioctl x describe pod "$POD" -n payments | grep -E "SPIFFE|mTLS|Identity|Service Account"
done

for app in fraud-svc audit-svc sanction-svc; do
  POD=$(kubectl get pod -n grc -l app=$app -o jsonpath='{.items[0].metadata.name}')
  echo "=== $app ==="
  istioctl x describe pod "$POD" -n grc | grep -E "SPIFFE|mTLS|Identity|Service Account"
done
```

---

#### TC-10: Verify AuthorizationPolicy enforces SPIFFE-based RBAC

Confirm that each service only accepts connections from its authorised upstream:

```bash
kubectl get authorizationpolicy -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,FROM:.spec.rules[*].from[*].source.principals[*]'
```

**Expected — one policy per service, one principal per policy:**

| Namespace | Policy | Allowed Principal |
|---|---|---|
| `retail-banking` | `allow-customer-profile-svc` | `cluster.local/ns/retail-banking/sa/retail-banking-ingressgateway` |
| `retail-banking` | `allow-account-svc` | `cluster.local/ns/retail-banking/sa/customer-profile-svc` |
| `retail-banking` | `allow-bank-statement-svc` | `cluster.local/ns/retail-banking/sa/account-svc` |
| `payments` | `allow-transfer-svc` | `cluster.local/ns/payments/sa/payments-ingressgateway` |
| `payments` | `allow-payment-gateway-svc` | `cluster.local/ns/payments/sa/transfer-svc` |
| `payments` | `allow-fx-svc` | `cluster.local/ns/payments/sa/payment-gateway-svc` |
| `grc` | `allow-fraud-svc` | `cluster.local/ns/grc/sa/grc-ingressgateway` |
| `grc` | `allow-audit-svc` | `cluster.local/ns/grc/sa/fraud-svc` |
| `grc` | `allow-sanction-svc` | `cluster.local/ns/grc/sa/audit-svc` |

---

### Negative Tests

#### TC-11: Unknown path returns 404

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: finance.mhnbank.xyz" http://${ELB_HOSTNAME}/unknown/
```

**Expected:** `404`

---

#### TC-12: Wrong Host header returns 404

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: unknown.mhnbank.xyz" http://${ELB_HOSTNAME}/retail-banking/
```

**Expected:** `404`

---

### Service Topology Reference

```
/retail-banking/ → customer-profile-svc:8081 → account-svc:8082 → bank-statement-svc:8083 (leaf)
/payments/       → transfer-svc:7071          → payment-gateway-svc:7072 → fx-svc:7073    (leaf)
/grc/            → fraud-svc:6061             → audit-svc:6062   → sanction-svc:6063      (leaf)
```
