output "namespace" {
  description = "Namespace where the operator is deployed"
  value       = kubernetes_namespace.operator.metadata[0].name
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.operator.name
}
