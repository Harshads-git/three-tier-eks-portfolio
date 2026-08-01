/**
 * k6/load-tests/stress-test.js — Stress Test (Find the Breaking Point)
 * ─────────────────────────────────────────────────────────────────────────────
 * PURPOSE: Push the system beyond normal capacity to find failure thresholds.
 * Answers: "At what load does the system start failing?"
 *
 * STRESS TEST vs LOAD TEST:
 *   Load Test:   Normal → Peak load. Validates system handles expected traffic.
 *   Stress Test: Push BEYOND peak. Finds breaking point + recovery behavior.
 *   Soak Test:   Sustained load over hours. Finds memory leaks, connection leaks.
 *
 * WHAT TO OBSERVE DURING STRESS TEST:
 *   1. Error rate spike: when does it exceed 10%?
 *   2. Response time degradation: p99 latency at 200 VUs?
 *   3. HPA behavior: does it reach maxReplicas and stay there?
 *   4. Cluster Autoscaler: does it add EC2 nodes?
 *   5. Recovery: after VUs ramp down, does the system recover?
 *   6. MongoDB: connection pool exhaustion? Operations queue up?
 *
 * THIS IS NOT FOR PRODUCTION TIMING — run during maintenance windows only.
 *
 * RUN COMMAND:
 *   k6 run k6/load-tests/stress-test.js \
 *     -e BASE_URL=http://<ALB-DNS> \
 *     --out json=results/stress-$(date +%Y%m%d-%H%M).json
 * ─────────────────────────────────────────────────────────────────────────────
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const errorRate = new Rate("error_rate");
const responseTime = new Trend("response_time_ms", true);

export const options = {
  stages: [
    { duration: "2m", target: 50 },   // Ramp to normal load
    { duration: "2m", target: 100 },  // Ramp to 2× normal
    { duration: "2m", target: 150 },  // Ramp to 3× normal
    { duration: "2m", target: 200 },  // Ramp to 4× normal (stress zone)
    { duration: "3m", target: 200 },  // Hold at peak stress
    { duration: "3m", target: 0 },    // Recovery ramp-down
  ],
  // Total: 14 minutes

  // Stress test thresholds (more lenient — we expect degradation)
  thresholds: {
    http_req_duration: ["p(95)<3000"],   // 3 seconds at peak (vs 1s in load test)
    http_req_failed: ["rate<0.15"],      // 15% error rate acceptable under stress
    error_rate: ["rate<0.15"],
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
const HEADERS = { "Content-Type": "application/json" };

export default function () {
  const start = Date.now();

  // Under stress: focus on the critical API path only
  const res = http.get(`${BASE_URL}/api/tasks`, { headers: HEADERS });
  responseTime.add(Date.now() - start);

  const ok = check(res, {
    "status is 200 or 503": (r) => r.status === 200 || r.status === 503,
    // 503 = Service Unavailable (backend overwhelmed) — not ideal but expected under stress
  });

  errorRate.add(res.status >= 500 && res.status !== 503);
  // Count 5xx errors (but not 503 which is expected graceful degradation)

  sleep(0.5); // Very short think time to maximize pressure
}

export function handleSummary(data) {
  // Custom summary output for stress test results
  const peakRPS =
    data.metrics.http_reqs.values.rate.toFixed(1);
  const p95Latency =
    data.metrics.http_req_duration.values["p(95)"].toFixed(0);
  const errorPct =
    (data.metrics.http_req_failed.values.rate * 100).toFixed(1);

  return {
    stdout: `
╔══════════════════════════════════════════════════════════╗
║                  STRESS TEST RESULTS                     ║
╠══════════════════════════════════════════════════════════╣
║  Peak RPS:        ${peakRPS.padEnd(37)} ║
║  p95 Latency:     ${(p95Latency + "ms").padEnd(37)} ║
║  Error Rate:      ${(errorPct + "%").padEnd(37)} ║
╚══════════════════════════════════════════════════════════╝
    `,
  };
}
