#!/usr/bin/env bash
set -euo pipefail

# restore-pitr.sh - Point-in-Time Recovery for MongoDB
#
# Usage:
#   ./backup/restore/restore-pitr.sh [OPTIONS]
#
# Options:
#   --help              Show this help message
#   --dry-run           Print commands without executing
#   --target-time TIME  Target restore time in ISO 8601 format (required)
#                       Example: 2024-01-15T14:30:00Z
#   --namespace NS      MongoDB namespace (default: mongodb)
#   --cluster NAME      Cluster name (default: mongodb-rs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
TARGET_TIME=""
DRY_RUN=false

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

run() {
  if [ "${DRY_RUN}" = true ]; then
    log "[DRY-RUN] $*"
  else
    log "Running: $*"
    "$@"
  fi
}

usage() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '!/usr/bin' | sed 's/^# \?//'
  exit 0
}

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    --target-time) TARGET_TIME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────

validate_inputs() {
  if [ -z "${TARGET_TIME}" ]; then
    log "ERROR: --target-time is required"
    log "Example: --target-time 2024-01-15T14:30:00Z"
    exit 2
  fi

  # Validate ISO 8601 format
  if ! date -d "${TARGET_TIME}" &>/dev/null 2>&1; then
    log "ERROR: Invalid date format: ${TARGET_TIME}"
    log "Expected ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ"
    exit 2
  fi

  log "Target restore time: ${TARGET_TIME}"
}

check_prerequisites() {
  local missing=()
  for cmd in kubectl jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR: Missing required tools: ${missing[*]}"
    exit 3
  fi

  if ! kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    log "ERROR: PerconaServerMongoDB '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'"
    exit 3
  fi
}

check_pitr_available() {
  log "Checking if PITR is available for target time..."

  local pitr_status
  pitr_status=$(kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.pitr.enabled}' 2>/dev/null || echo "false")

  if [ "${pitr_status}" != "true" ]; then
    log "WARNING: PITR may not be enabled on this cluster."
    log "Verify spec.backup.pitr.enabled is set to true in the CR."
  fi
}

# ──────────────────────────────────────────────
# Restore
# ──────────────────────────────────────────────

perform_pitr_restore() {
  log "Starting Point-in-Time Recovery to ${TARGET_TIME}..."

  local restore_name
  restore_name="pitr-restore-$(date +%Y%m%d-%H%M%S)"

  run kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: ${restore_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  pitr:
    type: date
    date: "${TARGET_TIME}"
EOF

  log "PITR restore CR '${restore_name}' created."
  log "Waiting for PITR restore to complete..."

  run kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-restore/${restore_name}" \
    -n "${NAMESPACE}" \
    --timeout=900s

  log "PITR restore completed successfully."
}

# ──────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────

validate_restore() {
  log "Running post-restore validation..."
  run bash "${SCRIPT_DIR}/validate-integrity.sh" \
    --namespace "${NAMESPACE}" \
    --cluster "${CLUSTER_NAME}"
  log "Validation complete."
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "=== MongoDB Point-in-Time Recovery ==="

  validate_inputs
  check_prerequisites
  check_pitr_available
  perform_pitr_restore
  validate_restore

  log "=== PITR completed successfully ==="
}

main
