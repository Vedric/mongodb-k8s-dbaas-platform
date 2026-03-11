# Architecture Overview

This document provides a detailed technical architecture of the mongodb-k8s-dbaas-platform, covering component topology, data flows, and integration patterns across all platform layers.

## High-Level Architecture

```mermaid
graph TB
    subgraph "Consumer Interface"
        CLAIM[MongoDBInstanceClaim<br/>v1alpha1]
    end

    subgraph "Self-Service Layer"
        XRD[MongoDBInstance XRD<br/>S / M / L sizing]
        COMP[Crossplane Composition]
    end

    subgraph "Orchestration Layer"
        NS[Tenant Namespace]
        NP[NetworkPolicy]
        RQ[ResourceQuota]
        LR[LimitRange]
        SECRET[SCRAM Credentials Secret]
    end

    subgraph "Operator Layer"
        PSMDB[Percona Server for<br/>MongoDB Operator v1.22.0]
    end

    subgraph "Data Layer"
        RS[3-Node Replica Set<br/>MongoDB 7.0]
        SH[Sharded Cluster<br/>mongos + cfg + 2 shards]
    end

    subgraph "Backup & DR"
        PBM[Percona Backup<br/>for MongoDB]
        MINIO[MinIO<br/>S3-compatible storage]
    end

    subgraph "Observability Stack"
        EXP[MongoDB Exporter]
        PROM[Prometheus]
        GRAF[Grafana<br/>4 dashboards]
        LOKI[Loki]
        FB[Fluent Bit DaemonSet]
        ALERTS[PrometheusRules<br/>14 alert rules + 8 recording rules]
    end

    subgraph "CDC Pipeline"
        CS[MongoDB Change Streams]
        DBZ[Debezium Connector 2.6.1]
        KAFKA[Strimzi Kafka<br/>3 brokers / KRaft]
        DLQ[Dead Letter Queue]
        CONS[Go Event Consumer]
    end

    subgraph "Security"
        TLS[cert-manager<br/>self-signed CA / RSA 2048]
        VAULT[Vault Agent<br/>Dynamic Credentials]
        SCRAM[SCRAM-SHA-256]
        ENCREST[WiredTiger<br/>Encryption at Rest]
        AUDITLOG[Audit Logging]
    end

    CLAIM --> XRD --> COMP
    COMP --> NS & NP & RQ & LR & SECRET
    COMP --> PSMDB
    PSMDB --> RS
    PSMDB --> SH
    RS --> PBM --> MINIO
    RS --> EXP --> PROM --> GRAF
    PROM --> ALERTS
    RS --> FB --> LOKI --> GRAF
    RS --> CS --> DBZ --> KAFKA --> CONS
    KAFKA --> DLQ
    TLS --> RS
    VAULT --> SECRET
    SCRAM --> RS
    ENCREST --> RS
    AUDITLOG --> RS
```

## Component Details

### Self-Service Layer

The self-service layer provides a Crossplane-based abstraction that allows product teams to provision MongoDB instances without knowledge of the underlying operator or infrastructure.

```mermaid
flowchart LR
    A[Product Team] -->|kubectl apply| B[MongoDBInstanceClaim]
    B -->|reconcile| C[Crossplane]
    C -->|create| D[Namespace<br/>mongodb-TEAM-ENV]
    C -->|create| E[NetworkPolicy]
    C -->|create| F[ResourceQuota]
    C -->|create| G[LimitRange]
    C -->|create| H[SCRAM Secret]
    C -->|create| I[PerconaServerMongoDB CR]
    I -->|reconcile| J[Percona Operator]
    J -->|create| K[StatefulSet<br/>3 pods]
```

**XRD API surface** (`dbaas.platform.local/v1alpha1`):

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `teamName` | string | Yes | Owning team (namespace prefix, RBAC, cost attribution) |
| `environment` | enum | Yes | `dev`, `staging`, `production` |
| `size` | enum | Yes | `S`, `M`, `L` (maps to resource profiles) |
| `version` | enum | No | MongoDB version (`6.0`, `7.0`). Default: `7.0` |
| `backupEnabled` | bool | No | Enable PBM backups. Default: `true` |
| `monitoringEnabled` | bool | No | Enable mongodb-exporter. Default: `true` |

