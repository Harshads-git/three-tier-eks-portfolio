# Distributed Tracing with OpenTelemetry & Jaeger

> **Core Philosophy:** Metrics tell you *that* latency spiked. Logs tell you *what* error was thrown. Distributed Traces tell you **which exact microservice, database query, or network hop caused the delay**.

---

## 1. The Three Pillars of Observability in CloudForge EKS

```
     ┌─────────────────────────────────────────────────────────┐
     │                      METRICS                            │
     │         (Prometheus & Grafana Dashboards)               │
     │  "Alert! P99 latency on /api/tasks spiked to 450ms"    │
     └────────────────────────────┬────────────────────────────┘
                                  │ Pinpoints the symptom
                                  ▼
     ┌─────────────────────────────────────────────────────────┐
     │                      TRACES                             │
     │         (OpenTelemetry & Jaeger Waterfalls)             │
     │  "Trace ID 7b8f: Express took 10ms, Mongoose took 420ms │
     │   waiting for unindexed MongoDB query on collection"    │
     └────────────────────────────┬────────────────────────────┘
                                  │ Pinpoints the exact bottleneck
                                  ▼
     ┌─────────────────────────────────────────────────────────┐
     │                       LOGS                              │
     │         (CloudWatch Container Insights)                 │
     │  "MongoError: query returned 10,000 documents"          │
     └─────────────────────────────────────────────────────────┘
```

---

## 2. Distributed Tracing Architecture

```
User Browser / API Client
          │
          │ 1. HTTP Request (GET /api/tasks)
          ▼
┌─────────────────────────────────────────────────────────────┐
│                 AWS Application Load Balancer               │
│               Injects X-Amzn-Trace-Id header                │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│            three-tier-backend (Node.js Express)             │
│                                                             │
│   • tracer.js loads BEFORE Express and Mongoose             │
│   • Extracts W3C traceparent context                        │
│   • Span 1: [express.middleware] -> auth & validation (2ms) │
│   • Span 2: [express.handler] -> GET /api/tasks (45ms)      │
│   • Span 3: [mongoose.find] -> db.tasks.find({}) (38ms)     │
└──────────────────────────────┬──────────────────────────────┘
                               │
            Asynchronously     │ 2. OTLP gRPC (:4317)
            exports spans      ▼
┌─────────────────────────────────────────────────────────────┐
│             OpenTelemetry Collector (DaemonSet/HA)          │
│                                                             │
│   • Receivers: OTLP gRPC (:4317), OTLP HTTP (:4318)         │
│   • Processors: memory_limiter (75%), batch (1024 spans/5s) │
│   • Exporters: otlp/jaeger, logging                         │
└──────────────────────────────┬──────────────────────────────┘
                               │
            Forwards batch     │ 3. OTLP gRPC (:4317)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Jaeger Backend & Query UI                   │
│                                                             │
│   • Ingestion: OTLP collector endpoint                      │
│   • Storage: In-memory span storage (100k traces)           │
│   • UI: Interactive Gantt-chart request waterfall (:16686)  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. W3C Trace Context Propagation

To connect spans across distributed boundaries (browser ➔ load balancer ➔ API ➔ database), OpenTelemetry standardizes on the **W3C `traceparent` HTTP header**:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             └┬┘└───────────────┬────────────────┘└───────┬────────┘└┬┘
          Version           Trace ID                   Span ID    Flags (01 = Sampled)
```

- **Trace ID (`4bf92f...`):** Stays identical across the entire lifecycle of a request across all services.
- **Span ID (`00f067...`):** Represents an individual operation or function call within that trace.

---

## 4. Real-World Trace Waterfall Example (Jaeger UI)

When an engineer inspects a trace in the Jaeger UI for `GET /api/tasks`, they see a visual breakdown:

```
Service: three-tier-backend | Trace ID: 9b2e81fc47... | Total Duration: 42.4ms

0ms                                   20ms                                  40ms
├──────────────────────────────────────────────────────────────────────────────┤
[ three-tier-backend: HTTP GET /api/tasks ] (42.4ms)
  ├── [ express - router - /api/tasks ] (40.1ms)
  │     ├── [ express - middleware - jsonParser ] (0.3ms)
  │     ├── [ express - middleware - cors ] (0.2ms)
  │     └── [ express - route - getTasks ] (39.2ms)
  │           └── [ mongoose - tasks.find ] (36.8ms)
  │                 • db.system: mongodb
  │                 • db.name: tasksdb
  │                 • db.mongodb.collection: tasks
  │                 • db.statement: {"completed": false}
```

### What This Tells the SRE:
- Out of **42.4ms** total duration, **36.8ms** was spent inside MongoDB executing `tasks.find`.
- If this latency jumped from 40ms to 2000ms, the team immediately knows to check database indexes or connection pool contention rather than Express routing code.

---

## 5. SRE Day-2 Operations Cheat Sheet

```bash
# Deploy the OpenTelemetry Collector and Jaeger tracing stack
make tracing-install

# Open the Jaeger UI at http://localhost:16686
make jaeger-ui

# Stream OpenTelemetry Collector logs to verify span ingestion
make otel-logs

# Query active Jaeger tracing services
curl -s http://localhost:16686/api/services | jq .
# Output: ["three-tier-backend", "jaeger-query"]
```
