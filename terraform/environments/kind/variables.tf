variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "mongodb-dbaas"
}

variable "kubernetes_version" {
  description = "Kubernetes version for kind nodes"
  type        = string
  default     = "v1.29.12"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "operator_namespace" {
  description = "Namespace for Percona operator"
  type        = string
  default     = "mongodb-operator"
}

variable "operator_chart_version" {
  description = "Percona operator Helm chart version"
  type        = string
  default     = "1.22.0"
}

variable "deploy_observability" {
  description = "Deploy kube-prometheus-stack"
  type        = bool
  default     = true
}

variable "monitoring_namespace" {
  description = "Namespace for monitoring stack"
  type        = string
  default     = "monitoring"
}
