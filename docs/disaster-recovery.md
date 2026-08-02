# Disaster Recovery Plan

## RTO and RPO Targets

| Scenario | RTO (Recovery Time Objective) | RPO (Data Recovery Point Objective) |
|---|---|---|
| Single pod failure | **< 2 minutes** | Zero (no data loss — pods are stateless) |
| Node failure (1 of 2) | **< 5 minutes** | Zero (pods reschedule) |
| MongoDB pod failure | **< 3 minutes** | Depends on backup frequency |
| All cluster nodes fail | **< 25 minutes** | Last MongoDB backup |
| EKS control plane outage | **< 1 hour** (AWS restores) | Zero (data in EBS/ECR/S3) |
| Complete cluster deletion | **< 30 minutes** | Last MongoDB backup |
| Region failure | **< 2 hours** | Last backup (cross-region required) |

> **RTO**: How long until the system is back online?
> **RPO**: How much data could be lost (time between last backup and failure)?

---

## Recovery Scenarios

### Scenario 1: Single Pod Failure (auto-recovered)

```
DETECTION: PodNotReady alert fires
ACTION: Kubernetes automatically restarts the pod (no human action needed)

Kubernetes ReplicaSet controller:
  Observes: desired=2, actual=1 (pod died)
  Action: creates new pod immediately
  Timeline:
    0s:  Pod dies
    5s:  Controller detects missing pod
    10s: New pod starts (container creating)
    30s: readinessProbe passes → pod enters Service endpoints
    30s: Traffic resumes on new pod

If pod keeps crashing: follow PodCrashLooping runbook above.
```

### Scenario 2: EC2 Node Failure

```
TIMELINE:
  0:00 - EC2 node hardware fails (power loss, network partition)
  0:30 - Kubernetes marks node as NotReady (kubelet stops heartbeating)
  5:00 - Pods on failed node marked for eviction (5-minute grace period)
  5:30 - PDB check: minAvailable=1 — is it safe to evict?
           Backend: 1 pod on surviving node → OK to evict dead node's pod
           Frontend: 1 pod on surviving node → OK
           MongoDB: only 1 replica! → blocked until rescheduled elsewhere
  6:00 - Pods reschedule to surviving node
  6:30 - readinessProbe passes → traffic resumes

ACTIONS FOR OPERATOR:
  1. Verify node failure:
     kubectl get nodes  (NotReady status)
     kubectl describe node <failed-node> | grep Events

  2. Terminate the bad EC2 instance (Cluster Autoscaler replaces it):
     aws ec2 terminate-instances --instance-ids <instance-id>

  3. Verify replacement node joins:
     kubectl get nodes -w  (watch for new node)
```

### Scenario 3: MongoDB Data Recovery

MongoDB is a StatefulSet with an EBS PVC. Data survives pod deletion.

```bash
# VERIFY: Data is in EBS (not in the pod)
# If mongo-0 pod is deleted, the EBS volume persists.
kubectl delete pod mongo-0 -n three-tier
# StatefulSet recreates mongo-0 and REATTACHES the same EBS volume.
kubectl get pod mongo-0 -n three-tier -w  # Watch it restart with same data.

# BACKUP: Manual MongoDB backup to S3
kubectl exec -n three-tier mongo-0 -- \
  mongodump \
    --uri="mongodb://admin:$(kubectl get secret mongo-secret \
      -n three-tier -o jsonpath='{.data.MONGO_PASSWORD}' | base64 -d)@localhost:27017" \
    --out=/tmp/backup

# Copy backup from pod to local
kubectl cp three-tier/mongo-0:/tmp/backup ./mongo-backup-$(date +%Y%m%d-%H%M)

# Upload to S3
aws s3 cp ./mongo-backup-$(date +%Y%m%d-%H%M) \
  s3://three-tier-eks-terraform-state/mongodb-backups/ \
  --recursive

# RESTORE: From S3 backup
aws s3 cp \
  s3://three-tier-eks-terraform-state/mongodb-backups/mongo-backup-20240115-1200 \
  ./restore --recursive

kubectl cp ./restore three-tier/mongo-0:/tmp/restore

kubectl exec -n three-tier mongo-0 -- \
  mongorestore \
    --uri="mongodb://admin:<password>@localhost:27017" \
    --drop \
    /tmp/restore
```

