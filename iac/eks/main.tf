terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "prefix" {
  type    = string
  default = "radius-e2e"
}

variable "github_repository" {
  description = "GitHub repository in 'owner/name' form, used for OIDC federation."
  type        = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "node_count" {
  type    = number
  default = 1
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Minimal VPC: two public subnets, no NAT (cheap; EKS managed nodes
# can use public subnets for this throwaway demo cluster).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.prefix}-vpc"
  cidr = "10.0.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.prefix}-eks"
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_count
      max_size       = var.node_count
      desired_size   = var.node_count

      subnet_ids = module.vpc.public_subnets
    }
  }

  # Give the OIDC IAM role full cluster admin access.
  access_entries = {
    gha = {
      principal_arn = aws_iam_role.gha.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

# OIDC federation for GitHub Actions.
#
# The GitHub Actions OIDC provider is account-scoped: AWS allows only one
# provider per URL per account. We look it up via a data source so this
# config plays nicely with accounts that already have it provisioned (from
# another repo, stack, or one-off setup). If the data source returns
# "no matching provider" on first apply, create it once with:
#
#   aws iam create-open-id-connect-provider \
#     --url https://token.actions.githubusercontent.com \
#     --client-id-list sts.amazonaws.com \
#     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
#
# (GitHub publishes the thumbprint; AWS also accepts any value here since
# OIDC discovery is used at verification time.) Then re-run terraform apply.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "gha_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Allow any branch / workflow_dispatch from this repo.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = "${var.prefix}-gha"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# eks:DescribeCluster + update-kubeconfig are sufficient for the
# workflow; the access entry above handles in-cluster RBAC.
resource "aws_iam_role_policy" "gha_eks" {
  name = "${var.prefix}-gha-eks"
  role = aws_iam_role.gha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

output "EKS_CLUSTER_NAME" {
  value = module.eks.cluster_name
}

output "AWS_REGION" {
  value = var.region
}

output "AWS_ROLE_ARN" {
  value = aws_iam_role.gha.arn
}
