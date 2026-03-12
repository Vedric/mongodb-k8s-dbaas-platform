# ---------------------------------------------------------------------------
# Observability Module
# ---------------------------------------------------------------------------
# Deploys kube-prometheus-stack via Helm for monitoring and dashboards.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "observability"
      "app.kubernetes.io/part-of"    = "mongodb-dbaas-platform"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      grafana = {
        enabled       = true
        adminUser     = var.grafana_admin_user
        adminPassword = var.grafana_admin_password
        service = {
          type = "ClusterIP"
          port = 3000
        }
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { memory = "256Mi" }
        }
        sidecar = {
          dashboards = {
            enabled        = true
            label          = "grafana_dashboard"
            labelValue     = "1"
            searchNamespace = "ALL"
          }
        }
      }
      prometheus = {
        prometheusSpec = {
          retention       = var.prometheus_retention
          scrapeInterval  = "30s"
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues            = false
        }
      }
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          resources = {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }
      }
      nodeExporter = {
        enabled = true
      }
      kubeStateMetrics = {
        enabled = true
      }
      kubeProxy            = { enabled = false }
      kubeScheduler        = { enabled = false }
      kubeControllerManager = { enabled = false }
      kubeEtcd             = { enabled = false }
    })
  ]

  timeout = 300

  depends_on = [kubernetes_namespace.monitoring]
}