### Scenario 4: Complete Cluster Reconstruction

If the entire cluster is accidentally deleted (terraform destroy) or destroyed:

```bash
# Total reconstruction time: ~25 minutes

# STEP 1: Backend infrastructure (18-20 min)
cd terraform
terraform init
terraform apply -auto-approve
# Creates: VPC, EKS, ECR, IAM, EBS CSI, ALB Controller, Cluster Autoscaler

# STEP 2: Configure kubectl (1 min)
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1

# STEP 3: Apply K8s manifests (2 min)
chmod +x scripts/k8s-apply.sh
./scripts/k8s-apply.sh

# STEP 4: Restore MongoDB data from S3 backup (2 min)
# (follow Scenario 3 restore steps above)

# STEP 5: Trigger new deployment (1 min)
# Push a commit or trigger CD workflow manually
# gh workflow run cd.yml

# STEP 6: Verify
kubectl get pods -n three-tier
kubectl get ingress three-tier-ingress -n three-tier
# Wait for ALB to be ACTIVE (2-3 minutes)
```

---

## Backup Strategy

### What Needs Backing Up?

| Data | Storage | Backup Strategy | RPO |
|---|---|---|---|
| **Terraform state** | S3 (versioned) | S3 versioning auto-enabled | Near-zero |
| **Docker images** | ECR | IMMUTABLE tags, lifecycle=10 | Last ECR push |
| **K8s manifests** | GitHub | Git history | Last commit |
| **MongoDB data** | EBS PVC | Manual or CronJob to S3 | Backup frequency |
| **Grafana dashboards** | EBS PVC + ConfigMap | Git-stored ConfigMaps | Last commit |
| **Secrets** | K8s etcd (EKS managed) | Re-create from AWS Secrets Manager | N/A |

### Automated MongoDB Backup (CronJob)

```yaml
# k8s/mongo/backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mongo-backup
  namespace: three-tier
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM UTC
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: mongodump
            image: mongo:6.0
            command:
            - sh
            - -c
            - |
              mongodump \
                --uri="$MONGO_URI" \
                --out=/tmp/backup && \
              aws s3 cp /tmp/backup \
                s3://three-tier-eks-terraform-state/mongodb-backups/$(date +%Y%m%d-%H%M) \
                --recursive
            env:
            - name: MONGO_URI
              valueFrom:
                secretKeyRef:
                  name: mongo-secret
                  key: MONGO_URI
          restartPolicy: OnFailure
```

---

## Chaos Engineering — Validating Resilience

```bash
# Test 1: Kill a backend pod (verify auto-recovery)
kubectl delete pod $(kubectl get pod -n three-tier -l app=backend \
  -o jsonpath='{.items[0].metadata.name}') -n three-tier
# Expected: Kubernetes creates replacement pod in ~30 seconds
# Verify: kubectl get pods -n three-tier -w

# Test 2: Kill ALL backend pods (verify PDB + readinessProbe)
kubectl delete pods -n three-tier -l app=backend
# Expected: Both pods restart, briefly 0 serving → auto-recover
# For PDB protection: use drain, not delete (delete bypasses PDB)

# Test 3: Fill MongoDB disk (verify disk alert)
kubectl exec -n three-tier mongo-0 -- \
  dd if=/dev/zero of=/data/db/test-file bs=1M count=4000
# Expected: MongoDBDiskRunningLow alert fires at <20% free
# Clean up: kubectl exec -n three-tier mongo-0 -- rm /data/db/test-file

# Test 4: Trigger HPA (verify auto-scaling)
# Run: k6 run k6/load-tests/hpa-validation.js -e BASE_URL=http://<ALB>
# Expected: backend scales from 2 → 3-5 pods within 90 seconds

# Test 5: Node drain (verify PDB protects pods)
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
# Expected: pods evicted one at a time, MongoDB pod blocks drain if can't reschedule
kubectl uncordon $NODE  # Restore node after test
```
