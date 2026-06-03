# Kubernetes Deployment Patterns & Rolling Update Strategy

## Architecture Overview — All K8s Resources

```
three-tier namespace
│
├── Tier 1: Frontend
│   ├── Deployment: frontend (replicas: 2)
│   ├── Service: frontend-service (NodePort → ALB routes here)
│   └── HPA: frontend-hpa (2-5 replicas, CPU 80%)
│
├── Tier 2: Backend
│   ├── ConfigMap: backend-config (PORT, NODE_ENV, LOG_LEVEL)
│   ├── Deployment: backend (replicas: 2)
│   ├── Service: backend-service (ClusterIP → internal only)
│   └── HPA: backend-hpa (2-5 replicas, CPU 70%, memory 80%)
│
└── Tier 3: MongoDB
    ├── Secret: mongo-secret (MONGO_URI, credentials)
    ├── StatefulSet: mongo (replicas: 1)
    ├── Service: mongo-service (ClusterIP)
    └── Service: mongo-headless (Headless)
```

---

## Deployment vs StatefulSet — Final Comparison

| | Deployment (frontend, backend) | StatefulSet (mongo) |
|---|---|---|
| Pod names | Random: `backend-5d9f-abc` | Stable: `mongo-0` |
| Storage | Shared or none | Per-pod PVC |
| Startup order | Parallel | Sequential |
| Use case | Stateless apps | Stateful databases |
| Scale out | Instant (create identical pods) | Sequential (mongo-0, then mongo-1...) |

---

## Rolling Update — Zero Downtime Explained

The Deployment `strategy: RollingUpdate` with `maxSurge: 1, maxUnavailable: 0` guarantees zero downtime:

```
Initial state:   [backend-v1-pod1] [backend-v1-pod2]   ← serving traffic

Deploy v2 (kubectl apply or kubectl set image):

Step 1: Create v2 pod
         [backend-v1-pod1] [backend-v1-pod2] [backend-v2-pod3]
                                              ↑ readinessProbe must pass

Step 2: v2 becomes Ready → add to Service Endpoints
         [backend-v1-pod1] [backend-v1-pod2] [backend-v2-pod3]
         ← ALL 3 serving traffic

Step 3: Terminate one v1 pod (SIGTERM → graceful shutdown)
         [backend-v1-pod1] [backend-v2-pod3]

Step 4: Create another v2 pod
         [backend-v1-pod1] [backend-v2-pod3] [backend-v2-pod4]

Step 5: v2-pod4 becomes Ready → remove last v1

Final:   [backend-v2-pod3] [backend-v2-pod4]  ← new version serving, zero downtime
```

> **Key insight**: `maxUnavailable: 0` means you NEVER drop below 2 pods during the update. Traffic always has healthy pods to route to.

---

## Rolling Back a Failed Deployment

```bash
# See rollout history
kubectl rollout history deployment/backend -n three-tier

# Rollback to the previous version (last working state)
kubectl rollout undo deployment/backend -n three-tier

# Rollback to a specific revision
kubectl rollout undo deployment/backend -n three-tier --to-revision=3

# Monitor rollback progress
kubectl rollout status deployment/backend -n three-tier
```

> **Why this works**: K8s keeps the last `revisionHistoryLimit: 5` ReplicaSets. Undo just swaps the active ReplicaSet.

---

## HPA — Horizontal Pod Autoscaler Deep Dive

### How HPA Calculates Scale

```
Current replicas: 2
CPU requests per pod: 100m
Average CPU usage: 80m per pod

Utilization = 80m / 100m = 80%
Target utilization: 70%

Desired replicas = ceil(current * (actual / target))
                 = ceil(2 * (80% / 70%))
                 = ceil(2 * 1.14)
                 = ceil(2.28)
                 = 3 replicas → scale up!
```

### HPA Scale-Up/Down Behavior

```
Scale UP (traffic spike):
  stabilizationWindowSeconds: 30 → waits 30s before scaling up again
  policy: max 2 pods per 60s → controlled ramp-up, not instant spike

Scale DOWN (traffic drops):
  stabilizationWindowSeconds: 300 → waits 5 MINUTES before scaling down
  policy: max 1 pod per 120s → very gradual scale-down

Why the asymmetry?
  Scale UP fast: users are impacted NOW → act quickly
  Scale DOWN slow: avoid "flapping" (scale down → spike → scale up → repeat)
                   also: traffic may return before pods fully initialize
```

