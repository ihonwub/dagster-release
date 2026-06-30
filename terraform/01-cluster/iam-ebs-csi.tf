# EBS CSI driver identity via EKS Pod Identity (NOT IRSA).
#
# The role is assumed by the Pod Identity service principal, and the association
# maps it to kube-system/ebs-csi-controller-sa. The aws-ebs-csi-driver addon is
# declared here (standalone) with an explicit depends_on the association, so the
# controller never starts before it has credentials -- the exact deadlock that
# bit the manual bring-up (addon stuck CREATING, controller CrashLoop, role null).

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = { "created-by" = "dagster-platform", "env" = var.env }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# Standalone addon so it can depend on the association above.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
    module.eks, # ensure cluster + node groups exist for the controller/daemonset
  ]
}
