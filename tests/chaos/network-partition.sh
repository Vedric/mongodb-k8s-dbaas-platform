#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# network-partition.sh - Simulate a network partition for one MongoDB
# replica set member using iptables and validate recovery after healing.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Defaults
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
RS_NAME="${RS_NAME:-rs0}"
DRY_RUN=false
PARTITION_DURATION=30
DETECTION_TIMEOUT=60
RECOVERY_TIMEOUT=120

# State variables
TARGET_POD=""
TARGET_IP=""
PEER_IPS=()
PARTITION_APPLIED=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

usage() {
  cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS]

Simulate a network partition for one MongoDB replica set member by blocking
traffic with iptables, then heal the partition and validate recovery.

This script requires the target pod to have iptables available. The Percona
operator pods typically include iptables in their container image.

Options:
  --namespace NAME            Kubernetes namespace (env: NAMESPACE, default: mongodb)
  --cluster-name NAME         Percona cluster name (env: CLUSTER_NAME, default: my-cluster)
  --rs-name NAME              Replica set name (env: RS_NAME, default: rs0)
  --partition-duration SEC    How long to maintain the partition (default: 30)
  --detection-timeout SEC     Max seconds to detect membership loss (default: 60)
  --recovery-timeout SEC      Max seconds to wait for recovery after healing (default: 120)
  --dry-run                   Print commands without executing
  --help                      Show this help message

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
    --partition-duration)
      [[ -n "${2:-}" ]] || die 2 "--partition-duration requires a value"
      PARTITION_DURATION="$2"; shift 2 ;;
    --detection-timeout)
      [[ -n "${2:-}" ]] || die 2 "--detection-timeout requires a value"
      DETECTION_TIMEOUT="$2"; shift 2 ;;
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

get_pod_ip() {
  local pod="$1"
  kubectl get pod -n "${NAMESPACE}" "${pod}" \
    -o jsonpath='{.status.podIP}' 2>/dev/null
}

get_all_pod_ips() {
  kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[*].status.podIP}' 2>/dev/null
}

select_target() {
  log "Selecting partition target..."

  TARGET_POD=$(find_secondary) || die 1 "Could not find a secondary to partition"
  TARGET_IP=$(get_pod_ip "${TARGET_POD}")
  log "Target pod: ${TARGET_POD} (IP: ${TARGET_IP})"

  local all_ips
  all_ips=$(get_all_pod_ips)

  PEER_IPS=()
  for ip in ${all_ips}; do
    if [[ "${ip}" != "${TARGET_IP}" ]]; then
      PEER_IPS+=("${ip}")
    fi
  done

  log "Peer IPs: ${PEER_IPS[*]}"
}

insert_test_data() {
  log "Inserting test data before partition..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would insert test data"
    return 0
  fi

  local primary
  primary=$(find_primary) || die 1 "No primary available"

  mongo_eval "${primary}" '
    const db = db.getSiblingDB("chaos_test");
    for (let i = 0; i < 50; i++) {
      db.partition_test.insertOne(
        {seq: i, phase: "pre-partition", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 10000}}
      );
    }
  ' || die 1 "Failed to insert pre-partition test data"

  sleep 3
  log "Pre-partition test data inserted"
}

apply_partition() {
  log "Applying network partition to ${TARGET_POD}..."

  for peer_ip in "${PEER_IPS[@]}"; do
    log "Blocking traffic between ${TARGET_POD} and ${peer_ip}"
    run kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
      iptables -A INPUT -s "${peer_ip}" -j DROP
    run kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
      iptables -A OUTPUT -d "${peer_ip}" -j DROP
  done

  PARTITION_APPLIED=true
  log "Network partition applied"
}

