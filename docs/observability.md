# Observability Architecture — Monitoring Stack

## Full Observability Stack Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OBSERVABILITY STACK (monitoring namespace)                │
│                                                                             │
│  DATA COLLECTION (every 30-60s):                                           │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐ │
│  │  Node Exporter   │  │ kube-state-      │  │  Prometheus Operator     │ │
│  │  (DaemonSet)     │  │ metrics          │  │  watches ServiceMonitor  │ │
│  │  EC2 host metrics│  │ K8s obj metrics  │  │  CRDs → updates config   │ │
│  └────────┬─────────┘  └────────┬─────────┘  └────────────┬─────────────┘ │
│           │                     │                          │               │
│           └─────────────────────┼──────────────────────────┘               │
│                                 ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                         PROMETHEUS                                   │  │
│  │  Scrapes: backend /metrics, frontend /nginx-health, node-exporter   │  │
│  │  Stores: 30 days of time-series data (10Gi EBS)                     │  │
│  │  Evaluates: PrometheusRules every 60s                                │  │
│  └──────────────────────┬───────────────────────┬────────────────────────┘  │
│                         │                       │                           │
│                         ▼                       ▼                           │
│  ┌────────────────────────────┐  ┌───────────────────────────────────────┐ │
│  │       GRAFANA              │  │          ALERTMANAGER                  │ │
│  │  Dashboards:               │  │  Routes alerts:                        │ │
│  │  - Cluster overview        │  │  critical → immediate notification     │ │
│  │  - Three-tier app          │  │  warning  → batched notification       │ │
│  │  - Node metrics            │  │  Targets: Slack, email, PagerDuty     │ │
│  │  - Pod resources           │  └───────────────────────────────────────┘ │
│  └────────────────────────────┘                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## The THREE Pillars of Observability

| Pillar | Tool | What It Answers |
|---|---|---|
| **Metrics** | Prometheus + Grafana | "How many requests/sec? What's the latency? Is CPU high?" |
| **Logs** | CloudWatch Container Insights / Loki | "What exactly happened at 14:32? What error did pod-X log?" |
| **Traces** | AWS X-Ray / Jaeger (future) | "Which service caused the 500ms latency spike?" |

This project focuses on **Metrics** (most impact per effort for a portfolio project).

---

## Key Metrics for Each Tier

### Frontend (Nginx)
```promql
# Request rate
rate(nginx_http_requests_total[5m])

# Active connections
nginx_connections_active

# Availability (is Nginx up?)
up{job="frontend"}
```

### Backend (Node.js + prom-client)
```promql
# API request rate by endpoint
rate(http_requests_total{namespace="three-tier"}[5m])

# Error rate (4xx + 5xx responses)
rate(http_requests_total{status_code=~"[45].."}[5m])
/ rate(http_requests_total[5m])

# Response time (p50, p95, p99)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Node.js event loop lag (early warning for performance issues)
nodejs_eventloop_lag_seconds
```

### MongoDB (via mongodb_exporter sidecar)
```promql
# Operations per second
rate(mongodb_op_counters_total[5m])

# Current connections
mongodb_connections{state="current"}

# Replication lag (for replica sets)
mongodb_mongod_replset_member_optime_date{state="SECONDARY"}

# Collection sizes
mongodb_dbstats_dataSize{db="three-tier"}
```

### Cluster (Kubernetes)
```promql
# Pod restart rate (crash detection)
rate(kube_pod_container_status_restarts_total[5m])

# HPA current vs desired
kube_horizontalpodautoscaler_status_current_replicas
kube_horizontalpodautoscaler_spec_desired_replicas

# CPU utilization per pod
sum(rate(container_cpu_usage_seconds_total{namespace="three-tier"}[5m])) by (pod)

# Memory utilization per pod
sum(container_memory_working_set_bytes{namespace="three-tier"}) by (pod)
```

---

## Alert Rules Summary

| Alert Name | Condition | Severity | For |
|---|---|---|---|
| `PodCrashLooping` | >2 restarts in 5m | critical | 5m |
| `PodNotReady` | Pod not ready | warning | 5m |
| `DeploymentReplicasMismatch` | Available < desired | warning | 10m |
| `HighCPUUtilization` | CPU > 85% of limit | warning | 10m |
| `HighMemoryUtilization` | Memory > 90% of limit | critical | 5m |
| `HPAAtMaxReplicas` | HPA at max | warning | 15m |
| `MongoDBDiskRunningLow` | Disk < 20% free | warning | 10m |
| `MongoDBDiskCritical` | Disk < 5% free | critical | 5m |

---

## Install and Access

### Step 1: Install the stack

```bash
# Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# Install with our custom values
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/prometheus-stack-values.yaml \
  --version 58.4.0

# Verify all pods running
kubectl get pods -n monitoring
```

### Step 2: Apply custom resources

```bash
# ServiceMonitors for backend, frontend, MongoDB
kubectl apply -f k8s/monitoring/servicemonitors.yaml

# Alert rules
kubectl apply -f k8s/monitoring/alerting-rules.yaml

# Verify Prometheus picked up the rules
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# Open: http://localhost:9090/rules  → look for 'three-tier-alerts'
# Open: http://localhost:9090/targets → look for 'three-tier/backend-monitor'
```

### Step 3: Access Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000
# Username: admin
# Password: ThreeTierPortfolio2024! (from values file)

# Or get the auto-generated password:
kubectl get secret kube-prometheus-stack-grafana \
  -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Step 4: Import pre-built dashboards

```
Grafana → + → Import → Enter ID:
  17119 → Kubernetes Cluster Overview (kube-prometheus-stack)
  6417  → Kubernetes Pods (kube-state-metrics)
  1860  → Node Exporter Full (EC2 node metrics)
  7362  → MongoDB Overview (requires mongodb_exporter)
```

---

## The `for:` Duration in Alert Rules — Why It Matters

```
Alert defined: PodCrashLooping (for: 5m)

00:00 - Pod restarts 3 times → condition becomes TRUE → alert enters "pending"
00:01 - Pod still restarting → still TRUE → still "pending"
...
00:05 - Still TRUE for 5 minutes → alert FIRES → AlertManager receives it

WITHOUT 'for':
  00:00 - Single restart → alert fires immediately → false alarm!
  (One restart during deployment is normal behavior)

WITH 'for: 5m':
  Alert fires only after sustained issue → fewer false alarms → ops team trusts alerts
  Rule: fire-and-forget alerts = ops team ignores ALL alerts
        Precise 'for' duration = high signal-to-noise ratio = trusted alerts
```

---

## Cost Analysis — Monitoring Stack

| Component | Cost |
|---|---|
| Grafana persistence | 2Gi EBS = $0.20/month |
| Prometheus storage | 10Gi EBS = $1.00/month |
| AlertManager storage | 2Gi EBS = $0.20/month |
| CPU for monitoring pods | ~500m (split across 2 nodes) |
| **Total monitoring overhead** | **~$1.40/month + 12.5% CPU** |

The monitoring stack costs less than $2/month additional — the value of catching a production incident early vastly outweighs this cost.
