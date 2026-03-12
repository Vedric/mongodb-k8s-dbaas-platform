# 🏗️ Terraform Provisioning Guide

## 📋 Overview

The platform supports Infrastructure as Code (IaC) provisioning via Terraform. The module structure enables identical deployment patterns across local development (kind) and cloud production (EKS) environments.

## 📁 Directory Structure

```
terraform/
├── environments/
│   ├── kind/              # Local development cluster
│   │   ├── main.tf        # Kind cluster + modules
│   │   ├── variables.tf   # Configurable parameters
│   │   ├── outputs.tf     # Cluster info outputs
│   │   └── versions.tf    # Provider requirements
│   └── eks/               # AWS EKS reference skeleton
│       ├── main.tf        # VPC + EKS + modules (commented)
│       └── README.md
└── modules/
    ├── percona-operator/  # Percona Operator Helm deployment
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── observability/     # kube-prometheus-stack deployment
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## 🚀 Quick Start (kind)

```bash
cd terraform/environments/kind

# Initialize providers
terraform init

# Review the execution plan
terraform plan

# Provision the cluster
terraform apply

# View outputs
terraform output
```

## ⚙️ Configuration

Copy the example variables file and customize:

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | `mongodb-dbaas` | Kind cluster name |
| `kubernetes_version` | `v1.29.12` | K8s version |
| `worker_count` | `3` | Number of worker nodes |
| `deploy_observability` | `true` | Deploy kube-prometheus-stack |
| `operator_chart_version` | `1.22.0` | Percona Operator version |

## 🔄 Module Reuse

Both environments reuse the same modules:

```hcl
# kind environment
module "percona_operator" {
  source = "../../modules/percona-operator"
  # ...
}

# EKS environment (same module, different config)
module "percona_operator" {
  source = "../../modules/percona-operator"
  # ...
}
```

## 🗑️ Teardown

```bash
terraform destroy
```

## 🔐 State Management

- **Local (kind)**: State stored locally in `terraform.tfstate`
- **Production (EKS)**: State stored in S3 with DynamoDB locking

Add `.terraform/` and `*.tfstate*` to `.gitignore` to avoid committing sensitive state files.
