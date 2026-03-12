output "cluster_name" {
  description = "Name of the kind cluster"
  value       = kind_cluster.dbaas.name
}

output "kubeconfig" {
  description = "Path to kubeconfig file"
  value       = kind_cluster.dbaas.kubeconfig_path
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint"
  value       = kind_cluster.dbaas.endpoint
}

output "operator_namespace" {
  description = "Namespace where Percona operator is deployed"
  value       = module.percona_operator.namespace
}

output "monitoring_namespace" {
  description = "Namespace where observability stack is deployed"
  value       = var.deploy_observability ? module.observability[0].namespace : "N/A"
}
