provider "aws" {
  alias = "eu"
  region = "eu-west-1"
}

data "aws_availability_zones" "available-eu" {
  provider = aws.eu
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name_eu = "k8gb-eks-eu-${random_string.suffix-eu.result}"
}

resource "random_string" "suffix-eu" {
  length  = 8
  special = false
}

module "vpc-eu" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
  providers = {
    aws = aws.eu
  }

  name = "k8gb-eu-vpc"

  tags = {
    "expiration" = "24h"
    "owner" = "jimmi"
  }

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available-eu.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_eu}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_eu}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks-eu" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"
  providers = {
    aws = aws.eu
  }

  cluster_name    = local.cluster_name_eu
  cluster_version = "1.28"

  tags = {
    "expiration" = "24h"
    "owner" = "jimmi"
  }

  vpc_id                         = module.vpc-eu.vpc_id
  subnet_ids                     = module.vpc-eu.private_subnets
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

module "iam_assumable_role_admin_eu" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "4.6.0"
  create_role                   = true
  role_name                     = "external-dns-${module.eks-eu.cluster_name}"
  provider_url                  = replace(module.eks-eu.cluster_oidc_issuer_url, "https://", "")
  role_policy_arns              = [aws_iam_policy.external-dns-route53-eu.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:k8gb:k8gb-external-dns"]
}

resource "aws_iam_policy" "external-dns-route53-eu" {
  name        = "AllowExternalDNSUpdatesFor${module.eks-eu.cluster_name}"
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
                "arn:aws:route53:::hostedzone/${data.aws_route53_zone.demo_zone.zone_id}"
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

output "cluster_endpoint_eu" {
  description = "Endpoint for EKS control plane - EU"
  value       = module.eks-eu.cluster_endpoint
}

output "cluster_name_eu" {
  description = "EKS cluster name - EU"
  value       = module.eks-eu.cluster_name
}

output "cluster_region_eu" {
  description = "Region for EKS cluster - EU"
  value       = "eu-west-1"
}
