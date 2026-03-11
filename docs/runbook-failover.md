# Runbook: MongoDB Primary Failover

> **Owner:** Platform Engineering Team
> **Last updated:** 2026-03-11
> **Severity:** P1 - Service availability impact

---

## Table of Contents

1. [When to Use](#-when-to-use)
2. [Prerequisites](#-prerequisites)
3. [Understanding Failover](#-understanding-failover)
4. [Procedure A - Automatic Failover (Monitoring)](#-procedure-a---automatic-failover-monitoring)
5. [Procedure B - Manual Stepdown (Planned Maintenance)](#-procedure-b---manual-stepdown-planned-maintenance)
6. [Procedure C - Emergency Recovery (Primary Pod Lost)](#-procedure-c---emergency-recovery-primary-pod-lost)
7. [Validation](#-validation)
8. [Rollback](#-rollback)
9. [Troubleshooting](#-troubleshooting)
10. [Post-Incident Review](#-post-incident-review)

---

## When to Use

| Trigger | Procedure |
|---------|-----------|
| Alert: `MongoDBPrimaryNotFound` fired | A (monitor automatic failover) |
| Planned node maintenance or rolling update | B (graceful stepdown) |
| Primary pod OOMKilled or CrashLoopBackOff | C (emergency recovery) |
| Primary node drained by cluster autoscaler | A (monitor automatic failover) |
| Network partition suspected | Troubleshooting section |
| DR drill - simulate primary failure | C (then validate) |

---

## Prerequisites

### Required Access

- `kubectl` configured with cluster admin or namespace-scoped RBAC
- MongoDB credentials (clusterAdmin role)

### Required Tools

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| `kubectl` | v1.28+ | Kubernetes API interaction |
| `mongosh` | v2.0+ | MongoDB shell |
| `jq` | v1.6+ | JSON parsing |

### Environment Variables

```bash
export NAMESPACE="mongodb"
export CLUSTER_NAME="mongodb-rs"
export RS_NAME="rs0"
```

---

## Understanding Failover

MongoDB replica sets use the Raft-based election protocol to automatically elect a new primary when the current primary becomes unavailable.

### Expected behavior

| Event | Expected Outcome | Target Time |
|-------|-------------------|-------------|
| Primary pod deleted | New primary elected | < 30 seconds |
| Primary node drained | Graceful stepdown, new election | < 15 seconds |
| Network partition (minority) | Primary steps down if isolated | < 10 seconds |
| Manual `rs.stepDown()` | Immediate election | < 10 seconds |

### Election priority

The Percona Operator configures equal priority across all replica set members by default. The member with the most recent oplog entry and highest priority wins the election.

---

## Procedure A - Automatic Failover (Monitoring)

**Estimated duration:** 2-5 minutes (monitoring only)

Use this when MongoDB's automatic failover is expected to handle the situation.

### Step 1: Confirm the alert

```bash
# Check current replica set status
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    rs.status().members.forEach(m => {
      print(m.name + ' | state: ' + m.stateStr + ' | health: ' + m.health);
    });
  " 2>/dev/null || echo "Pod 0 unreachable, trying pod 1..."

# If pod 0 is unreachable, try another member
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-1" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    rs.status().members.forEach(m => {
      print(m.name + ' | state: ' + m.stateStr + ' | health: ' + m.health);
    });
  "
```

### Step 2: Verify new primary was elected

```bash
# Wait up to 60 seconds for election
for i in $(seq 1 12); do
  PRIMARY=$(kubectl exec "${CLUSTER_NAME}-${RS_NAME}-1" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "rs.status().members.find(m => m.stateStr === 'PRIMARY')?.name" 2>/dev/null)
  if [ -n "${PRIMARY}" ] && [ "${PRIMARY}" != "" ]; then
    echo "Primary elected: ${PRIMARY}"
    break
  fi
  echo "Waiting for election... (attempt ${i}/12)"
  sleep 5
done
```

### Step 3: Verify write availability

```bash
# Find the new primary pod
PRIMARY_POD=$(kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -o json | jq -r '.items[] | select(.metadata.labels["app.kubernetes.io/component"]=="mongod") | .metadata.name' | head -1)

kubectl exec "${PRIMARY_POD}" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    try {
      db.getSiblingDB('test').failover_check.insertOne(
        { ts: new Date(), check: 'post_failover' },
        { writeConcern: { w: 'majority', wtimeout: 5000 } }
      );
      print('Write test: PASS');
      db.getSiblingDB('test').failover_check.drop();
    } catch(e) {
      print('Write test: FAIL - ' + e.message);
    }
  "
```

### Step 4: Proceed to Validation section

---

## Procedure B - Manual Stepdown (Planned Maintenance)

**Estimated duration:** 5-10 minutes

### Step 1: Identify current primary

```bash
PRIMARY_POD=$(kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const primary = rs.status().members.find(m => m.stateStr === 'PRIMARY');
    print(primary.name);
  ")
echo "Current primary: ${PRIMARY_POD}"
```

### Step 2: Check replication lag

```bash
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    status.members.filter(m => m.stateStr === 'SECONDARY').forEach(m => {
      const lag = (primary.optimeDate - m.optimeDate) / 1000;
      print(m.name + ' lag: ' + lag + 's');
    });
  "
```

> **Important:** Do NOT proceed if replication lag exceeds 10 seconds. Wait for secondaries to catch up.

### Step 3: Notify application teams

Inform all consumers that a brief (< 15 second) write interruption will occur.

### Step 4: Execute graceful stepdown

```bash
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    try {
      rs.stepDown(60, 10);
      print('Stepdown initiated successfully');
    } catch(e) {
      print('Stepdown result: ' + e.message);
    }
  "
```

Parameters:
- `60` - The former primary is ineligible for re-election for 60 seconds
- `10` - Wait up to 10 seconds for a secondary to catch up before stepping down

### Step 5: Verify new primary

```bash
sleep 10

kubectl exec "${CLUSTER_NAME}-${RS_NAME}-1" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const primary = rs.status().members.find(m => m.stateStr === 'PRIMARY');
    print('New primary: ' + primary.name);
  "
```

### Step 6: Proceed with maintenance

You can now safely perform maintenance on the former primary node.

---

## Procedure C - Emergency Recovery (Primary Pod Lost)

**Estimated duration:** 5-15 minutes

### Step 1: Assess the situation

```bash
# Check pod status
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide

# Check events for failure reasons
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
```

### Step 2: Check if automatic failover occurred

```bash
# Try any available pod
for i in 0 1 2; do
  echo "--- Trying pod ${i} ---"
  kubectl exec "${CLUSTER_NAME}-${RS_NAME}-${i}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "
      rs.status().members.forEach(m => {
        print(m.name + ' | ' + m.stateStr + ' | health: ' + m.health);
      });
    " 2>/dev/null && break
done
```

### Step 3: If no primary exists (all members SECONDARY)

This indicates an election failure, typically due to loss of majority.

```bash
# Check how many members are reachable
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-1" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const status = rs.status();
    const healthy = status.members.filter(m => m.health === 1).length;
    print('Healthy members: ' + healthy + '/' + status.members.length);
    print('Majority needed: ' + Math.floor(status.members.length / 2 + 1));
  "
```

If majority is lost (e.g., 2 of 3 members down), you need to reconfigure the replica set:

> **Warning:** Only use this as a last resort. This can cause data loss if the surviving member is behind.

```bash
# Force reconfiguration (DANGEROUS - only if majority is permanently lost)
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-<SURVIVING_MEMBER>" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const cfg = rs.conf();
    cfg.members = cfg.members.filter(m => m.host.includes('<SURVIVING_MEMBER>'));
    cfg.version++;
    rs.reconfig(cfg, { force: true });
  "
```

### Step 4: Ensure failed pod recovers

```bash
# Check if the pod is being rescheduled
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -w

# If stuck in Pending, check PVC and node capacity
kubectl describe pod "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" | tail -30
```

### Step 5: Verify recovered member rejoins

```bash
# Wait for all members to be healthy
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=300s

# Verify all members are in the replica set
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    rs.status().members.forEach(m => {
      print(m.name + ' | ' + m.stateStr + ' | health: ' + m.health);
    });
  "
```

---

## Validation

Run these checks after any failover event.

```bash
# 1. Replica set has exactly one PRIMARY
PRIMARY_COUNT=$(kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    print(rs.status().members.filter(m => m.stateStr === 'PRIMARY').length);
  ")
echo "Primary count: ${PRIMARY_COUNT} (expected: 1)"

# 2. All members are healthy (health: 1)
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const unhealthy = rs.status().members.filter(m => m.health !== 1);
    print('Unhealthy members: ' + unhealthy.length + ' (expected: 0)');
    unhealthy.forEach(m => print('  - ' + m.name + ': ' + m.stateStr));
  "

# 3. Replication lag is within acceptable range (< 10s)
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    status.members.filter(m => m.stateStr === 'SECONDARY').forEach(m => {
      const lag = (primary.optimeDate - m.optimeDate) / 1000;
      const verdict = lag < 10 ? 'PASS' : 'FAIL';
      print(m.name + ' lag: ' + lag + 's [' + verdict + ']');
    });
  "

# 4. Write with majority concern succeeds
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    try {
      db.getSiblingDB('test').health_check.insertOne(
        { ts: new Date(), type: 'failover_validation' },
        { writeConcern: { w: 'majority', wtimeout: 5000 } }
      );
      print('Majority write: PASS');
      db.getSiblingDB('test').health_check.drop();
    } catch(e) {
      print('Majority write: FAIL - ' + e.message);
    }
  "

# 5. PBM agent is healthy on all members
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm status 2>/dev/null | head -10
```

---

## Rollback

Failover operations are generally not "rolled back" - you can, however, force a specific member to become primary:

```bash
# Set higher priority on the preferred member
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const cfg = rs.conf();
    // Set member 0 to higher priority
    cfg.members[0].priority = 2;
    cfg.members[1].priority = 1;
    cfg.members[2].priority = 1;
    rs.reconfig(cfg);
    print('Priority reconfigured. Member 0 will become primary.');
  "
```

> **Note:** Reset priorities to equal values after maintenance to avoid creating a single point of preference.

---

## Troubleshooting

### No primary elected after 60 seconds

**Possible causes:**
1. Majority of members unreachable (check network, node status)
2. All members have the same priority and are in a tie-breaking loop
3. Oplog size exceeded - members cannot sync

```bash
# Check member connectivity
for i in 0 1 2; do
  echo "Pod ${i}:"
  kubectl exec "${CLUSTER_NAME}-${RS_NAME}-${i}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "rs.status().ok" 2>/dev/null || echo "UNREACHABLE"
done
```

### Member stuck in RECOVERING state

```bash
# Check oplog window
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const oplog = db.getSiblingDB('local').oplog.rs;
    const first = oplog.find().sort({ts: 1}).limit(1).next();
    const last = oplog.find().sort({ts: -1}).limit(1).next();
    print('Oplog window: ' + (last.ts.t - first.ts.t) + ' seconds');
  "
```

If the recovering member fell outside the oplog window, it needs an initial sync:

```bash
# Delete the member's data and let it resync (last resort)
kubectl delete pvc "mongod-data-${CLUSTER_NAME}-${RS_NAME}-<MEMBER_ID>" -n "${NAMESPACE}"
kubectl delete pod "${CLUSTER_NAME}-${RS_NAME}-<MEMBER_ID>" -n "${NAMESPACE}"
```

### Split-brain scenario (multiple primaries)

This should never happen with MongoDB's election protocol, but if detected:

1. Immediately identify which primary has the most recent writes
2. Step down the stale primary: `rs.stepDown(300)`
3. Investigate network partition cause
4. File an incident report

---

## Post-Incident Review

After any unplanned failover, document:

| Item | Details |
|------|---------|
| **Incident time** | When the failover was detected |
| **Root cause** | Why the primary became unavailable |
| **Failover duration** | Time between primary loss and new primary election |
| **Data impact** | Any unacknowledged writes lost |
| **Application impact** | Duration and scope of service disruption |
| **Action items** | Preventive measures to avoid recurrence |

File the post-incident review in your incident management system and link to this runbook.
