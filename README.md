# mde-gitops-manifests — Dagster on EKS (app-of-apps, self-service code locations)

GitOps for Dagster on EKS, deployed with a classic **app-of-apps** Argo CD pattern.

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
| -2 | `external-secrets.yaml` | `external-secrets/` | secrets operator (wraps upstream ESO) |
| -1 | `karpenter.yaml` | `karpenter/` | node autoscaler (wraps upstream Karpenter) |
| 0 | `reloader.yaml` | `reloader/` | rolls webserver/daemon on config change |
| 1 | `dagster-instance.yaml` | `dagster-instance/` | Dagster control plane (wraps official `dagster`) |
| 2 | `dagster-code-locations.yaml` | `dagster-code-locations/` | tenant ApplicationSet → one POD per team (**raw manifest**, not Helm) |
| 3 | `dagster-workspace.yaml` | `dagster-workspace/` | the workspace registry the control plane reads |

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
   = the code-server POD
```

Both read the **same** file, so it is the single source of truth, and
`CODEOWNERS` scopes each file to its team. Adding a location = drop a file.

## Two repos

- **Repo A (this repo)** — bootstrap, app-of-apps chart, all workload charts, the
  per-team location files.
- **Repo B (`dagster-code-location`, sibling folder)** — a versioned Helm wrapper
  around the official `dagster-user-deployments` chart + the per-location
  NetworkPolicy. Published to an OCI registry; consumed by Repo A's tenant
  ApplicationSet by version.

## Bring-up

1. `git init` this repo, push it, and set the real `repoURL` (currently the
   `github.com/org/...` placeholder, in `bootstrap/` and `app-of-apps/values-*`).
2. Label each cluster's Argo so the bootstrap appset knows its env (see the
   example Secret in [`bootstrap/root-appset.yaml`](bootstrap/root-appset.yaml)).
3. Publish Repo B's chart (see `../dagster-code-location/README.md`).
4. `kubectl apply -f bootstrap/root-appset.yaml` on each cluster. Argo does the rest.

## Verify before you ship

See [`dagster-plan.md`](dagster-plan.md) §11.
