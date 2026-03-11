# ADR-006: CDC Architecture - Debezium vs Native Change Streams

## Status

Accepted

## Context

The platform needs a Change Data Capture (CDC) pipeline to stream MongoDB document changes to downstream systems (analytics, search indexes, event-driven microservices). Two approaches were evaluated:

1. **Debezium MongoDB Connector** - A Kafka Connect connector that reads the MongoDB oplog (via change streams internally) and publishes events to Kafka topics with schema tracking, offset management, and exactly-once delivery guarantees.

2. **Native MongoDB Change Streams** - Direct application-level consumption of change streams via the MongoDB driver, processing events in custom consumer code without an intermediary message broker.

### Requirements

| Requirement | Weight |
|-------------|--------|
| At-least-once delivery guarantee | High |
| Schema evolution support | Medium |
| Resume after consumer restart (offset tracking) | High |
| Fan-out to multiple consumers | High |
| Decoupling producers from consumers | High |
| Operational observability (lag, throughput) | Medium |
| Minimal application code | Medium |
| Integration with existing Kubernetes tooling | Medium |

### Evaluation

| Criterion | Debezium + Kafka | Native Change Streams |
|-----------|-----------------|----------------------|
| **Delivery guarantees** | At-least-once (Kafka offsets) | At-least-once (resume tokens) |
| **Offset management** | Automatic (Kafka Connect) | Manual (application must persist resume token) |
| **Fan-out** | Native (Kafka consumer groups) | Requires custom multiplexing |
| **Schema evolution** | Built-in (Avro/JSON schema registry) | Application responsibility |
| **Decoupling** | Full (Kafka as buffer) | Tight coupling (direct connection) |
| **Backpressure** | Kafka handles retention | Application must handle |
| **Observability** | JMX metrics, Kafka consumer lag | Custom metrics required |
| **Operational complexity** | Higher (Kafka + Connect + Debezium) | Lower (just MongoDB driver) |
| **Latency** | Sub-second (through Kafka) | Real-time (direct) |
| **Resource cost** | Higher (Kafka cluster + ZK/KRaft) | Lower (no additional infra) |

## Decision

We chose **Debezium MongoDB Connector with Strimzi-managed Kafka** for the CDC pipeline.

### Key reasons

1. **Fan-out without coupling** - Multiple downstream consumers (analytics, search, audit) can independently consume the same change events via Kafka consumer groups, without any coordination or impact on MongoDB.

2. **Offset management** - Kafka Connect automatically tracks the position in the change stream. On restart, Debezium resumes from the last committed offset without data loss.

3. **Operational maturity** - Debezium has extensive production usage for MongoDB CDC, with built-in snapshot mode, tombstone events, and configurable transforms.

4. **Kubernetes-native with Strimzi** - The Strimzi operator provides declarative Kafka cluster management, topic creation, and user management - all as Kubernetes CRs that integrate with GitOps.

5. **Observability** - Kafka consumer lag metrics, Debezium connector health, and throughput are readily available via JMX and Prometheus exporters.

### Trade-offs accepted

- **Higher infrastructure cost** - Running Kafka (3 brokers) + Kafka Connect adds resource overhead
- **Increased complexity** - Three additional components (Strimzi operator, Kafka cluster, Debezium connector) to manage
- **Higher latency** - Events pass through Kafka before reaching consumers (typically sub-second, but not real-time)
- **Learning curve** - Teams need to understand Kafka consumer patterns and Debezium event schemas

## Consequences

### What becomes easier

- Adding new consumers for the same change events (just create a new consumer group)
- Replaying events from a specific offset for debugging or reprocessing
- Monitoring CDC pipeline health through Kafka lag metrics
- Handling consumer downtime (Kafka retains events per retention policy)

### What becomes harder

- Debugging end-to-end event flow across MongoDB -> Debezium -> Kafka -> Consumer
- Managing Kafka cluster upgrades and partition rebalancing
- Handling schema changes that break downstream consumers

### What we gain

- A reusable event streaming platform that can serve CDC for all database engines on the platform
- Clear separation between data producers (MongoDB) and consumers (analytics, search, microservices)
- Foundation for event-driven architecture patterns across the organization
