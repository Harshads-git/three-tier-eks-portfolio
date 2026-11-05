# Policy as Code & Cluster Governance with Kyverno

> **Core Philosophy:** Shift security left to the Kubernetes API boundary. Block insecure configurations before they reach the cluster rather than discovering them through runtime alerts.

---

## 1. Why Policy as Code (Kyverno vs OPA/Gatekeeper)?

In enterprise Kubernetes environments, human review alone cannot prevent misconfigurations (e.g. pods running as root, missing CPU limits, unversioned `:latest` tags).

| Feature | OPA / Gatekeeper | Kyverno (Chosen Architecture) |
|---|---|---|
| **Policy Language** | Custom DSL (Rego) | **Pure Kubernetes YAML** |
| **Learning Curve** | High (Requires learning Rego language) | **Low** (Uses native Kubernetes resource patterns) |
| **Mutating Capabilities** | Complex mutation hooks | **Native YAML JSON Patch / overlay mutations** |
| **Resource Generation** | Third-party operators required | **Native** (Auto-generates NetworkPolicies on namespace create) |
| **Image Verification** | Requires external Cosign plugins | **Native Sigstore Cosign & Notary v2 support** |
| **Testing in CI** | `opa test` | `kyverno test` CLI for pre-commit linting |

---

## 2. Admission Control Architecture

Kyverno registers as dynamic admission webhooks with the Kubernetes API server (`kube-apiserver`):

```
Developer / CI Runner / ArgoCD
              │
              │ kubectl apply / GitOps sync
              ▼
    ┌───────────────────┐
    │  kube-apiserver   │
    └─────────┬─────────┘
              │ Webhook Call
              ▼
┌─────────────────────────────────────────────────────────────┐
│                 Kyverno Policy Controller                   │
│                                                             │
│   1. Mutating Webhook (Optional):                           │
│      - Injects standard security context or default labels  │
│                                                             │
│   2. Validating Webhook (Enforce):                          │
│      - Evaluates ClusterPolicies against incoming Pod spec   │
│                                                             │
│      ┌─────────────────────────────┐                        │
│      │ disallow-root-user          │ ──► UID must be > 0    │
│      │ require-resource-limits     │ ──► CPU & RAM bounded  │
│      │ disallow-latest-tag         │ ──► Immutable tag only │
│      │ restrict-image-registries   │ ──► ECR / verified     │
│      │ disallow-privilege-escalate │ ──► Drop ALL caps      │
│      └─────────────────────────────┘                        │
└─────────────┬─────────────────────────────┬─────────────────┘
              │                             │
         All Passed                   Rule Breached
              │                             │
              ▼                             ▼
       API Admits Pod               API REJECTS REQUEST
    (Persisted to etcd)         (HTTP 400 Bad Request with
                                 actionable guidance message)
```

---

## 3. Core Policy Portfolio

All policies live declaratively in [`k8s/kyverno/policies/`](../k8s/kyverno/policies/):

| Policy | Category | Action | Threat Mitigated |
|---|---|---|---|
| **`disallow-root-user`** | Pod Security (Restricted) | `Enforce` | Container breakout / privilege escalation via UID 0 |
| **`disallow-privilege-escalation`** | Pod Security (Restricted) | `Enforce` | Kernel exploitation via setuid binaries |
| **`require-resource-limits`** | Capacity Management | `Enforce` | Noisy-neighbor resource starvation & node OOM panics |
| **`disallow-latest-tag`** | Supply Chain Security | `Enforce` | Non-deterministic rollouts and broken rollback states |
| **`restrict-image-registries`** | Supply Chain Security | `Enforce` | Rogue images from personal/untrusted public mirrors |
| **`require-standard-labels`** | Observability & Governance | `Enforce` | Missing metadata for billing and NetworkPolicy routing |

---

## 4. Audit Mode vs Enforce Mode

Kyverno policies support two evaluation modes:

1. **`validationFailureAction: Audit` (Safe Trial):**
   - Violations do **not** block deployments.
   - Kyverno logs infractions into `PolicyReport` and `ClusterPolicyReport` custom resources.
   - SRE teams use this to audit existing legacy workloads before turning on enforcement.

2. **`validationFailureAction: Enforce` (Production Gate):**
   - Offending API requests are **rejected immediately** at the API server boundary.
   - The developer receives an immediate, helpful failure message explaining exactly how to fix their manifest.

### Example Rejection Message:
```
Error from server: admission webhook "validate.kyverno.svc" denied the request: 
policy Pod/three-tier/test-pod for resource error: 

disallow-latest-tag:
  validate-image-tag: "Using ':latest' or omitting image tags is forbidden. 
  Specify an explicit immutable tag (e.g. sha-xxxx)."
```

---

## 5. Exemption Handling with `PolicyException`

Rather than disabling a global `ClusterPolicy` when a specific third-party workload requires elevated privileges, Kyverno uses the `PolicyException` CRD:

```yaml
apiVersion: kyverno.io/v2alpha1
kind: PolicyException
metadata:
  name: mongo-root-exception
  namespace: three-tier
spec:
  exceptions:
    - policyName: disallow-root-user
      ruleNames:
        - check-run-as-non-root
  match:
    any:
      - resources:
          kinds:
            - StatefulSet
          names:
            - mongo
```

This isolates exceptions cleanly, maintaining global enforcement across all other microservices.

---

## 6. SRE Day-2 Operations Cheat Sheet

```bash
# Check status of Kyverno cluster policies
kubectl get clusterpolicies

# Query aggregated policy violation reports across all namespaces
kubectl get policyreports -n three-tier

# View cluster-wide summary report
kubectl get clusterpolicyreports

# Test an offending pod against the policies (simulated rejection)
kubectl run bad-pod --image=nginx:latest -n three-tier
# Output: Error from server: admission webhook denied the request (disallow-latest-tag)
```
