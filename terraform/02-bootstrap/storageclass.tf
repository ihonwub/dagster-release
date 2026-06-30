# A CSI-backed default StorageClass. EKS pre-creates a legacy `gp2` class using
# the REMOVED in-tree provisioner (kubernetes.io/aws-ebs) which cannot bind
# volumes on modern EKS. We add gp3 (ebs.csi.aws.com) as default and demote gp2.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer" # AZ-aware: bind when a pod schedules
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# Demote the EKS-managed gp2 so there is exactly one default. `force` lets us
# overwrite an annotation on an object Terraform does not own.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
}
