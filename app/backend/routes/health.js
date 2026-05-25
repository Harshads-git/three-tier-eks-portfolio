/**
 * routes/health.js — Kubernetes Health Check Endpoint
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHY A DEDICATED HEALTH ENDPOINT?
 * ═══════════════════════════════════════════════════════════════════════════
 * Kubernetes uses HTTP probes to monitor pod health and manage traffic:
 *
 * 1. livenessProbe  → "Is the process still running correctly?"
 *    If this fails:  K8s kills the container and restarts the pod
 *    Use case:       Detects deadlocks, infinite loops, OOM conditions
 *
 * 2. readinessProbe → "Is the pod ready to serve traffic?"
 *    If this fails:  K8s removes the pod from the Service's Endpoints
 *                    (traffic stops flowing to this pod, but pod is NOT killed)
 *    Use case:       Detects DB connection loss, startup initialization
 *
 * 3. startupProbe   → "Has the application finished starting up?"
 *    If this fails:  K8s waits before activating liveness/readiness probes
 *    Use case:       Slow-starting apps that need time to warm up
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * HEALTH CHECK PHILOSOPHY
 * ═══════════════════════════════════════════════════════════════════════════
 * A GOOD health check does NOT just verify "is the process alive?"
 * It verifies "can this pod successfully serve real user requests?"
 *
 * For our backend, a request is healthy if:
 *   1. Express server is accepting connections ✅ (basic)
 *   2. MongoDB connection is in "connected" state ✅ (meaningful)
 *
 * If MongoDB is disconnected, the pod CAN'T serve requests (all DB ops fail).
 * So readinessProbe should return 503 when MongoDB is disconnected.
 * This removes the pod from the load balancer immediately.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * K8S DEPLOYMENT YAML CONFIGURATION (Preview — Day 19)
 * ═══════════════════════════════════════════════════════════════════════════
 * livenessProbe:
 *   httpGet:
 *     path: /health
 *     port: 5000
 *   initialDelaySeconds: 10   # Wait 10s after container start before probing
 *   periodSeconds: 15         # Check every 15 seconds
 *   failureThreshold: 3       # Kill pod after 3 consecutive failures
 *
 * readinessProbe:
 *   httpGet:
 *     path: /health
 *     port: 5000
 *   initialDelaySeconds: 5    # Start checking sooner than liveness
 *   periodSeconds: 10
 *   failureThreshold: 3
 */

"use strict";

const express = require("express");
const mongoose = require("mongoose");

const router = express.Router();

/**
 * GET /health — Health check endpoint
 *
 * Checks:
 *   1. Express is responding (implicit — we reached this handler)
 *   2. MongoDB connection state via mongoose.connection.readyState
 *
 * Response Codes:
 *   200 OK                → Healthy (K8s probe passes)
 *   503 Service Unavailable → Unhealthy (K8s probe fails → remove from LB)
 */
router.get("/", (req, res) => {
  /**
   * mongoose.connection.readyState values:
   *   0 = disconnected
   *   1 = connected      ← healthy
   *   2 = connecting
   *   3 = disconnecting
   */
  const mongoState = mongoose.connection.readyState;
  const isMongoConnected = mongoState === 1;

  const healthPayload = {
    status: isMongoConnected ? "ok" : "error",
    timestamp: new Date().toISOString(),
    uptime: Math.floor(process.uptime()),          // seconds since Node.js started
    environment: process.env.NODE_ENV || "development",
    checks: {
      mongodb: {
        status: isMongoConnected ? "connected" : "disconnected",
        readyState: mongoState,
        host: isMongoConnected ? mongoose.connection.host : null,
        database: isMongoConnected ? mongoose.connection.name : null,
      },
      memory: {
        // Memory usage in MB — useful for detecting memory leaks
        heapUsed: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`,
        heapTotal: `${Math.round(process.memoryUsage().heapTotal / 1024 / 1024)}MB`,
        rss: `${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB`,
      },
    },
  };

  if (isMongoConnected) {
    // 200 OK — pod is healthy and ready to serve traffic
    return res.status(200).json(healthPayload);
  }

  // 503 Service Unavailable — pod is alive but cannot serve requests
  // K8s readinessProbe will fail → pod removed from Service endpoints
  return res.status(503).json(healthPayload);
});

module.exports = router;
