# ADR-003: Crossplane Compositions vs ArgoCD ApplicationSets for Self-Service Layer

## Status

Accepted

## Context

The platform needs a self-service provisioning layer that allows product teams to request MongoDB instances without deep Kubernetes or operator knowledge. Two primary approaches were evaluated:

1. **Crossplane Compositions** - Define a custom Composite Resource Definition (XRD) that maps a simplified API to the underlying Percona PSMDB Custom Resource, namespace, NetworkPolicy, ResourceQuota, and LimitRange.

2. **ArgoCD ApplicationSets** - Use the Pull Request Generator or Cluster Generator to dynamically create ArgoCD Applications from a template repository. Teams submit PRs adding a values file, and ArgoCD deploys the corresponding Helm release.

### Requirements

| Requirement | Weight |
|-------------|--------|
| Product teams can provision without writing K8s manifests | High |
| Provisioning is declarative and GitOps-compatible | High |
| Platform team controls resource limits and security policies | High |
| Supports t-shirt sizing (S/M/L) with predefined profiles | Medium |
| Integrates with existing RBAC and namespace isolation | High |
| Minimal operational overhead for the platform team | Medium |
| Extensible to multi-cloud (EKS, AKS, GKE) in the future | Low |

### Evaluation

| Criterion | Crossplane | ArgoCD ApplicationSets |
|-----------|-----------|----------------------|
| **Abstraction level** | Custom API (XRD) hides all K8s complexity | Teams still interact with Helm values |
| **Declarative provisioning** | `kubectl apply` a single YAML claim | PR-based workflow, indirect |
| **Resource composition** | One claim creates namespace + RBAC + PSMDB + NetworkPolicy + Quota | Requires Helm chart with all resources bundled |
| **Lifecycle management** | Built-in reconciliation loop | Depends on ArgoCD sync policies |
| **T-shirt sizing** | Native via Composition patches and transforms | Possible but requires values-file conventions |
| **Team autonomy** | Teams own their claims, platform owns the Composition | Teams must follow PR templates, platform owns the chart |
| **Learning curve** | Higher initial setup, simple consumption | Lower setup, but teams need Helm/values knowledge |
| **Multi-cloud readiness** | First-class (Crossplane providers for AWS, Azure, GCP) | ArgoCD is cluster-scoped, not cloud-aware |
| **Drift detection** | Built-in (Crossplane controller) | ArgoCD detects drift but self-heal depends on config |
| **Maturity for DB workloads** | Growing ecosystem, strong for infrastructure | Mature for app deployment, less natural for stateful infra |

## Decision

We chose **Crossplane Compositions** for the self-service provisioning layer.

### Key reasons

1. **True API abstraction** - The XRD defines a clean, versioned API (`MongoDBInstance`) that completely hides the complexity of the underlying Percona CR, namespaces, network policies, and quotas. Product teams submit a 10-line YAML claim instead of understanding 200+ line operator CRs.

2. **Single-resource composition** - One Crossplane Claim triggers the creation of all required resources (namespace, PSMDB CR, NetworkPolicy, ResourceQuota, LimitRange, ServiceAccount). With ApplicationSets, this would require a monolithic Helm chart or multiple coordinated Applications.

3. **Platform-as-Product pattern** - The Crossplane XRD acts as an internal platform API, aligning with the platform engineering best practice of treating infrastructure as a product with a defined contract.

4. **GitOps compatibility** - Crossplane Claims are standard Kubernetes resources, stored in Git, and reconciled by the Crossplane controller. They integrate naturally with ArgoCD for the GitOps sync layer (ArgoCD syncs the Claims, Crossplane fulfills them).

5. **Multi-cloud extensibility** - When the platform expands to managed MongoDB services (Atlas, DocumentDB), Crossplane providers can fulfill the same XRD without changing the consumer API.

### Trade-offs accepted

- **Higher initial complexity** - Crossplane requires installing the Crossplane runtime, defining XRDs and Compositions, and understanding the Composition patching model
- **Additional controller** - Adds another controller to the cluster (Crossplane), increasing the operational surface
- **Community size** - Crossplane's ecosystem for database operators is smaller than ArgoCD's general adoption

## Consequences

### What becomes easier

- Product teams provision MongoDB instances with a single `kubectl apply` of a standardized claim
- Platform team enforces resource constraints, security policies, and network isolation centrally via the Composition
- Adding new t-shirt sizes or modifying resource profiles requires only Composition updates, not consumer changes
- Future multi-cloud support can be added transparently

### What becomes harder

- Platform engineers need to learn Crossplane's Composition model (patches, transforms, connection details)
- Debugging provisioning issues requires understanding both Crossplane and the Percona Operator reconciliation loops
- Upgrading Crossplane versions requires careful testing of XRD/Composition compatibility

### What we gain

- A clean internal API contract between platform and product teams
- Centralized governance without blocking team autonomy
- Foundation for extending the DBaaS to other database engines (PostgreSQL, Redis) using the same pattern
