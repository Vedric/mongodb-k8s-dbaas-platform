#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# delete-pv.sh - Simulate persistent volume loss for a MongoDB secondary
# member and validate automatic recovery with initial sync.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Defaults
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
DRY_RUN=false
RECOVERY_TIMEOUT=300
SYNC_TIMEOUT=600

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

usage() {
  cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS]

Simulate persistent volume loss for a MongoDB secondary member and validate
that the member recovers via initial sync with no data loss.

Options:
  --namespace NAME         Kubernetes namespace (env: NAMESPACE, default: mongodb)
  --cluster-name NAME      Percona cluster name (env: CLUSTER_NAME, default: mongodb-rs)
  --rs-name NAME           Replica set name (env: RS_NAME, default: rs0)
  --recovery-timeout SEC   Max seconds to wait for pod rescheduling (default: 300)
  --sync-timeout SEC       Max seconds to wait for initial sync (default: 600)
  --dry-run                Print commands without executing
  --help                   Show this help message

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
    --recovery-timeout)
      [[ -n "${2:-}" ]] || die 2 "--recovery-timeout requires a value"
      RECOVERY_TIMEOUT="$2"; shift 2 ;;
    --sync-timeout)
      [[ -n "${2:-}" ]] || die 2 "--sync-timeout requires a value"
      SYNC_TIMEOUT="$2"; shift 2 ;;
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

find_secondary() {
  local pods
  pods=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[*].metadata.name}')

  local primary
  primary=$(find_primary) || die 1 "Could not identify primary"

  for pod in ${pods}; do
    if [[ "${pod}" != "${primary}" ]]; then
      echo "${pod}"
      return 0
    fi
  done

  die 1 "Could not find a secondary member"
}

get_pvc_for_pod() {
  local pod="$1"
  kubectl get pod -n "${NAMESPACE}" "${pod}" \
    -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null \
    | awk '{print $1}'
}

get_document_count() {
  local pod="$1"
  local db_name="${2:-chaos_test}"
  local coll_name="${3:-pv_test}"
  mongo_eval "${pod}" "db.getSiblingDB('${db_name}').${coll_name}.countDocuments({})"
}

record_pre_failure_state() {
  log "Recording pre-failure state..."

  PRIMARY_POD=$(find_primary) || die 1 "Could not identify primary"
  log "Primary: ${PRIMARY_POD}"

  TARGET_POD=$(find_secondary) || die 1 "Could not identify secondary"
  log "Target secondary for PV deletion: ${TARGET_POD}"

  TARGET_PVC=$(get_pvc_for_pod "${TARGET_POD}")
  if [[ -z "${TARGET_PVC}" ]]; then
    die 1 "Could not find PVC for pod ${TARGET_POD}"
  fi
  log "Target PVC: ${TARGET_PVC}"

  # Insert test data and record count
  log "Inserting test data for validation..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    mongo_eval "${PRIMARY_POD}" '
      const db = db.getSiblingDB("chaos_test");
      for (let i = 0; i < 100; i++) {
        db.pv_test.insertOne(
          {seq: i, ts: new Date(), data: "pv-delete-chaos-test"},
          {writeConcern: {w: "majority", wtimeout: 10000}}
        );
      }
    ' || die 1 "Failed to insert test data"

    # Wait briefly for replication
    sleep 5

    DOC_COUNT_BEFORE=$(get_document_count "${PRIMARY_POD}") || die 1 "Failed to get document count"
    log "Document count before failure: ${DOC_COUNT_BEFORE}"
  else
    DOC_COUNT_BEFORE=0
    log "[DRY-RUN] Would insert test data and record count"
  fi
}

delete_pvc_and_pod() {
  log "Deleting PVC: ${TARGET_PVC}"
  run kubectl delete pvc -n "${NAMESPACE}" "${TARGET_PVC}" --wait=false

  log "Deleting pod: ${TARGET_POD}"
  run kubectl delete pod -n "${NAMESPACE}" "${TARGET_POD}" --grace-period=0 --force

  log "PVC and pod deletion initiated"
}

