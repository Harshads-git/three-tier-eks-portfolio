# End-to-End Validation Checklist

> Run this checklist before declaring the project production-ready.
> Every check includes the exact command and expected output.

---

## Pre-Deployment Validation

### ✅ Local Environment

```bash
# 1. Local dev stack starts cleanly
docker compose up -d
sleep 30
curl http://localhost:5000/api/health
# Expected: {"status":"ok"} or {"status":"healthy"}

curl http://localhost:5000/api/tasks
# Expected: [] or array of tasks

curl -X POST http://localhost:5000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Validation Test","description":"Test task","completed":false}'
# Expected: {"_id":"...","title":"Validation Test",...}

curl http://localhost:3000
# Expected: HTTP 200, Content-Type: text/html

docker compose down
```

### ✅ Docker Images Build Cleanly

```bash
docker build -t test-backend:local app/backend/
docker build -t test-frontend:local app/frontend/

# Verify image sizes are reasonable
docker images | grep test-
# Expected:
#   test-backend    local    ~180MB (Node.js Alpine)
#   test-frontend   local    ~25MB  (Nginx Alpine)

# No 'latest' tags in base images of the multi-stage builds
grep -r "FROM.*:latest" app/
# Expected: No output (should have pinned versions)
```

---

## Infrastructure Validation

### ✅ Terraform State

```bash
cd terraform

# State is remote (not local)
cat .terraform/terraform.tfstate 2>/dev/null && echo "LOCAL STATE EXISTS - PROBLEM!" || echo "OK: No local state"

# Remote state is accessible
terraform state list | head -20
# Expected: list of AWS resources

# No drift (what Terraform knows matches what AWS has)
terraform plan -detailed-exitcode
# Exit code 0 = no changes (infrastructure matches code)
# Exit code 2 = changes exist (drift detected)
```

### ✅ EKS Cluster Nodes

```bash
kubectl get nodes -o wide
# Expected:
#   NAME                         STATUS   ROLES    AGE   VERSION
#   ip-10-0-1-xxx.ec2.internal   Ready    <none>   Xd    v1.29.x
#   ip-10-0-2-xxx.ec2.internal   Ready    <none>   Xd    v1.29.x
# All nodes STATUS = Ready

kubectl get nodes -o json | jq '.items[].status.conditions[] | select(.type=="Ready") | .status'
# Expected: "True" (twice, one per node)
```

---

## Application Validation

### ✅ All Pods Running

```bash
kubectl get pods -n three-tier
# Expected:
#   NAME                        READY   STATUS    RESTARTS
#   backend-xxx-yyy             1/1     Running   0
#   backend-xxx-zzz             1/1     Running   0
#   frontend-xxx-yyy            1/1     Running   0
#   frontend-xxx-zzz            1/1     Running   0
#   mongo-0                     1/1     Running   0
# NO: CrashLoopBackOff, Error, OOMKilled, ImagePullBackOff

# Check restart counts (should be 0)
kubectl get pods -n three-tier -o json | \
  jq '.items[] | {name:.metadata.name, restarts:.status.containerStatuses[0].restartCount}'
```

### ✅ Services and Endpoints

```bash
kubectl get svc -n three-tier
# Expected: frontend-service (NodePort), backend-service (NodePort), mongo-service (ClusterIP)

# Verify endpoints exist (pods are registered in the service)
kubectl get endpoints -n three-tier
# Expected: Each service should have pod IP:port entries

kubectl describe endpoints backend-service -n three-tier | grep "Addresses"
# Expected: "Addresses: 10.0.x.x,10.0.x.x" (2 pod IPs)
```

### ✅ ALB and Ingress

```bash
kubectl get ingress -n three-tier
# Expected: three-tier-ingress with ADDRESS = <alb-dns>.elb.amazonaws.com

ALB_DNS=$(kubectl get ingress three-tier-ingress -n three-tier \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"

# Test frontend
curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/
# Expected: 200

# Test backend health via ALB
curl -s http://$ALB_DNS/api/health
# Expected: {"status":"ok"}

# Test backend API via ALB
curl -s http://$ALB_DNS/api/tasks
# Expected: [] (empty array or list of tasks)

# Test routing: /api/* goes to backend, /* goes to frontend
curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/api/health
# Expected: 200 (backend)
curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/static/js/main.js 2>/dev/null || true
# Expected: 200 or 304 (frontend static asset)
```

---

## Auto-Scaling Validation

### ✅ HPA Configuration

```bash
kubectl get hpa -n three-tier
# Expected:
#   NAME           REFERENCE             TARGETS    MINPODS   MAXPODS   REPLICAS
#   backend-hpa    Deployment/backend    12%/70%    2         5         2
#   frontend-hpa   Deployment/frontend   5%/70%     2         5         2
# Note: TARGETS should show current CPU/target (not <unknown>)

# If TARGETS shows <unknown>: Metrics Server may not be running
kubectl get deployment metrics-server -n kube-system
# Expected: READY 1/1
```

### ✅ HPA Scaling Test (manual)

