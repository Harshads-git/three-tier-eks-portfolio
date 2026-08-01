/**
 * k6/load-tests/smoke-test.js — Smoke Test (Sanity Check)
 * ─────────────────────────────────────────────────────────────────────────────
 * PURPOSE: Verify the application is functional with minimal load.
 * Run BEFORE every deployment to confirm basic connectivity.
 *
 * WHEN TO RUN:
 *   - After deployment: confirm new version is responding
 *   - After cluster restart: verify all services are up
 *   - Before load tests: validate endpoints before hammering them
 *
 * METRICS COLLECTED BY k6:
 *   http_req_duration  → response time (p50, p95, p99)
 *   http_req_failed    → % of requests that returned errors
 *   http_reqs          → total requests made
 *   vus                → virtual users (concurrent users)
 *   iterations         → number of full script executions
 *
 * RUN COMMAND:
 *   k6 run k6/load-tests/smoke-test.js \
 *     -e BASE_URL=http://<ALB-DNS>
 * ─────────────────────────────────────────────────────────────────────────────
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// ─────────────────────────────────────────────────────────────────────────────
// CUSTOM METRICS
// ─────────────────────────────────────────────────────────────────────────────
// k6 built-in metrics (http_req_duration, etc.) cover HTTP-level details.
// Custom metrics let you track business-level metrics.
const errorRate = new Rate("error_rate");
// Rate: tracks a proportion (0-1). errorRate tracks % of failed requests.

const apiLatency = new Trend("api_latency_ms");
// Trend: tracks min/max/avg/p95. apiLatency tracks our API response times.

// ─────────────────────────────────────────────────────────────────────────────
// TEST CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────────
export const options = {
  vus: 1,          // 1 virtual user (smoke test = minimal load)
  duration: "1m",  // Run for 1 minute

  // Thresholds: Pass/Fail criteria for the test
  thresholds: {
    // 95% of requests must complete in under 500ms
    http_req_duration: ["p(95)<500"],

    // Less than 1% of requests should fail
    http_req_failed: ["rate<0.01"],

    // Our custom API latency metric: p95 < 300ms
    api_latency_ms: ["p(95)<300"],

    // Custom error rate: < 1%
    error_rate: ["rate<0.01"],
  },
};

// ─────────────────────────────────────────────────────────────────────────────
// ENVIRONMENT CONFIG
// ─────────────────────────────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
// __ENV.BASE_URL: injected via -e BASE_URL=... at runtime
// Fallback to localhost for local development

const HEADERS = {
  "Content-Type": "application/json",
  Accept: "application/json",
};

// ─────────────────────────────────────────────────────────────────────────────
// TEST SCENARIO (default function)
// ─────────────────────────────────────────────────────────────────────────────
export default function () {
  // ── 1. Health Check ───────────────────────────────────────────────────────
  const healthRes = http.get(`${BASE_URL}/api/health`, { headers: HEADERS });

  check(healthRes, {
    "health check: status 200": (r) => r.status === 200,
    "health check: response time < 200ms": (r) => r.timings.duration < 200,
    "health check: has status field": (r) => {
      const body = JSON.parse(r.body);
      return body.status === "ok" || body.status === "healthy";
    },
  });

  errorRate.add(healthRes.status !== 200);
  sleep(0.5);

  // ── 2. GET All Tasks (main API endpoint) ──────────────────────────────────
  const startTime = Date.now();
  const listRes = http.get(`${BASE_URL}/api/tasks`, { headers: HEADERS });
  const duration = Date.now() - startTime;

  apiLatency.add(duration);

  const listCheck = check(listRes, {
    "GET /api/tasks: status 200": (r) => r.status === 200,
    "GET /api/tasks: response is array": (r) => {
      const body = JSON.parse(r.body);
      return Array.isArray(body);
    },
    "GET /api/tasks: response time < 300ms": (r) => r.timings.duration < 300,
  });

  errorRate.add(!listCheck);
  sleep(0.5);

  // ── 3. POST a Task (write endpoint) ───────────────────────────────────────
  const taskPayload = JSON.stringify({
    title: `Smoke Test Task ${Date.now()}`,
    description: "Created by k6 smoke test",
    completed: false,
  });

  const createRes = http.post(`${BASE_URL}/api/tasks`, taskPayload, {
    headers: HEADERS,
  });

  const createCheck = check(createRes, {
    "POST /api/tasks: status 201": (r) => r.status === 201,
    "POST /api/tasks: returns created task": (r) => {
      const body = JSON.parse(r.body);
      return body._id !== undefined || body.id !== undefined;
    },
    "POST /api/tasks: response time < 500ms": (r) => r.timings.duration < 500,
  });

  errorRate.add(!createCheck);
  sleep(1);

  // ── 4. Frontend Availability Check ────────────────────────────────────────
  const frontendRes = http.get(`${BASE_URL}/`);

  check(frontendRes, {
    "Frontend: status 200": (r) => r.status === 200,
    "Frontend: returns HTML": (r) =>
      r.headers["Content-Type"].includes("text/html"),
    "Frontend: response time < 1s": (r) => r.timings.duration < 1000,
  });

  errorRate.add(frontendRes.status !== 200);
  sleep(1);
}

// ─────────────────────────────────────────────────────────────────────────────
// SETUP (runs once before VUs start)
// ─────────────────────────────────────────────────────────────────────────────
export function setup() {
  console.log(`Starting smoke test against: ${BASE_URL}`);
  console.log("VUs: 1, Duration: 1m");
  console.log("Thresholds: p95 < 500ms, error rate < 1%");
}

// ─────────────────────────────────────────────────────────────────────────────
// TEARDOWN (runs once after all VUs finish)
// ─────────────────────────────────────────────────────────────────────────────
export function teardown(data) {
  console.log("Smoke test complete. Check thresholds above.");
}
