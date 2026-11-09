/**
 * tracer.js — OpenTelemetry Distributed Tracing Initialization
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHY INITIALIZE FIRST?
 * ═══════════════════════════════════════════════════════════════════════════
 * OpenTelemetry relies on monkey-patching Node.js core modules (http, https)
 * and third-party libraries (express, mongoose). This file MUST be imported
 * before 'express' or 'mongoose' are loaded, ensuring all outgoing HTTP requests
 * and MongoDB database queries are automatically wrapped with trace spans.
 *
 * TRACE ARCHITECTURE:
 *   Incoming HTTP Request (Browser)
 *        │
 *        ▼ (W3C traceparent header injected)
 *   Express Middleware Span [GET /api/tasks]
 *        │
 *        ▼
 *   Mongoose Query Span [tasks.find()]
 *        │
 *        ▼
 *   OTLP Exporter (gRPC :4317) ──► OpenTelemetry Collector ──► Jaeger UI
 * ═══════════════════════════════════════════════════════════════════════════
 */

"use strict";

const { NodeSDK } = require("@opentelemetry/sdk-node");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-grpc");
const { Resource } = require("@opentelemetry/resources");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");

const isTracingEnabled = process.env.ENABLE_TRACING !== "false";

if (isTracingEnabled) {
  const otelEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || "http://otel-collector.monitoring.svc.cluster.local:4317";
  const serviceName = process.env.OTEL_SERVICE_NAME || "three-tier-backend";
  const environment = process.env.NODE_ENV || "production";

  console.log(`[OpenTelemetry] Initializing tracer for service '${serviceName}' exporting to '${otelEndpoint}'...`);

  const traceExporter = new OTLPTraceExporter({
    url: otelEndpoint,
  });

  const sdk = new NodeSDK({
    resource: new Resource({
      [SemanticResourceAttributes.SERVICE_NAME]: serviceName,
      [SemanticResourceAttributes.SERVICE_VERSION]: "1.0.0",
      [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: environment,
      [SemanticResourceAttributes.CLOUD_PROVIDER]: "aws",
      [SemanticResourceAttributes.CLOUD_PLATFORM]: "aws_eks",
    }),
    traceExporter,
    instrumentations: [
      getNodeAutoInstrumentations({
        // Capture detailed database statements and query durations
        "@opentelemetry/instrumentation-mongoose": {
          enabled: true,
        },
        "@opentelemetry/instrumentation-express": {
          enabled: true,
        },
        "@opentelemetry/instrumentation-http": {
          enabled: true,
          // Ignore high-frequency Kubernetes health probe endpoints to reduce trace noise
          ignoreIncomingRequestHook: (req) => {
            return req.url === "/health" || req.url === "/ok" || req.url === "/api/health";
          },
        },
      }),
    ],
  });

  try {
    sdk.start();
    console.log("[OpenTelemetry] Tracing initialized successfully.");
  } catch (error) {
    console.warn("[OpenTelemetry] Warning: Failed to start OpenTelemetry SDK:", error.message);
  }

  // Graceful shutdown on process termination
  process.on("SIGTERM", () => {
    sdk
      .shutdown()
      .then(() => console.log("[OpenTelemetry] Tracing SDK terminated gracefully."))
      .catch((err) => console.error("[OpenTelemetry] Error shutting down tracing SDK:", err))
      .finally(() => process.exit(0));
  });
} else {
  console.log("[OpenTelemetry] Tracing is disabled via ENABLE_TRACING=false.");
}
