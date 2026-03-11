# 💾 ADR-004: Backup Strategy with Percona Backup for MongoDB (PBM)

## 📌 Status

**Accepted**

## 🔍 Context

The platform requires a robust backup strategy that supports:

- **RPO < 15 minutes**: Minimal data loss in a disaster scenario
- **RTO < 30 minutes**: Fast recovery to minimize downtime
- **Point-in-Time Recovery (PITR)**: Restore to any second within the backup window
- **Automated scheduling**: No manual intervention for routine backups
- **Integrity validation**: Automated verification that backups are restorable
- **S3-compatible storage**: Cloud-agnostic backup destination

### Options evaluated

| Tool | Type | PITR | Operator Integration | Consistency |
|------|------|------|---------------------|-------------|
| `mongodump` / `mongorestore` | Logical | No | None (manual scripting) | Application-level |
| Filesystem snapshots (LVM/EBS) | Physical | No | Partial (cloud-specific) | Crash-consistent |
| **Percona Backup for MongoDB (PBM)** | Physical + Oplog | **Yes** | **Native (built into Percona Operator)** | **Fully consistent** |

### Why not `mongodump`?

- No PITR capability (point-in-time granularity limited to backup frequency)
- Slow for large datasets (reads all documents sequentially)
- Restoration requires index rebuilds (adds significant time to RTO)
- No native integration with the Percona Operator lifecycle

### Why not filesystem snapshots?

- Cloud-provider specific (EBS snapshots, Azure Disk snapshots)
- No cross-cloud portability
- PITR requires additional oplog capture mechanism
- Snapshot coordination across replica set members is complex

## ✅ Decision

We adopt **Percona Backup for MongoDB (PBM)** with a two-tier backup schedule:

### Tier 1: Daily Full Snapshots

- **Schedule**: Daily at 02:00 UTC
- **Type**: Physical (hot backup, no downtime)
- **Retention**: 7 days
- **Storage**: MinIO (S3-compatible) for local dev, S3/GCS for production

### Tier 2: Continuous Oplog Backup

- **Interval**: Every 10 minutes
- **Type**: Oplog tailing (incremental)
- **Purpose**: Enables PITR to any point between the last full snapshot and now
- **RPO achieved**: 10 minutes (worst case: failure right before oplog flush)

### Storage Backend

| Environment | Backend | Rationale |
|-------------|---------|-----------|
| Local (kind) | MinIO | Zero-cost, S3 API compatible, self-hosted |
| AWS | S3 | Native, durable, lifecycle policies |
| Azure | Azure Blob (S3-compat) | Native, geo-redundant options |
| GCP | GCS (S3-compat) | Native, multi-regional |

MinIO is the default for development and CI. The S3 API compatibility ensures the same PBM configuration works across all environments with only endpoint and credential changes.

### Recovery Procedures

| Scenario | Procedure | Estimated RTO |
|----------|-----------|---------------|
| Full cluster loss | Restore latest snapshot + replay oplog to target time | ~20 minutes |
| Accidental data deletion | PITR to timestamp before deletion | ~15 minutes |
| Corruption detected | Restore to last known good snapshot | ~10 minutes |
| Single member failure | Operator auto-recovery (no backup needed) | ~2 minutes |

### Integrity Validation

Every restore operation (manual or CI) must include:

1. `dbHash` comparison between source and restored data
2. Collection count verification
3. Index consistency check
4. Application-level read test

This validation is automated in the CI pipeline (`tests/ci/backup-restore-ephemeral.sh`).

## 📊 Consequences

### ✅ What becomes easier

- PITR is available out of the box with 10-minute granularity
- Backup/restore is declarative (configured in the Percona CR)
- Same backup tooling works across local, cloud, and hybrid deployments
- Operator handles backup agent lifecycle (no separate deployment needed)

### ⚠️ What becomes harder

- PBM requires a dedicated S3-compatible storage endpoint (MinIO for local)
- Oplog continuous backup adds I/O overhead (~5-10% on write-heavy workloads)
- Restore to a different cluster name requires additional configuration
- PBM version must be kept in sync with the Percona Operator version

### 🚨 Risks

- MinIO single-node deployment (local) is not production-grade. For production, use managed S3 or a multi-node MinIO cluster
- Oplog backup interval of 10 minutes means worst-case RPO is 10 minutes. For sub-minute RPO, reduce the interval (at the cost of increased storage I/O)
