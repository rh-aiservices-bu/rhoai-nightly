---
name: install-evalhub
description: Install Eval Hub (TrustyAI evaluation harness — EvalHub + MLflow + DSPA) on a connected RHOAI cluster. Settle-gated, orthogonal to MaaS and observability. Also handles uninstall.
argument-hint: "[--branch <branch>] [--uninstall] [--dry-run]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(cat *), Bash(grep *), Bash(git *), Bash(LOGDIR=*), Bash(GITOPS_BRANCH=*), Bash(GITOPS_REPO_URL=*), Bash(scripts/*), Bash(date *), Bash(tee *), Bash(jq *), AskUserQuestion, Skill(install-rhoai)
---

# Install Eval Hub on Connected RHOAI Cluster

Install Eval Hub — a TrustyAI evaluation harness layered on RHOAI — on a cluster that already has RHOAI. Eval Hub is **opt-in** (not part of `make all`) and **orthogonal** to MaaS and observability: turning it on or off does not touch the `instance-rhoai` overlay, so it composes freely with whatever else is installed.

It ships as a standalone `instance-evalhub` ArgoCD Application (not an `instance-rhoai` overlay flip), mirroring the `install-maas.sh` pattern: detect repo + branch from the live `instance-rhoai` Application, then create the Application pointed at `components/instances/evalhub/`.

## Arguments

Parse `$ARGUMENTS`:
- `--branch <branch>` — git branch for ArgoCD (sets `GITOPS_BRANCH`, inline — no YAML commits). Auto-detects from the live `instance-rhoai` Application if unset.
- `--uninstall` — delete the `instance-evalhub` Application (finalizer cascade-prunes EvalHub, MLflow, DSPA, and the `evalhub-tenant` ns + RBAC + Job).
- `--dry-run` — preview without applying (passes through to the script).

## Branch Detection

The script (`scripts/install-evalhub.sh`) auto-detects `repoURL` + `targetRevision` from the existing `instance-rhoai` Application — this is the source of truth on a running cluster. Only override when testing a feature branch that differs from what `instance-rhoai` already points at:

Priority: `--branch` → `.env` `GITOPS_BRANCH` → `instance-rhoai` Application's `targetRevision`.

Pass the branch inline (`GITOPS_BRANCH=<branch> make evalhub`) — do NOT mutate checked-in YAML for ephemeral test pointing. Log the detected branch before proceeding.

## Execution Model

### Log Directory

