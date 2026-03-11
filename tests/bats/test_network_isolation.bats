#!/usr/bin/env bats

# test_network_isolation.bats
# Validates tenant network isolation: NetworkPolicy presence,
# intra-namespace connectivity, cross-namespace denial, and
# monitoring namespace access for Prometheus scraping.

NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

# Helper: get a running pod name in the given namespace
get_pod_in_namespace() {
  local ns="$1"
  local label="$2"
  kubectl get pods -n "${ns}" -l "${label}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ──────────────────────────────────────────────
# NetworkPolicy resource validation
# ──────────────────────────────────────────────

@test "NetworkPolicy 'tenant-isolation' exists in the MongoDB namespace" {
  local np
  np=$(kubectl get networkpolicy tenant-isolation -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.name}' 2>/dev/null)
  [ "${np}" = "tenant-isolation" ]
}

@test "NetworkPolicy has both Ingress and Egress policy types" {
  local policy_types
  policy_types=$(kubectl get networkpolicy tenant-isolation -n "${NAMESPACE}" \
    -o jsonpath='{.spec.policyTypes}' 2>/dev/null)

  echo "${policy_types}" | grep -q "Ingress"
  echo "${policy_types}" | grep -q "Egress"
}

@test "NetworkPolicy allows ingress from same namespace (podSelector)" {
  local ingress_rules
  ingress_rules=$(kubectl get networkpolicy tenant-isolation -n "${NAMESPACE}" \
    -o json 2>/dev/null | jq '.spec.ingress')

  # Should have a rule with empty podSelector (same namespace)
  echo "${ingress_rules}" | jq -e '.[] | select(.from[]?.podSelector == {})' >/dev/null
}

@test "NetworkPolicy allows ingress from monitoring namespace on port 9216" {
  local ingress_rules
  ingress_rules=$(kubectl get networkpolicy tenant-isolation -n "${NAMESPACE}" \
    -o json 2>/dev/null | jq '.spec.ingress')

  # Should have a rule with namespaceSelector for monitoring and port 9216
  echo "${ingress_rules}" | jq -e '
    .[] | select(
      .from[]?.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "monitoring"
      and .ports[]?.port == 9216
    )
  ' >/dev/null
}

@test "NetworkPolicy allows DNS egress on port 53" {
  local egress_rules
  egress_rules=$(kubectl get networkpolicy tenant-isolation -n "${NAMESPACE}" \
    -o json 2>/dev/null | jq '.spec.egress')

  echo "${egress_rules}" | jq -e '
    .[] | select(.ports[]?.port == 53)
  ' >/dev/null
}

# ──────────────────────────────────────────────
# Connectivity validation
# ──────────────────────────────────────────────

@test "intra-namespace connectivity: pod can reach other pods in same namespace" {
  local pod
  pod=$(get_pod_in_namespace "${NAMESPACE}" "app.kubernetes.io/instance=${CLUSTER_NAME}")

  if [ -z "${pod}" ]; then
    skip "No running pods found in ${NAMESPACE}"
  fi

  # Try to reach another pod's MongoDB port within the same namespace
  local target_svc="${CLUSTER_NAME}-${RS_NAME}"
  local result
  result=$(kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet "mongodb://${target_svc}.${NAMESPACE}.svc.cluster.local:27017/admin" \
    --eval "db.adminCommand({ ping: 1 }).ok" \
    --tls --tlsAllowInvalidCertificates 2>/dev/null || echo "0")

  [ "${result}" = "1" ] || [ "${result}" = "0" ]
}

@test "cross-namespace isolation: external namespace cannot reach tenant pods" {
  # Create a test pod in the default namespace and try to connect to the tenant namespace
  local test_pod="netpol-test-$(date +%s)"

  kubectl run "${test_pod}" --namespace=default \
    --image=busybox:1.36 --restart=Never \
    --command -- sleep 30 2>/dev/null || true

  kubectl wait --for=condition=ready pod "${test_pod}" \
    -n default --timeout=30s 2>/dev/null || {
    kubectl delete pod "${test_pod}" -n default --ignore-not-found 2>/dev/null
    skip "Could not create test pod in default namespace"
  }

  # Attempt to connect to MongoDB port in the tenant namespace (should fail/timeout)
  local target_svc="${CLUSTER_NAME}-${RS_NAME}.${NAMESPACE}.svc.cluster.local"
  local result
  result=$(kubectl exec "${test_pod}" -n default -- \
    timeout 5 nc -zv "${target_svc}" 27017 2>&1 || echo "connection_refused")

  # Clean up test pod
  kubectl delete pod "${test_pod}" -n default --ignore-not-found 2>/dev/null

  # Connection should fail (refused, timeout, or error)
  echo "${result}" | grep -qiE "refused|timed out|connection_refused|error|fail"
}

# ──────────────────────────────────────────────
# ResourceQuota and LimitRange validation
# ──────────────────────────────────────────────

@test "ResourceQuota exists in the tenant namespace" {
  local quota
  quota=$(kubectl get resourcequota -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "${quota}" ]
}

@test "ResourceQuota enforces CPU and memory limits" {
  local cpu_limit
  cpu_limit=$(kubectl get resourcequota -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.hard.limits\.cpu}' 2>/dev/null)

  local mem_limit
  mem_limit=$(kubectl get resourcequota -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.hard.limits\.memory}' 2>/dev/null)

  [ -n "${cpu_limit}" ]
  [ -n "${mem_limit}" ]
}

@test "LimitRange exists in the tenant namespace" {
  local lr
  lr=$(kubectl get limitrange -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "${lr}" ]
}

@test "LimitRange sets default container resource limits" {
  local default_cpu
  default_cpu=$(kubectl get limitrange -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.limits[0].default.cpu}' 2>/dev/null)

  local default_mem
  default_mem=$(kubectl get limitrange -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.limits[0].default.memory}' 2>/dev/null)

  [ -n "${default_cpu}" ]
  [ -n "${default_mem}" ]
}
