---
name: install-rhoai
description: Install RHOAI nightly on a connected OpenShift cluster. Runs the full make all workflow (ICSP, CPU/GPU nodes, pull-secret, GitOps, deploy, sync) with intelligent skip detection for already-completed phases.
argument-hint: "[--branch <branch>] [--skip-gpu] [--skip-cpu] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(LOGDIR=*), Bash(GITOPS_BRANCH=*)
---

# Install RHOAI on Connected Cluster

Run the full RHOAI nightly installation on a connected OpenShift cluster. This is equivalent to running `make all` (infra + secrets + gitops + deploy + sync), but with intelligent detection of already-completed phases.

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--branch <branch>` — git branch for ArgoCD to sync from (sets `GITOPS_BRANCH`). Default: `main`
- `--skip-gpu` — skip GPU MachineSet creation (`make gpu`)
- `--skip-cpu` — skip CPU MachineSet creation (`make cpu`)
- `--force` — run all phases even if they appear already completed

## Execution Model — Long-Running Commands

Many phases run scripts that wait for cluster resources (node restarts, machine provisioning, operator installs). These can take 5-20 minutes each.

### Log Directory

At the start of the install, create a timestamped log directory under `.tmp/logs/` (already gitignored):
```
LOGDIR=.tmp/logs/install-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```
Save ALL make target output there. This gives the user a persistent, browsable record for debugging.

### Rules for running make targets:

1. **Pipe make targets to log files AND run in the background.** For example:
   ```
   make icsp 2>&1 | tee $LOGDIR/phase1-icsp.log
   ```
   Use Bash `run_in_background: true` so Claude can continue monitoring. This applies to: `make icsp`, `make cpu`, `make gpu`, `make secrets`, `make gitops`, `make deploy`, `make sync`.

2. **Monitor background tasks** by checking their log files with `tail -50 $LOGDIR/phase<N>-<name>.log`. Check every 30-60 seconds.

3. **While a background task is running**, run monitoring commands in parallel to give the user visibility into cluster state. Useful monitoring commands by phase:
   - **ICSP**: `oc get mcp` (MachineConfigPool update progress), `oc get nodes` (node restart status)
   - **CPU/GPU**: `oc get machinesets -n openshift-machine-api`, `oc get machines -n openshift-machine-api`
   - **GitOps**: `oc get csv -n openshift-gitops-operator`, `oc get pods -n openshift-gitops`
   - **Deploy/Sync**: `oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`
   - **Operators**: `oc get csv -A | grep -E 'rhoai|nvidia|nfd|gitops|servicemesh'`

4. **Report progress to the user** after each monitoring check — don't just silently wait. Summarize what changed since the last check.

5. **Use timeout: 600000** (10 minutes) for any foreground commands that might take a while. Never use the default 2-minute timeout for make targets.

6. **Save monitoring snapshots** to the log directory — append timestamped cluster state to `$LOGDIR/monitoring.log` so there's a timeline of how the install progressed:
   ```
   echo "=== $(date) ===" >> $LOGDIR/monitoring.log
   oc get nodes >> $LOGDIR/monitoring.log 2>&1
   ```

7. **On failure**, tell the user the log file path so they can review the full output.

## Instructions

You MUST run this from the repository root.

Run each phase sequentially using `make` targets. After each phase, verify success before continuing. If any phase fails, STOP and ask the user how to proceed.

### Phase 0: Preflight — Cluster Assessment

First, verify cluster connection and assess what's already installed. Run ALL of these checks in parallel:

```
oc whoami --show-server
oc get clusterversion
oc get nodes
oc get imagecontentsourcepolicy 2>/dev/null || echo "No ICSP"
oc get machinesets -n openshift-machine-api
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' 2>/dev/null
oc get csv -n openshift-gitops-operator 2>/dev/null | grep gitops || echo "No GitOps operator"
oc get applications.argoproj.io -n openshift-gitops 2>/dev/null || echo "No ArgoCD apps"
oc get pods -n openshift-gitops 2>/dev/null || echo "No openshift-gitops namespace"
oc get datascienceclusters 2>/dev/null || echo "No DSC"
oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "No RHOAI CSV"
```

Based on the results, build a plan of which phases to run and which to skip. Report to the user:
- Cluster URL, OCP version, node count
- What's already installed vs what still needs to be done
- Which phases will be skipped and why

Unless `--force` was passed, skip any phase where the resources already exist and are healthy. The scripts themselves are idempotent, so re-running is safe — but skipping saves time on long waits (especially ICSP node restarts).

### Phase 1: ICSP (Registry Mirror)

**Skip if:** `oc get imagecontentsourcepolicy` shows an ICSP already exists and all nodes are Ready.

Run `make icsp` in the background. Monitor with `oc get mcp` and `oc get nodes` while waiting. The script waits for all nodes to come back Ready after MachineConfig update.

After completion, verify: `oc get nodes` — all nodes should be Ready.

### Phase 2: CPU Workers

**Skip if:** `--skip-cpu` was passed, or a CPU worker MachineSet already exists with Ready replicas in `oc get machinesets -n openshift-machine-api`.

Run `make cpu` in the background. Monitor with `oc get machinesets -n openshift-machine-api` and `oc get machines -n openshift-machine-api` while waiting.

After completion, verify: `oc get nodes -l node-role.kubernetes.io/worker` — at least one dedicated worker node Ready.

### Phase 3: GPU Workers

**Skip if:** `--skip-gpu` was passed, or a GPU MachineSet already exists with Ready replicas.

Run `make gpu` in the background. Monitor with `oc get machinesets -n openshift-machine-api` while waiting.

After completion, verify: `oc get nodes -l node-role.kubernetes.io/gpu` — GPU node Ready.

### Phase 4: Pull Secret

**Skip if:** pull-secret already contains `quay.io/rhoai` credentials (detected in Phase 0).

Run `make secrets` in the background (External Secrets mode can take a few minutes to install the operator and sync).

After completion, verify the pull-secret has quay.io/rhoai credentials:
```
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' | grep -c quay
```

### Phase 5: GitOps Operator + ArgoCD

**Skip if:** GitOps operator CSV exists and ArgoCD pods are Running in `openshift-gitops`.

Run `make gitops` in the background. Monitor with `oc get csv -n openshift-gitops-operator` and `oc get pods -n openshift-gitops` while waiting.

After completion, verify: `oc get pods -n openshift-gitops` — all pods Running/Ready.

### Phase 6: Deploy Apps

**Skip if:** ArgoCD Applications already exist AND are already pointed at the correct branch. If apps exist but point at wrong branch, run deploy anyway to re-patch them.

If a `--branch` was specified, export `GITOPS_BRANCH=<branch>` before running the deploy target.

Run: `GITOPS_BRANCH=<branch> make deploy` in the background. Monitor with `oc get applications.argoproj.io -n openshift-gitops` while waiting.

(If no branch specified, just run `make deploy` which defaults to `main`.)

The deploy script creates all ArgoCD Applications with sync DISABLED, patches them with the correct repo/branch, and waits for all apps to exist.

After completion, verify: `oc get applications.argoproj.io -n openshift-gitops` — all expected apps exist.

### Phase 7: Sync Apps

**Skip if:** All apps are already Synced + Healthy (rare on a fresh install).

Run `make sync` in the background. This is the longest phase (15-30 minutes). Monitor frequently with:
```
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Also monitor operator installs with:
```
oc get csv -A --no-headers 2>/dev/null | grep -v Succeeded || echo "All CSVs Succeeded"
```

Report progress to the user as apps transition from Unknown → Progressing → Healthy.

After completion, verify all apps are Synced + Healthy (some may show Progressing if operators are still installing).

### Phase 8: Validate

Run `make validate` to show final cluster state.

Then run these additional checks:
```
oc get catalogsource rhoai-catalog-nightly -n openshift-marketplace
oc get csv -n redhat-ods-operator | grep rhods
oc get datascienceclusters
```

### Final Report

Summarize the installation result:
- Cluster URL and OCP version
- Branch used for GitOps
- Number of nodes (masters, workers, GPU)
- ArgoCD app status (how many Synced+Healthy, any degraded)
- RHOAI operator CSV status
- DataScienceCluster status
- Any warnings or issues encountered
- Phases that were skipped (and why)