### Verifying HPA in Production

```bash
# Show current HPA status
kubectl get hpa -n three-tier

# Expected output:
# NAME           REFERENCE             TARGETS         MINPODS  MAXPODS  REPLICAS
# backend-hpa    Deployment/backend    45%/70%          2        5        2
# frontend-hpa   Deployment/frontend   12%/80%          2        5        2

# If TARGETS shows "<unknown>":
# → Metrics Server is not installed or pod requests are not set

# Watch HPA in real-time during a load test
watch kubectl get hpa -n three-tier

# Describe for full event history
kubectl describe hpa backend-hpa -n three-tier
```

---

## ConfigMap vs Secret — Decision Table

| Config Value | Type | Reason |
|---|---|---|
| `PORT=5000` | ConfigMap | Port number — not sensitive |
| `NODE_ENV=production` | ConfigMap | Environment name — not sensitive |
| `LOG_LEVEL=info` | ConfigMap | Logging config — not sensitive |
| `MONGO_URI=mongodb://...@...` | **Secret** | Contains database credentials |
| `MONGO_ROOT_PASSWORD` | **Secret** | Password |
| TLS certificate | **Secret** | Private key |
| Feature flags | ConfigMap | Non-sensitive toggles |
| AWS region | ConfigMap | Not sensitive |
| AWS Secret Access Key | **Secret** | AWS credential |

> **Rule**: Would your security team alert if this value appeared in a public GitHub repo? → Secret. Otherwise → ConfigMap.

---

## Apply Order for All Resources

```bash
# Full deployment apply order (Day 19 when cluster exists):

# 1. Namespace (must exist first)
kubectl apply -f k8s/mongo/namespace.yaml

# 2. Config/Secrets (before workloads that reference them)
kubectl apply -f k8s/mongo/secret.yaml
kubectl apply -f k8s/backend/configmap.yaml

# 3. Database tier (before backend which depends on it)
kubectl apply -f k8s/mongo/service.yaml
kubectl apply -f k8s/mongo/statefulset.yaml

# Wait for MongoDB to be ready:
kubectl rollout status statefulset/mongo -n three-tier

# 4. Backend tier
kubectl apply -f k8s/backend/service.yaml
kubectl apply -f k8s/backend/deployment.yaml
kubectl apply -f k8s/backend/hpa.yaml

# Wait for backend:
kubectl rollout status deployment/backend -n three-tier

# 5. Frontend tier
kubectl apply -f k8s/frontend/service.yaml
kubectl apply -f k8s/frontend/deployment.yaml
kubectl apply -f k8s/frontend/hpa.yaml

# 6. Ingress (ALB — Day 10)
kubectl apply -f k8s/ingress.yaml

# Or apply all at once (K8s applies in parallel, may fail if deps not ready):
kubectl apply -f k8s/ -R -n three-tier
```

---

## Security Context Summary

| Setting | Backend | Frontend | Why |
|---|---|---|---|
| `runAsNonRoot: true` | ✅ | ❌* | Backend has no port <1024 need |
| `runAsUser` | 1000 | N/A | nodejs UID from Dockerfile |
| `allowPrivilegeEscalation: false` | ✅ | ✅ | Prevent container breakout |
| `capabilities: drop ALL` | ✅ | ✅ | Minimal Linux capabilities |
| `capabilities: add NET_BIND_SERVICE` | ❌ | ✅ | Nginx needs port 80 |
| `readOnlyRootFilesystem` | ✅ | N/A | Immutable app code |
| emptyDir for /tmp | ✅ | ✅ | Writable temp for runtime |

*Nginx master process needs to bind port 80, which requires root or NET_BIND_SERVICE.

---

## Resource Sizing Guide

| Component | requests.cpu | requests.memory | limits.cpu | limits.memory |
|---|---|---|---|---|
| **Frontend (Nginx)** | 50m | 64Mi | 200m | 128Mi |
| **Backend (Node.js)** | 100m | 128Mi | 500m | 256Mi |
| **MongoDB** | 250m | 256Mi | 500m | 512Mi |

> **Production scaling**: MongoDB should be 2Gi+ memory. The values above are sized for a demo EKS cluster with t3.small nodes (2 vCPU, 2 GiB RAM).
