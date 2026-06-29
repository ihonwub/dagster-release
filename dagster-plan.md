# Dagster on EKS — App-of-Apps Implementation Plan

> Audience: someone new to Dagster, Argo CD, and Helm. This document explains
> **what we are building, why, and how the pieces connect**, then tracks the
> implementation. Read top to bottom once; after that the diagrams are the
> quick reference.

---

## 0. The 30-second summary

We run **Dagster** (a data-pipeline tool) on **Kubernetes (EKS)**. We deploy it
with **GitOps**: the desired state lives in Git, and **Argo CD** continuously
makes the cluster match Git. We use the **"app of apps"** pattern: one root
object in Git that, when applied, brings up *all* the platform pieces in the
right order — and later also Istio, External Secrets, etc.

The headline goal: **let each data-science (DS) team ship its own pipelines by
editing one small file, with zero involvement from the platform team.**

---

## 1. Dagster concepts in plain English

Dagster has two kinds of moving parts. Keep them separate in your head — the
whole design depends on it.

### The control plane (shared, platform-owned)
- **Webserver** — the UI you open in a browser. It shows pipelines and runs.
- **Daemon** — a background process that fires schedules and sensors and
  manages run queues.
- **Run launcher** — when a pipeline runs, it starts the actual work. We use the
  `K8sRunLauncher`: every run becomes its own Kubernetes **Job** (a throwaway
  pod). Karpenter/the cluster autoscaler gives it a node, the Job finishes, the
  pod goes away.

**The control plane contains NO user pipeline code.** It is generic. It does not
know what "the finance pipeline" is until it asks someone.

### A code location (per-team, DS-owned)
A **code location** is the unit of *user code*. Concretely it is **one long-lived
gRPC server** that has a team's pipeline code (`Definitions`: assets, jobs,
schedules, sensors) loaded inside it.

- On Kubernetes it is a **Deployment** (the gRPC server pod) plus a **Service**
  (a stable in-cluster DNS name so the control plane can reach it).
- The process inside is literally `dagster api grpc --python-module <module> -p <port>`.
- The webserver/daemon **connect over gRPC** to this server to (a) read the
  team's definitions for the UI and (b) launch runs. When a run launches, the
  run pod uses **the code location's image**, so it has the user code.

### The workspace (the phone book)
The webserver and daemon read one file, **`workspace.yaml`**. It is the
**registry / phone book** of code locations: for each location, a gRPC address
(host + port) and a name.

> If a location is **not** in the workspace, it does not exist to the instance —
> *even if its pod is running and healthy.* The pod is the phone; the workspace
> is the phone book. You need both.

### The one big idea
A team writes **one** file describing their location (name, port, image,
module). That single file feeds **two** consumers:

```
                 charts/dagster-workspace/locations/<team>.yaml
                         /                              \
        (Argo reads it)                                (Helm reads it)
              /                                              \
   FAN-OUT: make the POD                          FAN-IN: make the REGISTRY entry
   one Argo App per team ->                        glob ALL files -> one
   the dagster-user-deployments                    workspace.yaml ConfigMap that
   chart -> Deployment + Service                   the control plane reads
```

- **Fan-out** = "give this team a running gRPC server."
- **Fan-in** = "tell the shared instance that server exists."

Both read the **same** file, so the file is the single source of truth, and
`CODEOWNERS` scopes each file to its owning team.

---

## 2. Why two Git repos

| Repo | Owns | Who edits |
|---|---|---|
| **Repo A — `mde-gitops-manifests`** (this repo) | Cluster bootstrap, Dagster control plane, the workspace registry, the per-team location files | Platform team (DS teams send small PRs to their one location file) |
| **Repo B — `dagster-code-location`** (new) | A reusable, versioned Helm **wrapper chart** around Dagster's official `dagster-user-deployments` chart | Platform team publishes it; the tenant ApplicationSet in Repo A consumes it by version |

Why split: the control plane and the user-code *machinery* evolve on different
clocks. Repo B is a **product** (a pinned, tested chart) that Repo A consumes.
The per-team *data* (`locations/*.yaml`) stays in Repo A so the workspace
generator (Helm `.Files.Glob`, which can only read files inside its own chart)
keeps working. That preserves the single-source-of-truth property.

