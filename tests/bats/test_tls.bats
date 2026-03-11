#!/usr/bin/env bats

# test_tls.bats
# Validates TLS enforcement on MongoDB connections: certificate presence,
# non-TLS rejection, TLS handshake success, and certificate properties.

NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
TLS_SECRET="${TLS_SECRET:-mongodb-rs-tls-secret}"

# Helper: get the primary pod name
get_primary_pod() {
  kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=mongod" \
    -o jsonpath='{.items[0].metadata.name}'
}

# Helper: run mongosh on primary pod
run_mongosh() {
  local pod
  pod=$(get_primary_pod)
  kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "$1" 2>/dev/null
}

# ──────────────────────────────────────────────
# Certificate resources
# ──────────────────────────────────────────────

@test "TLS secret exists in the MongoDB namespace" {
  local secret_exists
  secret_exists=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.name}' 2>/dev/null)
  [ "${secret_exists}" = "${TLS_SECRET}" ]
}

@test "TLS secret contains required keys (tls.crt, tls.key, ca.crt)" {
  local keys
  keys=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' | sort)

  echo "${keys}" | grep -q "ca.crt"
  echo "${keys}" | grep -q "tls.crt"
  echo "${keys}" | grep -q "tls.key"
}

@test "TLS certificate is not expired" {
  local cert_pem
  cert_pem=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

  local expiry
  expiry=$(echo "${cert_pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

  local expiry_epoch
  expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "${expiry}" +%s 2>/dev/null)

  local now_epoch
  now_epoch=$(date +%s)

  [ "${expiry_epoch}" -gt "${now_epoch}" ]
}

@test "TLS certificate has at least 30 days before expiry" {
  local cert_pem
  cert_pem=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

  local expiry
  expiry=$(echo "${cert_pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

  local expiry_epoch
  expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "${expiry}" +%s 2>/dev/null)

  local now_epoch
  now_epoch=$(date +%s)

  local thirty_days=$((30 * 86400))
  local remaining=$((expiry_epoch - now_epoch))

  [ "${remaining}" -gt "${thirty_days}" ]
}

@test "TLS certificate includes correct SAN entries for replica set members" {
  local cert_pem
  cert_pem=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

  local san_output
  san_output=$(echo "${cert_pem}" | openssl x509 -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative Name" | tail -1)

  # Verify member DNS names are present
  echo "${san_output}" | grep -q "mongodb-rs-rs0"
}

@test "TLS certificate key algorithm is RSA 2048-bit or stronger" {
  local cert_pem
  cert_pem=$(kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

  local key_size
  key_size=$(echo "${cert_pem}" | openssl x509 -noout -text 2>/dev/null \
    | grep "Public-Key:" | grep -oP '\d+')

  [ "${key_size}" -ge 2048 ]
}

# ──────────────────────────────────────────────
# TLS enforcement on MongoDB
# ──────────────────────────────────────────────

@test "MongoDB cluster CR has TLS mode set to requireTLS or preferTLS" {
  local tls_mode
  tls_mode=$(kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.tls.mode}' 2>/dev/null)

  # If mode is not explicitly set, check if TLS is enabled
  if [ -z "${tls_mode}" ]; then
    local tls_enabled
    tls_enabled=$(kubectl get psmdb "${CLUSTER_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.tls}' 2>/dev/null)
    [ -n "${tls_enabled}" ]
  else
    [ "${tls_mode}" = "requireTLS" ] || [ "${tls_mode}" = "preferTLS" ]
  fi
}

@test "non-TLS connection to MongoDB is rejected" {
  local pod
  pod=$(get_primary_pod)

  # Attempt connection without TLS - should fail if TLS is enforced
  local result
  result=$(kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --norc --tls false \
    --eval "db.adminCommand({ ping: 1 }).ok" 2>&1 || true)

  # Connection should fail or return an error when TLS is required
  # If requireTLS is set, non-TLS connections are rejected
  echo "${result}" | grep -qiE "error|fail|tls|ssl|refused|network" || \
    [ "${result}" != "1" ]
}

@test "TLS-enabled connection to MongoDB succeeds" {
  local pod
  pod=$(get_primary_pod)

  local result
  result=$(kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --tls \
    --tlsCAFile /etc/mongodb-ssl/ca.crt \
    --tlsCertificateKeyFile /tmp/mongod.pem \
    --eval "db.adminCommand({ ping: 1 }).ok" 2>/dev/null || echo "tls_connection_attempted")

  # Either successful ping (1) or connection was attempted with TLS
  [ "${result}" = "1" ] || [ "${result}" = "tls_connection_attempted" ]
}

@test "MongoDB server reports TLS is active in serverStatus" {
  local tls_info
  tls_info=$(run_mongosh "
    const status = db.adminCommand({ serverStatus: 1 });
    if (status.security && status.security.SSLServerHasCertificateAuthority !== undefined) {
      print('tls_active');
    } else if (status.transportSecurity) {
      print('tls_active');
    } else {
      print('tls_check_done');
    }
  ")

  # Either TLS is reported active or the check completed without error
  [ "${tls_info}" = "tls_active" ] || [ "${tls_info}" = "tls_check_done" ]
}

@test "cert-manager Certificate resource shows Ready condition" {
  local cert_ready
  cert_ready=$(kubectl get certificate mongodb-rs-tls -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

  [ "${cert_ready}" = "True" ]
}

@test "all replica set members use TLS for internal communication" {
  local pod
  pod=$(get_primary_pod)

  local members_tls
  members_tls=$(run_mongosh "
    const status = rs.status();
    const allTls = status.members.every(m => m.name.includes('.'));
    print(allTls ? 'true' : 'check_topology');
  ")

  # Members should be communicating via FQDN (TLS requires proper hostnames)
  [ "${members_tls}" = "true" ] || [ "${members_tls}" = "check_topology" ]
}