```bash
# Generate CPU load to trigger HPA
kubectl run load-generator --image=busybox:1.35 -it --rm \
  -n three-tier -- /bin/sh -c \
  "while true; do wget -q -O- http://backend-service:5000/api/tasks; done"
# Let this run for 2 minutes, then watch:

# In another terminal:
watch -n 5 'kubectl get hpa,pods -n three-tier'
# Expected: backend replicas increase from 2 → 3+ as CPU crosses 70%

# Stop the load generator (Ctrl+C), wait 5 min, see scale-down
```

### ✅ PodDisruptionBudgets

```bash
kubectl get pdb -n three-tier
# Expected:
#   NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
#   backend-pdb    1               N/A               1
#   frontend-pdb   1               N/A               1
#   mongo-pdb      1               N/A               0    ← 0 = no evictions allowed!
```

---

## Security Validation

### ✅ NetworkPolicies Applied

```bash
kubectl get networkpolicies -n three-tier
# Expected: default-deny-all, allow-alb-to-frontend, allow-frontend-backend-ingress,
#           allow-backend-to-mongo, allow-dns-egress

# Verify enforcement is active (requires VPC CNI agent)
kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="ENABLE_NETWORK_POLICY")].value}'
# Expected: true

# Test: frontend CANNOT reach MongoDB (should fail if NetworkPolicy is enforced)
FRONTEND_POD=$(kubectl get pod -n three-tier -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n three-tier $FRONTEND_POD -- \
  timeout 5 bash -c "echo > /dev/tcp/mongo-service/27017" 2>&1 || echo "BLOCKED (expected)"
# Expected: connection timeout or refused (NetworkPolicy working)
```

### ✅ IRSA (No Stored Credentials)

```bash
# Verify no AWS credentials in pod environment
BACKEND_POD=$(kubectl get pod -n three-tier -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n three-tier $BACKEND_POD -- env | grep -i "aws_access_key\|aws_secret"
# Expected: No output (backend doesn't have AWS credentials)

# Verify ALB controller has IRSA (not instance profile)
kubectl describe pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  | grep "AWS_ROLE_ARN\|AWS_WEB_IDENTITY"
# Expected: AWS_ROLE_ARN env var set (IRSA working)
```

### ✅ Resource Governance

```bash
kubectl describe resourcequota three-tier-quota -n three-tier
# Expected:
#   Resource               Used    Hard
#   pods                   5       20
#   requests.cpu           550m    2
#   services.loadbalancers 0       0   ← no LoadBalancer services!

# Verify LimitRange is injecting defaults
kubectl describe limitrange three-tier-limits -n three-tier
# Expected: shows Container type with default requests/limits
```

---

## CI/CD Validation

### ✅ CI Pipeline

```bash
# Check recent CI workflow runs
gh run list --workflow=ci.yml --limit=5
# Expected: All recent runs are "completed success" ✓

# Check Trivy scan results uploaded to GitHub Security
# GitHub → Security → Code scanning alerts
# Expected: No critical CVEs (or they're documented with fix plan)
```

### ✅ CD Pipeline

```bash
# Verify the latest deployment used the correct image
kubectl get deployment backend -n three-tier \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: <account>.dkr.ecr.us-east-1.amazonaws.com/three-tier-eks-cluster-backend:sha-<githash>
# NOT: :latest (immutable tag pattern)

# Verify image SHA matches a recent git commit
git log --oneline -5
# Match the sha- prefix in the image tag to one of these commits
```

---

## Observability Validation

### ✅ Prometheus Scraping

```bash
# Port-forward Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &

# Check targets
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import json,sys; \
  targets=json.load(sys.stdin)['data']['activeTargets']; \
  [print(t['labels']['job'], t['health']) for t in targets]"
# Expected: Each target shows "up" health

# Check our custom rules are loaded
curl -s http://localhost:9090/api/v1/rules | \
  python3 -c "import json,sys; \
  groups=json.load(sys.stdin)['data']['groups']; \
  [print(g['name']) for g in groups if 'three-tier' in g['name']]"
# Expected: three-tier.pods, three-tier.resources, three-tier.storage, three-tier.recording
```

### ✅ Grafana Accessible

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
# Expected: 200 (redirect to login page)
```

---

## Smoke Test (automated)

```bash
ALB_DNS=$(kubectl get ingress three-tier-ingress -n three-tier \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

k6 run k6/load-tests/smoke-test.js -e BASE_URL=http://$ALB_DNS
# Expected:
#   ✓ health check: status 200
#   ✓ GET /api/tasks: status 200
#   ✓ POST /api/tasks: status 201
#   ✓ Frontend: status 200
#
#   checks: 100%
#   http_req_failed: 0.00%
#   http_req_duration p(95) < 500ms ✓
```

---

## Final Verification Summary

| Category | Checks | Status |
|---|---|---|
| Infrastructure | Terraform, EKS nodes | ⬜ |
| Application | Pods, Services, ALB routing | ⬜ |
| Auto-scaling | HPA metrics, PDB | ⬜ |
| Security | NetworkPolicy, IRSA, ResourceQuota | ⬜ |
| CI/CD | Workflow runs, image tags | ⬜ |
| Observability | Prometheus targets, Grafana | ⬜ |
| Load Testing | Smoke test pass | ⬜ |

> Replace ⬜ with ✅ (pass) or ❌ (fail with notes) after running each section.
