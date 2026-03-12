# ---------------------------------------------------------------------------
# Percona Operator Module
# ---------------------------------------------------------------------------
# Deploys Percona Server for MongoDB Operator via Helm.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "operator" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "percona-operator"
      "app.kubernetes.io/part-of"    = "mongodb-dbaas-platform"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "operator_crds" {
  name       = "psmdb-operator-crds"
  repository = "https://percona.github.io/percona-helm-charts/"
  chart      = "psmdb-operator-crds"
  version    = var.chart_version
  namespace  = kubernetes_namespace.operator.metadata[0].name

  depends_on = [kubernetes_namespace.operator]
}

resource "helm_release" "operator" {
  name       = "psmdb-operator"
  repository = "https://percona.github.io/percona-helm-charts/"
  chart      = "psmdb-operator"
  version    = var.chart_version
  namespace  = kubernetes_namespace.operator.metadata[0].name

  values = [
    yamlencode({
      watchAllNamespaces = true
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          memory = "512Mi"
        }
      }
    })
  ]

  timeout = 120

  depends_on = [helm_release.operator_crds]
}
