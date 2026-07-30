# Kubernetes Security Hardening & Resilience Patterns

## Security Hardening — Layers Applied to This Project

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  LAYER 1: NETWORK ISOLATION (NetworkPolicies)                               │
│  Default deny all → explicit allow only necessary paths                     │
│  frontend → backend ✅   frontend → MongoDB ❌ (blocked)                    │
│  backend → MongoDB ✅    MongoDB → anywhere ❌ (blocked)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  LAYER 2: AVAILABILITY PROTECTION (PodDisruptionBudgets)                    │
│  Node drain/autoscaler cannot take down ALL pods of a tier simultaneously   │
│  minAvailable: 1 → always 1 frontend/backend pod serving users             │
│  minAvailable: 1 → MongoDB cannot be evicted without safe rescheduling     │
├─────────────────────────────────────────────────────────────────────────────┤
│  LAYER 3: RESOURCE GOVERNANCE (ResourceQuota + LimitRange)                  │
│  Namespace total cap: 2 CPU, 1Gi RAM                                        │
│  No LoadBalancer services (prevents accidental NLB creation)                │
│  Per-container defaults injected for pods without resource specs            │
├─────────────────────────────────────────────────────────────────────────────┤
│  LAYER 4: CONTAINER SECURITY (SecurityContext — Days 6-7)                   │
│  Non-root users, read-only root filesystems, capability drops               │
│  Docker multi-stage builds → minimal attack surface                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  LAYER 5: SUPPLY CHAIN SECURITY (Trivy — Day 12)                           │
│  CVE scan on every Docker build in CI → CRITICAL blocks PR merge            │
│  SARIF results uploaded to GitHub Security Code Scanning                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  LAYER 6: ACCESS CONTROL (IRSA + OIDC — Days 10-11)                        │
│  No long-lived AWS credentials anywhere                                     │
│  Each pod/pipeline gets minimum required AWS permissions only               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## NetworkPolicy — Zero Trust Traffic Matrix

### Complete Traffic Allowed Matrix

```
                     FROM
                     ┌─────────┬─────────┬─────────┬─────────┬──────────┐
               TO    │ ALB     │Frontend │Backend  │MongoDB  │Internet  │
                     ├─────────┼─────────┼─────────┼─────────┼──────────┤
            Frontend │  ✅:80  │   ─     │   ❌    │   ❌    │   ❌     │
            Backend  │  ✅:5000│  ✅:5000│   ─     │   ❌    │   ❌     │
            MongoDB  │   ❌    │   ❌    │ ✅:27017 │   ─     │   ❌     │
            Internet │   ─     │   ❌    │   ❌    │   ❌    │   ─      │
            kube-dns │ ✅:53  UDP/TCP (all pods)                         │
                     └─────────┴─────────┴─────────┴─────────┴──────────┘
```

> **Key security property**: Frontend pods cannot reach MongoDB directly. All data access MUST go through the backend API tier. This prevents SQL/NoSQL injection from being exploited directly at the database level.

### IMPORTANT: NetworkPolicy Requires VPC CNI NetworkPolicy Agent

```bash
# Check if NetworkPolicy enforcement is enabled:
kubectl get daemonset -n kube-system aws-node \
  -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="ENABLE_NETWORK_POLICY")].value}'
# Should return: true

# Enable it (if not already enabled):
aws eks update-addon \
  --cluster-name three-tier-eks-cluster \
  --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy": "true"}'

# Verify NetworkPolicy is enforced (not just created):
kubectl exec -n three-tier <frontend-pod> -- nc -zv mongo-service 27017
# Should FAIL (connection refused) after NetworkPolicy is enforced
kubectl exec -n three-tier <backend-pod> -- nc -zv mongo-service 27017
# Should SUCCEED
```

---

## PodDisruptionBudget — The 4 Scenarios

### Scenario 1: Node Drain During Maintenance

```bash
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data

# Kubernetes checks PDB before evicting each pod:
# frontend-pod on node-1:
#   PDB check: minAvailable=1, current=2, disruptions allowed=1
#   → Eviction ALLOWED (1 pod will still remain)
# backend-pod on node-1:
#   Same check → ALLOWED
# Drain completes: all pods reschedule to node-2
# User traffic never interrupts (readinessProbe keeps pod in service until graceful shutdown)
```

### Scenario 2: Cluster Autoscaler Scale-Down

```
Node-2 utilization: 10% CPU (pods moved to node-3 via autoscaler)
Autoscaler: "I want to terminate node-2"
  → Evict frontend-pod-2 from node-2?
     PDB: minAvailable=1, current=2 running → allowed (1 remains)
  → Evict frontend-pod-1 from node-2?
     PDB: minAvailable=1, current=1 running → BLOCKED!
Autoscaler: Schedules new pod on another node first → then re-checks PDB
```

