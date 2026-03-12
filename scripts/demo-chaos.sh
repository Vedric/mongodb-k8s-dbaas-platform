#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# demo-chaos.sh - Full chaos engineering demo: kill primary, validate failover,
# verify recovery, and post Grafana annotations for visual timeline.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
SKIP_ANNOTATIONS="${SKIP_ANNOTATIONS:-false}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

annotate() {
  if [ "${SKIP_ANNOTATIONS}" = "true" ]; then
    return 0
  fi
  "${SCRIPT_DIR}/grafana-annotate.sh" \
    --url "${GRAFANA_URL}" \
    --tags "chaos,demo" \
    "$1" 2>/dev/null || true
}

get_admin_credentials() {
  local secret_name="${CLUSTER_NAME}-secrets"
  local user pass
  user=$(kubectl get secret "${secret_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_USER}' 2>/dev/null | base64 -d)
  pass=$(kubectl get secret "${secret_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -n "${user}" ] && [ -n "${pass}" ]; then
    echo "${user}:${pass}"
  fi
}

run_mongosh() {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  local creds
  creds=$(get_admin_credentials)
  if [ -n "${creds}" ]; then
    local user="${creds%%:*}"
    local pass="${creds#*:}"
    kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
      mongosh --quiet \
      -u "${user}" -p "${pass}" --authenticationDatabase admin \
      --eval "$1" 2>/dev/null
  else
    kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
      mongosh --quiet --eval "$1" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: Pre-chaos health check
# ---------------------------------------------------------------------------
log "========================================="
log "  MongoDB Chaos Engineering Demo"
log "========================================="
echo ""

log "Phase 1: Pre-chaos health check"
log "-----------------------------------------"

# Find current primary
PRIMARY_POD=""
for i in 0 1 2; do
  POD="${CLUSTER_NAME}-${RS_NAME}-${i}"
  STATE=$(kubectl exec "${POD}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet \
    -u "$(get_admin_credentials | cut -d: -f1)" \
    -p "$(get_admin_credentials | cut -d: -f2)" \
    --authenticationDatabase admin \
    --eval "rs.isMaster().ismaster" 2>/dev/null || echo "false")
  if [ "${STATE}" = "true" ]; then
    PRIMARY_POD="${POD}"
    log "  Current PRIMARY: ${POD}"
    break
  fi
done

if [ -z "${PRIMARY_POD}" ]; then
  log "ERROR: No primary found. Aborting."
  exit 1
fi

# Show current RS status
log "  Replica set members:"
for i in 0 1 2; do
  POD="${CLUSTER_NAME}-${RS_NAME}-${i}"
  READY=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  log "    ${POD}: Ready=${READY}"
done

DEMO_START=$(date +%s)
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Kill primary
# ---------------------------------------------------------------------------
log "Phase 2: Killing primary pod"
log "-----------------------------------------"

annotate "CHAOS START: Killing primary ${PRIMARY_POD}"
KILL_TIME=$(date +%s)

log "  Deleting pod: ${PRIMARY_POD}"
kubectl delete pod "${PRIMARY_POD}" -n "${NAMESPACE}" --grace-period=0 --force 2>/dev/null
log "  Primary pod deleted at $(date -u +%H:%M:%S)"

echo ""

# ---------------------------------------------------------------------------
# Phase 3: Wait for failover
# ---------------------------------------------------------------------------
log "Phase 3: Waiting for automatic failover"
log "-----------------------------------------"

FAILOVER_DETECTED=false
NEW_PRIMARY=""
for attempt in $(seq 1 30); do
  for i in 0 1 2; do
    POD="${CLUSTER_NAME}-${RS_NAME}-${i}"
    if [ "${POD}" = "${PRIMARY_POD}" ]; then
      continue
    fi
    STATE=$(kubectl exec "${POD}" -n "${NAMESPACE}" -c mongod -- \
      mongosh --quiet \
      -u "$(get_admin_credentials | cut -d: -f1)" \
      -p "$(get_admin_credentials | cut -d: -f2)" \
      --authenticationDatabase admin \
      --eval "rs.isMaster().ismaster" 2>/dev/null || echo "false")
    if [ "${STATE}" = "true" ]; then
      FAILOVER_TIME=$(date +%s)
      FAILOVER_DURATION=$((FAILOVER_TIME - KILL_TIME))
      NEW_PRIMARY="${POD}"
      FAILOVER_DETECTED=true
      log "  New PRIMARY elected: ${POD} (failover in ${FAILOVER_DURATION}s)"
      annotate "FAILOVER: New primary ${POD} elected in ${FAILOVER_DURATION}s"
      break 2
    fi
  done
  log "  Waiting for election... (attempt ${attempt}/30)"
  sleep 2
done

if [ "${FAILOVER_DETECTED}" = "false" ]; then
  log "ERROR: Failover not detected within 60s"
  annotate "CHAOS FAILED: No failover detected"
  exit 1
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 4: Wait for pod recovery
# ---------------------------------------------------------------------------
log "Phase 4: Waiting for killed pod to recover"
log "-----------------------------------------"

RECOVERY_DETECTED=false
for attempt in $(seq 1 60); do
  READY=$(kubectl get pod "${PRIMARY_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "${READY}" = "True" ]; then
    RECOVERY_TIME=$(date +%s)
    RECOVERY_DURATION=$((RECOVERY_TIME - KILL_TIME))
    RECOVERY_DETECTED=true
    log "  Pod ${PRIMARY_POD} recovered (total recovery: ${RECOVERY_DURATION}s)"
    annotate "RECOVERY: ${PRIMARY_POD} back online in ${RECOVERY_DURATION}s"
    break
  fi
  log "  Pod not ready yet... (attempt ${attempt}/60)"
  sleep 5
done

if [ "${RECOVERY_DETECTED}" = "false" ]; then
  log "WARNING: Pod did not recover within 300s"
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 5: Post-chaos validation
# ---------------------------------------------------------------------------
log "Phase 5: Post-chaos validation"
log "-----------------------------------------"

CHECKS_PASSED=0
CHECKS_FAILED=0

# Check all 3 pods ready
READY_COUNT=$(kubectl get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
  -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
if [ "${READY_COUNT}" -ge 3 ]; then
  log "  [PASS] All 3 pods are ready"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  log "  [FAIL] Only ${READY_COUNT}/3 pods ready"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check exactly 1 primary
PRIMARY_COUNT=$(run_mongosh "rs.status().members.filter(m => m.stateStr === 'PRIMARY').length" || echo "0")
if [ "${PRIMARY_COUNT}" = "1" ]; then
  log "  [PASS] Exactly 1 PRIMARY"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  log "  [FAIL] ${PRIMARY_COUNT} primaries detected"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check write concern majority
WRITE_RESULT=$(run_mongosh "db.getSiblingDB('chaos_test').recovery.insertOne({ts: new Date(), test: 'chaos-demo'}, {writeConcern: {w: 'majority', wtimeout: 5000}}).acknowledged" || echo "false")
if [ "${WRITE_RESULT}" = "true" ]; then
  log "  [PASS] Write concern majority succeeds"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  log "  [FAIL] Write concern majority failed"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check PSMDB status
PSMDB_STATE=$(kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
if [ "${PSMDB_STATE}" = "ready" ]; then
  log "  [PASS] PSMDB cluster state: ready"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  log "  [FAIL] PSMDB cluster state: ${PSMDB_STATE}"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

DEMO_END=$(date +%s)
TOTAL_DURATION=$((DEMO_END - DEMO_START))

echo ""
log "========================================="
log "  Chaos Demo Results"
log "========================================="
log "  Old primary:       ${PRIMARY_POD}"
log "  New primary:       ${NEW_PRIMARY:-N/A}"
log "  Failover time:     ${FAILOVER_DURATION:-N/A}s"
log "  Recovery time:     ${RECOVERY_DURATION:-N/A}s"
log "  Total duration:    ${TOTAL_DURATION}s"
log "  Checks passed:     ${CHECKS_PASSED}/4"
log "  Checks failed:     ${CHECKS_FAILED}/4"
log "========================================="

annotate "CHAOS COMPLETE: ${CHECKS_PASSED}/4 checks passed, failover in ${FAILOVER_DURATION:-N/A}s"

if [ "${CHECKS_FAILED}" -gt 0 ]; then
  exit 1
fi
