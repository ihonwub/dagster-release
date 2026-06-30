terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    # gavinbunney/kubectl applies CRs WITHOUT requiring the CRD at plan time --
    # essential for applying the Argo ApplicationSet in the same run that installs
    # Argo's CRDs. hashicorp/kubernetes_manifest does a plan-time dry-run and would
    # fail because the CRD does not exist yet.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  # backend "s3" { ... }   # see 01-cluster/versions.tf; use key = "02-bootstrap/terraform.tfstate"
}
