#!/usr/bin/env bash
set -euo pipefail

# restore-full.sh - Restore MongoDB from the latest full snapshot
#
# Usage:
#   ./backup/restore/restore-full.sh [OPTIONS]
#
# Options:
#   --help              Show this help message
#   --dry-run           Print commands without executing
#   --backup-name NAME  Specify backup name (default: latest)
#   --namespace NS      MongoDB namespace (default: mongodb)
#   --cluster NAME      Cluster name (default: mongodb-rs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
BACKUP_NAME=""
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
    --backup-name) BACKUP_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Precondition checks
# ──────────────────────────────────────────────

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

  # Verify cluster exists
  if ! kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    log "ERROR: PerconaServerMongoDB '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'"
    exit 3
  fi
}

# ──────────────────────────────────────────────
# Get latest backup name
# ──────────────────────────────────────────────

get_latest_backup() {
  if [ -n "${BACKUP_NAME}" ]; then
    log "Using specified backup: ${BACKUP_NAME}"
    return 0
  fi

  log "Finding latest completed backup..."
  BACKUP_NAME=$(kubectl get psmdb-backup -n "${NAMESPACE}" \
    -o json | jq -r '.items |
      map(select(.status.state == "ready")) |
      sort_by(.status.completed) |
      last |
      .metadata.name // empty')

  if [ -z "${BACKUP_NAME}" ]; then
    log "ERROR: No completed backups found in namespace '${NAMESPACE}'"
    exit 1
  fi

  log "Latest backup: ${BACKUP_NAME}"
}

# ──────────────────────────────────────────────
# Restore
# ──────────────────────────────────────────────

perform_restore() {
  log "Starting full restore from backup '${BACKUP_NAME}'..."

  # Create restore CR
  local restore_name="restore-$(date +%Y%m%d-%H%M%S)"

  run kubectl apply -f - <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: ${restore_name}
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  backupName: ${BACKUP_NAME}
EOF

  log "Restore CR '${restore_name}' created."
  log "Waiting for restore to complete..."

  run kubectl wait --for=jsonpath='{.status.state}'=ready \
    "psmdb-restore/${restore_name}" \
    -n "${NAMESPACE}" \
    --timeout=600s

  log "Restore completed successfully."
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
  log "=== MongoDB Full Restore ==="

  check_prerequisites
  get_latest_backup
  perform_restore
  validate_restore

  log "=== Full restore completed successfully ==="
}

main
