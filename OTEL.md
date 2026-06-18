# OpenTelemetry — Observability Guide

This project uses the **OpenTelemetry Java agent** for zero-code instrumentation across all backend services. Traces, metrics, and logs are exported via OTLP to the **OpenTelemetry Collector**, which forwards them to Prometheus / debug output.

---

## Architecture

```
┌─────────────────┐     OTLP gRPC (4317)     ┌──────────────────────┐     Prometheus (:8889)
│  Java Services   │ ──────────────────────── │  OTel Collector      │ ──────────────────→  Prometheus (:9090)
│  (5 microservices)│                          │  (otel-collector)    │
│                   │                          │                      │ ───→ debug (stdout)
│  -javaagent:...   │                          └──────────────────────┘
└─────────────────┘
```

Each service runs with `-javaagent:/app/opentelemetry-javaagent.jar` which auto-instruments:

- **HTTP** — Spring Web / Spring Cloud Gateway request/response spans
- **gRPC** — inter-service calls
- **JDBC** — database queries (PostgreSQL)
- **Redis** — Lettuce client calls
- **Kafka** — producer/consumer messaging
- **Micrometer** — bridges existing Prometheus metrics into OTel
- **Logback** — injects `trace_id` / `span_id` into MDC for log correlation

---

## Running with OTel

### Docker Compose (recommended)

Everything is pre-configured. Start the full stack:

```bash
docker compose up -d
```

This starts the OTel collector alongside all services. Each service automatically exports traces, metrics, and logs to `otel-collector:4317`.

### Running locally (outside Docker)

Set these environment variables before starting a service:

```bash
export OTEL_SERVICE_NAME=auth-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_TRACES_EXPORTER=otlp
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true
export OTEL_METRIC_EXPORT_INTERVAL=15000
export OTEL_LOGS_EXPORTER_OTLP_INSECURE=true

# Also need a local OTel collector on :4317
docker run -d --name otel-collector \
  -p 4317:4317 -p 8889:8889 \
  -v $(pwd)/docker/otel/otel-collector-config.yml:/etc/otel/config.yml \
  otel/opentelemetry-collector-contrib:0.112.0 \
  --config=/etc/otel/config.yml
```

Then start the service:

```bash
cd backend
mvn spring-boot:run -pl auth-service \
  -Dspring-boot.run.jvmArguments="-javaagent:/path/to/opentelemetry-javaagent.jar"
```

---

## What to Look At

### Traces

The OTel agent creates spans for every HTTP request, database query, Kafka message, and Redis call. Each span includes:

- **HTTP method & path** (e.g. `POST /api/signin`)
- **Status code** (e.g. `200`, `401`)
- **Duration** (how long the request took)
- **DB statement** (e.g. `SELECT * FROM users WHERE username = ?`)
- **Kafka topic** (e.g. `auth-events`)
- **Trace ID** — propagated across services via `traceparent` header

The collector outputs spans to stdout at `basic` verbosity. To see spans live:

```bash
docker compose logs -f otel-collector | grep "Span"
```

### Metrics

Micrometer metrics (JVM, request counts, DB pool, cache hits, etc.) are automatically bridged to OTel and exported. The collector exposes them on port **8889** in Prometheus format:

```bash
curl http://localhost:8889/metrics | head -50
```

Metrics are namespaced under `mytutorial_*` (e.g. `mytutorial_http_server_requests_seconds_count`).

Grafana can scrape the collector's Prometheus endpoint directly. Add a Prometheus datasource targeting `http://otel-collector:8889`.

### Logs

Logback appenders include `trace_id` and `span_id` in every log line:

```
2025-06-18 12:34:56.789 INFO [auth-service] [http-nio-8081-exec-1] c.b.m.a.AuthServiceImpl
  [trace=abc123,span=def456] - User signed in: john@example.com
```

This lets you **correlate logs with traces** — search by trace ID to see all logs from a single request across services.

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OTEL_SERVICE_NAME` | — | Service name (set per service in docker-compose) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | OTel collector gRPC endpoint |
| `OTEL_TRACES_EXPORTER` | `otlp` | Traces exporter |
| `OTEL_METRICS_EXPORTER` | `otlp` | Metrics exporter |
| `OTEL_LOGS_EXPORTER` | `otlp` | Logs exporter |
| `OTEL_INSTRUMENTATION_MICROMETER_ENABLED` | `true` | Bridge Micrometer → OTel metrics |
| `OTEL_METRIC_EXPORT_INTERVAL` | `15000` | Metric export interval (ms) |
| `OTEL_LOGS_EXPORTER_OTLP_INSECURE` | `true` | Skip TLS for log exporter |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | Sampling strategy |
| `OTEL_JAVAAGENT_DEBUG` | `false` | Enable agent debug logging |

### Collector Config

The OTel collector config lives at `docker/otel/otel-collector-config.yml`. It:

1. **Receives** OTLP gRPC (:4317) and HTTP (:4318)
2. **Processes** with memory limiter (512 MB) and batching
3. **Exports** metrics to Prometheus (:8889) and everything to debug output

To change verbosity of the debug exporter:

```yaml
exporters:
  debug:
    verbosity: detailed   # basic | normal | detailed
```

---

## Adding Custom Instrumentation (Advanced)

For custom spans in your code, use the OpenTelemetry API (the agent handles most cases — this is only needed for bespoke logic):

### 1. Add dependency

```xml
<dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-api</artifactId>
</dependency>
```

### 2. Create spans

```java
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;

@RequiredArgsConstructor
@Service
public class MyService {
    private final OpenTelemetry openTelemetry;

    public void doSomething() {
        Tracer tracer = openTelemetry.getTracer("my-instrumentation");
        Span span = tracer.spanBuilder("doSomething")
            .setAttribute("custom.key", "custom-value")
            .startSpan();
        try {
            // your logic
        } finally {
            span.end();
        }
    }
}
```

The OTel agent provides `OpenTelemetry` as a bean automatically.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No traces/metrics | Run `docker compose logs otel-collector` — see if data arrives |
| Agent not loading | Verify `-javaagent:` is in the JVM args (check Dockerfile ENTRYPOINT) |
| Collector crashing | Check memory limits; reduce `limit_mib` in config |
| Logs missing trace_id | Ensure `logback-spring.xml` pattern includes `%X{trace_id:-}` |
| Prometheus can't scrape | Verify `curl http://localhost:8889/metrics` works from host |

### Verify agent is loaded

Check service startup logs:

```bash
docker compose logs auth-service | grep -i "opentelemetry"
```

Expected output: `OpenTelemetry Java agent initialized`

### Verify data flow

```bash
# Watch collector receive spans
docker compose logs -f otel-collector | head -20
```

You should see entries like:
```
TraceID : abc123...
SpanID  : def456...
...
```
