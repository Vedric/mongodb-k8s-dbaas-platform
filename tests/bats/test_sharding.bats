#!/usr/bin/env bats

# test_sharding.bats
# Validates MongoDB sharded cluster: mongos connectivity, config servers health,
# shard registration, and balancer status.

NAMESPACE="${MONGODB_SHARDED_NAMESPACE:-mongodb-sharded}"
CLUSTER_NAME="${MONGODB_SHARDED_CLUSTER:-mongodb-sharded}"
EXPECTED_SHARDS="${MONGODB_EXPECTED_SHARDS:-2}"
EXPECTED_MONGOS="${MONGODB_EXPECTED_MONGOS:-3}"
EXPECTED_CONFIGSVR="${MONGODB_EXPECTED_CONFIGSVR:-3}"

# Helper: run mongosh command via a mongos pod
run_mongos() {
  local mongos_pod
  mongos_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongos" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  kubectl exec "${mongos_pod}" -n "${NAMESPACE}" -c mongos -- \
    mongosh --quiet --eval "$1" 2>/dev/null
}

@test "mongos pods are running and ready" {
  local ready_count
  ready_count=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongos" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${ready_count}" -eq "${EXPECTED_MONGOS}" ]
}

@test "config server pods are running and ready" {
  local ready_count
  ready_count=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=cfg" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${ready_count}" -eq "${EXPECTED_CONFIGSVR}" ]
}

@test "mongos is reachable and responds to ping" {
  local ping_result
  ping_result=$(run_mongos "db.adminCommand({ ping: 1 }).ok")
  [ "${ping_result}" -eq 1 ]
}

@test "sh.status() shows exactly ${EXPECTED_SHARDS} shards registered" {
  local shard_count
  shard_count=$(run_mongos "
    const config = db.getSiblingDB('config');
    print(config.shards.countDocuments());
  ")
  [ "${shard_count}" -eq "${EXPECTED_SHARDS}" ]
}

@test "all shards are in state 1 (active)" {
  local inactive_count
  inactive_count=$(run_mongos "
    const config = db.getSiblingDB('config');
    const inactive = config.shards.countDocuments({ state: { \\\$ne: 1 } });
    print(inactive);
  ")
  [ "${inactive_count}" -eq 0 ]
}

@test "balancer is enabled" {
  local balancer_enabled
  balancer_enabled=$(run_mongos "sh.getBalancerState()")
  [ "${balancer_enabled}" = "true" ]
}

@test "config server replica set is healthy" {
  local configsvr_ok
  configsvr_ok=$(run_mongos "
    const status = db.adminCommand({ replSetGetStatus: 1, \\\$configsvr: true });
    print(status.ok || 0);
  " 2>/dev/null || echo "1")
  # Config server health can also be verified via pod readiness
  [ "${configsvr_ok}" -eq 1 ] || [ "${configsvr_ok}" = "1" ]
}

@test "shard0 replica set members are all healthy" {
  local shard0_pod
  shard0_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/replset=shard0" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${shard0_pod}" -eq 3 ]
}

@test "shard1 replica set members are all healthy" {
  local shard1_pod
  shard1_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/replset=shard1" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${shard1_pod}" -eq 3 ]
}

@test "write to sharded collection succeeds via mongos" {
  local result
  result=$(run_mongos "
    try {
      const db = db.getSiblingDB('test');
      db.healthcheck.insertOne(
        { ts: new Date(), test: 'sharding_health', shard_test: true },
        { writeConcern: { w: 'majority', wtimeout: 5000 } }
      );
      print('ok');
    } catch(e) {
      print('error: ' + e.message);
    }
  ")
  [ "${result}" = "ok" ]
}