**T-shirt size profiles**:

| Size | CPU req/lim | Memory req/lim | Storage | WiredTiger Cache |
|------|-------------|----------------|---------|------------------|
| S | 500m / 1 | 1Gi / 2Gi | 10Gi | 0.5 GB |
| M | 1 / 2 | 2Gi / 4Gi | 20Gi | 1.0 GB |
| L | 2 / 4 | 4Gi / 8Gi | 50Gi | 2.0 GB |

**Composition resources** (6 total per claim):

1. **Namespace** - `mongodb-{teamName}-{environment}`
2. **NetworkPolicy** - Intra-namespace + monitoring + operator + DNS egress
3. **ResourceQuota** - 2x instance profile to allow for upgrades and operator overhead
4. **LimitRange** - Default container limits scaled to size profile
5. **PerconaServerMongoDB CR** - 3-node replica set with size-appropriate resources
6. **SCRAM Secret** - Database admin credentials (placeholder, replaced by Vault in production)

Reference: [ADR-003](decisions/ADR-003-crossplane-vs-argocd-appset.md), [ADR-005](decisions/ADR-005-self-service-xrd-design.md)

---

### Operator Layer

The Percona Server for MongoDB Operator v1.22.0 manages the full lifecycle of MongoDB clusters:

- Automated replica set initialization and member management
- Rolling updates with `SmartUpdate` strategy
- Automated primary failover coordination
- User management via Kubernetes Secrets
- Storage provisioning via PVC templates

**Deployment model**:

- Installed via Helm (`percona/psmdb-operator` chart v1.22.0) in `mongodb-operator` namespace
- `watchAllNamespaces: true` for cluster-wide CR reconciliation
- CRDs installed separately (`percona/psmdb-operator-crds`)
- Non-root, read-only filesystem, all capabilities dropped

Reference: [ADR-001](decisions/ADR-001-percona-vs-community-operator.md)

---

### Data Layer

#### Replica Set Topology

```mermaid
graph LR
    subgraph "Kubernetes Cluster"
        subgraph "Node 1"
            P[Primary<br/>mongodb-rs-rs0-0]
        end
        subgraph "Node 2"
            S1[Secondary<br/>mongodb-rs-rs0-1]
        end
        subgraph "Node 3"
            S2[Secondary<br/>mongodb-rs-rs0-2]
        end
    end

    P <-->|replication| S1
    P <-->|replication| S2
    S1 <-->|heartbeat| S2

    PDB[PodDisruptionBudget<br/>maxUnavailable: 1]
    AA[Anti-Affinity<br/>kubernetes.io/hostname]
```

- 3 data-bearing members spread across nodes via pod anti-affinity
- PDB ensures at most 1 member unavailable during voluntary disruptions
- Write concern `majority` ensures durability on acknowledged writes
- WiredTiger engine with operation profiling for slow queries (>100ms)

#### Sharded Cluster Topology

```mermaid
graph TB
    subgraph "Routing"
        M1[mongos-0]
        M2[mongos-1]
        M3[mongos-2]
    end

    subgraph "Config Servers"
        C1[cfg-0]
        C2[cfg-1]
        C3[cfg-2]
    end

    subgraph "Shard 0"
        S0P[Primary]
        S0S1[Secondary]
        S0S2[Secondary]
    end

    subgraph "Shard 1"
        S1P[Primary]
        S1S1[Secondary]
        S1S2[Secondary]
    end

    M1 & M2 & M3 --> C1 & C2 & C3
    M1 & M2 & M3 --> S0P & S1P
    S0P <--> S0S1 & S0S2
    S1P <--> S1S1 & S1S2
```

- 3 mongos routers for query distribution
- 3 config servers for metadata and chunk mapping
- 2 shards, each a 3-member replica set
- Total: 12 pods for a full sharded deployment

**Storage**:
- `StorageClass` with `WaitForFirstConsumer` binding (topology-aware scheduling)
- `Retain` reclaim policy to prevent accidental data loss
- Volume expansion enabled for online resize

