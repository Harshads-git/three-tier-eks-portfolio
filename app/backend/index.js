/**
 * index.js — Express Application Entry Point & Bootstrap
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHAT THIS FILE DOES
 * ═══════════════════════════════════════════════════════════════════════════
 * This is the main entry point for the Node.js backend server. It:
 *   1. Imports and configures the Express application
 *   2. Connects to MongoDB via db.js
 *   3. Registers global middleware (JSON body parser, CORS)
 *   4. Mounts route handlers (/api/tasks, /health, /ok)
 *   5. Starts the HTTP server on the configured PORT
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * MIDDLEWARE EXECUTION ORDER (CRITICAL)
 * ═══════════════════════════════════════════════════════════════════════════
 * Express middleware runs IN ORDER. Every incoming request passes through
 * each middleware in sequence before reaching a route handler.
 *
 * Request arrives
 *     │
 *     ▼ express.json()      → Parses JSON body → populates req.body
 *     │
 *     ▼ cors()              → Adds CORS headers → allows frontend to call API
 *     │
 *     ▼ /ok or /health      → Health check endpoints (quick return)
 *     │
 *     ▼ /api/tasks          → Task CRUD router (routes/tasks.js)
 *     │
 *     ▼ 404 handler         → If no route matched, return 404
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * KUBERNETES CONTEXT: HOW THIS SERVER RUNS IN A POD
 * ═══════════════════════════════════════════════════════════════════════════
 * In Kubernetes, this process runs inside a container:
 *   - Container image: node:18-alpine (multi-stage, built in Day 6)
 *   - Main process: node index.js (PID 1 inside container)
 *   - Port: 5000 (matched by K8s Service targetPort: 5000)
 *   - Env vars injected by K8s: MONGO_URI (from Secret), PORT (from ConfigMap)
 *
 * Health probes (added in Commit 4 of this day):
 *   - livenessProbe:  GET /health → 200 = pod is alive, restart if it fails
 *   - readinessProbe: GET /health → 200 = pod is ready, add to LB rotation
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * CORS CONFIGURATION (Important for Three-Tier Architecture)
 * ═══════════════════════════════════════════════════════════════════════════
 * CORS (Cross-Origin Resource Sharing) is a browser security mechanism.
 * Since the frontend (Nginx on port 80) and backend (Node on port 5000) are
 * different "origins", the browser blocks requests by default.
 *
 * cors() middleware adds these response headers:
 *   Access-Control-Allow-Origin: *          (allow all origins)
 *   Access-Control-Allow-Methods: GET,POST,PUT,DELETE
 *   Access-Control-Allow-Headers: Content-Type
 *
 * In PRODUCTION on K8s (behind a single ALB):
 *   Frontend: http://myalb.amazonaws.com/
 *   Backend:  http://myalb.amazonaws.com/api/tasks
 *   Both are same origin → CORS is NOT needed when using path-based routing!
 *
 * But we keep cors() for local development where ports differ.
 * You could also tighten the CORS config:
 *   cors({ origin: process.env.FRONTEND_URL })
 */

"use strict";

const express = require("express");
const cors = require("cors");
const connectToDatabase = require("./db");
const taskRouter = require("./routes/tasks");
const healthRouter = require("./routes/health");

// ─────────────────────────────────────────────────────────────────────────────
// EXPRESS APP INITIALIZATION
// ─────────────────────────────────────────────────────────────────────────────
const app = express();

// ─────────────────────────────────────────────────────────────────────────────
// DATABASE CONNECTION
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Connect to MongoDB before setting up routes.
 * db.js handles validation, connection options, and process.exit on failure.
 * Mongoose buffers queries — routes work correctly even before connection completes,
 * but in practice the connection is nearly instant on K8s (MongoDB is ClusterIP adjacent).
 */
connectToDatabase();

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL MIDDLEWARE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * express.json()
 * Parses incoming requests with JSON payloads.
 * Populates req.body from the raw JSON string in the request body.
 * Without this, req.body is undefined for POST/PUT requests.
 *
 * The Content-Type header must be "application/json" for this to activate.
 * axios (used in the frontend) sets this header automatically.
 */
app.use(express.json());

/**
 * cors()
 * Adds CORS headers to ALL responses.
 * Required for local development where frontend (port 3000) calls backend (port 5000).
 * On EKS with a single ALB domain, CORS is technically not needed.
 * See architecture note above.
 */
app.use(cors());

