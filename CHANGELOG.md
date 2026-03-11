# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0.1 - 2026-03-11

### Security

- Update `golang.org/x/crypto` v0.21.0 to v0.25.0
- Update `golang.org/x/net` v0.22.0 to v0.27.0
- Update `google.golang.org/protobuf` v1.32.0 to v1.33.0

### Added

- Dependabot configuration targeting `develop` branch for Go modules and GitHub Actions

### Changed

- CI Go version pinning updated from `1.22` to `stable`

## v1.0.0 - 2026-03-11

### Added

- Chaos testing scripts: kill-primary, delete-PV, network-partition with recovery validation (ADR-007)
- Seed data script with 260 sample documents across 3 collections
- Port-forward script for MongoDB, Grafana, MinIO, and Kafka local access
- Release CI workflow with tag-based semver validation, integration tests, and changelog extraction
- CHANGELOG.md with full release history

### Changed

- README.md updated with release badge, version badge, and correct XRD API reference

## v0.5.0 - 2026-03-11

### Added

- MongoDB exporter configuration with ServiceMonitors for Prometheus scraping
- 8 Prometheus recording rules (replication lag, cache metrics, connection utilization)
- 14 PrometheusRule alerting rules across 6 groups (availability, replication, resources, storage, WiredTiger, backup)
- 4 Grafana dashboards: replication, WiredTiger, connections, multi-tenant overview
- Fluent Bit DaemonSet with MongoDB JSON log parser and Loki output
- Grafana Loki datasource with derived field correlation
- ADR-006: Debezium vs native MongoDB Change Streams
- Strimzi Kafka cluster (3 brokers, Kafka 3.7.0, JMX Prometheus metrics)
- Debezium MongoDB connector 2.6.1 with full document pre-image capture
- CDC event topics with dead letter queue
- Go CDC event consumer microservice with Prometheus metrics and structured logging
- deploy-observability, deploy-cdc, deploy-self-service Makefile targets

## v0.4.0 - 2026-03-11

### Added

- ADR-003: Crossplane Compositions over ArgoCD ApplicationSets
- ADR-005: Self-service XRD design with t-shirt sizing (S/M/L)
- MongoDBInstance Crossplane XRD (v1alpha1) with 6-parameter consumer API
- Crossplane Composition mapping claims to 6 resources (namespace, NetworkPolicy, ResourceQuota, LimitRange, PSMDB CR, SCRAM credentials)
- 3 example claims: team-alpha (S/dev), team-beta (M/staging), team-gamma (L/production)
- Tenant isolation: namespace template, NetworkPolicy, ResourceQuota, LimitRange
- Bats tests for network isolation (11 tests)
- Bats tests for self-service provisioning flow (15 tests)
- Scaling runbook (vertical, horizontal, storage, self-service)

## v0.3.0 - 2026-03-11

### Added

- TLS encryption via cert-manager (self-signed CA, RSA 2048, auto-renewal)
- SCRAM-SHA-256 authentication with role-based user secrets
- MongoDB audit logging configuration
- WiredTiger encryption at rest with key rotation procedure
- Vault Agent integration for dynamic credential injection
- ADR-004: Two-tier backup strategy with PBM
- Percona Backup for MongoDB with MinIO S3-compatible storage
- Daily snapshot backups (02:00 UTC, 7-day retention, gzip)
- Continuous oplog backup every 10 minutes for PITR
- Full restore and PITR restore automation scripts
- Post-restore integrity validation (dbHash, counts, indexes)
- CI backup/restore validation cycle
- Bats tests for backup/restore (7 tests) and TLS enforcement (12 tests)
- Operational runbooks for backup/restore and primary failover

## v0.2.0 - 2026-03-11

### Added

- Percona Server for MongoDB Operator deployment (Helm + Kustomize)
- 3-node replica set CR with anti-affinity, PDB, WiredTiger tuning
- Sharded cluster CR (3 mongos, 3 config servers, 2 shards x 3 members)
- StorageClass for kind (local-path, WaitForFirstConsumer, Retain)
- Bats tests for replica set health (8 tests) and sharding (10 tests)
- Bootstrap script (kind cluster + operator + replica set)
- Teardown script with cleanup
- Kind cluster config (1 control-plane + 3 workers)
- CI test workflow with kind cluster
- ADR-002: Storage class selection
- Storage benchmark documentation (fio profiles)
- deploy-operator, deploy-replicaset, deploy-sharded Makefile targets

## v0.1.0 - 2026-03-11

### Added

- Project scaffolding with Apache 2.0 license
- Pre-commit hooks (yamllint, shellcheck, gitleaks)
- YAML linting configuration (.yamllint.yaml)
- EditorConfig for consistent formatting
- CI lint workflow (yamllint, shellcheck, helm lint, gitleaks)
- ADR-001: Percona vs Community Operator
- README.md with architecture diagram, feature overview, and usage guide
- Makefile with help, lint, clean, and placeholder targets
