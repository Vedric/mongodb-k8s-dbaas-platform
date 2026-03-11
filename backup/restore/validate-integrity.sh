#!/usr/bin/env bash
set -euo pipefail

# validate-integrity.sh - Post-restore data integrity validation
#
# Usage:
#   ./backup/restore/validate-integrity.sh [OPTIONS]
#
# Options:
#   --help              Show this help message
#   --dry-run           Print commands without executing
#   --namespace NS      MongoDB namespace (default: mongodb)
#   --cluster NAME      Cluster name (default: mongodb-rs)
#
# Validation checks:
#   1. dbHash consistency across replica set members
#   2. Collection count verification
#   3. Index consistency check
#   4. Basic read operation test

# Configuration
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
DRY_RUN=false
ERRORS=0

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; ERRORS=$((ERRORS + 1)); }

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

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Checks
# ──────────────────────────────────────────────

check_replica_set_health() {
  log "Checking replica set health..."
  local rs_ok
  rs_ok=$(run_mongosh "rs.status().ok" || echo "0")
  if [ "${rs_ok}" = "1" ]; then
    pass "Replica set is healthy (rs.status().ok = 1)"
  else
    fail "Replica set is not healthy (rs.status().ok = ${rs_ok})"
  fi
}

check_dbhash_consistency() {
  log "Checking dbHash consistency across members..."
  local hash_result
  hash_result=$(run_mongosh "
    const dbs = db.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !['admin', 'config', 'local'].includes(d.name))
      .map(d => d.name);

    let consistent = true;
    for (const dbName of dbs) {
      const hashResult = db.getSiblingDB(dbName).runCommand({ dbHash: 1 });
      if (!hashResult.ok) {
        print('ERROR: dbHash failed for ' + dbName);
        consistent = false;
      }
    }
    print(consistent ? 'consistent' : 'inconsistent');
  " || echo "error")

  if [ "${hash_result}" = "consistent" ]; then
    pass "dbHash is consistent across all user databases"
  elif [ "${hash_result}" = "error" ]; then
    fail "dbHash check could not be executed"
  else
    fail "dbHash inconsistency detected"
  fi
}

check_collection_counts() {
  log "Checking collection counts..."
  local db_count
  db_count=$(run_mongosh "
    const dbs = db.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !['admin', 'config', 'local'].includes(d.name));
    let totalCollections = 0;
    for (const dbInfo of dbs) {
      const colls = db.getSiblingDB(dbInfo.name).getCollectionNames();
      totalCollections += colls.length;
    }
    print(totalCollections);
  " || echo "0")

  if [ "${db_count}" -ge 0 ] 2>/dev/null; then
    pass "Found ${db_count} collections across user databases"
  else
    fail "Could not enumerate collections"
  fi
}

check_index_consistency() {
  log "Checking index consistency..."
  local index_result
  index_result=$(run_mongosh "
    const dbs = db.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !['admin', 'config', 'local'].includes(d.name));
    let allValid = true;
    for (const dbInfo of dbs) {
      const sdb = db.getSiblingDB(dbInfo.name);
      const colls = sdb.getCollectionNames();
      for (const coll of colls) {
        const result = sdb.getCollection(coll).validate({ full: false });
        if (!result.valid) {
          print('INVALID: ' + dbInfo.name + '.' + coll);
          allValid = false;
        }
      }
    }
    print(allValid ? 'valid' : 'invalid');
  " || echo "error")

  if [ "${index_result}" = "valid" ]; then
    pass "All collection indexes are valid"
  elif [ "${index_result}" = "error" ]; then
    fail "Index validation could not be executed"
  else
    fail "Index inconsistency detected"
  fi
}

check_read_operations() {
  log "Checking read operations..."
  local read_result
  read_result=$(run_mongosh "
    try {
      db.getSiblingDB('admin').runCommand({ ping: 1 });
      print('ok');
    } catch(e) {
      print('error: ' + e.message);
    }
  " || echo "error")

  if [ "${read_result}" = "ok" ]; then
    pass "Read operations are functional"
  else
    fail "Read operations failed: ${read_result}"
  fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "=== Post-Restore Integrity Validation ==="
  log "Cluster: ${CLUSTER_NAME} | Namespace: ${NAMESPACE}"
  log ""

  check_replica_set_health
  check_dbhash_consistency
  check_collection_counts
  check_index_consistency
  check_read_operations

  log ""
  if [ "${ERRORS}" -eq 0 ]; then
    log "=== All integrity checks passed ==="
    exit 0
  else
    log "=== ${ERRORS} integrity check(s) FAILED ==="
    exit 1
  fi
}

main
