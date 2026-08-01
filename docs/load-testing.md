# Load Testing Strategy & HPA Scaling Behavior

## Test Suite Overview

| Test | VUs | Duration | Purpose |
|---|---|---|---|
| **Smoke** | 1 | 1m | Sanity check after deploy |
| **Load** | 0→50 | 16m | Validate HPA, benchmark performance |
| **Stress** | 0→200 | 14m | Find breaking point |
| **HPA Validation** | 2→50 | 14m | Specifically validate auto-scaling |

---

## k6 Core Concepts

### Virtual Users (VUs) vs Real Users

```
1 k6 VU ≠ 1 real user

Real user: loads page → reads (5-30 seconds) → clicks → waits → reads more
           Average: 1-3 requests per minute

k6 VU:     sends request → gets response → sleeps 1s → sends next request
           Average: 30-60 requests per minute

So: 50 VUs ≈ 500-1500 concurrent real users visiting the app
```

### The Think Time Paradox

```javascript
// NO sleep: 50 VUs × 60 req/s each = 3000 req/s
// → Unrealistically high, causes artificial failures
export default function() {
  http.get(BASE_URL + "/api/tasks");
  // no sleep → hammering the server at maximum rate
}

// WITH sleep (realistic):
export default function() {
  http.get(BASE_URL + "/api/tasks");
  sleep(1 + Math.random() * 2); // 1-3s think time
  // Simulates: user reading the page before next click
}
```

Our load test uses `sleep(1 + Math.random() * 2)` — realistic behavior.

---

## HPA Scaling Timeline

```
T+0:00 - k6 starts ramping to 50 VUs
T+2:00 - 50 VUs reached. Backend CPU climbs to ~80% (above 70% threshold)

T+2:30 - HPA observes CPU > 70% for 15s (default --sync-period)
         HPA calculates: ceil(2 × 80/70) = ceil(2.28) = 3 replicas needed
         HPA event: "SuccessfulRescale - New size: 3"

T+2:35 - Third pod starts creating (kubectl get pods → ContainerCreating)
T+2:50 - Third pod passes readinessProbe → Ready → joins Service endpoints
T+2:50 - Traffic now distributed across 3 pods → CPU per pod drops

T+4:00 - CPU still high (50 VUs sustained): HPA scales to 4 pods
T+5:00 - HPA scales to 5 pods (maxReplicas reached)
T+5:30 - 5 pods serving 50 VUs → CPU ~35% per pod → HPA stabilizes at 5

T+10:00 - k6 ramps down to 0 VUs
T+10:00 - CPU drops to near 0%
T+15:00 - HPA scale-down stabilization window expires (5 minutes default)
           HPA scales from 5 → 2 pods
           Note: Scale-DOWN is intentionally slow (prevents thrashing)
```

### Why Scale-Down is Slow (by Design)

```
Scale-up:   Fast (30-90 seconds). Serving users is critical.
Scale-down: Slow (5+ minutes). Prevents "thrashing":

THRASHING without stabilization window:
  Load spike → scale up to 5 pods → load drops → scale down to 2 pods
  → Another spike → scale up to 5 again → drops → scale down → repeat
  → Constant pod churn → user requests fail during rapid changes

With 5-minute stabilization window:
  Load drops → HPA waits 5 minutes → confirms load is actually gone
  → Scale down safely once → stable
```

---

## Interpreting k6 Output

```
     ✓ GET /api/tasks: status 200
     ✓ GET /api/tasks: is array

     checks.........................: 99.84%  ✓ 4983       ✗ 8
     data_received..................: 12 MB   12 kB/s
     data_sent......................: 1.7 MB  1.8 kB/s
     http_req_blocked...............: avg=1.24ms   min=1µs     med=4µs     max=1.01s
     http_req_connecting............: avg=0.5ms    min=0µs     med=0µs     max=499.65ms
     http_req_duration..............: avg=142.9ms  min=4.5ms   med=98ms    p(90)=319ms  p(95)=456ms  p(99)=892ms
       { expected_response:true }...: avg=141.6ms  min=4.5ms   med=97.4ms  p(90)=316ms  p(95)=452ms  p(99)=882ms
     http_req_failed................: 0.16%   ✓ 8          ✗ 4983
     http_req_receiving.............: avg=46.7µs   min=13µs    med=37µs    max=15.16ms
     http_req_sending...............: avg=24.7µs   min=6µs     med=19µs    max=8.27ms
     http_req_tls_handshaking.......: avg=0s        ...
     http_req_waiting...............: avg=142.8ms   ...  ← "Time to first byte" (pure backend latency)
     http_reqs......................: 4991    5.2/s  ← RPS during test
     iteration_duration.............: avg=3.15s     ...
     iterations.....................: 1664    1.73/s
     vus............................: 1       min=1        max=50
     vus_max........................: 50      min=50       max=50

KEY METRICS TO READ:
  p(95) = 456ms: 95% of requests completed in 456ms ← most important
  p(99) = 892ms: 99% completed in 892ms (tail latency)
  http_req_failed = 0.16%: very low error rate ✓
  http_req_waiting = 142ms: pure backend/DB processing time
```

---

## Thresholds — Pass/Fail Criteria

```javascript
thresholds: {
  // p95 response time < 1 second under load
  "http_req_duration": ["p(95)<1000"],

  // Why p95? Not p50 (average)?
  // p50 = 142ms: Half the users are slower than this (hidden by average)
  // p95 = 456ms: 1 in 20 users waits this long
  // p99 = 892ms: 1 in 100 users waits this long
  // For a todo app with 1000 daily users:
  //   p99 = 892ms → 10 users/day get ~1s response → acceptable
  //   p99 > 5000ms → 10 users/day get >5s → unacceptable
}
```

---

## HPA Verification Commands

```bash
# Watch HPA scale in real-time (run DURING load test):
watch -n 5 'kubectl get hpa -n three-tier'
# Output:
# NAME          REFERENCE             TARGETS   MINPODS   MAXPODS   REPLICAS
# backend-hpa   Deployment/backend   82%/70%   2         5         4
#                                    ↑ above threshold → still scaling

# Watch pods scale up:
kubectl get pods -n three-tier -w
# NAME                        READY   STATUS              RESTARTS
# backend-7d9f9b-x8k2p        1/1     Running
# backend-7d9f9b-p4m8n        1/1     Running
# backend-7d9f9b-hn3q7        0/1     ContainerCreating   ← HPA scaling up!
# backend-7d9f9b-hn3q7        0/1     Running
# backend-7d9f9b-hn3q7        1/1     Running             ← Ready! Now serving

# Check HPA event history:
kubectl describe hpa backend-hpa -n three-tier | grep -A 30 Events

# Check metrics server data (what HPA uses):
kubectl top pods -n three-tier
# NAME                       CPU(cores)   MEMORY(bytes)
# backend-7d9f9b-x8k2p       180m         145Mi   ← 180m/250m = 72% (above 70%)
# backend-7d9f9b-p4m8n       175m         143Mi
```

---

## Performance Baselines (Expected for t3.medium 2-node cluster)

| Metric | Smoke (1 VU) | Load (50 VU) | Stress (200 VU) |
|---|---|---|---|
| p50 latency | < 50ms | < 200ms | < 500ms |
| p95 latency | < 200ms | < 1000ms | < 3000ms |
| Error rate | < 1% | < 5% | < 15% |
| RPS sustained | ~1 | ~30-50 | ~80-120 |
| Backend replicas | 2 | 3-5 (HPA) | 5 (max) |

> **Baseline values are estimates.** Actual numbers depend on MongoDB query complexity, Node.js event loop efficiency, and network latency to the ALB.
