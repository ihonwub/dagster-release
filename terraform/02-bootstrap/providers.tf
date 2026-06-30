provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      project    = var.project
      owner      = var.owner_email
      env        = var.env
      managed-by = "terraform"
    }
  }
}

# Point the in-cluster providers at the ALREADY-EXISTING cluster (created by
# 01-cluster). Looking it up by name via data sources -- rather than referencing
# 01's module outputs -- keeps this stage decoupled from 01's state file.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Short-lived token via exec auth, so credentials are never written to state.
locals {
  cluster_host = data.aws_eks_cluster.this.endpoint
  cluster_ca   = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec_args    = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region, "--profile", var.aws_profile]
}

provider "kubernetes" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}
