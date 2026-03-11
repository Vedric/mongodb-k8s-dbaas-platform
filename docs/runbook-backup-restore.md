# Runbook: Backup and Restore Procedures

> **Owner:** Platform Engineering Team
> **Last updated:** 2026-03-11
> **Severity:** P1 - Critical data operations

---

## Table of Contents

1. [When to Use](#-when-to-use)
2. [Prerequisites](#-prerequisites)
3. [Procedure A - Full Snapshot Restore](#-procedure-a---full-snapshot-restore)
4. [Procedure B - Point-in-Time Recovery (PITR)](#-procedure-b---point-in-time-recovery-pitr)
5. [Procedure C - Manual On-Demand Backup](#-procedure-c---manual-on-demand-backup)
6. [Validation](#-validation)
7. [Rollback](#-rollback)
8. [Troubleshooting](#-troubleshooting)
9. [SLA Targets](#-sla-targets)

---

## When to Use

| Trigger | Procedure |
|---------|-----------|
| Data corruption detected | Full Snapshot Restore (A) |
| Accidental data deletion (known timestamp) | Point-in-Time Recovery (B) |
| Pre-migration safety backup | Manual On-Demand Backup (C) |
| Alert: `MongoDBBackupFailed` fired | Troubleshooting section |
| Compliance audit - backup verification | Validation section |
| Disaster recovery drill (scheduled quarterly) | Full cycle: C then A |

---

## Prerequisites

### Required Access

- `kubectl` configured with cluster admin or namespace-scoped RBAC for `mongodb` namespace
- Access to MinIO console or S3 bucket (backup storage)
- MongoDB credentials (clusterAdmin role) via Vault or Kubernetes Secret

### Required Tools

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| `kubectl` | v1.28+ | Kubernetes API interaction |
| `mongosh` | v2.0+ | MongoDB shell (available inside pods) |
| `jq` | v1.6+ | JSON parsing |
| `pbm` | v2.4+ | Percona Backup for MongoDB CLI (inside backup-agent container) |

### Environment Variables

```bash
export NAMESPACE="mongodb"
export CLUSTER_NAME="mongodb-rs"
export RS_NAME="rs0"
```

---

## Procedure A - Full Snapshot Restore

**Estimated duration:** 10-30 minutes (depends on data size)

### Step 1: Identify the backup to restore

```bash
# List all available backups
kubectl get psmdb-backup -n "${NAMESPACE}" -o wide

# Or via PBM CLI inside the backup-agent container
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm list
```

Select the backup name closest to (but before) the incident timestamp.

### Step 2: Verify backup integrity

```bash
# Check backup status is "ready"
kubectl get psmdb-backup <BACKUP_NAME> -n "${NAMESPACE}" \
  -o jsonpath='{.status.state}'
```

Expected output: `ready`

### Step 3: Notify stakeholders

> **Important:** A full restore will make the cluster temporarily unavailable.
> Notify all application teams consuming this MongoDB instance.

### Step 4: Execute the restore

```bash
# Using the restore script
./backup/restore/restore-full.sh \
  --backup-name <BACKUP_NAME> \
  --namespace "${NAMESPACE}" \
  --cluster "${CLUSTER_NAME}"
```

Or manually via kubectl:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: restore-$(date +%Y%m%d-%H%M%S)
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  backupName: <BACKUP_NAME>
EOF
```

### Step 5: Monitor restore progress

```bash
# Watch restore status
kubectl get psmdb-restore -n "${NAMESPACE}" -w

# Check operator logs for detailed progress
kubectl logs -n mongodb-operator \
  -l app.kubernetes.io/name=percona-server-mongodb-operator \
  --tail=100 -f
```

### Step 6: Wait for cluster stabilization

```bash
# Wait for all pods to become ready
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=300s
```

### Step 7: Validate (see Validation section below)

---

## Procedure B - Point-in-Time Recovery (PITR)

**Estimated duration:** 15-45 minutes

> **Requirement:** Continuous oplog backup must have been running before the target timestamp.

### Step 1: Determine the target recovery timestamp

Identify the exact moment just before the incident. Use ISO 8601 format.

```bash
# Example: recover to March 11, 2026 at 14:30:00 UTC
TARGET_TIME="2026-03-11T14:30:00Z"
```

### Step 2: Verify oplog coverage

```bash
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm status | grep -A5 "PITR"
```

Confirm the target timestamp falls within the PITR oplog range.

### Step 3: Execute PITR restore

```bash
./backup/restore/restore-pitr.sh \
  --target-time "${TARGET_TIME}" \
  --namespace "${NAMESPACE}" \
  --cluster "${CLUSTER_NAME}"
```

Or manually:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: pitr-restore-$(date +%Y%m%d-%H%M%S)
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  pitr:
    type: date
    date: "${TARGET_TIME}"
EOF
```

### Step 4: Monitor and validate

Follow Steps 5-7 from Procedure A.

---

## Procedure C - Manual On-Demand Backup

**Estimated duration:** 5-15 minutes

### Step 1: Trigger the backup

```bash
BACKUP_NAME="manual-$(date +%Y%m%d-%H%M%S)"

cat <<EOF | kubectl apply -f -
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-minio
EOF
```

### Step 2: Wait for completion

```bash
kubectl wait --for=jsonpath='{.status.state}'=ready \
  "psmdb-backup/${BACKUP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=300s
```

### Step 3: Verify backup

```bash
kubectl get psmdb-backup "${BACKUP_NAME}" -n "${NAMESPACE}" -o wide
```

---

## Validation

Run these checks after every restore operation.

### Automated validation

```bash
./backup/restore/validate-integrity.sh \
  --namespace "${NAMESPACE}" \
  --cluster "${CLUSTER_NAME}"
```

### Manual validation checklist

```bash
# 1. Check replica set status
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' -> ' + m.stateStr))"

# 2. Verify document counts on critical collections
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    db.adminCommand({ listDatabases: 1 }).databases.forEach(d => {
      if (!['admin','local','config'].includes(d.name)) {
        const dbRef = db.getSiblingDB(d.name);
        print(d.name + ':');
        dbRef.getCollectionNames().forEach(c => {
          print('  ' + c + ': ' + dbRef[c].countDocuments() + ' docs');
        });
      }
    });
  "

# 3. Verify indexes are intact
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    db.adminCommand({ listDatabases: 1 }).databases.forEach(d => {
      if (!['admin','local','config'].includes(d.name)) {
        const dbRef = db.getSiblingDB(d.name);
        dbRef.getCollectionNames().forEach(c => {
          const indexes = dbRef[c].getIndexes();
          print(d.name + '.' + c + ': ' + indexes.length + ' indexes');
        });
      }
    });
  "

# 4. Test write operations
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
  mongosh --quiet --eval "
    const result = db.getSiblingDB('test').restore_validation.insertOne(
      { ts: new Date(), check: 'post_restore' },
      { writeConcern: { w: 'majority' } }
    );
    print('Write test: ' + (result.acknowledged ? 'PASS' : 'FAIL'));
    db.getSiblingDB('test').restore_validation.drop();
  "
```

---

## Rollback

If the restore produces unexpected results:

1. **Do NOT panic** - the original backup is still available in MinIO/S3
2. **Take a new backup** of the current (post-restore) state before attempting another restore
3. **Try restoring from a different backup** - select an earlier snapshot
4. **Escalate** if multiple restore attempts fail - engage MongoDB support or Percona support

```bash
# Take emergency backup of current state
EMERGENCY_BACKUP="emergency-$(date +%Y%m%d-%H%M%S)"
cat <<EOF | kubectl apply -f -
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: ${EMERGENCY_BACKUP}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-minio
EOF
```

---

## Troubleshooting

### Backup stuck in "running" state

```bash
# Check PBM logs
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm logs --tail=50

# Check if PBM lock is stale
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm config --list
```

### Restore fails with "storage error"

```bash
# Verify MinIO connectivity
kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c backup-agent -- \
  pbm status

# Check MinIO pods
kubectl get pods -n "${NAMESPACE}" -l app=minio

# Check MinIO credentials
kubectl get secret minio-credentials -n "${NAMESPACE}" -o jsonpath='{.data}' | jq 'keys'
```

### Restore completes but data is missing

1. Verify you selected the correct backup (check timestamp)
2. Run `dbHash` comparison if pre-backup hash is available
3. Check if the missing data was in a database excluded from the backup scope

---

## SLA Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| **RPO** (Recovery Point Objective) | 15 minutes | Continuous oplog backup every 10 minutes |
| **RTO** (Recovery Time Objective) | 30 minutes | Full restore + validation |
| **Backup success rate** | 99.9% | Monitored via `MongoDBBackupFailed` alert |
| **Backup retention** | 7 days (snapshots) | Configured in PBM schedule |
| **DR drill frequency** | Quarterly | Tracked in incident management system |
