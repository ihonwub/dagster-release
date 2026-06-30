# Bring-Up Postmortem — Dagster on EKS (First Full Deploy)

This document captures every error hit during the first end-to-end bring-up of
the Dagster app-of-apps stack on a fresh EKS cluster, and the exact fix for
each. Read this before a second bring-up — most of these are avoidable with
the cluster.yaml and values fixes now in place.

---

## 1. eksctl too old to support Kubernetes 1.33

**Symptom:** `Error: invalid version, supported values: 1.23 ... 1.29`

**Root cause:** WSL had an old eksctl binary (< v0.180).

**Fix:**
```bash
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/eksctl
```

---

## 2. `${AWS_REGION}` / `${EKS_CLUSTER_NAME}` not substituted

**Symptom:** `checking AWS STS access — cannot get role ARN ... invalid input region ${AWS_REGION}`

**Root cause:** eksctl does NOT do shell variable substitution. The cluster.yaml
used `${VAR}` placeholders but the env vars were not exported before running.

**Fix:** Use `envsubst` to render the file first:
```bash
export AWS_REGION=us-west-2
export EKS_CLUSTER_NAME=dagster-tutorial
envsubst < .scratch/cluster.yaml | eksctl create cluster -f - --profile iamgen
```
Or bake the real values directly into cluster.yaml (done — see `.scratch/cluster.yaml`).

---

## 3. Argo CD ApplicationSet CRD too large for `kubectl apply`

**Symptom:** `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`

**Root cause:** `kubectl apply` stores the last-applied config in an annotation.
The ApplicationSet CRD's schema is large enough to exceed the 256 KB limit.

**Fix:** Use `kubectl create` (first time) or `kubectl replace` (if it exists):
```bash
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml -o /tmp/appset-crd.yaml
kubectl create -f /tmp/appset-crd.yaml 2>/dev/null || kubectl replace -f /tmp/appset-crd.yaml
```

---

## 4. No default StorageClass — Postgres PVC stuck Pending

**Symptom:** `dagster-instance-postgresql-0` stayed `Pending`. PVC event:
`pod has unbound immediate PersistentVolumeClaims`

**Root cause:** EKS ships with the `gp2` StorageClass but does NOT mark it as
default. The Postgres StatefulSet's PVC had no `storageClassName` set, so it
couldn't bind.

**Fix (immediate):**
```bash
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**Fix (permanent — now in cluster.yaml):** Add the EBS CSI driver addon and
a `gp2` default StorageClass so this never happens on a fresh cluster.

---

## 5. EBS CSI driver not installed — volumes never provisioned on EKS 1.33

**Symptom:** Even after marking `gp2` default, the in-tree `kubernetes.io/aws-ebs`
provisioner (used by the legacy `gp2` class) does not work on EKS 1.33+.

**Root cause:** The in-tree EBS provisioner was deprecated in Kubernetes 1.23 and
removed on newer EKS AMIs. EKS 1.33 requires the out-of-tree **EBS CSI driver**.

**Fix (immediate):**
```bash
# Create IRSA role for the CSI driver
# (see full commands in session transcript — creates dagster-tutorial-ebs-csi role)
aws eks create-addon \
  --cluster-name dagster-tutorial \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::381491911327:role/dagster-tutorial-ebs-csi \
  --region us-west-2 --profile iamgen
