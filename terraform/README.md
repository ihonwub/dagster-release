# Terraform bring-up — EKS + Argo CD

Replaces the `eksctl` (`.scratch/cluster.yaml`) + manual `kubectl` runbook. Two
stages: `01-cluster` stands up the AWS substrate; `02-bootstrap` installs Argo CD
and hands off to the existing GitOps (`app-of-apps/`, `apps/*` are unchanged).

## Why two stages

Stage 02's `kubernetes`/`helm`/`kubectl` providers must point at a cluster that
**already exists**. Splitting the apply avoids the provider chicken-egg where those
providers try to initialise against a not-yet-created cluster.

## What this fixes vs the manual bring-up

- **Pod Identity, not IRSA** — no OIDC provider; the "cluster came up without OIDC
  → every IRSA role dead → EBS CSI deadlock" failure class is gone.
- **EBS CSI** gets credentials from a Pod Identity association created *with* the
  addon (`01-cluster/iam-ebs-csi.tf`) — never role-less, never CrashLooping.
- **gp3 default StorageClass** + gp2 demotion are declarative (`02-bootstrap`).
- **Argo CRDs** install via the Helm chart — no oversized-CRD `kubectl create`.
- **Teardown** removes everything Terraform owns — no orphaned OIDC provider.

## Prerequisites

- `terraform >= 1.5`, `aws` CLI, `kubectl`, AWS profile `iamgen`.
- Providers used: `hashicorp/aws`, `hashicorp/helm`, `hashicorp/kubernetes`,
  `gavinbunney/kubectl`.

## Apply

```bash
# Stage 1 — AWS substrate (VPC, EKS, addons, EBS CSI Pod Identity). ~15 min.
terraform -chdir=terraform/01-cluster init
terraform -chdir=terraform/01-cluster apply

# Point kubectl at the new cluster
aws eks update-kubeconfig --name dagster-tutorial --region us-west-2 --profile iamgen

# Stage 2 — Argo CD + day-1 objects + StorageClass. ~3 min.
terraform -chdir=terraform/02-bootstrap init
terraform -chdir=terraform/02-bootstrap apply
```

## Verify

```bash
# Substrate
kubectl get nodes                                  # 3 Ready
aws eks list-addons --cluster-name dagster-tutorial --region us-west-2 --profile iamgen
aws eks list-pod-identity-associations --cluster-name dagster-tutorial \
  --region us-west-2 --profile iamgen              # ebs-csi-controller-sa mapped
kubectl get pods -n kube-system | grep ebs-csi-controller   # 6/6 Running, no crashloop

# Bootstrap / GitOps
kubectl get sc                                     # gp3 (default), gp2 NOT default
kubectl get applications -n argocd                 # all Synced/Healthy, postgres binds on gp3
terraform -chdir=terraform/02-bootstrap output     # port-forward + admin-password commands
```

Then open the Dagster UI (port-forward from the output) — the `signals` location
loads and **Materialize All** succeeds.

## Teardown

```bash
# Release Argo-managed EBS volumes FIRST (not in TF state, so destroy won't).
kubectl delete ns dagster dagster-signals

terraform -chdir=terraform/02-bootstrap destroy
terraform -chdir=terraform/01-cluster destroy      # removes the cluster + IAM; nothing orphans
```

## Notes

- **State** is local for now. To go remote, uncomment the `backend "s3"` block in
  each stage's `versions.tf` and `terraform init -migrate-state`.
- **Argo CD is Terraform-owned.** Upgrade by bumping `argocd_chart_version` in
  `02-bootstrap` and re-applying. Letting Argo manage itself (negative sync-wave
  Application) is a deliberate future change, not done here.
- `eksctl` `cluster.yaml` + `storageclass-gp3.yaml` remain as a documented
  fallback path.
