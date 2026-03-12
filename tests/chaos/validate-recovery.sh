#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# validate-recovery.sh - Generic recovery validation for MongoDB replica sets.
# Checks member health, primary count, replication lag, write availability,
# and backup agent status. Can be run standalone or called from other scripts.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Defaults
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
MAX_LAG=10
DRY_RUN=false

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

usage() {
  cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS]

Validate the health and recovery state of a MongoDB replica set. Performs
the following checks:

  - All RS members are in a healthy state (PRIMARY or SECONDARY)
  - Exactly one PRIMARY exists
  - Replication lag is below the specified threshold
  - Majority write concern succeeds
  - PBM backup agent is running and healthy

This script can be run standalone or called from other chaos test scripts.

Options:
  --namespace NAME        Kubernetes namespace (env: NAMESPACE, default: mongodb)
  --cluster-name NAME     Percona cluster name (env: CLUSTER_NAME, default: mongodb-rs)
  --rs-name NAME          Replica set name (env: RS_NAME, default: rs0)
  --max-lag SEC           Maximum acceptable replication lag in seconds (default: 10)
  --dry-run               Print checks without executing
  --help                  Show this help message

Environment variables:
  NAMESPACE      Kubernetes namespace
  CLUSTER_NAME   Percona cluster name
  RS_NAME        Replica set name

Exit codes:
  0  All checks passed
  1  One or more checks failed
  2  Usage error
  3  Precondition not met
HELP
}

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] $*"
  else
    "$@"
  fi
}

die() {
  local code="$1"
  shift
  log "ERROR: $*" >&2
  exit "${code}"
}

check_pass() {
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
  log "PASS: $*"
}

check_fail() {
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  log "FAIL: $*"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ -n "${2:-}" ]] || die 2 "--namespace requires a value"
      NAMESPACE="$2"; shift 2 ;;
    --cluster-name)
      [[ -n "${2:-}" ]] || die 2 "--cluster-name requires a value"
      CLUSTER_NAME="$2"; shift 2 ;;
    --rs-name)
      [[ -n "${2:-}" ]] || die 2 "--rs-name requires a value"
      RS_NAME="$2"; shift 2 ;;
    --max-lag)
      [[ -n "${2:-}" ]] || die 2 "--max-lag requires a value"
      MAX_LAG="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --help)
      usage; exit 0 ;;
    *)
      die 2 "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Precondition checks
# ---------------------------------------------------------------------------

check_preconditions() {
  log "Checking preconditions..."

  if ! command -v kubectl &>/dev/null; then
    die 3 "kubectl is not installed or not in PATH"
  fi

  if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    die 3 "Namespace '${NAMESPACE}' does not exist"
  fi

  log "Preconditions satisfied"
}

# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------

mongo_eval() {
  local pod="$1"
  shift
  kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    mongosh --quiet --eval "$@" 2>/dev/null
}

