/**
 * k6/load-tests/hpa-validation.js — HPA Auto-Scaling Validation Test
 * ─────────────────────────────────────────────────────────────────────────────
 * PURPOSE: Specifically validate that HPA (HorizontalPodAutoscaler) scales
 * pods correctly when CPU/memory thresholds are crossed.
 *
 * HPA CONFIGURATION (from k8s/backend/hpa.yaml Day 6):
 *   targetCPUUtilizationPercentage: 70
 *   minReplicas: 2
 *   maxReplicas: 5
 *
 * EXPECTED BEHAVIOR:
 *   Phase 1 (Baseline): 2 VUs → backend at ~20% CPU → HPA does NOT scale
 *   Phase 2 (Trigger):  50 VUs → backend at ~80% CPU → HPA scales to 3-5 pods
 *   Phase 3 (Sustain):  Hold 50 VUs → HPA maintains 3-5 pods
 *   Phase 4 (Cool down): 0 VUs → after 5m stabilization → HPA scales back to 2
 *
 * TIMING NOTE:
 *   HPA scale-up: ~30-90 seconds (wait for metrics, create pods, readiness probe)
 *   HPA scale-down: ~5 minutes (stabilization window prevents thrashing)
 *
 * VALIDATION COMMANDS (run in separate terminal):
 *   watch -n 10 'echo "=== HPA ===" && kubectl get hpa -n three-tier && \
 *     echo "" && echo "=== PODS ===" && kubectl get pods -n three-tier && \
 *     echo "" && echo "=== CPU ===" && kubectl top pods -n three-tier'
 *
 * RUN COMMAND:
 *   k6 run k6/load-tests/hpa-validation.js \
 *     -e BASE_URL=http://<ALB-DNS>
 * ─────────────────────────────────────────────────────────────────────────────
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const errorRate = new Rate("error_rate");
const scaleUpRequests = new Counter("requests_during_scale_up");
const postScaleLatency = new Trend("post_scale_latency_ms", true);

export const options = {
  scenarios: {
    // SCENARIO 1: Baseline (verify NO scaling at low load)
    baseline: {
      executor: "constant-vus",
      vus: 2,
      duration: "3m",
      startTime: "0s",
      tags: { scenario: "baseline" },
    },

    // SCENARIO 2: Scale Trigger (cross the 70% CPU threshold)
    scale_trigger: {
      executor: "ramping-vus",
      startTime: "3m",  // Start after baseline
      stages: [
        { duration: "1m", target: 50 },   // Rapid ramp to trigger HPA
        { duration: "5m", target: 50 },   // Hold — HPA should scale up
        { duration: "1m", target: 10 },   // Reduce load
        { duration: "3m", target: 10 },   // Hold low — HPA stabilization window
        { duration: "1m", target: 0 },    // Ramp down
      ],
      tags: { scenario: "scale_trigger" },
    },
  },

  thresholds: {
    // During scale-up: latency may increase as new pods become Ready
    http_req_duration: ["p(95)<2000"],
    http_req_failed: ["rate<0.10"],

    // Our tagged metrics per scenario
    "http_req_duration{scenario:baseline}": ["p(95)<500"],
    // Baseline: must be fast (no load, 2 pods, no scaling happening)

    "http_req_duration{scenario:scale_trigger}": ["p(95)<2000"],
    // Scale trigger: allow higher latency while HPA creates new pods
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
const HEADERS = { "Content-Type": "application/json" };

export default function (data) {
  const scenario = __ENV.K6_SCENARIO_NAME || "unknown";
  const start = Date.now();

  // CPU-intensive workload: POST requests (write to MongoDB) generate more CPU
  const payload = JSON.stringify({
    title: `HPA Test - VU${__VU} Iter${__ITER}`,
    description: "HPA validation request to trigger CPU threshold",
    completed: false,
  });

  // Mix of reads and writes to generate realistic CPU load
  let res;
  if (__ITER % 3 === 0) {
    // Every 3rd iteration: write (more CPU intensive)
    res = http.post(`${BASE_URL}/api/tasks`, payload, { headers: HEADERS });
    check(res, {
      "POST: 201 Created": (r) => r.status === 201,
    });
  } else {
    // Otherwise: read
    res = http.get(`${BASE_URL}/api/tasks`, { headers: HEADERS });
    check(res, {
      "GET: 200 OK": (r) => r.status === 200,
    });
  }

  const latency = Date.now() - start;
  if (scenario === "scale_trigger") {
    postScaleLatency.add(latency);
    scaleUpRequests.add(1);
  }

  errorRate.add(res.status >= 500);

  // Short sleep = more requests = higher CPU = triggers HPA faster
  sleep(0.5);
}

export function setup() {
  console.log(`
HPA Validation Test
═══════════════════════════════════════
Target: ${BASE_URL}
Expected HPA behavior:
  Baseline (0-3m):   CPU < 70% → 2 pods (no scaling)
  Scale trigger (3-10m): CPU > 70% → HPA scales to 3-5 pods
  Cool down (10-14m): CPU drops → HPA scales back to 2 pods

Monitor with:
  watch -n 10 'kubectl get hpa,pods -n three-tier'
═══════════════════════════════════════
  `);
  return {};
}
