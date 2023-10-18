provider "aws" {
  alias = "us"
  region = "us-west-2"
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available-us" {
  provider = aws.us
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name_us = "k8gb-eks-us-${random_string.suffix-us.result}"
}

resource "random_string" "suffix-us" {
  length  = 8
  special = false
}

module "vpc-us" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
  providers = {
    aws = aws.us
  }

  name = "k8gb-us-vpc"

  tags = {
    "expiration" = "24h"
    "owner" = "jimmi"
  }

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available-us.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_us}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_us}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks-us" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"
  providers = {
    aws = aws.us
  }

  cluster_name    = local.cluster_name_us
  cluster_version = "1.28"

  tags = {
    "expiration" = "24h"
    "owner" = "jimmi"
  }

  vpc_id                         = module.vpc-us.vpc_id
  subnet_ids                     = module.vpc-us.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }
}

module "iam_assumable_role_admin_us" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "4.6.0"
  create_role                   = true
  role_name                     = "external-dns-${module.eks-us.cluster_name}"
  provider_url                  = replace(module.eks-us.cluster_oidc_issuer_url, "https://", "")
  role_policy_arns              = [aws_iam_policy.external-dns-route53-us.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:k8gb:k8gb-external-dns"]
}

resource "aws_iam_policy" "external-dns-route53-us" {
  name        = "AllowExternalDNSUpdatesFor${module.eks-us.cluster_name}"
  description = "Enable external-dns to update Route53"
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/${data.aws_route53_zone.ksphere_platform.zone_id}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZones",
                "route53:ListResourceRecordSets"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF
}

output "cluster_endpoint_us" {
  description = "Endpoint for EKS control plane - US"
  value       = module.eks-us.cluster_endpoint
}

output "cluster_name_us" {
  description = "EKS cluster name - US"
  value       = module.eks-us.cluster_name
}

output "cluster_region_us" {
  description = "Region for EKS cluster - US"
  value       = "us-west-2"
}
