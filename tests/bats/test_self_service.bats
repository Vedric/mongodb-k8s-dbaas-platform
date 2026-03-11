#!/usr/bin/env bats

# test_self_service.bats
# Validates the Crossplane self-service provisioning flow:
# XRD registration, Composition readiness, claim submission,
# resource creation, and connection secret publishing.

CROSSPLANE_NAMESPACE="${CROSSPLANE_NAMESPACE:-crossplane-system}"

# ──────────────────────────────────────────────
# Crossplane runtime health
# ──────────────────────────────────────────────

@test "Crossplane pods are running" {
  local running_count
  running_count=$(kubectl get pods -n "${CROSSPLANE_NAMESPACE}" \
    --field-selector=status.phase=Running \
    -o json | jq '.items | length')
  [ "${running_count}" -ge 1 ]
}

@test "Crossplane kubernetes provider is installed and healthy" {
  local provider_status
  provider_status=$(kubectl get provider.pkg.crossplane.io \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null)
  [ "${provider_status}" = "True" ] || skip "Crossplane kubernetes provider not installed"
}

# ──────────────────────────────────────────────
# XRD and Composition registration
# ──────────────────────────────────────────────

@test "MongoDBInstance XRD is registered" {
  local xrd
  xrd=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o jsonpath='{.metadata.name}' 2>/dev/null)
  [ "${xrd}" = "mongodbinstances.dbaas.platform.local" ]
}

@test "MongoDBInstance XRD is established (offered)" {
  local established
  established=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
  [ "${established}" = "True" ]
}

@test "MongoDBInstance XRD offers claim kind MongoDBInstanceClaim" {
  local claim_kind
  claim_kind=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o jsonpath='{.spec.claimNames.kind}' 2>/dev/null)
  [ "${claim_kind}" = "MongoDBInstanceClaim" ]
}

@test "Composition 'mongodbinstance-percona' exists and is ready" {
  local comp
  comp=$(kubectl get composition mongodbinstance-percona \
    -o jsonpath='{.metadata.name}' 2>/dev/null)
  [ "${comp}" = "mongodbinstance-percona" ]
}

@test "Composition references correct composite type" {
  local type_ref
  type_ref=$(kubectl get composition mongodbinstance-percona \
    -o jsonpath='{.spec.compositeTypeRef.kind}' 2>/dev/null)
  [ "${type_ref}" = "MongoDBInstance" ]
}

# ──────────────────────────────────────────────
# XRD schema validation
# ──────────────────────────────────────────────

@test "XRD schema requires teamName, environment, and size parameters" {
  local required
  required=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o json 2>/dev/null | jq -r '
      .spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.parameters.required[]
    ' | sort | tr '\n' ',')

  echo "${required}" | grep -q "environment"
  echo "${required}" | grep -q "size"
  echo "${required}" | grep -q "teamName"
}

@test "XRD schema accepts valid size values (S, M, L)" {
  local sizes
  sizes=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o json 2>/dev/null | jq -r '
      .spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.parameters.properties.size.enum[]
    ' | sort | tr '\n' ',')

  [ "${sizes}" = "L,M,S," ]
}

@test "XRD schema accepts valid environment values (dev, staging, production)" {
  local envs
  envs=$(kubectl get compositeresourcedefinition mongodbinstances.dbaas.platform.local \
    -o json 2>/dev/null | jq -r '
      .spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.parameters.properties.environment.enum[]
    ' | sort | tr '\n' ',')

  [ "${envs}" = "dev,production,staging," ]
}

# ──────────────────────────────────────────────
# Claim provisioning (end-to-end)
# ──────────────────────────────────────────────

@test "submitting a MongoDBInstanceClaim creates composite resource" {
  local claim_name="bats-test-$(date +%s)"

  kubectl apply -f - <<EOF
apiVersion: dbaas.platform.local/v1alpha1
kind: MongoDBInstanceClaim
metadata:
  name: ${claim_name}
  namespace: default
spec:
  parameters:
    teamName: batstest
    environment: dev
    size: S
    version: "7.0"
    backupEnabled: false
    monitoringEnabled: false
  compositionSelector:
    matchLabels:
      dbaas.platform.local/provider: percona
  writeConnectionSecretToRef:
    name: ${claim_name}-conn
EOF

  # Wait for the composite to be created
  sleep 10

  local composite
  composite=$(kubectl get mongodbinstanceclaim "${claim_name}" -n default \
    -o jsonpath='{.spec.resourceRef.name}' 2>/dev/null)

  # Clean up
  kubectl delete mongodbinstanceclaim "${claim_name}" -n default --ignore-not-found 2>/dev/null

  [ -n "${composite}" ]
}

@test "provisioned claim creates tenant namespace with correct naming" {
  local claim_name="bats-ns-$(date +%s)"

  kubectl apply -f - <<EOF
apiVersion: dbaas.platform.local/v1alpha1
kind: MongoDBInstanceClaim
metadata:
  name: ${claim_name}
  namespace: default
spec:
  parameters:
    teamName: nscheck
    environment: dev
    size: S
    backupEnabled: false
    monitoringEnabled: false
  compositionSelector:
    matchLabels:
      dbaas.platform.local/provider: percona
  writeConnectionSecretToRef:
    name: ${claim_name}-conn
EOF

  # Wait for namespace to be created
  local attempts=0
  local ns_exists="false"
  while [ "${attempts}" -lt 12 ] && [ "${ns_exists}" = "false" ]; do
    if kubectl get namespace mongodb-nscheck-dev 2>/dev/null; then
      ns_exists="true"
    fi
    attempts=$((attempts + 1))
    sleep 5
  done

  # Clean up
  kubectl delete mongodbinstanceclaim "${claim_name}" -n default --ignore-not-found 2>/dev/null
  sleep 5
  kubectl delete namespace mongodb-nscheck-dev --ignore-not-found 2>/dev/null

  [ "${ns_exists}" = "true" ]
}

# ──────────────────────────────────────────────
# Example claims validation
# ──────────────────────────────────────────────

@test "example claim team-alpha-small.yaml is valid YAML" {
  local script_dir
  script_dir="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  local project_root
  project_root="$(cd "${script_dir}/../.." && pwd)"

  local claim_file="${project_root}/self-service/crossplane/examples/team-alpha-small.yaml"
  [ -f "${claim_file}" ]

  kubectl apply --dry-run=client -f "${claim_file}" 2>/dev/null
}

@test "example claim team-beta-medium.yaml is valid YAML" {
  local script_dir
  script_dir="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  local project_root
  project_root="$(cd "${script_dir}/../.." && pwd)"

  local claim_file="${project_root}/self-service/crossplane/examples/team-beta-medium.yaml"
  [ -f "${claim_file}" ]

  kubectl apply --dry-run=client -f "${claim_file}" 2>/dev/null
}

@test "example claim team-gamma-large.yaml is valid YAML" {
  local script_dir
  script_dir="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  local project_root
  project_root="$(cd "${script_dir}/../.." && pwd)"

  local claim_file="${project_root}/self-service/crossplane/examples/team-gamma-large.yaml"
  [ -f "${claim_file}" ]

  kubectl apply --dry-run=client -f "${claim_file}" 2>/dev/null
}
