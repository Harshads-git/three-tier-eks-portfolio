# Operations Runbook — Three-Tier EKS Portfolio

> **Purpose**: Step-by-step incident response procedures for every alert defined in `k8s/monitoring/alerting-rules.yaml`.
> **On-call rule**: Read the alert → find the section → follow steps in order.

---

## Quick Reference — Cluster Access

```bash
# 1. Configure kubectl (run once after login)
aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1

# 2. Verify cluster is reachable
kubectl cluster-info
kubectl get nodes -o wide

# 3. Check overall health
kubectl get pods -n three-tier
kubectl get pods -n kube-system
kubectl get hpa,pdb -n three-tier

# 4. Access Grafana (local tunnel)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
# Open: http://localhost:3000 (admin / ThreeTierPortfolio2024!)
```

---

## INCIDENT: PodCrashLooping

**Alert**: `PodCrashLooping` — severity: **critical**
**Trigger**: Pod restarting >2 times in 5 minutes

### Triage (2 minutes)

```bash
# 1. Which pod is crash-looping?
kubectl get pods -n three-tier
# Look for RESTARTS > 3 or STATUS = CrashLoopBackOff

# 2. What is the pod's last error?
kubectl logs <pod-name> -n three-tier --previous
# --previous: shows logs from the LAST crashed container (not current)

# 3. Why did it crash?
kubectl describe pod <pod-name> -n three-tier
# Look for: Last State, Exit Code, Events at the bottom
# Exit Code 137 = OOMKill (memory limit hit)
# Exit Code 1   = Application error (non-zero exit)
# Exit Code 139 = Segmentation fault (very rare in Node.js)
```

### Resolution by Exit Code

```bash
# Exit Code 137 — OOM Kill (memory limit exceeded)
kubectl describe pod <pod-name> -n three-tier | grep -A 5 "Last State"
# Fix: Increase memory limit in k8s/<service>/deployment.yaml
# Temporary: kubectl set resources deployment/backend \
#   --limits=memory=512Mi -n three-tier

# Exit Code 1 — Application crash
kubectl logs <pod-name> -n three-tier --previous | tail -50
# Look for: Error, Cannot connect to MongoDB, ECONNREFUSED, TypeError
# Common: MongoDB connection string wrong → check backend-config ConfigMap
kubectl get configmap backend-config -n three-tier -o yaml
kubectl get secret mongo-secret -n three-tier -o yaml | base64 -d

# General: Force restart with new image
kubectl rollout restart deployment/backend -n three-tier
kubectl rollout status deployment/backend -n three-tier --timeout=120s
```

### Escalation

If restarts continue after the above steps:
```bash
# 1. Scale down to 0 to stop the restart loop
kubectl scale deployment/backend --replicas=0 -n three-tier

# 2. Investigate thoroughly
kubectl logs <pod-name> -n three-tier --previous | grep -i "error\|fatal\|uncaught"

# 3. Scale back up
kubectl scale deployment/backend --replicas=2 -n three-tier
```

---

## INCIDENT: PodNotReady

**Alert**: `PodNotReady` — severity: **warning**
**Trigger**: Pod not in Ready state for 5 minutes

```bash
# 1. Identify the not-ready pod
kubectl get pods -n three-tier -o wide
# STATUS: Running but READY 0/1 = readinessProbe failing

# 2. Check the readiness probe status
kubectl describe pod <pod-name> -n three-tier | grep -A 10 "Readiness"
# Readiness: http-get http://:5000/api/health delay=10s timeout=5s

# 3. Is the health endpoint responding?
kubectl exec -n three-tier <any-running-pod> -- \
  curl -s http://<pod-ip>:5000/api/health
# If 200: readinessProbe config might be wrong
# If 500: backend is failing health checks (DB connection issue?)

# 4. Check MongoDB connection
kubectl exec -n three-tier <backend-pod> -- \
  node -e "const {MongoClient}=require('mongodb'); \
  MongoClient.connect(process.env.MONGO_URI).then(()=>console.log('OK')).catch(e=>console.error(e))"

# 5. Check node the pod is on (node pressure?)
kubectl describe node <node-name> | grep -E "Conditions|Pressure"
# DiskPressure=True: node is running out of disk (old container images?)
# MemoryPressure=True: node is low on memory
```

---

## INCIDENT: HighMemoryUtilization

**Alert**: `HighMemoryUtilization` — severity: **critical**
**Trigger**: Container memory > 90% of limit (OOMKill imminent)

```bash
# 1. Current memory usage
kubectl top pods -n three-tier --containers
# NAME       CONTAINER   CPU    MEMORY
# backend-x  backend     150m   230Mi  ← approaching 256Mi limit!

# 2. Is it a memory leak? Check growth over time
# Grafana → Dashboards → Kubernetes Pods → backend pod → Memory graph
# Linear growth over hours = memory leak

# 3. Immediate: restart the container to reclaim memory
kubectl rollout restart deployment/backend -n three-tier
# Rolling restart: new pods start before old ones stop (zero downtime)

# 4. Medium-term: increase memory limit
# Edit k8s/backend/deployment.yaml:
#   resources.limits.memory: 512Mi  (double the current 256Mi)
kubectl apply -f k8s/backend/deployment.yaml

# 5. Long-term: profile the Node.js memory usage
# Add heap snapshot endpoint or use Clinic.js for profiling
```

---

