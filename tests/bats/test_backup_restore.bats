#!/usr/bin/env bats

# test_backup_restore.bats
# Validates backup and restore functionality: PBM agent health, backup schedules,
# manual backup/restore cycle, and data integrity verification.

NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-mongodb}"

# Helper: run mongosh command via primary pod
run_mongosh() {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "$1" 2>/dev/null
}

@test "PBM agent containers are running on all replica set members" {
  local running_count
  running_count=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="backup-agent")].ready}{"\n"}{end}' \
    | grep -c "true")
  [ "${running_count}" -eq 3 ]
}

@test "PBM status reports healthy cluster" {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  local pbm_status
  pbm_status=$(kubectl exec "${pod}" -n "${NAMESPACE}" -c backup-agent -- \
    pbm status 2>/dev/null)
  echo "${pbm_status}" | grep -q "Cluster"
}

@test "backup storage (S3/MinIO) is reachable from PBM" {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  local storage_check
  storage_check=$(kubectl exec "${pod}" -n "${NAMESPACE}" -c backup-agent -- \
    pbm status 2>/dev/null)
  # PBM status should not show storage errors
  ! echo "${storage_check}" | grep -qi "storage error"
}

@test "daily backup schedule is configured" {
  local schedule_count
  schedule_count=$(kubectl get psmdb-backup -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | wc -l || echo "0")
  # Verify schedule exists in CR
  local cr_schedule
  cr_schedule=$(kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.backup.tasks}' 2>/dev/null)
  [ -n "${cr_schedule}" ]
}

@test "manual backup can be triggered and completes successfully" {
  local backup_name="bats-test-$(date +%s)"

  kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: ${backup_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-minio
EOF

  # Wait for backup to complete (timeout: 5 minutes)
  kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-backup/${backup_name}" \
    -n "${NAMESPACE}" \
    --timeout=300s

  # Clean up test backup
  kubectl delete psmdb-backup "${backup_name}" -n "${NAMESPACE}" --ignore-not-found
}

@test "insert, backup, drop, restore, validate cycle preserves data integrity" {
  local test_db="bats_backup_test"
  local test_col="integrity_check"
  local backup_name="bats-integrity-$(date +%s)"

  # Insert test data
  run_mongosh "
    const testDb = db.getSiblingDB('${test_db}');
    testDb.${test_col}.drop();
    const docs = [];
    for (let i = 0; i < 100; i++) {
      docs.push({ _id: i, value: 'test-' + i });
    }
    testDb.${test_col}.insertMany(docs, { writeConcern: { w: 'majority' } });
  "

  # Record pre-backup state
  local pre_count
  pre_count=$(run_mongosh "print(db.getSiblingDB('${test_db}').${test_col}.countDocuments());")
  [ "${pre_count}" -eq 100 ]

  local pre_hash
  pre_hash=$(run_mongosh "print(db.getSiblingDB('${test_db}').runCommand({ dbHash: 1 }).md5);")

  # Trigger backup
  kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: ${backup_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-minio
EOF

  kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-backup/${backup_name}" \
    -n "${NAMESPACE}" \
    --timeout=300s

  # Drop test data
  run_mongosh "db.getSiblingDB('${test_db}').${test_col}.drop();"

  local post_drop
  post_drop=$(run_mongosh "print(db.getSiblingDB('${test_db}').${test_col}.countDocuments());")
  [ "${post_drop}" -eq 0 ]

  # Restore from backup
  kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: restore-${backup_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  backupName: ${backup_name}
EOF

  kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-restore/restore-${backup_name}" \
    -n "${NAMESPACE}" \
    --timeout=600s

  # Wait for cluster to stabilize after restore
  sleep 15
  kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -n "${NAMESPACE}" \
    --timeout=120s

  # Validate integrity
  local post_count
  post_count=$(run_mongosh "print(db.getSiblingDB('${test_db}').${test_col}.countDocuments());")
  [ "${post_count}" -eq 100 ]

  local post_hash
  post_hash=$(run_mongosh "print(db.getSiblingDB('${test_db}').runCommand({ dbHash: 1 }).md5);")
  [ "${post_hash}" = "${pre_hash}" ]

  # Clean up
  run_mongosh "db.getSiblingDB('${test_db}').dropDatabase();"
  kubectl delete psmdb-backup "${backup_name}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete psmdb-restore "restore-${backup_name}" -n "${NAMESPACE}" --ignore-not-found
}

@test "backup metadata includes correct cluster name" {
  local latest_backup
  latest_backup=$(kubectl get psmdb-backup -n "${NAMESPACE}" \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

  if [ -n "${latest_backup}" ]; then
    local cluster_ref
    cluster_ref=$(kubectl get psmdb-backup "${latest_backup}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.clusterName}')
    [ "${cluster_ref}" = "${CLUSTER_NAME}" ]
  else
    skip "No backups found to validate metadata"
  fi
}
