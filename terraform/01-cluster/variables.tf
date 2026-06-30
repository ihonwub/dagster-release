variable "region" {
  description = "AWS region for the cluster."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile to use."
  type        = string
  default     = "iamgen"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "dagster-tutorial"
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.33"
}

variable "env" {
  description = "Environment label applied to the cluster (dev | preprod)."
  type        = string
  default     = "dev"
}
