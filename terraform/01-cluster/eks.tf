module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  # API auth mode + make the Terraform caller a cluster admin (so kubectl/the
  # 02-bootstrap providers can reach the cluster right after create).
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Pod Identity, not IRSA -- no OIDC provider is created. This removes the
  # entire failure class from the eksctl bring-up (cluster without OIDC -> every
  # IRSA role silently dead). Workload AWS identity comes from
  # aws_eks_pod_identity_association resources (see iam-ebs-csi.tf).
  enable_irsa = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Lightweight addons managed inline. The EBS CSI driver is intentionally NOT
  # here -- it is a standalone aws_eks_addon in iam-ebs-csi.tf so it can depend
  # on its Pod Identity association and never start without credentials.
  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
    vpc-cni = {
      before_compute = true # configure CNI before nodes join (prefix delegation)
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION          = "true"
          ENABLE_POD_ENI                    = "true"
          POD_SECURITY_GROUP_ENFORCING_MODE = "standard"
        }
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.large"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      labels         = { "workshop-default" = "yes" }
    }
  }
}
