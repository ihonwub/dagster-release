# Day-1 objects that hand control to GitOps. All depend on the Argo install so
# their CRDs exist. The kubectl provider applies these CRs without a plan-time
# CRD check (unlike kubernetes_manifest).

# 1. AppProject -- every Application references project: data-platform, so Argo
#    rejects the whole app-of-apps if this is missing.
resource "kubectl_manifest" "app_project" {
  depends_on = [helm_release.argocd]
  yaml_body  = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: data-platform
      namespace: argocd
    spec:
      description: Dagster data platform
      sourceRepos: ["*"]
      destinations:
        - { namespace: "*", server: "*" }
      clusterResourceWhitelist:
        - { group: "*", kind: "*" }
  YAML
}

# 2. Register the in-cluster API server with an `env` label. The bootstrap
#    ApplicationSet's cluster generator selects clusters by this label and uses
#    it to pick app-of-apps/values-<env>.yaml.
resource "kubectl_manifest" "in_cluster_secret" {
  depends_on = [helm_release.argocd]
  yaml_body  = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: in-cluster
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: cluster
        env: ${var.env}
    stringData:
      name: in-cluster
      server: https://kubernetes.default.svc
      config: '{"tlsClientConfig":{"insecure":false}}'
  YAML
}

# 3. The single imperative step from the old runbook, now declarative: apply the
#    bootstrap ApplicationSet straight from the committed file. After this, Argo
#    renders app-of-apps and the whole stack reconciles from git.
resource "kubectl_manifest" "root_appset" {
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.app_project,
    kubectl_manifest.in_cluster_secret,
  ]
  yaml_body = file("${path.module}/../../bootstrap/root-appset.yaml")
}
