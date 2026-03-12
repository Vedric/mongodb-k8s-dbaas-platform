# 🚀 EKS Production Environment

## 📋 Overview

This directory contains a **reference skeleton** for deploying the MongoDB DBaaS Platform on AWS EKS. It demonstrates how the same Terraform modules used for local kind development can be reused for cloud production deployments.

## 🏗️ Architecture

```
AWS Region (eu-west-1)
├── VPC (10.0.0.0/16)
│   ├── Private Subnets (3 AZs) - EKS worker nodes
│   ├── Public Subnets (3 AZs) - Load balancers
│   └── NAT Gateways
├── EKS Cluster (v1.29)
│   ├── Managed Node Group: m6i.xlarge x3-6
│   ├── GP3 EBS volumes (100GB, 3000 IOPS)
│   └── Encrypted storage
├── Percona Operator (reuses modules/percona-operator)
└── Observability Stack (reuses modules/observability)
```

## 🔧 Prerequisites

- AWS CLI configured with appropriate credentials
- S3 bucket for Terraform state backend
- DynamoDB table for state locking

## 📖 Usage

1. Uncomment the desired sections in `main.tf`
2. Configure your AWS credentials and backend
3. Run:

```bash
terraform init
terraform plan
terraform apply
```

## 🔄 Module Reuse

The same `modules/percona-operator` and `modules/observability` modules used in the `kind` environment are reused here, demonstrating the portability of the Terraform module structure across environments.
