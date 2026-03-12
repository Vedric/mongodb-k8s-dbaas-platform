# ADR-008: ArgoCD + Crossplane Complementary Pattern

## Status

Accepted

## Context

ADR-003 selected Crossplane Compositions over ArgoCD ApplicationSets for the **self-service provisioning layer**. However, the platform still needs a GitOps delivery mechanism for managing platform components (operator, observability stack, cluster configurations).

ArgoCD and Crossplane serve complementary roles:

- **ArgoCD** excels at continuous delivery - syncing Kubernetes manifests from Git to clusters
- **Crossplane** excels at infrastructure abstraction - exposing simplified APIs for complex resources

## Decision

Deploy ArgoCD alongside Crossplane with clear separation of concerns:

| Layer | Tool | Responsibility |
|-------|------|---------------|
| Platform delivery | ArgoCD | Sync operator, observability, cluster configs from Git |
| Self-service provisioning | Crossplane | Fulfill MongoDBInstance claims with XRD compositions |
| Tenant onboarding | ArgoCD ApplicationSet | Auto-sync new tenant claims from Git to clusters |

### Architecture

```
Git Repository
  |
  ├── ArgoCD App of Apps (root-app.yaml)
  │   ├── percona-operator Application
  │   ├── observability Application
  │   └── mongodb-replicaset Application
  |
  └── ArgoCD ApplicationSet (tenant-claims)
      └── Watches self-service/crossplane/examples/*-claim.yaml
          └── Syncs Claims to cluster
              └── Crossplane fulfills Claims -> PSMDB CRs
```

### Flow

1. Platform team pushes manifest changes to Git
2. ArgoCD detects drift and syncs to cluster (self-heal enabled)
3. Product teams add claim files to `self-service/crossplane/examples/`
4. ArgoCD ApplicationSet auto-creates an Application for each claim
5. Crossplane Composition translates the claim into full PSMDB CR + namespace + NetworkPolicy

## Consequences

### Positive

- Single source of truth in Git for all platform state
- ArgoCD UI provides visual overview of all managed components
- ApplicationSet bridges the gap between ArgoCD and Crossplane
- No contradiction with ADR-003 - Crossplane still handles provisioning logic

### Negative

- Additional operational component (ArgoCD) to maintain
- Resource overhead (~500 MB RAM for minimal ArgoCD deployment)
- Requires careful RBAC separation between ArgoCD and Crossplane

## References

- ADR-003: Crossplane Compositions vs ArgoCD ApplicationSets
- [ArgoCD App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [ApplicationSet Git Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
