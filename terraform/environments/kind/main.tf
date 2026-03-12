# ---------------------------------------------------------------------------
# MongoDB DBaaS Platform - kind Development Environment
# ---------------------------------------------------------------------------
# Provisions a local kind cluster with Percona operator and optional
# observability stack via Terraform.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Kind cluster
# ---------------------------------------------------------------------------
resource "kind_cluster" "dbaas" {
  name            = var.cluster_name
  node_image      = "kindest/node:${var.kubernetes_version}"
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      kubeadm_config_patches = [
        <<-PATCH
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        PATCH
      ]
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes and Helm providers (configured after cluster creation)
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = kind_cluster.dbaas.endpoint
  cluster_ca_certificate = kind_cluster.dbaas.cluster_ca_certificate
  client_certificate     = kind_cluster.dbaas.client_certificate
  client_key             = kind_cluster.dbaas.client_key
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.dbaas.endpoint
    cluster_ca_certificate = kind_cluster.dbaas.cluster_ca_certificate
    client_certificate     = kind_cluster.dbaas.client_certificate
    client_key             = kind_cluster.dbaas.client_key
  }
}

# ---------------------------------------------------------------------------
# Percona operator
# ---------------------------------------------------------------------------
module "percona_operator" {
  source = "../../modules/percona-operator"

  namespace     = var.operator_namespace
  chart_version = var.operator_chart_version

  depends_on = [kind_cluster.dbaas]
}

# ---------------------------------------------------------------------------
# Observability stack (optional)
# ---------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"
  count  = var.deploy_observability ? 1 : 0

  namespace = var.monitoring_namespace

  depends_on = [kind_cluster.dbaas]
}
