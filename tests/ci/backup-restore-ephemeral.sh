#!/usr/bin/env bash
set -euo pipefail

# backup-restore-ephemeral.sh - CI backup/restore validation cycle
#
# Usage:
#   ./tests/ci/backup-restore-ephemeral.sh [OPTIONS]
#
# Options:
#   --help        Show this help message
#   --dry-run     Print commands without executing
#
# This script performs a full backup/restore validation cycle:
#   1. Insert test data with known checksums
#   2. Trigger a manual backup
#   3. Drop the test data
#   4. Restore from the backup
#   5. Validate data integrity (dbHash, counts)
#   6. Clean up ephemeral resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
TEST_DB="backup_test"
TEST_COLLECTION="validation_data"
DRY_RUN=false

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

run() {
  if [ "${DRY_RUN}" = true ]; then
    log "[DRY-RUN] $*"
  else
    "$@"
  fi
}

usage() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '!/usr/bin' | sed 's/^# \?//'
  exit 0
}

run_mongosh() {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "$1" 2>/dev/null
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Step 1: Insert test data
# ──────────────────────────────────────────────

insert_test_data() {
  log "Step 1: Inserting test data..."
  run_mongosh "
    const db = db.getSiblingDB('${TEST_DB}');
    db.${TEST_COLLECTION}.drop();

    const docs = [];
    for (let i = 0; i < 1000; i++) {
      docs.push({
        _id: i,
        data: 'test-document-' + i,
        checksum: MD5('test-document-' + i),
        created: new Date()
      });
    }
    db.${TEST_COLLECTION}.insertMany(docs, { writeConcern: { w: 'majority' } });
    print('Inserted ' + db.${TEST_COLLECTION}.countDocuments() + ' documents');
  "
}

# ──────────────────────────────────────────────
# Step 2: Record pre-backup state
# ──────────────────────────────────────────────

record_pre_backup_state() {
  log "Step 2: Recording pre-backup state..."
  PRE_COUNT=$(run_mongosh "
    print(db.getSiblingDB('${TEST_DB}').${TEST_COLLECTION}.countDocuments());
  ")
  PRE_HASH=$(run_mongosh "
    print(db.getSiblingDB('${TEST_DB}').runCommand({ dbHash: 1 }).md5);
  ")
  log "Pre-backup state: count=${PRE_COUNT}, hash=${PRE_HASH}"
}

# ──────────────────────────────────────────────
# Step 3: Trigger manual backup
# ──────────────────────────────────────────────

trigger_backup() {
  log "Step 3: Triggering manual backup..."
  local backup_name="ci-backup-$(date +%Y%m%d-%H%M%S)"

  run kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: ${backup_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-minio
EOF

  log "Waiting for backup '${backup_name}' to complete..."
  run kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-backup/${backup_name}" \
    -n "${NAMESPACE}" \
    --timeout=300s

  BACKUP_NAME="${backup_name}"
  log "Backup completed: ${BACKUP_NAME}"
}

# ──────────────────────────────────────────────
# Step 4: Drop test data
# ──────────────────────────────────────────────

drop_test_data() {
  log "Step 4: Dropping test data to simulate data loss..."
  run_mongosh "
    db.getSiblingDB('${TEST_DB}').${TEST_COLLECTION}.drop();
    print('Test collection dropped');
  "

  # Verify data is gone
  local post_drop_count
  post_drop_count=$(run_mongosh "
    print(db.getSiblingDB('${TEST_DB}').${TEST_COLLECTION}.countDocuments());
  ")
  log "Post-drop count: ${post_drop_count} (should be 0)"
}

# ──────────────────────────────────────────────
# Step 5: Restore from backup
# ──────────────────────────────────────────────

restore_from_backup() {
  log "Step 5: Restoring from backup '${BACKUP_NAME}'..."
  run bash "${PROJECT_ROOT}/backup/restore/restore-full.sh" \
    --backup-name "${BACKUP_NAME}" \
    --namespace "${NAMESPACE}" \
    --cluster "${CLUSTER_NAME}"
}

# ──────────────────────────────────────────────
# Step 6: Validate integrity
# ──────────────────────────────────────────────

validate_integrity() {
  log "Step 6: Validating data integrity..."

  local post_count
  post_count=$(run_mongosh "
    print(db.getSiblingDB('${TEST_DB}').${TEST_COLLECTION}.countDocuments());
  ")

  local post_hash
  post_hash=$(run_mongosh "
    print(db.getSiblingDB('${TEST_DB}').runCommand({ dbHash: 1 }).md5);
  ")

  log "Post-restore state: count=${post_count}, hash=${post_hash}"

  local errors=0

  if [ "${post_count}" = "${PRE_COUNT}" ]; then
    log "PASS: Document count matches (${post_count})"
  else
    log "FAIL: Document count mismatch (expected: ${PRE_COUNT}, got: ${post_count})"
    errors=$((errors + 1))
  fi

  if [ "${post_hash}" = "${PRE_HASH}" ]; then
    log "PASS: dbHash matches"
  else
    log "FAIL: dbHash mismatch (expected: ${PRE_HASH}, got: ${post_hash})"
    errors=$((errors + 1))
  fi

  # Run full validation suite
  run bash "${PROJECT_ROOT}/backup/restore/validate-integrity.sh" \
    --namespace "${NAMESPACE}" \
    --cluster "${CLUSTER_NAME}"

  if [ "${errors}" -gt 0 ]; then
    log "ERROR: ${errors} integrity check(s) failed"
    exit 1
  fi
}

# ──────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────

cleanup() {
  log "Cleaning up test resources..."
  run_mongosh "db.getSiblingDB('${TEST_DB}').dropDatabase();" || true
  if [ -n "${BACKUP_NAME:-}" ]; then
    run kubectl delete psmdb-backup "${BACKUP_NAME}" -n "${NAMESPACE}" --ignore-not-found || true
  fi
  log "Cleanup complete."
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "=== CI Backup/Restore Validation Cycle ==="

  # Ensure cleanup runs on exit
  trap cleanup EXIT

  insert_test_data
  record_pre_backup_state
  trigger_backup
  drop_test_data
  restore_from_backup
  validate_integrity

  log "=== Backup/Restore validation PASSED ==="
}

main