```

**Fix (permanent — now in cluster.yaml):** The `aws-ebs-csi-driver` addon is now
declared in cluster.yaml with `wellKnownPolicies.ebsCSIController: true` so
eksctl creates the IRSA role automatically.

---

## 6. Tenant ApplicationSet YAML parse errors from Go template syntax

Three separate errors in `apps/dagster-code-locations/applicationset.yaml`,
each from a different class of Go template syntax:

### 6a. Block-level `{{- if }}` / `{{- range }}` — broke raw YAML structure

**Symptom:** `yaml: line 91: could not find expected ':'`

**Root cause:** Argo's repo-server parses the ApplicationSet file as raw YAML
before applying it. Block-level Go template directives (`{{- if .envConfigMaps }}`,
`{{- range }}`) don't produce valid YAML when unrendered — they appear as stray
lines that break YAML indentation structure.

**Fix:** Remove block-level conditionals. Optional fields (`envConfigMaps`,
`resources`) can be added back once there's a solution that doesn't break raw
YAML (e.g. a separate overlay or Helm chart per location).

### 6b. Dotted Go template expressions parsed as YAML flow mappings

**Symptom:** `yaml: invalid map key: map[interface {}]interface {}{".image.repository":interface {}(nil)}`

**Root cause:** `{{ .image.repository }}` — the YAML parser sees `{` and
interprets the content as a flow mapping, treating `.image.repository` as a map
key with a null value. Same issue with `{{ .image.tag }}`, `{{ .image.pullPolicy }}`.

**Fix:** Switch `valuesObject` (parsed as YAML) to `values` (a block string):
```yaml
helm:
  values: |
    dagster-user-deployments:
      deployments:
        - image:
            repository: {{ .image.repository }}   # fine inside a string block
            port: {{ .port }}                      # renders as integer 4001
```
Inside a YAML block scalar (`|`), Go templates are just text — the parser never
sees them. Argo renders them as Go templates BEFORE passing to Helm.

### 6c. Integer `port` field quoted → Helm schema rejection

**Symptom:** `values don't meet the specifications of the schema: at '/deployments/0/port': got string, want integer`

**Root cause:** Quoting `port: "{{ .port }}"` made Helm receive `"4001"` (string)
but the chart schema declares `port` as integer. Switching to `values` block
string (fix 6b) resolved this — `{{ .port }}` renders to `4001` which Helm
parses as an integer from the values YAML.

---

## 7. Code-server pod: `secret "dagster-postgresql-secret" not found`

**Symptom:** `CreateContainerConfigError` — event: `Error: secret "dagster-postgresql-secret" not found`

**Root cause:** The `dagster-user-deployments` chart always injects
`DAGSTER_PG_PASSWORD` into every code-server pod via a `secretKeyRef` — UNLESS
`global.postgresqlAuthWifEnabled: true` is set. In the stock single-namespace
install the secret exists in the same namespace. In our split-namespace design
the secret is in `dagster` but the pod is in `dagster-signals`.

**Fix:** Add to the tenant ApplicationSet values:
```yaml
dagster-user-deployments:
  global:
    postgresqlAuthWifEnabled: true   # skip DAGSTER_PG_PASSWORD secret injection
```
The code-server pod doesn't need Postgres credentials — only run pods do, and
those are launched in the `dagster` namespace where the secret exists.

---

## 8. Wrong `dagster api grpc` flag — `--python-module` does not exist in 1.13.x

**Symptom:** Pod in `CrashLoopBackOff`. Logs: `Error: No such option '--python-module'. Did you mean '--python-file'?`

**Root cause:** The ApplicationSet passed `"--python-module"` as the gRPC arg, but
in Dagster 1.13.x the correct flag is `--module-name` (short: `-m`).

**Fix:**
```yaml
dagsterApiGrpcArgs:
  - "--module-name"        # was "--python-module"
  - {{ .module }}
```

Verify correct flags for any Dagster version:
```bash
docker run <image> dagster api grpc --help | grep -i module
```

---

## 9. Webserver not loading the workspace — "No code location"

**Symptom:** Dagster UI showed "No code locations" even though the `dagster-workspace`
ConfigMap was correct and the signals gRPC pod was running.

**Root cause (a):** `dagsterWebserver.workspace.enabled` was not set to `true`.
The `dagster.workspace.configmapName` Helm helper only returns the
`externalConfigmap` value when BOTH `enabled: true` AND `externalConfigmap` are
set. Without `enabled: true` the chart fell back to its own generated
`dagster-instance-workspace-yaml` ConfigMap, which contained `load_from: []`.

**Root cause (b):** The upstream chart's `workspace.servers` has a non-empty
default value (an example entry). When `enabled: true` and `externalConfigmap`
are set but `servers` is not explicitly cleared, the chart fails with:
`workspace.servers and workspace.externalConfigmap cannot both be set.`

**Fix:**
```yaml
dagsterWebserver:
  workspace:
    enabled: true
    servers: []                          # explicitly clear the default example entry
    externalConfigmap: dagster-workspace # our generated ConfigMap
```

---

## 10. Cluster created WITHOUT OIDC — every IRSA role dead on arrival

**Symptom:** EBS CSI addon stuck in `CREATING` forever; controller pods
`CrashLoopBackOff` with no AWS permissions; `eksctl create iamserviceaccount`
failed: `no IAM OIDC provider associated with cluster`.

**Root cause:** the running cluster was NOT created from our `cluster.yaml`
(which has `iam.withOIDC: true`). With OIDC disabled, IRSA cannot function —
`eks.amazonaws.com/role-arn` service-account annotations are silently inert. This
breaks the EBS CSI driver, the Dagster per-location roles, external-secrets, and
karpenter all at once. The EBS CSI addon entered a deadlock: it could not go
ACTIVE because the controller was unhealthy, the controller was unhealthy because
it had no role, and the role could not attach while the addon was `CREATING`.

**Fix (immediate):**
```bash
# 1. Enable OIDC on the existing cluster
eksctl utils associate-iam-oidc-provider \
  --cluster <name> --region us-west-2 --approve --profile iamgen

# 2. Create the CSI IRSA role (role-only)
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa --namespace kube-system \
  --cluster <name> --region us-west-2 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --role-name <name>-ebs-csi --role-only --approve --profile iamgen

# 3. The addon is wedged in CREATING -- delete and recreate WITH the role
aws eks delete-addon --cluster-name <name> --addon-name aws-ebs-csi-driver \
  --no-preserve --region us-west-2 --profile iamgen
# wait for full deletion, then:
aws eks create-addon --cluster-name <name> --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::<acct>:role/<name>-ebs-csi \
  --resolve-conflicts OVERWRITE --region us-west-2 --profile iamgen
```

**Fix (permanent):** Build the cluster FROM `.scratch/cluster.yaml` (has
`withOIDC: true`) and VERIFY it took before anything else:
```bash
aws eks describe-cluster --name <name> --region us-west-2 --profile iamgen \
  --query "cluster.identity.oidc.issuer" --output text   # must print an https URL
```

---

## 11. EBS CSI addon does not create a StorageClass — and `gp2` is the wrong one

**Symptom:** even with the CSI driver healthy, `gp2 (default)` still uses
provisioner `kubernetes.io/aws-ebs` (the removed in-tree one). PVCs that bind to
it never provision on EKS 1.23+.

**Root cause:** EKS pre-creates the legacy `gp2` StorageClass with the in-tree
provisioner. The `aws-ebs-csi-driver` addon installs the driver
(`ebs.csi.aws.com`) but does NOT create a StorageClass using it. eksctl's
ClusterConfig also cannot express a StorageClass.

**Fix:** apply a CSI-backed default class and demote `gp2`:
```bash
kubectl apply -f .scratch/storageclass-gp3.yaml          # gp3, ebs.csi.aws.com, default
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```
`storageclass-gp3.yaml` is the companion file that MUST be applied after every
cluster create — it can never live in the eksctl config.

---

## 12. Recreating Postgres → empty DB → webserver 500 `relation "instance_info" does not exist`

**Symptom:** after deleting/recreating the Postgres StatefulSet (e.g. to move it
onto `gp3`), the Dagster UI returned HTTP 500;
`psycopg2.errors.UndefinedTable: relation "instance_info" does not exist`.

**Root cause:** the new PVC is a fresh, empty database with no Dagster schema.
The webserver pod was older than the new Postgres, so it had started against the
OLD database and was now querying an empty one.

**Fix:** restart the Dagster components so they reconnect and initialize the
schema on the fresh DB:
```bash
kubectl rollout restart deployment/dagster-instance-dagster-webserver -n dagster
kubectl rollout restart deployment/dagster-instance-daemon -n dagster
```
Avoid entirely by building the cluster correctly the first time (EBS CSI + gp3
working from the start) so Postgres provisions once and is never recreated.

---

## Lessons for the next bring-up

1. **Use the updated `cluster.yaml`** — it now includes EBS CSI driver (with IRSA
   via `wellKnownPolicies`) and marks `gp2` as default. No manual patching needed.

2. **Install Argo CD CRDs separately if `kubectl apply` fails** — use
   `kubectl create` for the ApplicationSet CRD.

3. **The `AppProject` and in-cluster Secret must exist before the bootstrap
   ApplicationSet is applied** — otherwise every generated Application is
   immediately rejected by Argo.

4. **ApplicationSet Go templates in `valuesObject` will fail** — always use
   `helm.values` (block string) for ApplicationSet templates that contain
   Go expressions. `valuesObject` is parsed as YAML before rendering.

5. **Dagster workspace: three required values, not one** — `enabled: true`,
   `servers: []`, and `externalConfigmap: <name>` must all be set together.

6. **Verify OIDC is enabled FIRST** — before installing any addon or bootstrapping
   Argo, confirm `cluster.identity.oidc.issuer` is a real URL. Without it every
   IRSA role is dead and the EBS CSI addon deadlocks. This is the single highest-
   leverage pre-check.

7. **Apply `storageclass-gp3.yaml` after every cluster create** — the CSI addon
   does not bring a StorageClass and the eksctl config cannot hold one. The
   default `gp2` is the wrong (in-tree) provisioner until you demote it.

8. **Never recreate Postgres on a running instance unless you mean it** — a fresh
   PVC = empty schema = webserver 500s until the components restart. Get the
   cluster right the first time so Postgres provisions exactly once.
