# MongoDB on Kubernetes — StatefulSet Design & Storage Architecture

## Why MongoDB Uses a StatefulSet

Kubernetes has two primary workload controllers for running containers:

| | Deployment | StatefulSet |
|---|---|---|
| **Pod names** | Random: `backend-7d9f4-xkz2` | Predictable: `mongo-0`, `mongo-1` |
| **Storage** | Shared PVC or ephemeral | Dedicated PVC per pod |
| **Startup/shutdown order** | Parallel (random order) | Sequential (0, 1, 2...) |
| **DNS identity** | Shared service DNS only | Per-pod DNS via Headless Service |
| **Use case** | Stateless apps (API, frontend) | Stateful apps (databases) |

MongoDB **requires** a StatefulSet because:
1. Each replica needs its **own data directory** (its own EBS volume)
2. Replica set members address each other by **stable hostnames** (`mongo-0.mongo-headless...`)
3. Pod `mongo-0` must always start before `mongo-1` (primary before secondaries)
4. If `mongo-0` crashes and restarts, it must get the **same name and same PVC** back

---

## Kubernetes Storage Architecture (EKS)

```
StatefulSet "mongo" (replicas: 1)
         │
         │ creates
         ▼
      Pod: mongo-0
         │
         │ claims storage via
         ▼
   PVC: mongo-data-mongo-0
   (ReadWriteOnce, 5Gi, gp2)
         │
         │ dynamically provisioned by
         ▼
   StorageClass: gp2
   (AWS EBS CSI Driver — installed via Terraform Day 13)
         │
         │ provisions
         ▼
   AWS EBS Volume (gp2, 5 GiB)
   in same AZ as EC2 node running mongo-0
         │
         │ mounted at
         ▼
   /data/db  inside mongo-0 container
   (WiredTiger engine stores all MongoDB data here)
```

---

## Data Persistence Scenarios

| Event | PVC Survives? | Data Survives? | Action Required |
|---|---|---|---|
| Pod deleted/evicted | ✅ Yes | ✅ Yes | K8s recreates `mongo-0`, remounts same EBS |
| Node terminated | ✅ Yes | ✅ Yes | Pod rescheduled, EBS reattaches to new node |
| StatefulSet scaled to 0 | ✅ Yes | ✅ Yes | Scale back to 1, pod remounts same EBS |
| StatefulSet deleted | ✅ Yes | ✅ Yes | PVC orphaned — must apply StatefulSet again |
| `kubectl delete pvc` | ❌ No | ❌ **DATA LOSS** | Recreate PVC, MongoDB starts fresh |
| EC2 AZ failure (1 replica) | ✅ Yes | ✅ Yes | EBS is AZ-specific — pod may get stuck if scheduler can't find node in same AZ |

> **Production note**: For multi-AZ MongoDB replica sets, each replica is in a different AZ. EBS volumes are AZ-bound, so each `mongo-N` pod stays in its AZ. This is why StatefulSet pod DNS stability matters — `mongo-0` always goes back to AZ-a's EBS, `mongo-1` to AZ-b's, etc.

---

## DNS Resolution in Kubernetes

### ClusterIP Service (`mongo-service`)

Used by the **backend pod** in its `MONGO_URI`:

```
mongodb://admin:password@mongo-service.three-tier.svc.cluster.local:27017/tasksdb

Breakdown:
  mongo-service         → K8s Service name (defined in service.yaml)
  three-tier            → Namespace
  svc                   → Kubernetes service subdomain
  cluster.local         → Default cluster domain
  :27017                → MongoDB port
  /tasksdb              → Database name
  ?authSource=admin     → Auth against 'admin' database
```

**Within the same namespace**, the short form also works:
```
mongodb://admin:password@mongo-service:27017/tasksdb?authSource=admin
```

### Headless Service (`mongo-headless`) — Per-Pod DNS

For replica set member-to-member communication:

```
mongo-0.mongo-headless.three-tier.svc.cluster.local:27017  → pod mongo-0's IP
mongo-1.mongo-headless.three-tier.svc.cluster.local:27017  → pod mongo-1's IP
mongo-2.mongo-headless.three-tier.svc.cluster.local:27017  → pod mongo-2's IP
```

