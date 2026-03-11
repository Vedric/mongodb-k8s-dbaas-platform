# ADR-007: Chaos Testing Approach

## Status

Accepted

## Context

The platform must demonstrate resilience under failure conditions typical of production Kubernetes environments. Chaos testing validates that MongoDB HA mechanisms (replica set elections, PDB enforcement, data persistence) function correctly when components fail unexpectedly.

### Scenarios to validate

| Failure Mode | Expected Recovery | Target |
|-------------|-------------------|--------|
| Primary pod deleted | New primary elected | < 30 seconds |
| Persistent volume deleted | Pod reschedules, initial sync | < 10 minutes |
| Network partition (minority isolation) | Primary steps down if isolated | < 15 seconds |
| Node drain (rolling maintenance) | Graceful stepdown, PDB respected | Zero data loss |
| OOMKill on mongod container | Pod restarts, rejoins RS | < 60 seconds |

### Approaches evaluated

1. **Custom bash scripts** - Targeted scripts for each failure scenario using `kubectl delete`, `kubectl exec`, and `iptables`/`tc` for network simulation
2. **Litmus Chaos** - Full chaos engineering framework with ChaosEngine, ChaosExperiment CRDs, and a web dashboard
3. **Chaos Mesh** - CNCF project with similar CRD-based approach, built-in network/IO/stress scenarios

## Decision

We chose **custom bash scripts** as the primary chaos testing mechanism, with optional Litmus integration for extended scenarios.

### Key reasons

1. **Simplicity** - Each chaos script is a self-contained, readable bash file that platform engineers can understand, modify, and debug without learning a framework
2. **CI integration** - Scripts run directly in GitHub Actions without requiring a chaos operator deployment in the CI cluster
3. **Targeted validation** - Scripts include built-in recovery validation (not just failure injection), asserting specific recovery time objectives
4. **Low overhead** - No additional CRDs, controllers, or operators needed in the test cluster
5. **Transparency** - Every action is visible in the script output, making incident post-mortems straightforward

### Trade-offs accepted

- **No scheduler/dashboard** - Chaos runs are triggered manually or via CI, not through a web UI
- **Limited blast radius control** - Scripts directly execute kubectl commands without safety nets like abort conditions
- **No pre-built experiments** - Each scenario must be scripted from scratch (vs Litmus/Chaos Mesh library)

## Consequences

### What becomes easier

- Running chaos tests in CI without additional infrastructure
- Understanding exactly what each chaos test does (readable bash)
- Modifying scenarios for specific edge cases
- Integrating chaos results into existing CI test reports

### What becomes harder

- Building complex multi-failure scenarios (cascading failures)
- Scheduling recurring chaos experiments in production
- Correlating chaos events with observability data automatically

### What we gain

- Validated recovery times for the three most critical failure modes
- Confidence that PDB enforcement and RS elections work as expected
- Scripts that double as runbook validation (matching runbook-failover.md procedures)