// ─────────────────────────────────────────────────────────────────────────────
// ROUTES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Health Check Endpoint — Legacy (from reference repo)
 * GET /ok
 *
 * Simple ping endpoint kept for backward compatibility with the reference repo.
 */
app.get("/ok", (req, res) => {
  res.status(200).json({ status: "ok" });
});

/**
 * Kubernetes Health Check Endpoint (NEW — Day 3, Commit 4)
 * GET /health
 *
 * Full health check: verifies Express + MongoDB connection state.
 * Used by K8s livenessProbe and readinessProbe in deployment.yaml.
 * Returns 200 if healthy, 503 if MongoDB is disconnected.
 *
 * See: routes/health.js for full documentation.
 */
app.use("/health", healthRouter);

/**
 * Task API Routes
 * Mounts the taskRouter at /api/tasks
 *
 * All routes defined in routes/tasks.js are now prefixed with /api/tasks:
 *   POST   /api/tasks      → taskRouter.post("/")
 *   GET    /api/tasks      → taskRouter.get("/")
 *   PUT    /api/tasks/:id  → taskRouter.put("/:id")
 *   DELETE /api/tasks/:id  → taskRouter.delete("/:id")
 *
 * The /api/ prefix is important for the ALB Ingress rule:
 *   /api/* → backend-service (this server)
 *   /*     → frontend-service (Nginx)
 */
app.use("/api/tasks", taskRouter);

// ─────────────────────────────────────────────────────────────────────────────
// 404 CATCH-ALL HANDLER
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Any request that doesn't match a defined route falls through to here.
 * Returns a clear 404 JSON response instead of the default HTML error page.
 */
app.use((req, res) => {
  res.status(404).json({
    message: `Route not found: ${req.method} ${req.originalUrl}`,
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL ERROR HANDLER
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Express error handler — must have FOUR parameters (err, req, res, next).
 * Catches any unhandled errors thrown in route handlers (via next(error)).
 *
 * In production: Remove stack traces from responses (don't expose internals).
 */
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error("[ERROR]", err.stack);
  res.status(500).json({
    message: "Internal server error",
    // Only expose stack in development:
    ...(process.env.NODE_ENV === "development" && { stack: err.stack }),
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SERVER STARTUP
// ─────────────────────────────────────────────────────────────────────────────
/**
 * PORT Configuration:
 * - process.env.PORT  → Set by Kubernetes ConfigMap or docker-compose env
 * - Default: 5000     → Used for local development without env var
 *
 * K8s Service MUST match this port:
 *   spec.ports[].targetPort: 5000  ← in k8s/backend/service.yaml
 *
 * Listening on "0.0.0.0" (all interfaces) is REQUIRED in containers.
 * "localhost" or "127.0.0.1" only accepts connections from inside the container,
 * blocking K8s network traffic from other pods and health probes.
 */
const PORT = process.env.PORT || 5000;

const server = app.listen(PORT, "0.0.0.0", () => {
  console.log(`[index.js] ✅ Backend server running on port ${PORT}`);
  console.log(`[index.js] Environment: ${process.env.NODE_ENV || "development"}`);
  console.log(`[index.js] Health check: http://0.0.0.0:${PORT}/health`);
});

// ─────────────────────────────────────────────────────────────────────────────
// GRACEFUL SHUTDOWN (Production Best Practice)
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Kubernetes sends SIGTERM to the main process when terminating a pod.
 * Without a graceful shutdown handler, the process dies instantly, potentially
 * dropping in-flight requests and leaving MongoDB transactions incomplete.
 *
 * With graceful shutdown:
 *   1. K8s sends SIGTERM → this handler fires
 *   2. Server stops accepting NEW connections
 *   3. Existing requests complete (within 30s timeout)
 *   4. MongoDB connection closes cleanly
 *   5. Process exits with code 0 (success)
 *
 * K8s waits terminationGracePeriodSeconds (default: 30s) before force-killing.
 */
const gracefulShutdown = (signal) => {
  console.log(`[index.js] Received ${signal}. Shutting down gracefully...`);
  server.close(() => {
    console.log("[index.js] HTTP server closed. Closing MongoDB connection...");
    require("mongoose").connection.close(false, () => {
      console.log("[index.js] MongoDB connection closed. Exiting.");
      process.exit(0);
    });
  });

  // Force exit after 30s if graceful shutdown hangs
  setTimeout(() => {
    console.error("[index.js] Force shutdown after timeout.");
    process.exit(1);
  }, 30000);
};

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT")); // Ctrl+C in local dev

module.exports = app; // Export for testing
