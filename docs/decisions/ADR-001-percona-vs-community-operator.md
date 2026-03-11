# ADR-001: Percona Server for MongoDB Operator vs MongoDB Community Operator

## Status

Accepted

## Context

Deploying MongoDB on Kubernetes requires a mature operator to manage the lifecycle of replica sets, sharded clusters, backups, and upgrades. Two primary open-source options exist:

1. **MongoDB Community Operator** (maintained by MongoDB Inc.)
2. **Percona Server for MongoDB Operator** (maintained by Percona)

The platform requires:

- High-availability replica sets (3+ nodes) with automated failover
- Sharded cluster support (mongos, config servers, multiple shards)
- Integrated backup and point-in-time recovery (PITR)
- TLS for intra-cluster and client connections
- Encryption at rest
- Production-grade resource management (affinity, tolerations, resource limits)
- Active upstream maintenance and community

### Licensing comparison

| Aspect | MongoDB Community Operator | Percona Operator |
|--------|--------------------------|------------------|
| License | Apache 2.0 | Apache 2.0 |
| Server License | SSPL (Server Side Public License) | Apache 2.0 (Percona Server for MongoDB) |
| Commercial restrictions | SSPL may create constraints for service providers | No restrictions |

The SSPL license on MongoDB Community Edition introduces legal ambiguity for organizations offering database services (internal or external). Percona Server for MongoDB is a fully Apache 2.0 licensed drop-in replacement, removing this concern entirely.

### Feature comparison

| Feature | MongoDB Community Operator | Percona Operator |
|---------|--------------------------|------------------|
| Replica set management | Yes | Yes |
| Sharded cluster support | No (Enterprise Operator only) | Yes |
| Integrated backup (PBM) | No (external tooling required) | Yes (built-in PBM integration) |
| Point-in-time recovery | No | Yes (oplog-based via PBM) |
| TLS management | Basic | Full (auto-rotation support) |
| Encryption at rest | No | Yes (KMIP / key file) |
| Multi-cluster support | No | Yes |
| Automated minor upgrades | Yes | Yes |
| PMM integration | No | Yes (Percona Monitoring and Management) |
| Helm chart | Yes | Yes |
| Kustomize support | Limited | Full |

### Maintenance and community

| Metric | MongoDB Community Operator | Percona Operator |
|--------|--------------------------|------------------|
| GitHub stars (as of 2024) | ~600 | ~1,100 |
| Release cadence | Quarterly | Monthly |
| Issue response time | Weeks | Days |
| Production references | Limited public references | Widely used in enterprise (banking, telecom) |
| Documentation quality | Basic | Comprehensive with runbooks |

## Decision

We adopt the **Percona Server for MongoDB Operator** as the primary operator for this platform.

Key drivers:

1. **Sharding support out of the box** - The MongoDB Community Operator does not support sharded clusters. This is only available in the Enterprise Operator, which requires a MongoDB subscription. The Percona Operator supports both replica sets and sharded clusters in its open-source version.

2. **Integrated backup with PBM** - Percona Backup for MongoDB (PBM) is tightly integrated into the operator lifecycle. Backup schedules, retention policies, and PITR are configured declaratively in the CR. With the Community Operator, backup requires external tooling (mongodump, custom scripts, or third-party solutions).

3. **Licensing clarity** - The entire stack (operator + server) is Apache 2.0. There are no SSPL concerns for internal or external service offerings.

4. **Production maturity** - The Percona Operator is battle-tested in regulated industries (banking, energy, defense) where data integrity and compliance are non-negotiable.

5. **Observability integration** - Built-in support for Percona MongoDB Exporter and PMM reduces the effort to build a monitoring stack.

## Consequences

### What becomes easier

- Backup and PITR configuration is declarative and operator-managed
- Sharded clusters can be deployed with the same tooling as replica sets
- No licensing concerns for any deployment model
- Monitoring exporters are pre-configured in the CR

### What becomes harder

- Teams familiar with the MongoDB Community Operator will need to learn the Percona CR schema (though it is well-documented)
- Percona Server for MongoDB has minor behavioral differences compared to MongoDB Community Edition (mostly around default configurations and monitoring endpoints)
- Dependency on Percona's release cycle for operator and server version updates

### Risks

- If Percona significantly changes their licensing or support model, migration to an alternative operator would require CR schema migration. This risk is mitigated by the Apache 2.0 license and the active fork ecosystem.
