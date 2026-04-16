---
name: install-rhoai
description: Install RHOAI nightly on a connected OpenShift cluster. Runs the full make all workflow (ICSP, CPU/GPU nodes, pull-secret, GitOps, deploy, sync) with intelligent skip detection for already-completed phases. Optionally installs MaaS with sample models.
argument-hint: "[--branch <branch>] [--skip-gpu] [--skip-cpu] [--skip-maas] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(cat *), Bash(grep *), Bash(LOGDIR=*), Bash(GITOPS_BRANCH=*), Bash(for *), Bash(date *), Bash(cp *), Bash(git *), Bash(sed *), AskUserQuestion, Skill(install-maas)
---

# Install RHOAI on Connected Cluster

Run the full RHOAI nightly installation on a connected OpenShift cluster. This is equivalent to running `make all` (infra + secrets + gitops + deploy + sync), but with intelligent detection of already-completed phases. After RHOAI is installed, optionally installs MaaS (Models as a Service) with sample models.

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--branch <branch>` — git branch for ArgoCD to sync from (sets `GITOPS_BRANCH`). If not specified, auto-detect (see below).
- `--skip-gpu` — skip GPU MachineSet creation (`make gpu`)
- `--skip-cpu` — skip CPU MachineSet creation (`make cpu`)
- `--skip-maas` — skip MaaS installation prompt at the end
- `--force` — run all phases even if they appear already completed

## Branch Detection

Determine the git branch to use, in priority order:
1. `--branch <branch>` argument (explicit override)
2. `GITOPS_BRANCH` from `.env` file
3. **Auto-detect from current git state**: `git branch --show-current` — use the current local branch
4. Fallback: `main`

Also detect the repo URL:
1. `GITOPS_REPO_URL` from `.env` file
2. **Auto-detect from git remote**: `git remote get-url origin`
3. Fallback: `https://github.com/rh-aiservices-bu/rhoai-nightly`

Log the detected branch and repo URL so the user can verify before proceeding.

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

### Phase 0: Configuration Check — .env Setup

Before anything else, check the `.env` file and confirm settings with the user.

**Step 1: Check if .env exists**

```bash
ls -la .env 2>/dev/null || echo "NO_ENV_FILE"
```

If `.env` does not exist, create it from the example:
```bash
cp .env.example .env
```

**Step 2: Read current .env and show configuration summary**

Read the `.env` file and present the user with a summary of current settings:

```
Configuration Summary:
  Credentials:   [Manual (QUAY_USER set) | External Secrets (no credentials) | Not configured]
  GitOps Branch:  [<branch from .env> | auto-detect: <current git branch>]
  GitOps Repo:    [<repo from .env> | auto-detect: <git remote origin>]
  GPU Nodes:      [<instance type> min=<min> max=<max> | defaults (g6e.2xlarge, 1-3)]
  CPU Workers:    [<instance type> min=<min> max=<max> | defaults (m6a.4xlarge, 1-3)]
  MaaS Models:    [<model list from .env> | default: all]
```

**Step 3: Ask if changes are needed**

Ask the user: "Does this configuration look correct? Would you like to change anything before proceeding?"

If the user wants changes, help them update `.env` accordingly. Key things they might want to change:
- **Credentials**: Set `QUAY_USER`/`QUAY_TOKEN` for manual mode, or leave empty for External Secrets
- **Branch/Repo**: Set `GITOPS_BRANCH` and `GITOPS_REPO_URL` if different from auto-detected values
- **GPU config**: Instance type, min/max replicas, availability zone
- **CPU config**: Instance type, min/max replicas
- **MaaS models**: Which models to deploy (simulator, gpt-oss-20b, granite-tiny-gpu)

Once confirmed, proceed to preflight.

### Phase 1: Preflight — Cluster Assessment

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

### Phase 2: ICSP (Registry Mirror)

**Skip if:** `oc get imagecontentsourcepolicy` shows an ICSP already exists and all nodes are Ready.

Run `make icsp` in the background. Monitor with `oc get mcp` and `oc get nodes` while waiting. The script waits for all nodes to come back Ready after MachineConfig update.

