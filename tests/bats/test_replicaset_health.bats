#!/usr/bin/env bats

# test_replicaset_health.bats
# Validates MongoDB replica set health: member count, primary election,
# replication status, and pod readiness.

NAMESPACE="${MONGODB_NAMESPACE:-mongodb}"
CLUSTER_NAME="${MONGODB_CLUSTER:-mongodb-rs}"
RS_NAME="${MONGODB_RS_NAME:-rs0}"
EXPECTED_MEMBERS="${MONGODB_RS_MEMBERS:-3}"

# Helper: get MongoDB connection string from the cluster secret
get_connection_uri() {
  local secret_name="${CLUSTER_NAME}-${RS_NAME}-users"
  kubectl get secret "${secret_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_URI}' 2>/dev/null | base64 -d
}

# Helper: run mongosh command against the replica set
run_mongosh() {
  local uri
  uri=$(get_connection_uri)
  if [ -z "${uri}" ]; then
    # Fallback: connect via pod exec
    kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
      mongosh --quiet --eval "$1" 2>/dev/null
  else
    kubectl exec "${CLUSTER_NAME}-${RS_NAME}-0" -n "${NAMESPACE}" -c mongod -- \
      mongosh "${uri}" --quiet --eval "$1" 2>/dev/null
  fi
}

@test "replica set pods are running and ready" {
  local ready_count
  ready_count=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/replset=${RS_NAME}" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${ready_count}" -eq "${EXPECTED_MEMBERS}" ]
}

@test "replica set has exactly ${EXPECTED_MEMBERS} members" {
  local member_count
  member_count=$(run_mongosh "rs.status().members.length")
  [ "${member_count}" -eq "${EXPECTED_MEMBERS}" ]
}

@test "replica set has exactly one primary" {
  local primary_count
  primary_count=$(run_mongosh \
    "rs.status().members.filter(m => m.stateStr === 'PRIMARY').length")
  [ "${primary_count}" -eq 1 ]
}

@test "all secondaries are in SECONDARY state" {
  local secondary_count
  secondary_count=$(run_mongosh \
    "rs.status().members.filter(m => m.stateStr === 'SECONDARY').length")
  local expected_secondaries=$((EXPECTED_MEMBERS - 1))
  [ "${secondary_count}" -eq "${expected_secondaries}" ]
}

@test "replication lag is below 10 seconds" {
  local max_lag
  max_lag=$(run_mongosh "
    const status = rs.status();
    const primary = status.members.find(m => m.stateStr === 'PRIMARY');
    const maxLag = status.members
      .filter(m => m.stateStr === 'SECONDARY')
      .reduce((max, m) => {
        const lag = (primary.optimeDate - m.optimeDate) / 1000;
        return Math.max(max, lag);
      }, 0);
    print(maxLag);
  ")
  # max_lag should be less than 10 seconds
  [ "$(echo "${max_lag} < 10" | bc -l)" -eq 1 ]
}

@test "rs.status() reports healthy (ok: 1)" {
  local rs_ok
  rs_ok=$(run_mongosh "rs.status().ok")
  [ "${rs_ok}" -eq 1 ]
}

@test "all members have valid optime" {
  local invalid_count
  invalid_count=$(run_mongosh "
    const members = rs.status().members;
    const invalid = members.filter(m => !m.optime || !m.optime.ts);
    print(invalid.length);
  ")
  [ "${invalid_count}" -eq 0 ]
}

@test "write concern majority succeeds" {
  local result
  result=$(run_mongosh "
    try {
      db.getSiblingDB('test').healthcheck.insertOne(
        { ts: new Date(), test: 'replicaset_health' },
        { writeConcern: { w: 'majority', wtimeout: 5000 } }
      );
      print('ok');
    } catch(e) {
      print('error: ' + e.message);
    }
  ")
  [ "${result}" = "ok" ]
}