Reference: [ADR-002](decisions/ADR-002-storage-class-selection.md)

---

### Backup and Disaster Recovery

```mermaid
flowchart LR
    subgraph "MongoDB Replica Set"
        RS[rs0]
    end

    subgraph "Percona Backup for MongoDB"
        SNAP[Daily Snapshot<br/>02:00 UTC / gzip]
        OPLOG[Continuous Oplog<br/>every 10 min]
    end

    subgraph "S3 Storage"
        MINIO[MinIO<br/>minio.mongodb-backup.svc:9000]
    end

    RS --> SNAP --> MINIO
    RS --> OPLOG --> MINIO

    MINIO -->|restore-full.sh| FULL[Full Snapshot Restore]
    MINIO -->|restore-pitr.sh| PITR[Point-in-Time Recovery]
    FULL --> VALIDATE[validate-integrity.sh<br/>dbHash + counts + indexes]
    PITR --> VALIDATE
```

| Metric | Target | Implementation |
|--------|--------|----------------|
| **RPO** | 15 minutes | Continuous oplog backup every 10 minutes |
| **RTO** | 30 minutes | Automated restore scripts with validation |
| **Retention** | 7 days | Daily snapshots with gzip compression |

Restore procedures:
1. **Full restore** (`restore-full.sh`) - Restores the latest or specified snapshot
2. **PITR restore** (`restore-pitr.sh`) - Restores snapshot + replays oplog to target timestamp
3. **Integrity validation** (`validate-integrity.sh`) - Verifies `dbHash`, document counts, and index consistency

Reference: [ADR-004](decisions/ADR-004-backup-strategy-pbm.md)

---

### Observability Stack

```mermaid
flowchart TB
    subgraph "Metrics Pipeline"
        EXP[MongoDB Exporter<br/>port 9216] -->|scrape| SM[ServiceMonitor]
        SM -->|discover| PROM[Prometheus]
        PROM -->|evaluate| RR[8 Recording Rules]
        PROM -->|evaluate| AR[14 Alert Rules<br/>6 groups]
        PROM -->|query| GRAF[Grafana]
    end

    subgraph "Logging Pipeline"
        MONGOD[mongod JSON logs] -->|tail| FB[Fluent Bit DaemonSet]
        FB -->|push| LOKI[Loki]
        LOKI -->|query| GRAF
    end

    subgraph "Grafana Dashboards"
        D1[Replication<br/>lag, oplog, member states]
        D2[WiredTiger<br/>cache, evictions, checkpoints]
        D3[Connections<br/>active, pool, per-client]
        D4[Tenant Overview<br/>resource consumption]
    end

    GRAF --> D1 & D2 & D3 & D4
```

**Recording rules** (pre-computed metrics):
- `mongodb:replication_lag:seconds` - Lag between primary and secondary optime
- `mongodb:connections:utilization_ratio` - Current / available connections
- `mongodb:wiredtiger:cache_used_ratio` - Cache bytes in use / max configured
- `mongodb:opcounters:rate5m` - Operation rates (insert, query, update, delete, command)
- Plus 4 additional recording rules for dashboard efficiency

**Alert groups** (14 rules across 6 groups):

| Group | Alerts | Severity |
|-------|--------|----------|
| Availability | Primary not found, member down | Critical |
| Replication | Lag > 10s, oplog window < 2h | Warning / Critical |
| Resources | CPU > 80%, memory > 85% | Warning |
| Storage | Disk > 80%, disk > 90% | Warning / Critical |
| WiredTiger | Cache dirty > 20%, eviction stalls | Warning |
| Backup | Backup failed, backup age > 25h | Critical |

**Log correlation**: Loki datasource configured with derived fields for trace ID extraction, enabling metric-to-log correlation in Grafana.

---

### CDC Pipeline

