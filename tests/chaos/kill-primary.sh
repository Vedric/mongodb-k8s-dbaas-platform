#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# kill-primary.sh - Simulate primary pod failure and validate automatic
# failover, re-election, pod recovery, and replication health.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Defaults
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
DRY_RUN=false
ELECTION_TIMEOUT=60
RECOVERY_TIMEOUT=120

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

usage() {
  cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS]

Simulate a MongoDB primary pod failure and validate automatic recovery.

Options:
  --namespace NAME        Kubernetes namespace (env: NAMESPACE, default: mongodb)
  --cluster-name NAME     Percona cluster name (env: CLUSTER_NAME, default: mongodb-rs)
  --rs-name NAME          Replica set name (env: RS_NAME, default: rs0)
  --election-timeout SEC  Max seconds to wait for new primary (default: 60)
  --recovery-timeout SEC  Max seconds to wait for old pod recovery (default: 120)
  --dry-run               Print commands without executing
  --help                  Show this help message

Environment variables:
  NAMESPACE      Kubernetes namespace
  CLUSTER_NAME   Percona cluster name
  RS_NAME        Replica set name

Exit codes:
  0  Success
  1  General error
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
    --election-timeout)
      [[ -n "${2:-}" ]] || die 2 "--election-timeout requires a value"
      ELECTION_TIMEOUT="$2"; shift 2 ;;
    --recovery-timeout)
      [[ -n "${2:-}" ]] || die 2 "--recovery-timeout requires a value"
      RECOVERY_TIMEOUT="$2"; shift 2 ;;
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

  local pod_count
  pod_count=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    --no-headers 2>/dev/null | wc -l)

  if [[ "${pod_count}" -lt 3 ]]; then
    die 3 "Expected at least 3 replica set pods, found ${pod_count}"
  fi

  log "Preconditions satisfied"
}

# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------

get_mongo_pod() {
  local index="${1:-0}"
  kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath="{.items[${index}].metadata.name}" 2>/dev/null
}

mongo_eval() {
  local pod="$1"
  shift
  kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    mongosh --quiet --eval "$@" 2>/dev/null
}

find_primary() {
  local pods
  pods=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[*].metadata.name}')

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

get_oplog_position() {
  local pod="$1"
  mongo_eval "${pod}" 'rs.status().members.find(m => m.stateStr === "PRIMARY").optimeDate'
}

record_pre_failure_state() {
  log "Recording pre-failure state..."

  PRIMARY_POD=$(find_primary) || die 1 "Could not identify the current primary"
  log "Current primary: ${PRIMARY_POD}"

  OPLOG_POS=$(get_oplog_position "${PRIMARY_POD}") || true
  log "Oplog position: ${OPLOG_POS:-unknown}"

  RS_STATUS_BEFORE=$(mongo_eval "${PRIMARY_POD}" 'JSON.stringify(rs.status().members.map(m => ({name: m.name, state: m.stateStr})))') || true
  log "RS members before: ${RS_STATUS_BEFORE:-unknown}"
}

kill_primary_pod() {
  log "Deleting primary pod: ${PRIMARY_POD}"
  run kubectl delete pod -n "${NAMESPACE}" "${PRIMARY_POD}" --grace-period=0 --force
  log "Primary pod deletion initiated"
}

wait_for_new_primary() {
  log "Waiting up to ${ELECTION_TIMEOUT}s for new primary election..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for new primary election"
    return 0
  fi

  local elapsed=0
  local new_primary=""

  while [[ "${elapsed}" -lt "${ELECTION_TIMEOUT}" ]]; do
    new_primary=$(find_primary 2>/dev/null) || true

    if [[ -n "${new_primary}" && "${new_primary}" != "${PRIMARY_POD}" ]]; then
      log "New primary elected: ${new_primary} (after ${elapsed}s)"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  die 1 "No new primary elected within ${ELECTION_TIMEOUT}s"
}

wait_for_pod_recovery() {
  log "Waiting up to ${RECOVERY_TIMEOUT}s for old primary pod to recover: ${PRIMARY_POD}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for pod recovery"
    return 0
  fi

  local elapsed=0

  while [[ "${elapsed}" -lt "${RECOVERY_TIMEOUT}" ]]; do
    local phase
    phase=$(kubectl get pod -n "${NAMESPACE}" "${PRIMARY_POD}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "${phase}" == "Running" ]]; then
      local ready
      ready=$(kubectl get pod -n "${NAMESPACE}" "${PRIMARY_POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

      if [[ "${ready}" == "True" ]]; then
        log "Old primary pod recovered and is Ready (after ${elapsed}s)"
        return 0
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  die 1 "Old primary pod did not recover within ${RECOVERY_TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

validate_recovery() {
  log "Running recovery validation..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would validate recovery"
    return 0
  fi

  # Validate new primary exists and differs from old primary
  local current_primary
  current_primary=$(find_primary) || die 1 "No primary found after failover"

  if [[ "${current_primary}" == "${PRIMARY_POD}" ]]; then
    log "WARNING: Same pod became primary again (valid but unexpected)"
  fi

  # Check replication lag on all secondaries
  log "Checking replication lag..."
  local lag_check
  lag_check=$(mongo_eval "${current_primary}" '
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === "PRIMARY");
    const lagging = status.members.filter(m =>
      m.stateStr === "SECONDARY" &&
      (primary.optimeDate - m.optimeDate) / 1000 > 10
    );
    JSON.stringify({ok: lagging.length === 0, count: lagging.length});
  ') || die 1 "Failed to check replication lag"

  local lag_ok
  lag_ok=$(echo "${lag_check}" | grep -o '"ok":true' || true)
  if [[ -z "${lag_ok}" ]]; then
    die 1 "Replication lag exceeds 10 seconds on one or more secondaries"
  fi
  log "Replication lag within acceptable threshold (<10s)"

  # Validate majority write succeeds
  log "Testing majority write concern..."
  local write_result
  write_result=$(mongo_eval "${current_primary}" '
    try {
      db.getSiblingDB("chaos_test").kill_primary_test.insertOne(
        {test: "kill-primary", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 10000}}
      );
      "write_ok"
    } catch(e) {
      "write_failed: " + e.message
    }
  ') || die 1 "Failed to execute majority write test"

  if [[ "${write_result}" != *"write_ok"* ]]; then
    die 1 "Majority write failed after failover: ${write_result}"
  fi
  log "Majority write succeeded"

  # Call validate-recovery.sh if available
  if [[ -x "${SCRIPT_DIR}/validate-recovery.sh" ]]; then
    log "Running comprehensive recovery validation..."
    "${SCRIPT_DIR}/validate-recovery.sh" \
      --namespace "${NAMESPACE}" \
      --cluster-name "${CLUSTER_NAME}" \
      --rs-name "${RS_NAME}"
  fi

  log "All validations passed"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
  if [[ "${DRY_RUN}" != "true" ]]; then
    log "Cleaning up test data..."
    local primary
    primary=$(find_primary 2>/dev/null) || true
    if [[ -n "${primary}" ]]; then
      mongo_eval "${primary}" \
        'db.getSiblingDB("chaos_test").kill_primary_test.drop()' &>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "=== Kill Primary Chaos Test ==="
  log "Namespace: ${NAMESPACE}"
  log "Cluster:   ${CLUSTER_NAME}"
  log "RS Name:   ${RS_NAME}"
  log "Dry Run:   ${DRY_RUN}"

  check_preconditions
  record_pre_failure_state
  kill_primary_pod
  wait_for_new_primary
  wait_for_pod_recovery
  validate_recovery

  log "=== Kill Primary Chaos Test PASSED ==="
}

main
