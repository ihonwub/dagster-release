data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Three AZs, /16 split into private + public /20s.
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  vpc_cidr        = "10.42.0.0/16"
  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i)]     # 10.42.0/20, 16/20, 32/20
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i + 8)] # 10.42.128/20, ...
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT for cost; use one-per-AZ for real HA

  # Tags EKS needs to discover subnets for load balancers.
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  tags = {
    "created-by" = "dagster-platform"
    "env"        = var.env
  }
}
