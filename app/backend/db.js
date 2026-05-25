/**
 * db.js — MongoDB Database Connection Module
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHAT THIS FILE DOES
 * ═══════════════════════════════════════════════════════════════════════════
 * This module exports a single async function that establishes a connection
 * to MongoDB using Mongoose (an ODM — Object Document Mapper for MongoDB).
 * It is called ONCE at application startup in index.js.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE: WHY A SEPARATE CONNECTION MODULE?
 * ═══════════════════════════════════════════════════════════════════════════
 * Separating the connection logic from index.js follows the
 * Single Responsibility Principle:
 *   - index.js  → application bootstrap (middleware, routes, server start)
 *   - db.js     → database concern (connection, retry logic, env config)
 *
 * This also makes it easier to mock the DB in tests without touching the
 * Express app setup.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * KUBERNETES / DEVOPS CONTEXT
 * ═══════════════════════════════════════════════════════════════════════════
 * In K8s, the MONGO_URI environment variable is injected via a Kubernetes
 * Secret (not a ConfigMap — secrets are base64-encoded and kept separate).
 *
 * The K8s Secret is defined in: k8s/mongo/secret.yaml
 * The backend Deployment references it via: secretKeyRef
 *
 * Connection string format:
 *   mongodb://<username>:<password>@<service-name>:<port>/<database>
 *
 * In Kubernetes (using K8s DNS):
 *   mongodb://admin:password@mongo-service:27017/tasksdb
 *   └─────────────────────┘ └────────────┘ └──────┘
 *   Credentials from Secret  K8s Service DNS  DB name
 *
 * IMPORTANT: The MongoDB service name "mongo-service" resolves via
 * Kubernetes internal DNS to the MongoDB pod's ClusterIP.
 * This works ONLY within the same namespace.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * CONNECTION POOLING
 * ═══════════════════════════════════════════════════════════════════════════
 * Mongoose maintains a connection POOL (default: 5 connections).
 * This means multiple concurrent HTTP requests can query MongoDB simultaneously
 * without each needing to establish a new TCP connection.
 *
 * For EKS with HPA scaling to 5 backend pods:
 *   5 pods × 5 connections = up to 25 concurrent MongoDB connections
 * Set MONGO_URI's maxPoolSize if you need to control this:
 *   mongodb://...?maxPoolSize=10
 */

"use strict";

const mongoose = require("mongoose");

/**
 * connectToDatabase — Establishes a Mongoose connection to MongoDB.
 *
 * This is an async function exported as the module's default export.
 * Called once at startup: connection() in index.js
 *
 * Mongoose Connection States:
 *   0 = disconnected
 *   1 = connected      ← we want this
 *   2 = connecting
 *   3 = disconnecting
 *
 * @returns {Promise<void>}
 * @throws {Error} Logs error and exits process if connection fails
 */
module.exports = async () => {
  try {
    // ─────────────────────────────────────────────────────────────────────
    // CONNECTION OPTIONS
    // ─────────────────────────────────────────────────────────────────────
    const connectionParams = {
      /**
       * useNewUrlParser: true
       * Uses the new MongoDB connection string parser.
       * The old parser is deprecated in MongoDB driver 4.x.
       * Without this, you'll see deprecation warnings in logs.
       */
      useNewUrlParser: true,

      /**
       * useUnifiedTopology: true
       * Uses the new Unified Topology layer for server monitoring.
       * Enables:
       *   - Automatic reconnection after network blips
       *   - Better load balancing for replica sets
       *   - Required for MongoDB Atlas connections
       *
       * In K8s: If the MongoDB pod restarts, Mongoose will automatically
       * reconnect without crashing the backend pod. This is critical
       * for production workloads.
       */
      useUnifiedTopology: true,

      /**
       * serverSelectionTimeoutMS (added vs reference repo)
       * How long to wait for MongoDB to become available before giving up.
       * Default: 30000ms (30s). We reduce to 5s for faster K8s pod startup
       * failure detection (K8s restarts failed pods quickly).
       */
      serverSelectionTimeoutMS: 5000,
    };

    // ─────────────────────────────────────────────────────────────────────
    // STARTUP VALIDATION — Fail fast if env var is missing
    // ─────────────────────────────────────────────────────────────────────
    /**
     * WHY validate here?
     * Without this check, mongoose.connect() would receive "undefined"
     * and throw a cryptic error. This gives a clear, actionable message.
     *
     * In K8s: If the Secret is not mounted correctly, the pod will
     * CrashLoopBackOff with this message in the logs — easy to debug.
     *
     * Check with: kubectl logs -n three-tier <backend-pod-name>
     */
    const mongoUri = process.env.MONGO_URI;
    if (!mongoUri) {
      console.error(
        "[db.js] FATAL: MONGO_URI environment variable is not set.\n" +
        "In Kubernetes, ensure the Secret is created and secretKeyRef is correct.\n" +
        "See: k8s/mongo/secret.yaml and k8s/backend/deployment.yaml"
      );
      process.exit(1); // Exit with failure code — K8s will restart the pod
    }

    // ─────────────────────────────────────────────────────────────────────
    // ESTABLISH CONNECTION
    // ─────────────────────────────────────────────────────────────────────
    await mongoose.connect(mongoUri, connectionParams);

    console.log("[db.js] ✅ Connected to MongoDB successfully.");
    console.log(`[db.js] Host: ${mongoose.connection.host}`);
    console.log(`[db.js] Database: ${mongoose.connection.name}`);

  } catch (error) {
    /**
     * Connection failure handling:
     * We log the error and EXIT the process. This is intentional.
     *
     * WHY process.exit(1)?
     * If we can't connect to MongoDB, the backend cannot serve any useful
     * requests. It's better to fail loudly and immediately so:
     *   1. Kubernetes restarts the pod (based on restartPolicy: Always)
     *   2. The K8s readiness probe fails → pod removed from load balancer
     *   3. Operators get alerted via monitoring/logs immediately
     *
     * "Fail fast" is a distributed systems best practice.
     * A zombie pod that accepts requests but can't store data is WORSE
     * than a pod that won't start.
     */
    console.error("[db.js] ❌ MongoDB connection failed:", error.message);
    console.error("[db.js] Full error:", error);
    process.exit(1);
  }

  // ─────────────────────────────────────────────────────────────────────
  // CONNECTION EVENT LISTENERS (Post-connection monitoring)
  // ─────────────────────────────────────────────────────────────────────
  /**
   * These events fire AFTER the initial connection succeeds.
   * They handle runtime connection changes (e.g., MongoDB pod restarts in K8s).
   * Mongoose automatically buffers queries and reconnects — these are for logging.
   */
  mongoose.connection.on("disconnected", () => {
    console.warn("[db.js] ⚠️  MongoDB disconnected. Mongoose will attempt reconnect...");
  });

  mongoose.connection.on("reconnected", () => {
    console.log("[db.js] ✅ MongoDB reconnected successfully.");
  });

  mongoose.connection.on("error", (err) => {
    console.error("[db.js] MongoDB connection error:", err.message);
  });
};