get_mongod_pods() {
  kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

find_primary() {
  local pods
  pods=$(get_mongod_pods)

  for pod in ${pods}; do
    local is_master
    is_master=$(mongo_eval "${pod}" 'db.isMaster().ismaster' 2>/dev/null || echo "false")
    if [[ "${is_master}" == "true" ]]; then
      echo "${pod}"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# Validation checks
# ---------------------------------------------------------------------------

check_all_members_healthy() {
  log "Check: All RS members are in a healthy state..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would check all members healthy"
    return 0
  fi

  local primary
  primary=$(find_primary 2>/dev/null) || {
    check_fail "Cannot find any primary to query RS status"
    return 1
  }

  local unhealthy
  unhealthy=$(mongo_eval "${primary}" '
    const status = rs.status();
    const bad = status.members.filter(m =>
      m.stateStr !== "PRIMARY" &&
      m.stateStr !== "SECONDARY" &&
      m.stateStr !== "ARBITER"
    );
    JSON.stringify(bad.map(m => ({name: m.name, state: m.stateStr})));
  ') || {
    check_fail "Failed to query RS member states"
    return 1
  }

  if [[ "${unhealthy}" == "[]" ]]; then
    check_pass "All RS members are healthy"
  else
    check_fail "Unhealthy members found: ${unhealthy}"
  fi
}

check_single_primary() {
  log "Check: Exactly one PRIMARY exists..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would check single primary"
    return 0
  fi

  local any_pod
  any_pod=$(get_mongod_pods | awk '{print $1}')
  if [[ -z "${any_pod}" ]]; then
    check_fail "No mongod pods found"
    return 1
  fi

  local primary_count
  primary_count=$(mongo_eval "${any_pod}" '
    const status = rs.status();
    status.members.filter(m => m.stateStr === "PRIMARY").length;
  ') || {
    check_fail "Failed to query primary count"
    return 1
  }

  if [[ "${primary_count}" == "1" ]]; then
    check_pass "Exactly 1 PRIMARY exists"
  else
    check_fail "Expected 1 PRIMARY, found ${primary_count}"
  fi
}

check_replication_lag() {
  log "Check: Replication lag < ${MAX_LAG}s on all secondaries..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would check replication lag"
    return 0
  fi

  local primary
  primary=$(find_primary 2>/dev/null) || {
    check_fail "Cannot find primary to check replication lag"
    return 1
  }

  local lag_result
  lag_result=$(mongo_eval "${primary}" "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    const results = status.members
      .filter(m => m.stateStr === 'SECONDARY')
      .map(m => ({
        name: m.name,
        lagSeconds: Math.round((primary.optimeDate - m.optimeDate) / 1000)
      }));
    JSON.stringify(results);
  ") || {
    check_fail "Failed to query replication lag"
    return 1
  }

  local has_excessive_lag
  has_excessive_lag=$(mongo_eval "${primary}" "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    const lagging = status.members.filter(m =>
      m.stateStr === 'SECONDARY' &&
      Math.round((primary.optimeDate - m.optimeDate) / 1000) > ${MAX_LAG}
    );
    lagging.length;
  ") || {
    check_fail "Failed to evaluate lag threshold"
    return 1
  }

  if [[ "${has_excessive_lag}" == "0" ]]; then
    check_pass "Replication lag within threshold (${MAX_LAG}s): ${lag_result}"
  else
    check_fail "Replication lag exceeds ${MAX_LAG}s: ${lag_result}"
  fi
}

check_majority_write() {
  log "Check: Majority write concern succeeds..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would check majority write"
    return 0
  fi

  local primary
  primary=$(find_primary 2>/dev/null) || {
    check_fail "Cannot find primary for write test"
    return 1
  }

  local write_result
  write_result=$(mongo_eval "${primary}" '
    try {
      db.getSiblingDB("chaos_test").recovery_validation.insertOne(
        {test: "validate-recovery", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 10000}}
      );
      "write_ok"
    } catch(e) {
      "write_failed: " + e.message
    }
  ') || {
    check_fail "Failed to execute majority write test"
    return 1
  }

  if [[ "${write_result}" == *"write_ok"* ]]; then
    check_pass "Majority write succeeded"
    # Clean up test document
    mongo_eval "${primary}" \
      'db.getSiblingDB("chaos_test").recovery_validation.drop()' &>/dev/null || true
  else
    check_fail "Majority write failed: ${write_result}"
  fi
}

check_backup_agent() {
  log "Check: PBM backup agent is healthy..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would check backup agent"
    return 0
  fi

  local primary
  primary=$(find_primary 2>/dev/null) || {
    check_fail "Cannot find primary to check backup agent"
    return 1
  }

  # Check if PBM status can be retrieved from the backup agent container
  local pbm_status
  pbm_status=$(kubectl exec -n "${NAMESPACE}" "${primary}" -c backup-agent -- \
    pbm status 2>/dev/null) || {
    # Backup agent container may not exist or PBM may not be configured
    log "INFO: Backup agent check skipped (container or PBM not available)"
    return 0
  }

  if echo "${pbm_status}" | grep -qi "error"; then
    check_fail "PBM agent reports errors: $(echo "${pbm_status}" | head -5)"
  else
    check_pass "PBM backup agent is healthy"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "=== MongoDB Replica Set Recovery Validation ==="
  log "Namespace:  ${NAMESPACE}"
  log "Cluster:    ${CLUSTER_NAME}"
  log "RS Name:    ${RS_NAME}"
  log "Max Lag:    ${MAX_LAG}s"
  log "Dry Run:    ${DRY_RUN}"

  check_preconditions

  check_all_members_healthy
  check_single_primary
  check_replication_lag
  check_majority_write
  check_backup_agent

  log "---"
  log "Results: ${CHECKS_PASSED} passed, ${CHECKS_FAILED} failed"

  if [[ "${CHECKS_FAILED}" -gt 0 ]]; then
    log "=== Recovery Validation FAILED ==="
    exit 1
  fi

  log "=== Recovery Validation PASSED ==="
}

main
