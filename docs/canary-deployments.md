# Progressive Delivery with Argo Rollouts — Architecture & Canary Operations

> **Core Concept:** Never deploy untested code to 100% of users. Release gradually to a small fraction of traffic (10%), verify against live Prometheus metrics in real time, and automatically abort if errors or latency spike.

---

## 1. Why Progressive Delivery over Standard Rolling Updates?

| Feature | Standard Kubernetes Deployment (`RollingUpdate`) | Argo Rollouts (`Canary`) |
|---|---|---|
| **Traffic Splitting** | ❌ None (random per pod ratio) | ✅ **Precise traffic percentage** (10% → 25% → 50% → 100%) |
| **Verification Gate** | ❌ Readiness probe only (process health) | ✅ **Prometheus analysis** (Error rate, P99 latency) |
| **Blast Radius** | ⚠️ High (100% of users affected if bug passes probe) | 🛡️ **Minimal** (Only 10% exposed during evaluation) |
| **Rollback Trigger** | ❌ Manual engineer intervention required | 🤖 **Fully automated** within 30 seconds of metric breach |
| **Rollback Speed** | ⚠️ Slow (re-pulls previous image, recreates pods) | ⚡ **Instant** (Preserved previous ReplicaSet receives 100% traffic) |

---

## 2. Traffic Shifting Architecture on Amazon EKS

Argo Rollouts coordinates with the **AWS Load Balancer Controller** to dynamically split incoming traffic at the Application Load Balancer target group level.

```
Incoming Internet Traffic
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│                 AWS Application Load Balancer               │
│                                                             │
│   Routing Rule for /api/*:                                  │
│   - backend-service (Stable Target Group): 90% weight       │
│   - backend-service-canary (Canary Target Group): 10% weight│
└─────────────────┬───────────────────────────┬───────────────┘
                  │ 90%                       │ 10%
                  ▼                           ▼
        ┌────────────────────┐      ┌────────────────────┐
        │  Stable Pods (v1)  │      │  Canary Pods (v2)  │
        │  backend-v1-xxx    │      │  backend-v2-yyy    │
        │  backend-v1-zzz    │      │                    │
        └────────────────────┘      └─────────┬──────────┘
                                              │
                                              ▼
                                   Scraped by Prometheus
                                              │
                                              ▼
                                ┌───────────────────────────┐
                                │     AnalysisTemplate      │
                                │  • 5xx Error Rate <= 1%   │
                                │  • P99 Latency <= 300ms   │
                                └─────────────┬─────────────┘
                                              │
                         ┌────────────────────┴────────────────────┐
                         │                                         │
                    Metric Passes                            Metric Fails
                         ▼                                         ▼
            Advance to next step (25%)              AUTOMATIC EMERGENCY ABORT
                                                    • Shift 100% traffic to v1
                                                    • Scale down v2 canary
```

---

## 3. Canary Progression Step Timeline

Our backend rollout ([k8s/rollouts/backend-rollout.yaml](../k8s/rollouts/backend-rollout.yaml)) enforces the following staged schedule:

```
T + 00:00 ─── Deploy Canary v2 (1 pod created)
      │
      ├─── Step 1: Set weight to 10%
      │    10% of API requests route to Canary v2
      │
      ├─── Step 2: Pause 2 minutes
      │    AnalysisRun queries Prometheus:
      │    ✓ 5xx error rate: 0.02% (threshold <= 1%)
      │    ✓ P99 latency: 45ms (threshold <= 300ms)
      │
T + 02:00 ─── Step 3: Increase weight to 25%
      │    Canary scaled to handle 25% load
      │
      ├─── Step 4: Pause 5 minutes
      │    Sustained load verification under k6 traffic
      │
T + 07:00 ─── Step 5: Increase weight to 50%
      │    Half of production traffic routed to v2
      │
      ├─── Step 6: Pause 5 minutes
      │    Final confidence gate
      │
T + 12:00 ─── Step 7: Promote to 100%
           Canary v2 becomes the new Stable version.
           Previous ReplicaSet kept alive for 60s (scaleDownDelaySeconds), then pruned.
```

---

## 4. Automated Analysis & Rollback Scenarios

### Scenario: Broken Release with Latent 500 Errors
A developer commits a change where a malformed database query causes 5% of requests to throw an unhandled exception.

1. **Step 1:** Rollout shifts 10% of traffic to the new pod.
2. **AnalysisRun:** Prometheus records HTTP 500 responses. The query returns:
   ```promql
   sum(rate(http_requests_total{status=~"5.."}[1m])) / sum(rate(http_requests_total[1m])) = 0.051 (5.1%)
   ```
3. **Trigger:** `0.051 > 0.01` breaches `successCondition: result[0] <= 0.01`.
4. **Second verification (30s later):** Still failing. Exceeds `failureLimit: 2`.
5. **Instant Abort:**
   - Argo Rollouts sets the rollout phase to `Degraded`.
   - AWS ALB target group weight for canary is set to `0%`.
   - Stable v1 pods immediately receive 100% of traffic.
   - Outage duration for users: **Only 10% of users saw errors for < 60 seconds.**

---

## 5. Daily SRE Operations with Argo Rollouts CLI

```bash
# Watch a live rollout in terminal with visual progression
kubectl argo rollouts get rollout backend -n three-tier --watch

# View the Web Dashboard UI (waterfall graphs, metrics, and logs)
kubectl argo rollouts dashboard -n argo-rollouts &

# Manually promote a paused rollout (override pause timer)
kubectl argo rollouts promote backend -n three-tier

# Manual Emergency Abort (instantly reverts to stable)
kubectl argo rollouts abort backend -n three-tier

# Retry an aborted rollout after fixing an external dependency
kubectl argo rollouts retry rollout backend -n three-tier

# Declarative rollback to a specific previous revision
kubectl argo rollouts undo backend -n three-tier --to-revision=2
```
