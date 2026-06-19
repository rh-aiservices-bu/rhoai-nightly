# Eval Hub

Eval Hub is a [TrustyAI](https://trustyai.org/) evaluation harness layered on RHOAI:
an EvalHub controller plus MLflow for experiment tracking and a Data Science Pipelines
backend for running evaluation jobs.

It is **opt-in** — not part of `make all` — and **orthogonal** to MaaS and observability:
turning it on or off doesn't touch the `instance-rhoai` overlay, so it composes freely
with whatever else you have installed. It ships as its own `instance-evalhub` ArgoCD
Application (not an overlay flip).

## Prerequisites

- RHOAI installed and the DataScienceCluster `Ready` (see [Install with make](install-make.md)).
- **A default StorageClass.** MLflow and the pipelines MinIO each request an RWO PVC;
  without a default StorageClass they sit `Pending`. Check:
  ```bash
  oc get storageclass
  ```
- RHOAI **3.x nightly** — the `EvalHub`, `MLflow`, and DSPA CRDs only exist there. On a
  first install ArgoCD may briefly report `Degraded` for a few minutes while the CRDs
  register and resources reconcile.

## What gets deployed

All manifests live in `components/instances/evalhub/`.

| Component | Namespace | Description |
|-----------|-----------|-------------|
| `EvalHub/evalhub` | `redhat-ods-applications` | The TrustyAI evaluation controller |
| `MLflow/mlflow` | `redhat-ods-applications` | Experiment tracking, backed by a 10Gi RWO PVC |
| `DataSciencePipelinesApplication/dspa` | `evalhub-tenant` | Pipelines backend — brings up its own MinIO (with external route), MariaDB, and pipeline API server |
| `evalhub-tenant` namespace + RBAC | `evalhub-tenant` | Role + RoleBindings for the pipelines/eval jobs |
| `Job/update-secret-minio` | `evalhub-tenant` | Hook Job that points DSPA's S3 secret at the in-cluster MinIO |

> **Demo-grade posture.** DSPA enables `enableExternalRoute: true` and
> `podToPodTLS: false`, and the hook Job runs with a namespace-scoped `edit` role —
> fine for a demo rig, noted for awareness.

## Install

```bash
make evalhub
```

`scripts/install-evalhub.sh` detects the repo + branch from the live `instance-rhoai`
Application, then creates the `instance-evalhub` ArgoCD Application pointed at
`components/instances/evalhub/`. A lightweight **settle-gate** runs first (no
master-memory check — eval-hub adds ~5 worker pods, no control-plane cascade):

1. `rhods-operator` CSV `Succeeded`
2. DSC `Ready` / DSCI `Available`
3. At least one default StorageClass exists

It then waits up to ~600s for `EvalHub` to reach `status.phase=Ready` and for MLflow,
DSPA, and the `evalhub-tenant` namespace to come up, followed by a warn-only
pod-readiness check. Expect **~3–5 minutes** total.

From Claude Code: `/install-evalhub` (see [Install with Claude](install-claude.md)).

### Point at a feature branch

```bash
GITOPS_BRANCH=my-feature-branch make evalhub   # inline, no YAML commits
```

### Dry run

`make evalhub` doesn't forward flags, so call the script directly to preview:

```bash
scripts/install-evalhub.sh --dry-run
```

## Verify

```bash
oc get evalhub,mlflow,dspa -A
oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}'; echo
oc get pods -n redhat-ods-applications | grep -E 'evalhub|mlflow'
oc get pods -n evalhub-tenant
oc get job update-secret-minio -n evalhub-tenant     # hook Job completed
oc get route -n evalhub-tenant                       # pipeline / MinIO routes
oc get application.argoproj.io/instance-evalhub -n openshift-gitops
```

## Uninstall

```bash
make evalhub-uninstall
```

Deletes the `instance-evalhub` Application; the `resources-finalizer.argocd.argoproj.io`
finalizer cascade-prunes EvalHub, MLflow, DSPA, and the `evalhub-tenant` namespace +
RBAC + Job. From Claude Code: `/install-evalhub --uninstall`. See [Uninstall](uninstall.md).