---

## Files in this Manifest Set

| File | Kind | Purpose |
|---|---|---|
| `namespace.yaml` | Namespace | Creates `three-tier` namespace — apply first |
| `secret.yaml` | Secret | MongoDB credentials (base64, NOT encrypted by default) |
| `statefulset.yaml` | StatefulSet | MongoDB pod definition + PVC template |
| `service.yaml` | Service (×2) | Headless (DNS) + ClusterIP (backend access) |

---

## Apply Order

```bash
# Always apply in this order (dependencies first)
kubectl apply -f k8s/mongo/namespace.yaml
kubectl apply -f k8s/mongo/secret.yaml
kubectl apply -f k8s/mongo/service.yaml
kubectl apply -f k8s/mongo/statefulset.yaml
```

Or apply the entire directory (K8s applies in dependency order for most resources):
```bash
kubectl apply -f k8s/mongo/ -n three-tier
```

---

## Verifying the Deployment

```bash
# 1. Check StatefulSet is ready
kubectl get statefulset -n three-tier
# Expected: mongo   1/1   Ready

# 2. Check pod is running
kubectl get pods -n three-tier -l app=mongodb
# Expected: mongo-0   1/1   Running   0   <age>

# 3. Check PVC was created and bound
kubectl get pvc -n three-tier
# Expected: mongo-data-mongo-0   Bound   <pv-name>   5Gi   RWO   gp2

# 4. Check services
kubectl get svc -n three-tier -l app=mongodb
# Expected: mongo-headless (ClusterIP None) + mongo-service (ClusterIP <IP>)

# 5. Verify MongoDB is accepting connections
kubectl exec -it mongo-0 -n three-tier -- mongosh \
  --username admin --password password123 \
  --authenticationDatabase admin \
  --eval "db.adminCommand('ping')"
# Expected: { ok: 1 }

# 6. Check pod logs
kubectl logs mongo-0 -n three-tier
# Look for: "Waiting for connections" message
```

---

## Production Scaling: 1 → 3 Replicas (MongoDB Replica Set)

```yaml
# In statefulset.yaml: change replicas: 1 to replicas: 3
spec:
  replicas: 3
```

After scaling, initialize the replica set inside `mongo-0`:
```javascript
// kubectl exec -it mongo-0 -n three-tier -- mongosh -u admin -p password123 --authenticationDatabase admin

rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-0.mongo-headless.three-tier.svc.cluster.local:27017" },
    { _id: 1, host: "mongo-1.mongo-headless.three-tier.svc.cluster.local:27017" },
    { _id: 2, host: "mongo-2.mongo-headless.three-tier.svc.cluster.local:27017" }
  ]
})
// Each member hostname uses the Headless Service DNS — this is why we need it!
```

---

## Security Considerations

| Concern | Current State | Production Improvement |
|---|---|---|
| **Credential storage** | Base64 in K8s Secret (not encrypted) | Enable EKS Envelope Encryption with AWS KMS |
| **Secret management** | Manual `kubectl apply` | External Secrets Operator + AWS Secrets Manager |
| **Network access** | ClusterIP (internal only) | Add NetworkPolicy: only `backend` pods can reach MongoDB |
| **Container privileges** | Runs as UID 999 (non-root) ✅ | Keep this — it's already correct |
| **Image version** | Pinned to `mongo:6.0` ✅ | Add Trivy scan in CI/CD to catch CVEs |
| **Authentication** | Root user with INITDB credentials | Create dedicated app user with only `readWrite` on `tasksdb` |

---

## NetworkPolicy (Day 21 Preview)

```yaml
# Only backend pods can talk to MongoDB — frontend and others are blocked
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-mongo
  namespace: three-tier
spec:
  podSelector:
    matchLabels:
      app: mongodb
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: backend   # Only backend pods
      ports:
        - protocol: TCP
          port: 27017
  policyTypes:
    - Ingress
```