wait_for_pod_reschedule() {
  log "Waiting up to ${RECOVERY_TIMEOUT}s for pod to be rescheduled..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for pod rescheduling"
    return 0
  fi

  local elapsed=0

  while [[ "${elapsed}" -lt "${RECOVERY_TIMEOUT}" ]]; do
    local phase
    phase=$(kubectl get pod -n "${NAMESPACE}" "${TARGET_POD}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "${phase}" == "Running" ]]; then
      local ready
      ready=$(kubectl get pod -n "${NAMESPACE}" "${TARGET_POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

      if [[ "${ready}" == "True" ]]; then
        log "Pod rescheduled and is Ready (after ${elapsed}s)"
        return 0
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  die 1 "Pod did not become Ready within ${RECOVERY_TIMEOUT}s"
}

wait_for_pvc_provision() {
  log "Checking for PVC re-provisioning..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for PVC provisioning"
    return 0
  fi

  local elapsed=0

  while [[ "${elapsed}" -lt "${RECOVERY_TIMEOUT}" ]]; do
    local pvc_status
    pvc_status=$(kubectl get pvc -n "${NAMESPACE}" "${TARGET_PVC}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "${pvc_status}" == "Bound" ]]; then
      log "PVC re-provisioned and Bound (after ${elapsed}s)"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  die 1 "PVC was not re-provisioned within ${RECOVERY_TIMEOUT}s"
}

wait_for_initial_sync() {
  log "Waiting up to ${SYNC_TIMEOUT}s for initial sync to complete..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for initial sync"
    return 0
  fi

  local primary
  primary=$(find_primary) || die 1 "No primary available"

  local elapsed=0

  while [[ "${elapsed}" -lt "${SYNC_TIMEOUT}" ]]; do
    local member_state
    member_state=$(mongo_eval "${primary}" "
      const status = rs.status();
      const member = status.members.find(m => m.name.includes('${TARGET_POD}'));
      member ? member.stateStr : 'UNKNOWN';
    " 2>/dev/null || echo "UNKNOWN")

    if [[ "${member_state}" == "SECONDARY" ]]; then
      log "Member completed initial sync and is SECONDARY (after ${elapsed}s)"
      return 0
    fi

    log "Member state: ${member_state} (waiting for SECONDARY)..."
    sleep 10
    elapsed=$((elapsed + 10))
  done

  die 1 "Initial sync did not complete within ${SYNC_TIMEOUT}s"
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

  local primary
  primary=$(find_primary) || die 1 "No primary found after recovery"

  # Check document count matches
  local doc_count_after
  doc_count_after=$(get_document_count "${primary}") || die 1 "Failed to get document count"

  if [[ "${doc_count_after}" -lt "${DOC_COUNT_BEFORE}" ]]; then
    die 1 "Data loss detected: expected >=${DOC_COUNT_BEFORE} documents, found ${doc_count_after}"
  fi
  log "Document count after recovery: ${doc_count_after} (before: ${DOC_COUNT_BEFORE})"

  # Verify the recovered member has the same data
  local secondary_count
  secondary_count=$(get_document_count "${TARGET_POD}") || die 1 "Failed to get count from recovered member"

  if [[ "${secondary_count}" -lt "${DOC_COUNT_BEFORE}" ]]; then
    die 1 "Recovered member has incomplete data: expected >=${DOC_COUNT_BEFORE}, found ${secondary_count}"
  fi
  log "Recovered member document count: ${secondary_count}"

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
        'db.getSiblingDB("chaos_test").pv_test.drop()' &>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "=== Delete PV Chaos Test ==="
  log "Namespace: ${NAMESPACE}"
  log "Cluster:   ${CLUSTER_NAME}"
  log "RS Name:   ${RS_NAME}"
  log "Dry Run:   ${DRY_RUN}"

  check_preconditions
  record_pre_failure_state
  delete_pvc_and_pod
  wait_for_pvc_provision
  wait_for_pod_reschedule
  wait_for_initial_sync
  validate_recovery

  log "=== Delete PV Chaos Test PASSED ==="
}

main