```bash
LOGDIR=.tmp/logs/evalhub-install-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

Pipe the make target to a log file AND run it in the background (`run_in_background: true`); the install waits ~3-5 min for the cascade. Monitor every 30-60s — don't poll faster, the script has its own wait loops.

```bash
make evalhub 2>&1 | tee $LOGDIR/evalhub-install.log
```

## Problem Tracking — Fix in Repo, Not on Cluster

Every unexpected symptom: capture in `$LOGDIR`, add a numbered entry to `.tmp/plans/install-gotchas.md` (symptom / detection / root cause / repo-side fix), prefer a committed repo fix over hand-patching the cluster, then re-run. Do not silently swallow errors.

## Instructions

Run from the repo root.

### Phase 0: Preflight + State Detection

```bash
oc whoami --show-server
oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "No RHOAI CSV"
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; echo
oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
oc get application.argoproj.io/instance-evalhub -n openshift-gitops 2>/dev/null || echo "instance-evalhub not present"
oc get evalhub,mlflow -n redhat-ods-applications 2>/dev/null
oc get dspa -n evalhub-tenant 2>/dev/null || echo "evalhub-tenant not present"
```

State machine:
- **RHOAI not installed** (no rhods CSV): ask to invoke `Skill(install-rhoai, "--branch <branch>")` first, then return here. Eval Hub needs the EvalHub/MLflow/DSPA CRDs, which only exist once RHOAI is reconciled.
- **No default StorageClass**: STOP — the settle-gate will refuse. MLflow (10Gi RWO PVC) and DSPA-managed MinIO both sit Pending without one. Report this to the user; do not try `make evalhub`.
- **RHOAI installed, eval-hub not**: proceed to Phase 1.
- **`instance-evalhub` already present**: report current state. Re-running is idempotent (`oc apply`); only re-run if the user wants to re-point a branch or repair.

Report cluster URL, RHOAI CSV, DSC Ready state, default StorageClass, and what will run.

### Phase 1: Install (or Uninstall)

**Install:**
```bash
GITOPS_BRANCH=<detected-branch> make evalhub 2>&1 | tee $LOGDIR/evalhub-install.log
```

`install-evalhub.sh` flow:
1. **Phase D** — detect repo URL + branch from `instance-rhoai`
2. **Phase S — settle-gate** (lighter than observability; no master-memory check): rhods-operator CSV Succeeded, DSC Ready + DSCI Available/not-Degraded, at least one default StorageClass. Refuses with a pointer if any fail — don't override, fix the condition.
3. **Phase A** — create the `instance-evalhub` Application (`oc apply`, idempotent, `resources-finalizer` for cascade delete)
4. **Phase W** — wait up to 600s for `EvalHub` phase=Ready + MLflow + DSPA + `evalhub-tenant` ns
5. **Phase V** — 120s pod-readiness check (eval-hub + mlflow pods in `redhat-ods-applications`; DSPA + MinIO pods in `evalhub-tenant`). Warn-only — the Application is already created by then.

Monitor:
```bash
oc get application.argoproj.io/instance-evalhub -n openshift-gitops
oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}'; echo
oc get pods -n redhat-ods-applications | grep -E 'evalhub|mlflow'
oc get pods -n evalhub-tenant
```

DSPA pods (MinIO, MariaDB, pipeline API server) take ~3-5 min on first install. CRDs being newly registered can leave the Application Degraded for a few minutes on a fresh cluster — ArgoCD retries.

**Uninstall:**
```bash
make evalhub-uninstall 2>&1 | tee $LOGDIR/evalhub-uninstall.log
```
Deletes the `instance-evalhub` Application; the `resources-finalizer.argocd.argoproj.io` cascade prunes EvalHub, MLflow, DSPA, and the `evalhub-tenant` ns + RBAC + Job (~30s).

### Phase 2: Verify

```bash
oc get evalhub,mlflow,dspa -A
oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}'; echo
oc get pods -n redhat-ods-applications | grep -E 'evalhub|mlflow'
oc get pods -n evalhub-tenant
oc get job update-secret-minio -n evalhub-tenant
oc get route -n evalhub-tenant
oc get application.argoproj.io/instance-evalhub -n openshift-gitops -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
```

Expected end-state:
- `EvalHub/evalhub` status.phase=Ready
- `MLflow/mlflow` present; eval-hub + mlflow pods Running in `redhat-ods-applications`
- `DSPA/dspa` reconciled; DSPA + MinIO + MariaDB + pipeline-server pods Running in `evalhub-tenant`
- `Job/update-secret-minio` Completed
- DSPA pipeline routes present in `evalhub-tenant`
- `instance-evalhub` Application Synced + Healthy

### Final Report

Summarize: cluster URL + RHOAI CSV; EvalHub/MLflow/DSPA Ready states; pod counts in both namespaces; hook Job status; DSPA routes; Application sync/health; any problems (with `.tmp/plans/install-gotchas.md` pointers + repo-side fix commits); log directory path.

If this run tested a feature branch, remind the user it's only ArgoCD-runtime-pointed — merge to `main` is still required for others.

## Common Mistakes

- **Running before RHOAI is installed** → EvalHub/MLflow/DSPA CRDs don't exist; the Application reports Degraded indefinitely. Install RHOAI first.
- **No default StorageClass** → settle-gate refuses (correctly). Set one: `oc patch storageclass <name> -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.
- **Expecting an `instance-rhoai` overlay flip** → there isn't one. Eval Hub is a standalone Application precisely so it stays orthogonal to the MaaS / observability overlay flips.
- **Overriding the branch unnecessarily** → the script reads it from `instance-rhoai`; only pass `--branch` when intentionally testing a different branch.