---

## 3. The official chart we wrap (and where it sits)

`dagster-user-deployments`
(https://artifacthub.io/packages/helm/dagster/dagster-user-deployments) is the
official chart that renders the **pod side** of a code location. Per entry in
its `deployments[]` list it creates exactly:

- **1 Deployment** — the gRPC code server (`image` + `dagsterApiGrpcArgs` + `port`)
- **1 Service** — stable DNS so the control plane can reach the gRPC port

It does NOT create a webserver, daemon, workspace, or NetworkPolicy.

Normally this chart is a **subchart of the main `dagster` chart** (instance +
code bundled, workspace auto-generated). We deliberately turn that off
(`dagster-user-deployments.enableSubchart: false` in the control-plane values)
so the control plane ships with **zero** user code. User code is installed
**separately**, once per team, through Repo B's wrapper. Layer chain:

```
Repo A · tenant ApplicationSet  (one Argo App per locations/<team>.yaml)
   |
   v
Repo B · dagster-code-location  (our wrapper chart, pinned + published)
   |   Chart.yaml depends on:
   v
OFFICIAL · dagster-user-deployments @ 1.11.7
   |   renders:
   v
Kubernetes (namespace dagster-<team>):
     Deployment dagster-loc-<team>   (gRPC server)
     Service    dagster-loc-<team>   (DNS for the control plane)
   + from the wrapper: ServiceAccount (IRSA) + NetworkPolicy
```

Two bugs the wrapper fixes for free:
1. **Service name must match the workspace host.** The workspace hardcodes host
   `dagster-loc-<name>`; the official chart names the Service after the
   `deployments[].name` you pass. The wrapper pins `name: dagster-loc-<name>` so
   the DNS always matches.
2. **NetworkPolicy race.** Moving the per-location NetworkPolicy into the wrapper
   means the *same* Argo App that creates the namespace also creates the
   NetworkPolicy — no cross-App ordering race, so we can drop the retry
   workaround the old workspace App needed.

---

## 4. Target layout — Repo A

```
mde-gitops-manifests/                       (this repo = project root)
├── dagster-plan.md                          <- this document
├── README.md
├── CODEOWNERS
├── .github/workflows/validate-locations.yaml
│
├── bootstrap/
│   └── root-appset.yaml                     LAYER 1: ONE ApplicationSet (cluster
│                                            generator). Applied to every cluster;
│                                            picks its env from the cluster's label.
│
├── app-of-apps/                             LAYER 2: the "ArgoCD application" chart
│   ├── Chart.yaml
│   ├── values-dev.yaml / values-preprod.yaml   env + per-app on/off switches
│   └── templates/                           ONE explicit `kind: Application` per app:
│       ├── external-secrets.yaml            (wave -2)
│       ├── karpenter.yaml                   (wave -1)
│       ├── reloader.yaml                    (wave 0)
│       ├── dagster-instance.yaml            (wave 1)
│       ├── dagster-code-locations.yaml      (wave 2, directory source)
│       └── dagster-workspace.yaml           (wave 3)
│
└── apps/                                     LAYER 3: the ACTUAL workload charts
    ├── external-secrets/                     wrapper -> upstream ESO
    ├── karpenter/                            wrapper -> upstream Karpenter
    ├── reloader/                             wrapper -> upstream Reloader
    ├── dagster-instance/                     wrapper -> official `dagster`
    │   ├── Chart.yaml + values-dev.yaml + values-preprod.yaml
    ├── dagster-code-locations/               RAW manifest (NOT Helm) — see note below
    │   └── applicationset.yaml               the tenant fan-out ApplicationSet
    └── dagster-workspace/                    custom chart: workspace registry + NOTES
        ├── locations/                        SOURCE OF TRUTH (CODEOWNED per file)
        │   ├── signals.yaml
        │   └── finance.yaml
        └── templates/workspace-configmap.yaml    THE GENERATOR (fan-in)
```

Every `apps/<app>/` is a full Helm chart **except** `dagster-code-locations`,
which is a raw manifest: its body is itself Argo `{{ }}` templating, so Helm must
not render it. Its Application (`app-of-apps/templates/dagster-code-locations.yaml`)
uses a `directory` source to apply the YAML verbatim.

---

## 5. The three layers (how app-of-apps works here)

**LAYER 1 — `bootstrap/root-appset.yaml`.** ONE ApplicationSet, identical on every
cluster. A **cluster generator** reads the `env` label off the cluster's Argo
entry and renders the app-of-apps chart with `values-<env>.yaml`. So the same
committed file picks dev on the dev cluster and preprod on preprod — you label
each cluster's in-cluster entry once (example Secret is in the file). That single
`kubectl apply` is the only imperative step.

**LAYER 2 — `app-of-apps/`.** A Helm chart whose templates are ArgoCD
`Application` objects — **one explicit file per app** under `templates/`. Each is
gated by a `.Values.<app>.enabled` switch, carries a sync-wave, and points at a
chart in `apps/` with `valueFiles: values-<env>.yaml`. See exactly what it makes:

```
helm template app-of-apps app-of-apps -f app-of-apps/values-dev.yaml
```

**LAYER 3 — `apps/<app>/`.** Each folder is a full Helm chart wrapping its
upstream chart plus our per-env values (the one exception is the raw
`dagster-code-locations` manifest, see §4).

**Sync-waves** reproduce the bring-up order automatically: external-secrets (-2),
karpenter (-1), reloader (0), dagster-instance (1), dagster-code-locations (2),
dagster-workspace (3).

---

## 6. Control-plane wrapper chart (`apps/dagster-instance`)

Instead of the old Argo "multi-source `$values`" trick, we make a tiny Helm
chart whose only job is to **depend on the official `dagster` chart** and supply
our values. Benefits: we can `helm template` it locally, pin the version in
`Chart.yaml`, and add our own resources later.

Gotcha to remember: when `dagster` is a **subchart**, all of its values must be
**nested under a top-level `dagster:` key** (and its own subchart becomes
`dagster.dagster-user-deployments`). `values-dev.yaml` / `values-preprod.yaml`
reflect that.

---

## 7. The workspace generator + code locations (the heart)

This is the cleverest part — read the heavy comments in
`apps/dagster-workspace/templates/workspace-configmap.yaml` and
`apps/dagster-code-locations/applicationset.yaml`. In short:

- **Fan-out** (`apps/dagster-code-locations/applicationset.yaml`): a second
  ApplicationSet (the *tenant* one) reads `locations/*.yaml` and makes one Argo
  App per team that installs Repo B's wrapper chart -> the team's gRPC pod.
- **Fan-in** (`apps/dagster-workspace/templates/workspace-configmap.yaml`): a Helm template globs the
  same `locations/*.yaml` and builds the single `workspace.yaml` ConfigMap. The
  gRPC address is **derived by convention** from the team name, so no human
  decision is needed:
  `host = dagster-loc-<name>.<namespacePrefix>-<name>.svc.cluster.local`.

Adding a location = drop a file. The tenant ApplicationSet makes the pod; the
workspace chart adds the registry entry; Reloader rolls the webserver/daemon so
they re-read the workspace. Zero central edits.

---

## 8. Repo B — `dagster-code-location` wrapper chart

Scaffolded as a **sibling folder** (`../dagster-code-location`) for review, to be
pushed to its own repo and published to an OCI registry (ECR).

```
dagster-code-location/
├── Chart.yaml                  depends on dagster-user-deployments @ 1.11.7
├── values.yaml                 sane defaults + the NetworkPolicy inputs
├── templates/networkpolicy.yaml   per-location ingress lockdown (moved from Repo A)
└── README.md                   the DS-team contract
```

Honest design note: a Helm wrapper **cannot template its subchart's values**
(Helm resolves subchart values before templating). So the friendly
"file fields -> `deployments[]`" mapping is done in the **tenant ApplicationSet**
(it builds `dagster-user-deployments.deployments` from each `locations/*.yaml`
and passes it to the wrapper). The wrapper's value-add is: pin the official
chart version, ship safe defaults, and add the NetworkPolicy.

---

## 9. Multi-environment (dev + preprod)

- Two **separate EKS clusters**, each with its **own Argo CD**.
- **One** bootstrap file (`bootstrap/root-appset.yaml`), identical on both
  clusters. A cluster generator reads the cluster's `env` label and selects
  `app-of-apps/values-<env>.yaml`; each app then loads its own `values-<env>.yaml`.
- You label each cluster's in-cluster Argo entry once (`env: dev` / `env: preprod`).
- Adding `prod` later = label a third cluster `env: prod` + add `values-prod.yaml`
  files; no new bootstrap file.

---

## 10. Execution checklist

- [x] **Phase 0 — hygiene:** flatten the triple-nested folders, delete the 3
      duplicate top-level files, remove orphan Zone.Identifier files.
- [x] **Phase 1 — control-plane wrapper chart:** `charts/dagster-instance`
      (`Chart.yaml` + `values-dev` + `values-preprod`); retired `platform/`.
      Verified: `helm template` renders the control plane with K8sRunLauncher,
      the Reloader annotations, and the external workspace ConfigMap wired.
- [x] **Phase 2 — true app-of-apps:** one `bootstrap/root-appset.yaml` (cluster
      generator) → `app-of-apps/` chart with **one explicit Application template
      per app** → workload charts in `apps/`. external-secrets + karpenter built
      as wrapper charts; istio dropped. Verified: the umbrella renders all six
      Applications with correct sync-waves and enable flags.
- [x] **Phase 3 — Repo B scaffold** (`../dagster-code-location`) incl. moved
      NetworkPolicy; tenant ApplicationSet points at it; netpol + retry removed
      from Repo A.
- [x] **Updated README + CODEOWNERS + CI** for the new layout (CI now lints/renders
      `apps/dagster-workspace`).

### Still requires YOU (cannot be done from here)
- [ ] `git init` the repo + push; replace the `github.com/org/...` placeholder
      `repoURL` in `bootstrap/root-appset.yaml` and `app-of-apps/values-*.yaml`.
- [ ] Label each cluster's in-cluster Argo entry (`env: dev` / `env: preprod`) so
      the bootstrap appset selects the right values (example Secret in the file).
- [ ] Publish Repo B's chart to your OCI registry and pin its `targetRevision`
      in `apps/dagster-code-locations/applicationset.yaml`.
- [ ] Fill the `# PIN` placeholders in the new wrapper charts (external-secrets
      role, karpenter clusterName/role/version).
- [ ] Wire RDS creds + Postgres secret (control plane and code-location globals).
- [ ] Run `helm template`/`argocd appset generate` against your real cluster
      version and walk the §11 verify list.

---

## 11. Verify before you ship (do not guess)

1. **Subchart values for your pinned `dagster` version** — confirm the workspace
   key and that CRDs/hooks render correctly when `dagster` is a subchart:
   `helm template apps/dagster-instance -f apps/dagster-instance/values-dev.yaml`.
2. **External workspace key** — `dagsterWebserver.workspace.externalConfigmap`
   has moved across chart versions:
   `helm show values dagster/dagster --version <ver> | grep -A 30 'workspace:'`.
3. **Reloader annotation placement** — must land on the webserver/daemon
   Deployments; if your version only exposes pod annotations, use a PostSync
   `kubectl rollout restart` hook.
4. **Code-server pod label** — the wrapper's NetworkPolicy selects
   `deployment: dagster-loc-<name>`; confirm the official chart's label key for
   your version (`kubectl -n dagster-signals get pod --show-labels`).
5. **AppProject scope** — the tenant Apps write into `dagster-*` namespaces;
   whitelist those destinations in the `data-platform` AppProject.
6. **Pin every chart version** (`dagster`, `dagster-user-deployments`,
   `reloader`) — placeholders are marked `# PIN`.
7. **Publish Repo B** to a registry before the tenant ApplicationSet can pull it
   (it is marked `# PUBLISH`).
8. **Repo is not yet its own Git repo** — `git init` the project root and set the
   real `repoURL` (currently the `github.com/org/...` placeholder) before Argo
   can sync from it.
