# ADR-005: Self-Service XRD Design with T-Shirt Sizing

## Status

Accepted

## Context

Product teams need a simple, self-service interface to provision MongoDB instances without understanding the Percona Operator CR schema, Kubernetes storage classes, network policies, or resource quotas. The platform team must retain control over infrastructure standards, security policies, and resource governance.

### Design goals

1. **Minimal consumer API** - Product teams specify only what matters to them: team name, environment, size, and optional features (backup, monitoring)
2. **T-shirt sizing** - Predefined resource profiles (S, M, L) that map to tested and validated configurations
3. **Secure by default** - Every provisioned instance includes TLS, SCRAM auth, network isolation, and resource limits without explicit opt-in
4. **Platform governance** - The Composition (owned by platform team) enforces resource ceilings, naming conventions, and operational standards

### T-shirt size evaluation

Resource profiles were designed based on common MongoDB workload patterns observed in regulated industries:

| Profile | Use Case | CPU (request/limit) | Memory (request/limit) | Storage | Replica Set Size |
|---------|----------|---------------------|----------------------|---------|-----------------|
| **S (Small)** | Dev/test, prototyping, low-traffic APIs | 500m / 1 | 1Gi / 2Gi | 10Gi | 3 members |
| **M (Medium)** | Staging, moderate production workloads | 1 / 2 | 2Gi / 4Gi | 20Gi | 3 members |
| **L (Large)** | High-traffic production, analytics backends | 2 / 4 | 4Gi / 8Gi | 50Gi | 3 members |

All sizes deploy a 3-member replica set to maintain HA guarantees. The WiredTiger cache is set to 50% of the memory limit for each profile.

## Decision

We define a Crossplane `CompositeResourceDefinition` (XRD) named `MongoDBInstance` with the following schema:

### XRD API surface (what product teams see)

```yaml
apiVersion: dbaas.platform.local/v1alpha1
kind: MongoDBInstance
metadata:
  name: team-alpha-orders-db
spec:
  parameters:
    teamName: alpha              # Required - owning team
    environment: staging         # Required - dev | staging | production
    size: M                      # Required - S | M | L
    version: "7.0"               # Optional - MongoDB version (default: 7.0)
    backupEnabled: true          # Optional - enable PBM backups (default: true)
    monitoringEnabled: true      # Optional - enable Prometheus exporter (default: true)
```

### What the XRD abstracts (hidden from consumers)

| Abstracted concern | How the Composition handles it |
|-------------------|-------------------------------|
| Namespace creation | Auto-creates `mongodb-<teamName>-<environment>` namespace |
| Percona PSMDB CR | Maps size to CPU/memory/storage, sets TLS, SCRAM, anti-affinity |
| StorageClass | Platform-standard StorageClass with WaitForFirstConsumer |
| NetworkPolicy | Restricts ingress to same namespace + monitoring namespace |
| ResourceQuota | Caps total namespace resources at 2x the instance profile |
| LimitRange | Sets default pod limits matching the size profile |
| PBM backup config | Configures daily snapshot + oplog backup if `backupEnabled: true` |
| Monitoring | Deploys mongodb-exporter sidecar if `monitoringEnabled: true` |
| Labels and annotations | Consistent labeling with team, environment, managed-by |

### What the XRD exposes (consumer-controlled)

| Exposed parameter | Rationale |
|-------------------|-----------|
| `teamName` | Drives namespace naming, RBAC, and cost attribution |
| `environment` | Controls anti-affinity strength (soft for dev, hard for production) |
| `size` | Maps to validated resource profiles |
| `version` | Allows teams to pin MongoDB version for compatibility |
| `backupEnabled` | Some dev instances do not need backup overhead |
| `monitoringEnabled` | Optional for dev environments |

### Naming conventions

All generated resources follow this pattern:

```
Namespace:     mongodb-{teamName}-{environment}
PSMDB CR:      {teamName}-{environment}-rs
Service:       {teamName}-{environment}-rs-rs0
Backup:        {teamName}-{environment}-backup-{timestamp}
```

### Versioning strategy

The XRD uses `v1alpha1` to signal that the API is experimental. Migration to `v1beta1` will occur after:
- At least 3 teams have used the API in staging
- No breaking schema changes for 2 consecutive minor releases
- Connection detail publishing is validated end-to-end

## Consequences

### What becomes easier

- Product teams provision a MongoDB instance with 6 lines of YAML
- Platform team updates resource profiles centrally without touching consumer claims
- Cost attribution is automatic via team-scoped namespaces
- Security baseline (TLS, SCRAM, NetworkPolicy) is enforced without consumer effort
- Adding a new size (XL, XXL) requires only a Composition patch, no API change

### What becomes harder

- Teams with non-standard requirements (custom WiredTiger settings, specific shard topology) must request platform team support
- The Composition complexity grows as more features are added (CDC, custom auth, read preferences)
- Schema evolution requires careful versioning to avoid breaking existing claims

### What we gain

- A documented, versioned contract between platform and product teams
- Repeatable, auditable provisioning (every instance is a Kubernetes resource in Git)
- Foundation for extending to other database engines using the same pattern (PostgreSQL XRD, Redis XRD)

### References

- ADR-003: Crossplane vs ArgoCD ApplicationSets
- ADR-001: Percona vs Community Operator
