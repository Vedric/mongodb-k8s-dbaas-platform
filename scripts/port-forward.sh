#!/usr/bin/env bash
set -euo pipefail

# port-forward.sh - Port-forward platform services for local access
#
# Usage:
#   ./scripts/port-forward.sh [OPTIONS]
#
# Options:
#   --help        Show this help message
#   --dry-run     Print commands without executing
#
# Forwarded services:
#   MongoDB:  localhost:27017 -> mongodb-rs-rs0 (mongodb namespace)
#   Grafana:  localhost:3000  -> grafana (monitoring namespace)
#   MinIO:    localhost:9001  -> minio console (mongodb namespace)
#   Kafka:    localhost:9092  -> kafka bootstrap (kafka namespace)

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Port forwards
# ──────────────────────────────────────────────

PIDS=()

cleanup() {
  log "Stopping port-forwards..."
  for pid in "${PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  log "All port-forwards stopped."
}

trap cleanup EXIT INT TERM

forward_service() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"

  if kubectl get svc "${service}" -n "${namespace}" &>/dev/null; then
    log "Forwarding ${name}: localhost:${local_port} -> ${service}:${remote_port}"
    run kubectl port-forward "svc/${service}" "${local_port}:${remote_port}" \
      -n "${namespace}" &
    PIDS+=($!)
  else
    log "SKIP: ${name} service '${service}' not found in '${namespace}' namespace"
  fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "Starting port-forwards for platform services..."
  log ""

  forward_service "MongoDB"  "mongodb"          "mongodb-rs-rs0"                27017 27017
  forward_service "Grafana"  "monitoring"        "grafana"                        3000  3000
  forward_service "MinIO"    "mongodb"           "minio"                          9001  9001
  forward_service "Kafka"    "kafka"             "mongodb-cdc-kafka-bootstrap"    9092  9092

  log ""
  log "Services available at:"
  log "  MongoDB:  mongodb://localhost:27017"
  log "  Grafana:  http://localhost:3000"
  log "  MinIO:    http://localhost:9001"
  log "  Kafka:    localhost:9092"
  log ""
  log "Press Ctrl+C to stop all port-forwards."

  wait
}

main