### Scenario 3: Rolling Node Group Update (EKS AMI upgrade)

```
EKS begins rolling update: replaces each EC2 node with new AMI
For each node:
  1. Drain node (respects PDB — won't proceed if PDB blocks)
  2. Terminate old EC2 instance
  3. Launch new EC2 instance with new AMI
  4. New node joins cluster
  5. Pods reschedule
If PDB blocks: EKS waits until capacity is available elsewhere
→ Application stays online throughout the entire node group upgrade
```

### Scenario 4: MongoDB PDB (most restrictive)

```
MongoDB: replicas=1, PDB minAvailable=1
  → Disruptions allowed: 1 - 1 = 0

kubectl drain <node-with-mongodb>
→ BLOCKED: "Cannot evict pod due to PodDisruptionBudget 'mongo-pdb'"
→ kubectl drain will hang waiting

Resolution: Scale MongoDB replicas to 2+ first, then drain
→ Production: 3-node MongoDB replica set with minAvailable=2
  → Can drain 1 node at a time safely
```

---

## ResourceQuota — Budget Enforcement

```bash
# View current quota usage:
kubectl describe resourcequota three-tier-quota -n three-tier

# Output example:
# Name:                   three-tier-quota
# Namespace:              three-tier
# Resource                Used    Hard
# ─────────────────────   ─────   ─────
# limits.cpu              1500m   4
# limits.memory           640Mi   2Gi
# persistentvolumeclaims  1       5
# pods                    5       20
# requests.cpu            550m    2
# requests.memory         640Mi   1Gi
# secrets                 1       10
# services                3       10
# services.loadbalancers  0       0     ← LoadBalancer creation is blocked!
# services.nodeports      1       3

# Simulate exceeding quota:
kubectl run test-pod \
  --image=nginx \
  --requests='cpu=2,memory=2Gi'
# → Error: exceeded quota: three-tier-quota, requested: requests.cpu=2000m,
#           used: requests.cpu=550m, limited: requests.cpu=2000m
```

---

## LimitRange — Default Injection

```bash
# Without LimitRange, a pod with no resource spec is created:
kubectl run no-limits --image=nginx  # No requests/limits set
# → Pod uses UNLIMITED CPU and memory
# → Under memory pressure: this pod starves other pods (OOMKill them first!)

# With LimitRange, the admission controller injects defaults:
kubectl run with-defaults --image=nginx
kubectl get pod with-defaults -o jsonpath='{.spec.containers[0].resources}'
# Output:
# {
#   "limits":   {"cpu": "500m", "memory": "256Mi"},
#   "requests": {"cpu": "100m", "memory": "128Mi"}
# }
# LimitRange injected these defaults automatically!
```

---

## Applying All Resources

```bash
# Apply in order (namespace must exist):
kubectl apply -f k8s/mongo/namespace.yaml

# Resource governance (before workloads)
kubectl apply -f k8s/resource-quota/quotas.yaml

# Network policies (before workloads for security)
kubectl apply -f k8s/network-policies/deny-all.yaml
kubectl apply -f k8s/network-policies/allow-ingress.yaml

# Workloads (all other manifests)
kubectl apply -f k8s/mongo/
kubectl apply -f k8s/backend/
kubectl apply -f k8s/frontend/

# PDB (after deployments exist, selector must match running pods)
kubectl apply -f k8s/pdb/poddisruptionbudgets.yaml

# Verify everything
kubectl get networkpolicies -n three-tier
kubectl get pdb -n three-tier
kubectl describe resourcequota -n three-tier
```

---

## Verification Commands

```bash
# NetworkPolicy verification:
# (requires NetworkPolicy enforcement to be active — see note above)
kubectl get networkpolicies -n three-tier
kubectl describe networkpolicy default-deny-all -n three-tier

# PDB verification:
kubectl get pdb -n three-tier
# NAME           MIN AVAILABLE  MAX UNAVAILABLE  ALLOWED DISRUPTIONS  AGE
# backend-pdb    1              N/A              1                    5m
# frontend-pdb   1              N/A              1                    5m
# mongo-pdb      1              N/A              0                    5m  ← 0 disruptions!

# ResourceQuota verification:
kubectl get resourcequota -n three-tier
kubectl describe resourcequota three-tier-quota -n three-tier

# LimitRange verification:
kubectl get limitrange -n three-tier
kubectl describe limitrange three-tier-limits -n three-tier
```
