output "cluster_name" {
  description = "EKS cluster name (feed to 02-bootstrap)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN backing the EBS CSI driver (via Pod Identity)."
  value       = aws_iam_role.ebs_csi.arn
}
