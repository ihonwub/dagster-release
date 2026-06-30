# Argo CD itself is installed by Terraform -- the ONE thing that cannot be
# GitOps-managed at bootstrap, because nothing processes an Application/appset
# until Argo is already running. The argo-cd Helm chart bundles all CRDs
# (Application, ApplicationSet, AppProject), so there is no separate "kubectl
# create the oversized ApplicationSet CRD" step like the manual bring-up needed.
#
# Terraform OWNS this install. Argo manages workloads (app-of-apps), not itself.
# To upgrade Argo, bump var.argocd_chart_version and re-apply.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  # Keep the install lean; defaults are fine for a single-cluster control plane.
  # Add values here (e.g. ingress, SSO, HA) when needed.
}
