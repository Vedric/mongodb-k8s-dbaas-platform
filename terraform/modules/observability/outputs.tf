output "namespace" {
  description = "Namespace where the observability stack is deployed"
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

output "grafana_service" {
  description = "Grafana service name for port-forwarding"
  value       = "kube-prometheus-stack-grafana"
}
