# Runbook: MongoDB Scaling Operations

> **Owner:** Platform Engineering Team
> **Last updated:** 2026-03-11
> **Severity:** P2 - Operational change

---

## Table of Contents

1. [When to Use](#-when-to-use)
2. [Prerequisites](#-prerequisites)
3. [Procedure A - Vertical Scaling (Resize)](#-procedure-a---vertical-scaling-resize)
4. [Procedure B - Horizontal Scaling (Add Members)](#-procedure-b---horizontal-scaling-add-members)
5. [Procedure C - Storage Expansion](#-procedure-c---storage-expansion)
6. [Procedure D - T-Shirt Size Upgrade (Self-Service)](#-procedure-d---t-shirt-size-upgrade-self-service)
7. [Validation](#-validation)
8. [Rollback](#-rollback)
9. [Troubleshooting](#-troubleshooting)

---

## When to Use

| Trigger | Procedure |
|---------|-----------|
| Alert: `MongoDBHighCPUUsage` (> 80% sustained) | A (vertical scaling) |
| Alert: `MongoDBHighMemoryUsage` (> 85% sustained) | A (vertical scaling) |
| Alert: `MongoDBHighReplicationLag` (> 10s sustained) | A or B |
| Alert: `MongoDBStorageNearFull` (> 80% used) | C (storage expansion) |
| Planned capacity increase for traffic growth | D (t-shirt upgrade) |
| New read-heavy workload requiring read scaling | B (add secondaries) |
| Performance degradation during peak hours | A then B if insufficient |

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

### Pre-scaling Checklist

- [ ] Take a backup before any scaling operation (see runbook-backup-restore.md)
- [ ] Verify current replication lag is < 5 seconds
- [ ] Confirm available node resources (CPU, memory) for the target size
- [ ] Notify application teams of potential brief disruption during rolling restart

---

## Procedure A - Vertical Scaling (Resize)

**Estimated duration:** 10-20 minutes (rolling restart)

> The Percona Operator performs a rolling restart when resource limits change. One pod restarts at a time, maintaining availability.

### Step 1: Check current resource allocation

```bash
kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replsets[0].resources}' | jq .
```

### Step 2: Determine target resources

| Current | Target | CPU req/lim | Memory req/lim |
|---------|--------|-------------|----------------|
| S | M | 1 / 2 | 2Gi / 4Gi |
| M | L | 2 / 4 | 4Gi / 8Gi |
| Custom | Custom | As needed | As needed |

### Step 3: Patch the PSMDB CR

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "resources": {
        "requests": {
          "cpu": "2",
          "memory": "4Gi"
        },
        "limits": {
          "cpu": "4",
          "memory": "8Gi"
        }
      }
    }]
  }
}'
```

### Step 4: Update WiredTiger cache size

The WiredTiger cache should be approximately 50% of the memory limit.

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "configuration": "operationProfiling:\n  mode: slowOp\n  slowOpThresholdMs: 100\nstorage:\n  wiredTiger:\n    engineConfig:\n      cacheSizeGB: 2.0\n"
    }]
  }
}'
```

### Step 5: Monitor rolling restart

```bash
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -w
```

Wait for all pods to reach `Running` and `Ready` state.

### Step 6: Validate (see Validation section)

---

## Procedure B - Horizontal Scaling (Add Members)

**Estimated duration:** 15-30 minutes (initial sync of new member)

> Adding members to a replica set increases read capacity and fault tolerance. New members perform an initial sync from the primary.

### Step 1: Check current replica set size

```bash
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "rs.status().members.length"
```

### Step 2: Determine target size

| Current | Target | Notes |
|---------|--------|-------|
| 3 | 5 | Increases fault tolerance (survives 2 failures) |
| 3 | 4 | Not recommended (even number can cause tie elections) |
| 5 | 7 | Maximum recommended for most workloads |

> **Important:** Always use an odd number of voting members.

### Step 3: Patch replica set size

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "size": 5
    }]
  }
}'
```

### Step 4: Wait for new members to sync

```bash
# Watch for new pods
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -w

# Monitor initial sync progress
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    rs.status().members.forEach(m => {
      print(m.name + ' | ' + m.stateStr + ' | health: ' + m.health);
    });
  "
```

### Step 5: Validate (see Validation section)

---

## Procedure C - Storage Expansion

**Estimated duration:** 5-15 minutes (no restart required)

> **Requirement:** The StorageClass must support volume expansion (`allowVolumeExpansion: true`). The `local-path` provisioner in kind does NOT support online expansion. Use `standard` or cloud-provider StorageClasses in production.

### Step 1: Check current storage allocation

```bash
kubectl get pvc -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -o custom-columns='NAME:.metadata.name,SIZE:.spec.resources.requests.storage,STATUS:.status.phase'
```

### Step 2: Verify StorageClass supports expansion

```bash
kubectl get storageclass \
  -o custom-columns='NAME:.metadata.name,EXPAND:.allowVolumeExpansion'
```

### Step 3: Patch storage size in PSMDB CR

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "volumeSpec": {
        "persistentVolumeClaim": {
          "resources": {
            "requests": {
              "storage": "50Gi"
            }
          }
        }
      }
    }]
  }
}'
```

### Step 4: Verify PVC expansion

```bash
# Watch PVC resize
kubectl get pvc -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -w

# Verify filesystem size inside the pod
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  df -h /data/db
```

---

## Procedure D - T-Shirt Size Upgrade (Self-Service)

**Estimated duration:** 15-30 minutes

For teams using the Crossplane self-service layer, scaling is done by updating the claim.

### Step 1: Update the MongoDBInstanceClaim

```bash
kubectl patch mongodbinstanceclaim <CLAIM_NAME> -n <TEAM_NAMESPACE> --type merge -p '{
  "spec": {
    "parameters": {
      "size": "L"
    }
  }
}'
```

### Step 2: Crossplane applies the changes

The Composition automatically maps the new size to updated:
- CPU/memory requests and limits
- Storage allocation
- WiredTiger cache size
- ResourceQuota and LimitRange values

### Step 3: Monitor via Crossplane

```bash
# Check composite resource status
kubectl get mongodbinstance -o wide

# Check claim status
kubectl get mongodbinstanceclaim <CLAIM_NAME> -n <TEAM_NAMESPACE> -o yaml
```

### Step 4: Validate (see Validation section)

---

## Validation

Run after every scaling operation.

```bash
# 1. All pods running and ready
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -o custom-columns='POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready'

# 2. Replica set health
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    rs.status().members.forEach(m => {
      print(m.name + ' | ' + m.stateStr + ' | health: ' + m.health);
    });
  "

# 3. Resource allocation matches target
kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}: cpu={.spec.containers[0].resources.limits.cpu}, mem={.spec.containers[0].resources.limits.memory}{"\n"}{end}'

# 4. Replication lag is acceptable (< 5s)
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    status.members.filter(m => m.stateStr === 'SECONDARY').forEach(m => {
      const lag = (primary.optimeDate - m.optimeDate) / 1000;
      print(m.name + ' lag: ' + lag + 's');
    });
  "

# 5. Write with majority concern
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    try {
      db.getSiblingDB('test').scale_check.insertOne(
        { ts: new Date(), type: 'post_scale_validation' },
        { writeConcern: { w: 'majority', wtimeout: 5000 } }
      );
      print('Majority write: PASS');
      db.getSiblingDB('test').scale_check.drop();
    } catch(e) {
      print('Majority write: FAIL - ' + e.message);
    }
  "
```

---

## Rollback

### Vertical scaling rollback

Revert the PSMDB CR patch to the previous resource values. The operator will perform another rolling restart.

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "resources": {
        "requests": { "cpu": "<PREVIOUS_CPU>", "memory": "<PREVIOUS_MEM>" },
        "limits": { "cpu": "<PREVIOUS_CPU_LIMIT>", "memory": "<PREVIOUS_MEM_LIMIT>" }
      }
    }]
  }
}'
```

### Horizontal scaling rollback

Reduce the replica set size. The operator will gracefully remove the extra members.

```bash
kubectl patch psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" --type merge -p '{
  "spec": {
    "replsets": [{
      "name": "rs0",
      "size": 3
    }]
  }
}'
```

### Storage rollback

> **Warning:** PVC storage expansion is **not reversible**. You cannot shrink a PVC. If you need to reduce storage, you must create a new instance with smaller storage and migrate the data.

---

## Troubleshooting

### Pod stuck in Pending after vertical scaling

The node may not have enough resources for the new limits.

```bash
kubectl describe pod "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" | grep -A5 "Events"
kubectl describe nodes | grep -A5 "Allocated resources"
```

**Solution:** Scale the Kubernetes nodes or reduce the resource request.

### New member stuck in STARTUP2

Initial sync is taking longer than expected due to large dataset.

```bash
# Check sync progress
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const status = rs.status();
    status.members.filter(m => m.stateStr === 'STARTUP2').forEach(m => {
      print(m.name + ': sync progress - check mongod logs');
    });
  "

# Check mongod logs on the syncing member
kubectl logs "${CLUSTER_NAME}-${RS_NAME}-3" -n "${NAMESPACE}" -c mongod --tail=50
```

**Solution:** Wait for initial sync to complete. For large datasets (> 100GB), this can take hours.

### WiredTiger cache pressure after scaling

If memory was increased but WiredTiger cache was not updated, the extra memory is unused by the engine.

```bash
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const stats = db.serverStatus().wiredTiger.cache;
    print('Cache size: ' + Math.round(stats['maximum bytes configured'] / 1073741824 * 100) / 100 + ' GB');
    print('Dirty pages: ' + Math.round(stats['tracked dirty bytes in the cache'] / 1048576) + ' MB');
  "
```

**Solution:** Update the WiredTiger `cacheSizeGB` in the PSMDB CR configuration (Step 4 of Procedure A).