```mermaid
flowchart LR
    subgraph "Source"
        RS[MongoDB Replica Set]
        CS[Change Streams<br/>full document pre-image]
    end

    subgraph "Capture"
        DBZ[Debezium MongoDB<br/>Connector 2.6.1]
    end

    subgraph "Streaming"
        KAFKA[Strimzi Kafka<br/>3 brokers / KRaft / 3.7.0]
        TOPIC[mongodb.cdc.events]
        DLQ[DLQ Topic]
    end

    subgraph "Consumer"
        GO[Go Event Consumer<br/>Sarama client]
        METRICS[Prometheus Metrics<br/>lag, throughput, errors]
    end

    RS --> CS --> DBZ --> TOPIC
    DBZ -->|errors| DLQ
    TOPIC --> GO
    GO --> METRICS
```

**Kafka cluster**:
- 3 brokers managed by Strimzi Operator
- KRaft mode (no ZooKeeper dependency)
- Kafka 3.7.0 with JMX Prometheus metrics
- Topic replication factor 3 for durability

**Debezium connector**:
- MongoDB connector v2.6.1
- Full document pre-image capture for complete change context
- Offset tracking for exactly-once delivery semantics
- Dead letter queue for poison messages

**Go event consumer**:
- Sarama Kafka client library
- Structured logging with `slog`
- Prometheus metrics: consumer lag, event throughput, processing errors, latency histogram
- Graceful shutdown with signal handling (SIGINT, SIGTERM)
- Multi-stage Docker build with distroless runtime image

Reference: [ADR-006](decisions/ADR-006-cdc-debezium-vs-change-streams.md)

---

### Security Architecture

```mermaid
flowchart TB
    subgraph "Encryption in Transit"
        CM[cert-manager] -->|issue| CA[Self-Signed CA<br/>10-year validity]
        CA -->|sign| CERT[Server/Client Certs<br/>ECDSA P-256 / auto-renew]
        CERT --> RS[MongoDB RS<br/>requireTLS mode]
    end

    subgraph "Authentication"
        SCRAM[SCRAM-SHA-256] --> RS
        VAULT[Vault Agent] -->|inject| CREDS[Dynamic Credentials<br/>auto-rotation]
        CREDS --> RS
    end

    subgraph "Authorization"
        ROLES[5 Role-Based Users]
        R1[databaseAdmin - full management]
        R2[clusterAdmin - replica set ops]
        R3[userAdmin - user/role management]
        R4[clusterMonitor - read-only monitoring]
        R5[backup - PBM operations]
    end

    subgraph "Data Protection"
        ENCREST[WiredTiger Encryption<br/>at Rest] --> RS
        AUDIT[Audit Logging<br/>auth + CRUD + DDL] --> RS
    end

    subgraph "Network Isolation"
        NP[NetworkPolicy per tenant]
        NP -->|allow| INTRA[Intra-namespace traffic]
        NP -->|allow| MON[Monitoring scrape :9216]
        NP -->|allow| DNS[DNS resolution :53]
        NP -->|deny| CROSS[Cross-tenant traffic]
    end
```

**Defense in depth layers**:

1. **Network** - NetworkPolicies enforce tenant isolation; only intra-namespace, monitoring, operator, and DNS traffic is allowed
2. **Transport** - TLS enforced on all replica set connections via cert-manager certificates
3. **Authentication** - SCRAM-SHA-256 with 5 role-based users; dynamic rotation via Vault
4. **Storage** - WiredTiger encryption at rest with key management
5. **Audit** - All authentication events, CRUD operations, and DDL changes are logged

---

### Multi-Tenancy Model

```mermaid
flowchart TB
    subgraph "Tenant: team-alpha (dev)"
        NS1[Namespace: mongodb-alpha-dev]
        NP1[NetworkPolicy]
        RQ1[ResourceQuota: 2 CPU / 4Gi]
        LR1[LimitRange]
        RS1[MongoDB S instance]
    end

    subgraph "Tenant: team-beta (staging)"
        NS2[Namespace: mongodb-beta-staging]
        NP2[NetworkPolicy]
        RQ2[ResourceQuota: 4 CPU / 8Gi]
        LR2[LimitRange]
        RS2[MongoDB M instance]
    end

    subgraph "Tenant: team-gamma (production)"
        NS3[Namespace: mongodb-gamma-production]
        NP3[NetworkPolicy]
        RQ3[ResourceQuota: 8 CPU / 16Gi]
        LR3[LimitRange]
        RS3[MongoDB L instance]
    end

    NS1 -.->|isolated| NS2
    NS2 -.->|isolated| NS3
    NS1 -.->|isolated| NS3
```

