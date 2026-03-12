# ---------------------------------------------------------------------------
# MongoDB DBaaS Platform - AWS EKS Production Environment
# ---------------------------------------------------------------------------
# This is a reference skeleton for deploying the platform on AWS EKS.
# Uncomment and configure sections as needed for your AWS environment.
# ---------------------------------------------------------------------------

# terraform {
#   required_version = ">= 1.5.0"
#
#   backend "s3" {
#     bucket         = "mongodb-dbaas-tfstate"
#     key            = "eks/terraform.tfstate"
#     region         = "eu-west-1"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
#
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#     kubernetes = {
#       source  = "hashicorp/kubernetes"
#       version = "~> 2.35"
#     }
#     helm = {
#       source  = "hashicorp/helm"
#       version = "~> 2.17"
#     }
#   }
# }

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
# module "vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "~> 5.0"
#
#   name = "mongodb-dbaas-vpc"
#   cidr = "10.0.0.0/16"
#
#   azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
#   private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
#   public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
#
#   enable_nat_gateway   = true
#   single_nat_gateway   = false
#   enable_dns_hostnames = true
#
#   tags = {
#     Environment = "production"
#     Project     = "mongodb-dbaas-platform"
#     ManagedBy   = "terraform"
#   }
# }

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------
# module "eks" {
#   source  = "terraform-aws-modules/eks/aws"
#   version = "~> 20.0"
#
#   cluster_name    = "mongodb-dbaas"
#   cluster_version = "1.29"
#
#   vpc_id     = module.vpc.vpc_id
#   subnet_ids = module.vpc.private_subnets
#
#   cluster_endpoint_public_access = true
#
#   eks_managed_node_groups = {
#     mongodb = {
#       name           = "mongodb-workers"
#       instance_types = ["m6i.xlarge"]
#       min_size       = 3
#       max_size       = 6
#       desired_size   = 3
#
#       labels = {
#         role    = "mongodb"
#         project = "mongodb-dbaas-platform"
#       }
#
#       # GP3 storage for MongoDB data
#       block_device_mappings = {
#         xvda = {
#           device_name = "/dev/xvda"
#           ebs = {
#             volume_size = 100
#             volume_type = "gp3"
#             iops        = 3000
#             throughput  = 125
#             encrypted   = true
#           }
#         }
#       }
#     }
#   }
#
#   tags = {
#     Environment = "production"
#     Project     = "mongodb-dbaas-platform"
#     ManagedBy   = "terraform"
#   }
# }

# ---------------------------------------------------------------------------
# Percona Operator (reuses the same module as kind)
# ---------------------------------------------------------------------------
# module "percona_operator" {
#   source = "../../modules/percona-operator"
#
#   namespace     = "mongodb-operator"
#   chart_version = "1.22.0"
#
#   depends_on = [module.eks]
# }

# ---------------------------------------------------------------------------
# Observability Stack (reuses the same module as kind)
# ---------------------------------------------------------------------------
# module "observability" {
#   source = "../../modules/observability"
#
#   namespace              = "monitoring"
#   prometheus_retention   = "15d"
#   grafana_admin_password = var.grafana_admin_password
#
#   depends_on = [module.eks]
# }
