variable "namespace" {
  description = "Namespace for the Percona operator"
  type        = string
  default     = "mongodb-operator"
}

variable "chart_version" {
  description = "Helm chart version for Percona operator"
  type        = string
  default     = "1.22.0"
}
