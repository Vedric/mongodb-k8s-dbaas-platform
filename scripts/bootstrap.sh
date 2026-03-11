#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh - Create kind cluster and deploy the full MongoDB DBaaS platform
#
# Usage:
#   ./scripts/bootstrap.sh [OPTIONS]
#
# Options:
#   --help        Show this help message
#   --dry-run     Print commands without executing
#   --skip-operator   Skip operator installation
#   --skip-cluster    Skip MongoDB cluster deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-mongodb-dbaas}"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.28.13}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-mongodb-operator}"
MONGODB_NAMESPACE="${MONGODB_NAMESPACE:-mongodb}"
HELM_REPO_NAME="percona"
HELM_REPO_URL="https://percona.github.io/percona-helm-charts/"

DRY_RUN=false
SKIP_OPERATOR=false
SKIP_CLUSTER=false

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
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --skip-cluster) SKIP_CLUSTER=true; shift ;;
    *) log "Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Precondition checks
# ──────────────────────────────────────────────

check_prerequisites() {
  local missing=()
  for cmd in kind kubectl helm jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR: Missing required tools: ${missing[*]}"
    log "Install them before running this script."
    exit 3
  fi
}

# ──────────────────────────────────────────────
# Kind cluster
# ──────────────────────────────────────────────

create_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log "Kind cluster '${KIND_CLUSTER_NAME}' already exists, skipping creation."
    return 0
  fi

  log "Creating kind cluster '${KIND_CLUSTER_NAME}'..."
  run kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --image "${KIND_IMAGE}" \
    --config "${PROJECT_ROOT}/scripts/kind-config.yaml" \
    --wait 120s

  log "Kind cluster created successfully."
}

# ──────────────────────────────────────────────
# Operator deployment
# ──────────────────────────────────────────────

deploy_operator() {
  if [ "${SKIP_OPERATOR}" = true ]; then
    log "Skipping operator deployment (--skip-operator)."
    return 0
  fi

  log "Deploying Percona Server for MongoDB Operator..."

  # Create namespace
  run kubectl apply -k "${PROJECT_ROOT}/operator/"

  # Add Helm repo
  run helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" 2>/dev/null || true
  run helm repo update "${HELM_REPO_NAME}"

  # Install CRDs
  run helm upgrade --install psmdb-operator-crds "${HELM_REPO_NAME}/psmdb-operator-crds" \
    --namespace "${OPERATOR_NAMESPACE}"

  # Install operator
  run helm upgrade --install psmdb-operator "${HELM_REPO_NAME}/psmdb-operator" \
    --namespace "${OPERATOR_NAMESPACE}" \
    -f "${PROJECT_ROOT}/operator/percona-server-mongodb-operator/values.yaml" \
    --wait --timeout 120s

  log "Operator deployed successfully."
}

# ──────────────────────────────────────────────
# MongoDB cluster deployment
# ──────────────────────────────────────────────

deploy_mongodb_cluster() {
  if [ "${SKIP_CLUSTER}" = true ]; then
    log "Skipping MongoDB cluster deployment (--skip-cluster)."
    return 0
  fi

  log "Deploying MongoDB replica set..."

  # Create namespace and apply replica set resources
  run kubectl create namespace "${MONGODB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  run kubectl apply -k "${PROJECT_ROOT}/clusters/replicaset/"

  log "Waiting for replica set pods to become ready..."
  run kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/instance=mongodb-rs" \
    -n "${MONGODB_NAMESPACE}" \
    --timeout=300s 2>/dev/null || \
    log "WARNING: Timeout waiting for pods. They may still be initializing."

  log "MongoDB replica set deployment initiated."
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "Starting MongoDB DBaaS Platform bootstrap..."

  check_prerequisites
  create_kind_cluster
  deploy_operator
  deploy_mongodb_cluster

  log "Bootstrap complete."
  log ""
  log "Next steps:"
  log "  - Check cluster status: kubectl get psmdb -n ${MONGODB_NAMESPACE}"
  log "  - Run tests: make test"
  log "  - Load sample data: make seed-data"
  log "  - Port-forward services: make port-forward"
}

main
