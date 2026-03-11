#!/usr/bin/env bash
set -euo pipefail

# teardown.sh - Destroy kind cluster and clean up all resources
#
# Usage:
#   ./scripts/teardown.sh [OPTIONS]
#
# Options:
#   --help        Show this help message
#   --dry-run     Print commands without executing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-mongodb-dbaas}"

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
    *) log "Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Teardown
# ──────────────────────────────────────────────

destroy_kind_cluster() {
  if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log "Kind cluster '${KIND_CLUSTER_NAME}' does not exist, nothing to destroy."
    return 0
  fi

  log "Destroying kind cluster '${KIND_CLUSTER_NAME}'..."
  run kind delete cluster --name "${KIND_CLUSTER_NAME}"
  log "Kind cluster destroyed."
}

cleanup_local_files() {
  log "Cleaning up local generated files..."
  run rm -rf "${SCRIPT_DIR}/../tmp/" "${SCRIPT_DIR}/../minio-data/"
  log "Cleanup complete."
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "Starting MongoDB DBaaS Platform teardown..."

  destroy_kind_cluster
  cleanup_local_files

  log "Teardown complete."
}

main
