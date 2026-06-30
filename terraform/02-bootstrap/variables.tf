variable "region" {
  description = "AWS region the cluster lives in."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile to use."
  type        = string
  default     = "iamgen"
}

variable "cluster_name" {
  description = "EKS cluster name created by 01-cluster."
  type        = string
  default     = "dagster-tutorial"
}

variable "env" {
  description = "Environment label for the in-cluster Argo entry (dev | preprod)."
  type        = string
  default     = "dev"
}

variable "git_repo_url" {
  description = "Repo A URL the bootstrap ApplicationSet points at."
  type        = string
  default     = "https://github.com/ihonwub/dagster-release.git"
}

variable "project" {
  description = "Project name applied as a default tag to all resources."
  type        = string
  default     = "dagster-platform"
}

variable "owner_email" {
  description = "Owner email applied as a default tag to all resources."
  type        = string
  default     = "ioncloudjourney@gmail.com"
}

variable "argocd_chart_version" {
  description = "argo/argo-cd Helm chart version. Bump as needed; verify the latest at https://github.com/argoproj/argo-helm/releases."
  type        = string
  default     = "9.7.1"
}
