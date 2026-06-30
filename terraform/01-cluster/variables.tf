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
  default     = "1.35"
}

variable "env" {
  description = "Environment label applied to the cluster (dev | preprod)."
  type        = string
  default     = "dev"
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