After completion, verify: `oc get nodes` — all nodes should be Ready.

### Phase 3: CPU Workers

**Skip if:** `--skip-cpu` was passed, or a CPU worker MachineSet already exists with Ready replicas in `oc get machinesets -n openshift-machine-api`.

Run `make cpu` in the background. Monitor with `oc get machinesets -n openshift-machine-api` and `oc get machines -n openshift-machine-api` while waiting.

After completion, verify: `oc get nodes -l node-role.kubernetes.io/worker` — at least one dedicated worker node Ready.

### Phase 4: GPU Workers

**Skip if:** `--skip-gpu` was passed, or a GPU MachineSet already exists with Ready replicas.

Run `make gpu` in the background. Monitor with `oc get machinesets -n openshift-machine-api` while waiting.

After completion, verify: `oc get nodes -l node-role.kubernetes.io/gpu` — GPU node Ready.

### Phase 5: Pull Secret

**Skip if:** pull-secret already contains `quay.io/rhoai` credentials (detected in Phase 0).

Run `make secrets` in the background (External Secrets mode can take a few minutes to install the operator and sync).

After completion, verify the pull-secret has quay.io/rhoai credentials:
```
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' | grep -c quay
```

### Phase 6: GitOps Operator + ArgoCD

**Skip if:** GitOps operator CSV exists and ArgoCD pods are Running in `openshift-gitops`.

Run `make gitops` in the background. Monitor with `oc get csv -n openshift-gitops-operator` and `oc get pods -n openshift-gitops` while waiting.

After completion, verify: `oc get pods -n openshift-gitops` — all pods Running/Ready.

### Phase 7: Deploy Apps

**Skip if:** ArgoCD Applications already exist AND are already pointed at the correct branch. If apps exist but point at wrong branch, run deploy anyway to re-patch them.

If a `--branch` was specified, export `GITOPS_BRANCH=<branch>` before running the deploy target.

Run: `GITOPS_BRANCH=<branch> make deploy` in the background. Monitor with `oc get applications.argoproj.io -n openshift-gitops` while waiting.

(If no branch specified, just run `make deploy` which defaults to `main`.)

The deploy script creates all ArgoCD Applications with sync DISABLED, patches them with the correct repo/branch, and waits for all apps to exist.

After completion, verify: `oc get applications.argoproj.io -n openshift-gitops` — all expected apps exist.

### Phase 8: Sync Apps

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

### Phase 9: Validate

Run `make validate` to show final cluster state.

Then run these additional checks:
```
oc get catalogsource rhoai-catalog-nightly -n openshift-marketplace
oc get csv -n redhat-ods-operator | grep rhods
oc get datascienceclusters
```

### Phase 10: MaaS (Models as a Service) — Optional

**Skip if:** `--skip-maas` was passed.

After RHOAI validation succeeds, ask the user:

> "RHOAI is installed and healthy. Would you like to install MaaS (Models as a Service) with sample models?"
>
> Available models (configured in .env `MAAS_MODELS`, default: all):
> - **simulator** — CPU-only mock (instant startup)
> - **gpt-oss-20b** — GPU, vLLM CUDA, 24Gi RAM
> - **granite-tiny-gpu** — GPU, vLLM CUDA, 64Gi RAM
>
> Options:
> 1. Yes, install MaaS with default models
> 2. Yes, but let me choose which models
> 3. No, skip MaaS

If the user chooses option 1 or 2:
- If option 2, ask which models they want and update `MAAS_MODELS` in `.env` accordingly
- Invoke `/install-maas` with the same branch: `Skill(install-maas, "--branch <detected-branch>")`
- The install-maas skill handles platform install, model deployment, and verification

If the user chooses option 3, skip and proceed to final report.

### Final Report

Summarize the installation result:
- Cluster URL and OCP version
- Branch used for GitOps
- Number of nodes (masters, workers, GPU)
- ArgoCD app status (how many Synced+Healthy, any degraded)
- RHOAI operator CSV status
- DataScienceCluster status
- MaaS status (installed/skipped, which models deployed, verification result)
- Any warnings or issues encountered
- Phases that were skipped (and why)