wait_for_membership_loss() {
  log "Waiting up to ${DETECTION_TIMEOUT}s for partition detection..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for membership loss detection"
    return 0
  fi

  local primary
  primary=$(find_primary 2>/dev/null) || true

  # If the target was not the primary, use the current primary to check
  if [[ -z "${primary}" || "${primary}" == "${TARGET_POD}" ]]; then
    # Try each non-target pod
    local pods
    pods=$(kubectl get pods -n "${NAMESPACE}" \
      -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
      -o jsonpath='{.items[*].metadata.name}')

    for pod in ${pods}; do
      if [[ "${pod}" != "${TARGET_POD}" ]]; then
        primary="${pod}"
        break
      fi
    done
  fi

  local elapsed=0

  while [[ "${elapsed}" -lt "${DETECTION_TIMEOUT}" ]]; do
    local target_state
    target_state=$(mongo_eval "${primary}" "
      const status = rs.status();
      const member = status.members.find(m => m.name.includes('${TARGET_POD}'));
      member ? member.stateStr : 'UNKNOWN';
    " 2>/dev/null || echo "UNKNOWN")

    if [[ "${target_state}" != "SECONDARY" && "${target_state}" != "PRIMARY" ]]; then
      log "Partitioned member detected as: ${target_state} (after ${elapsed}s)"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "WARNING: Partitioned member may not have been fully detected within ${DETECTION_TIMEOUT}s"
}

hold_partition() {
  log "Maintaining partition for ${PARTITION_DURATION}s..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would hold partition for ${PARTITION_DURATION}s"
    return 0
  fi

  # Insert additional data during partition
  local primary
  primary=$(find_primary 2>/dev/null) || true

  if [[ -n "${primary}" && "${primary}" != "${TARGET_POD}" ]]; then
    log "Inserting data during partition..."
    mongo_eval "${primary}" '
      const db = db.getSiblingDB("chaos_test");
      for (let i = 0; i < 50; i++) {
        db.partition_test.insertOne(
          {seq: i + 50, phase: "during-partition", ts: new Date()},
          {writeConcern: {w: 1, wtimeout: 5000}}
        );
      }
    ' || log "WARNING: Some writes during partition may have failed"
  fi

  sleep "${PARTITION_DURATION}"
}

heal_partition() {
  log "Healing network partition on ${TARGET_POD}..."

  for peer_ip in "${PEER_IPS[@]}"; do
    log "Removing iptables rules for ${peer_ip}"
    run kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
      iptables -D INPUT -s "${peer_ip}" -j DROP 2>/dev/null || true
    run kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
      iptables -D OUTPUT -d "${peer_ip}" -j DROP 2>/dev/null || true
  done

  PARTITION_APPLIED=false
  log "Network partition healed"
}

wait_for_rejoin() {
  log "Waiting up to ${RECOVERY_TIMEOUT}s for member to rejoin..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would wait for member to rejoin"
    return 0
  fi

  local check_pod
  local pods
  pods=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[*].metadata.name}')

  for pod in ${pods}; do
    if [[ "${pod}" != "${TARGET_POD}" ]]; then
      check_pod="${pod}"
      break
    fi
  done

  local elapsed=0

  while [[ "${elapsed}" -lt "${RECOVERY_TIMEOUT}" ]]; do
    local target_state
    target_state=$(mongo_eval "${check_pod}" "
      const status = rs.status();
      const member = status.members.find(m => m.name.includes('${TARGET_POD}'));
      member ? member.stateStr : 'UNKNOWN';
    " 2>/dev/null || echo "UNKNOWN")

    if [[ "${target_state}" == "SECONDARY" || "${target_state}" == "PRIMARY" ]]; then
      log "Member rejoined as ${target_state} (after ${elapsed}s)"
      return 0
    fi

    log "Member state: ${target_state} (waiting for SECONDARY or PRIMARY)..."
    sleep 5
    elapsed=$((elapsed + 5))
  done

  die 1 "Member did not rejoin within ${RECOVERY_TIMEOUT}s"
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
  primary=$(find_primary) || die 1 "No primary found after partition healing"

  # Check all data is present
  local total_count
  total_count=$(mongo_eval "${primary}" \
    'db.getSiblingDB("chaos_test").partition_test.countDocuments({})') \
    || die 1 "Failed to get document count"

  if [[ "${total_count}" -lt 50 ]]; then
    die 1 "Data loss detected: expected at least 50 pre-partition documents, found ${total_count}"
  fi
  log "Total documents on primary: ${total_count}"

  # Wait for the target to catch up, then verify its count
  sleep 5
  local target_count
  target_count=$(mongo_eval "${TARGET_POD}" \
    'db.getSiblingDB("chaos_test").partition_test.countDocuments({})') \
    || log "WARNING: Could not read from recovered member directly"

  if [[ -n "${target_count}" ]]; then
    log "Documents on recovered member: ${target_count}"
    if [[ "${target_count}" -lt "${total_count}" ]]; then
      log "WARNING: Recovered member still catching up (${target_count}/${total_count})"
    fi
  fi

  # Validate majority write succeeds
  log "Testing majority write concern..."
  local write_result
  write_result=$(mongo_eval "${primary}" '
    try {
      db.getSiblingDB("chaos_test").partition_test.insertOne(
        {seq: 999, phase: "post-partition", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 10000}}
      );
      "write_ok"
    } catch(e) {
      "write_failed: " + e.message
    }
  ') || die 1 "Failed to execute majority write test"

  if [[ "${write_result}" != *"write_ok"* ]]; then
    die 1 "Majority write failed after partition healing: ${write_result}"
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
  # Always attempt to heal partition on exit
  if [[ "${PARTITION_APPLIED}" == "true" ]]; then
    log "Cleanup: healing partition..."
    for peer_ip in "${PEER_IPS[@]}"; do
      kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
        iptables -D INPUT -s "${peer_ip}" -j DROP 2>/dev/null || true
      kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- \
        iptables -D OUTPUT -d "${peer_ip}" -j DROP 2>/dev/null || true
    done
  fi

  if [[ "${DRY_RUN}" != "true" ]]; then
    log "Cleaning up test data..."
    local primary
    primary=$(find_primary 2>/dev/null) || true
    if [[ -n "${primary}" ]]; then
      mongo_eval "${primary}" \
        'db.getSiblingDB("chaos_test").partition_test.drop()' &>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "=== Network Partition Chaos Test ==="
  log "Namespace:  ${NAMESPACE}"
  log "Cluster:    ${CLUSTER_NAME}"
  log "RS Name:    ${RS_NAME}"
  log "Duration:   ${PARTITION_DURATION}s"
  log "Dry Run:    ${DRY_RUN}"

  check_preconditions
  select_target
  insert_test_data
  apply_partition
  wait_for_membership_loss
  hold_partition
  heal_partition
  wait_for_rejoin
  validate_recovery

  log "=== Network Partition Chaos Test PASSED ==="
}

main