Each tenant receives:
- Dedicated namespace (`mongodb-{team}-{env}`)
- NetworkPolicy preventing cross-tenant communication
- ResourceQuota scaled to 2x the instance size profile (headroom for upgrades)
- LimitRange with defaults matching the size profile
- Independent SCRAM credentials

---

### CI/CD Pipeline

```mermaid
flowchart LR
    subgraph "lint.yaml"
        L1[yamllint]
        L2[shellcheck]
        L3[helm lint]
        L4[gofmt]
        L5[gitleaks]
    end

    subgraph "test.yaml"
        T1[Create kind cluster<br/>K8s v1.29.12]
        T2[Deploy operator]
        T3[Deploy replica set]
        T4[Wait for PSMDB ready]
        T5[Run bats tests<br/>8 integration tests]
    end

    subgraph "release.yaml"
        R1[Validate semver tag]
        R2[Check CHANGELOG entry]
        R3[Lint]
        R4[Integration tests]
        R5[Create GitHub Release]
    end

    PUSH[Push / PR] --> L1 & L2 & L3 & L4 & L5
    PR[PR to develop/main] --> T1 --> T2 --> T3 --> T4 --> T5
    TAG[Tag v*] --> R1 --> R2 --> R3 --> R4 --> R5
```

**Test coverage**:

| Test Suite | File | Tests | Coverage |
|-----------|------|-------|----------|
| Replica Set Health | `test_replicaset_health.bats` | 8 | Pod readiness, member count, primary election, replication lag, write concern |
| Sharding | `test_sharding.bats` | 10 | Mongos routing, config servers, shard topology |
| Backup/Restore | `test_backup_restore.bats` | 7 | Snapshot, PITR, integrity validation |
| Self-Service | `test_self_service.bats` | 15 | XRD provisioning, claim lifecycle, connection secrets |
| TLS | `test_tls.bats` | 12 | Certificate generation, TLS enforcement |
| Network Isolation | `test_network_isolation.bats` | 11 | Tenant isolation, cross-namespace denial |

**Chaos scenarios** (covered in [ADR-007](decisions/ADR-007-chaos-testing-approach.md)):

| Scenario | Script | Validates |
|----------|--------|-----------|
| Primary failure | `kill-primary.sh` | New primary elected <30s, no write loss, app reconnection <45s |
| Storage loss | `delete-pv.sh` | Backup-based recovery, data integrity post-restore |
| Network partition | `network-partition.sh` | Split-brain handling, partition healing, convergence |

---

## Cross-Project Integration Points

This platform is designed to integrate with a broader platform engineering portfolio:

```mermaid
flowchart TB
    MONGO[mongodb-k8s-dbaas-platform]

    VAULT[vault-k8s-enterprise-secrets-platform]
    CONSUL[consul-zero-trust-service-mesh]
    TERRAFORM[terraform-azure-enterprise-landing-zone]
    CICD[secure-cicd-platform]
    EKS[aws-eks-production-platform]

    VAULT -->|Dynamic MongoDB credentials<br/>auto-rotation| MONGO
    CONSUL -->|mTLS between CDC consumer<br/>and Kafka| MONGO
    TERRAFORM -->|AKS infrastructure<br/>provisioning| MONGO
    CICD -->|Trivy scanning of<br/>CDC consumer image| MONGO
    EKS -->|EKS deployment variant<br/>EBS CSI tuning| MONGO
```

| Project | Integration |
|---------|-------------|
| `vault-k8s-enterprise-secrets-platform` | Vault Agent injects dynamic MongoDB credentials with TTL-based rotation |
| `consul-zero-trust-service-mesh` | mTLS between CDC consumer and Kafka brokers, service discovery |
| `terraform-azure-enterprise-landing-zone` | AKS infrastructure with managed disks optimized for MongoDB |
| `secure-cicd-platform` | Trivy vulnerability scanning and SBOM generation for CDC consumer image |
| `aws-eks-production-platform` | EKS deployment variant with EBS CSI driver and gp3 storage tuning |
