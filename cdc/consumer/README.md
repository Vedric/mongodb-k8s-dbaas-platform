# CDC Event Consumer

A lightweight Go microservice that consumes MongoDB change events from Kafka, published by the Debezium MongoDB connector.

## Features

- Consumes CDC events from Kafka using consumer groups
- Structured JSON logging via `slog`
- Prometheus metrics endpoint (`/metrics`) for monitoring
- Health check endpoints (`/healthz`, `/readyz`)
- Graceful shutdown on SIGINT/SIGTERM
- Configurable via environment variables

## Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `cdc_consumer_events_processed_total` | Counter | Total events processed (labeled by operation, database, collection) |
| `cdc_consumer_events_errors_total` | Counter | Total event processing errors |
| `cdc_consumer_processing_duration_seconds` | Histogram | Event processing latency |
| `cdc_consumer_last_event_timestamp` | Gauge | Timestamp of the last processed event |

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `KAFKA_BROKERS` | `mongodb-cdc-kafka-bootstrap.kafka.svc.cluster.local:9092` | Comma-separated Kafka broker addresses |
| `KAFKA_TOPIC` | `mongodb.backup-test.validation-data` | Kafka topic to consume from |
| `CONSUMER_GROUP` | `cdc-event-consumer` | Kafka consumer group ID |
| `METRICS_PORT` | `8080` | Port for metrics and health endpoints |

## Build

```bash
# Build locally
go build -o cdc-consumer .

# Build Docker image
docker build -t cdc-consumer:latest .
```

## Run

```bash
# Local (requires Kafka access)
export KAFKA_BROKERS="localhost:9092"
export KAFKA_TOPIC="mongodb.test.events"
./cdc-consumer

# Kubernetes (deployed via Dockerfile)
kubectl apply -f deployment.yaml
```

## Event Format

The consumer expects Debezium-transformed events (ExtractNewDocumentState):

```json
{
  "op": "c",
  "source_db": "mydb",
  "source_collection": "mycollection",
  "source_ts_ms": 1710000000000,
  "after": { "field": "value" }
}
```

Operations: `c` (insert), `u` (update), `d` (delete), `r` (read/snapshot)