## INCIDENT: HPAAtMaxReplicas

**Alert**: `HPAAtMaxReplicas` — severity: **warning**
**Trigger**: HPA at maxReplicas (5) for 15+ minutes

This means the application is at full capacity. More load than 5 pods can handle.

```bash
# 1. Confirm HPA state
kubectl get hpa backend-hpa -n three-tier
# REPLICAS: 5/5 (at max)

# 2. Check current load
kubectl top pods -n three-tier

# 3. Option A: Increase maxReplicas (requires node capacity)
# Edit k8s/backend/hpa.yaml: maxReplicas: 10
kubectl apply -f k8s/backend/hpa.yaml
# Note: more pods need more nodes — check Cluster Autoscaler added nodes

# 4. Option B: Increase node group size (if CA is also at limit)
# Edit terraform/variables.tf: node_max_size = 6
# Commit → terraform.yml workflow applies it
# OR: manual override:
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name <node-group-asg-name> \
  --desired-capacity 4

# 5. Option C: Find and fix the performance bottleneck
# Check: Is this sustained traffic OR a spike?
# Grafana → backend request rate graph
# If spike: investigate DDoS or traffic anomaly
# If sustained: app optimization needed
```

---

## INCIDENT: MongoDBDiskCritical

**Alert**: `MongoDBDiskCritical` — severity: **critical**
**Trigger**: MongoDB PVC < 5% free space

```bash
# 1. Confirm disk usage
kubectl exec -n three-tier mongo-0 -- df -h /data/db
# OR via metrics:
kubectl get pvc -n three-tier

# 2. How much data is in MongoDB?
kubectl exec -n three-tier mongo-0 -- mongosh --eval \
  'db.adminCommand({listDatabases:1}).databases.forEach(d=>print(d.name, d.sizeOnDisk))'

# 3. Immediate: expand the EBS volume (if StorageClass allows)
kubectl patch pvc mongo-data-mongo-0 -n three-tier \
  --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
# Wait 2-3 minutes for EBS to expand
kubectl get pvc -n three-tier -w

# 4. Clean up old data if possible (application-level)
# Delete completed/old tasks that are no longer needed

# 5. Verify expansion
kubectl exec -n three-tier mongo-0 -- df -h /data/db
# Should show larger disk now

# NOTE: gp2 StorageClass supports volume expansion by default.
# If pvc patch fails: check StorageClass allowVolumeExpansion: true
kubectl get storageclass gp2 -o yaml | grep allowVolumeExpansion
```

---

## INCIDENT: Deployment Rollback

When a bad deployment reaches production:

```bash
# 1. Identify the bad deployment
kubectl rollout history deployment/backend -n three-tier
# REVISION  CHANGE-CAUSE
# 1         Initial deployment
# 2         sha-abc1234 deployed  ← current bad deployment

# 2. Immediate rollback to previous version
kubectl rollout undo deployment/backend -n three-tier
kubectl rollout status deployment/backend -n three-tier --timeout=120s

# 3. Rollback to a specific revision
kubectl rollout undo deployment/backend --to-revision=1 -n three-tier

# 4. Rollback via image tag (to a specific git SHA)
kubectl set image deployment/backend \
  backend=<ecr-url>/three-tier-eks-cluster-backend:sha-previous \
  -n three-tier
kubectl rollout status deployment/backend -n three-tier

# 5. Prevent bad code from re-deploying
# Block the branch in GitHub until the issue is fixed
# Open a P1 issue: gh issue create --title "ROLLBACK: <describe issue>" --label "P1"
```

---

## INCIDENT: Node Not Ready

```bash
# 1. Check node status
kubectl get nodes
# STATUS: NotReady = node is unhealthy

# 2. Describe the unhealthy node
kubectl describe node <node-name> | grep -A 20 "Conditions:"
# Check: KubeletReady, MemoryPressure, DiskPressure, PIDPressure

# 3. Check node events
kubectl get events --field-selector involvedObject.name=<node-name> -A

# 4. Drain the node (move pods to healthy nodes)
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=60s
# Note: PDBs will protect your pods during drain (minAvailable=1)

# 5. If EC2 instance is healthy: try uncordon
kubectl uncordon <node-name>

# 6. If EC2 instance is truly failed: terminate it
# Cluster Autoscaler will replace it automatically
aws ec2 terminate-instances --instance-ids <instance-id>
```

---

## Daily Health Check Script

```bash
#!/bin/bash
# Run this every morning to verify cluster health

echo "=== CLUSTER NODES ==="
kubectl get nodes -o wide

echo ""
echo "=== PODS STATUS ==="
kubectl get pods -n three-tier
kubectl get pods -n kube-system | grep -E "(crash|error|pending)" || echo "kube-system: all pods healthy"

echo ""
echo "=== HPA STATUS ==="
kubectl get hpa -n three-tier

echo ""
echo "=== PDB STATUS ==="
kubectl get pdb -n three-tier

echo ""
echo "=== RESOURCE USAGE ==="
kubectl top nodes
kubectl top pods -n three-tier

echo ""
echo "=== RECENT EVENTS (last 1 hour) ==="
kubectl get events -n three-tier --sort-by='.lastTimestamp' | tail -20

echo ""
echo "=== RECENT DEPLOYMENTS ==="
kubectl rollout history deployment/backend -n three-tier
kubectl rollout history deployment/frontend -n three-tier
```
