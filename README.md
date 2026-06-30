# dagster-release — Dagster on EKS (app-of-apps, self-service code locations)

GitOps for Dagster on EKS, deployed with a classic **app-of-apps** Argo CD pattern.
The cluster + Argo CD are provisioned by **Terraform** (`terraform/`); Argo CD then
reconciles everything below from this repo.

> New here? Read [`dagster-plan.md`](dagster-plan.md) first — it explains Dagster,
> Argo CD, and every piece of this repo in plain English. This README is the
> quick reference.

## The three layers

```
1. bootstrap/root-appset.yaml         ONE ApplicationSet, applied per cluster.
   (cluster generator)                Reads the cluster's `env` label, then renders ↓
        │
        ▼
2. app-of-apps/                        The "ArgoCD application" Helm chart.
   templates/<app>.yaml                ONE explicit `kind: Application` per app ↓
        │     (values-dev.yaml / values-preprod.yaml = env + on/off switches)
        ▼
3. apps/<app>/                         The ACTUAL workload charts. Each folder is a
                                       full Helm chart (wraps its upstream + our values).
```

Want to know what deploys X? Open `app-of-apps/templates/X.yaml` (the Application)
and `apps/X/` (the chart). No indirection.

## What's deployed, in sync-wave order

| Wave | App (`app-of-apps/templates/…`) | Chart (`apps/…`) | What it is |
|---|---|---|---|
| -2 | `external-secrets.yaml` | `external-secrets/` | secrets operator (wraps upstream ESO) — *off in dev* |
| -1 | `karpenter.yaml` | `karpenter/` | node autoscaler (wraps upstream Karpenter) — *off in dev* |
| 0 | `reloader.yaml` | `reloader/` | rolls webserver/daemon on config change |
| 1 | `dagster-instance.yaml` | `dagster-instance/` | Dagster control plane (wraps official `dagster`) |
| 2 | `dagster-code-locations.yaml` | `dagster-code-locations/` | tenant ApplicationSet → one POD per team (**raw manifest**, not Helm) |
| 3 | `dagster-workspace.yaml` | `dagster-workspace/` | the workspace registry the control plane reads |

> Per-env on/off switches live in `app-of-apps/values-<env>.yaml`. In `dev`,
> external-secrets and karpenter are disabled (bundled Postgres, static node group).

> `dagster-code-locations` is the one app that is a **raw manifest**, not a Helm
> chart: its body is itself Argo `{{ }}` templating, so Helm must not render it.
> Its Application uses a `directory` source. Everything else is a real chart.

## The one idea: per-team files have two consumers

A DS team writes **one** `apps/dagster-workspace/locations/<team>.yaml`. Two
things read it:

```
                 apps/dagster-workspace/locations/signals.yaml
                         /                              \
        (Argo git generator)                       (Helm .Files.Glob)
              /                                              \
   FAN-OUT: one App per team ->                  FAN-IN: all files -> ONE
   Repo B wrapper -> official                    workspace ConfigMap
   dagster-user-deployments chart                = the REGISTRY entry
   = the code-server POD (Service                (host derived from the same
    named after the file's `name`)                `name`, so the two agree)
```

A location file **is a standard upstream `dagster-user-deployments` deployment
entry** — teams write normal Dagster YAML (`name`, `port`, `dagsterApiGrpcArgs`,
`image`, `resources`, …); the platform wraps namespace/identity/NetworkPolicy/
registration around it. Both consumers read the **same** file, so it is the single
source of truth, and `CODEOWNERS` scopes each file to its team. Adding a location =
drop a file.

## Three repos

- **Repo A (this repo, `dagster-release`)** — bootstrap, app-of-apps chart, all
  workload charts, the per-team location files, and `terraform/` (cluster + Argo).
- **Repo B (`dagster-code-location`, sibling folder)** — a Helm wrapper around the
  official `dagster-user-deployments` chart + the per-location NetworkPolicy. Argo
  CD pulls it **straight from git** (the tenant ApplicationSet source points at the
  repo + path `.`); no OCI publish step.
- **Repo C (`dagster-signals`, sibling folder)** — an example DS-team repo: the
  Python assets, `requirements.txt`, and `Dockerfile` that build the code-server
  image referenced by `locations/signals.yaml`.

## Bring-up

The whole cluster + Argo CD + this GitOps stack comes up via Terraform —
**see [`terraform/README.md`](terraform/README.md)**:

```bash
terraform -chdir=terraform/01-cluster   apply   # VPC, EKS, addons, EBS CSI (Pod Identity)
terraform -chdir=terraform/02-bootstrap apply   # StorageClass, Argo CD, day-1 objects -> hand-off
```

Stage 02 installs Argo CD and applies `bootstrap/root-appset.yaml` for you; from
there Argo reconciles every app above. No manual `kubectl` runbook.

## Verify before you ship

See [`dagster-plan.md`](dagster-plan.md) §11.
