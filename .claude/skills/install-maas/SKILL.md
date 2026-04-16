---
name: install-maas
description: Install MaaS (Models as a Service) on a connected RHOAI cluster. Installs the MaaS platform, deploys models, and runs verification.
argument-hint: "[--branch <branch>] [--models-only] [--verify-only] [--skip-models] [--skip-verify]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(cat *), Bash(git *), Bash(LOGDIR=*), Bash(MAAS_MODELS=*), Bash(scripts/*), Bash(date *), Bash(curl *), AskUserQuestion, Skill(install-rhoai)
---

# Install MaaS on Connected RHOAI Cluster

Install Models as a Service on an OpenShift cluster with RHOAI. This skill handles the full MaaS lifecycle:
1. Verify RHOAI is installed (offer to install if not)
2. Install MaaS platform (`make maas`)
3. Deploy models (`make maas-model`)
4. Verify the installation (`make maas-verify`)

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--branch <branch>` — git branch for ArgoCD to sync from. If not specified, auto-detect (see below).
- `--models-only` — skip platform install, only deploy models
- `--verify-only` — skip install and models, only run verification
- `--skip-models` — install platform but don't deploy models
- `--skip-verify` — skip the verification step

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

When calling `/install-rhoai`, pass the detected branch: `Skill(install-rhoai, "--branch <detected-branch>")`

## Execution Model — Long-Running Commands

### Log Directory

At the start of the install, create a log directory under `.tmp/logs/` (already gitignored):
```
LOGDIR=.tmp/logs/maas-install-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```
Save ALL command output there for debugging.

### Rules for running commands:

1. **Pipe commands to log files AND run in the background.** For example:
   ```
   make maas 2>&1 | tee $LOGDIR/phase2-platform.log
   ```
   Use Bash `run_in_background: true` so Claude can continue monitoring.

2. **Monitor background tasks** by reading their log files with `tail -50 $LOGDIR/<phase>.log`.

3. **While a background task is running**, run monitoring commands in parallel:
   - **Platform install**: `oc get application.argoproj.io/instance-maas -n openshift-gitops`, `oc get pods -n redhat-ods-applications | grep -E 'postgres|maas'`, `oc get gateway -n openshift-ingress`
   - **Model deploy**: `oc get pods -n llm`, `oc get llminferenceservice -n llm`, `oc get maasmodelref -n llm`
   - **Verification**: Read the log file for pass/fail status

4. **Report progress to the user** after each monitoring check.

5. **Use timeout: 600000** (10 minutes) for foreground commands. Never use the default 2-minute timeout.

6. **On failure**, tell the user the log file path.

## Instructions

You MUST run this from the repository root.

### Phase 0: Preflight — Verify RHOAI Installation

Run ALL of these checks in parallel:

```
oc whoami --show-server
oc get nodes
oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "No RHOAI CSV"
oc get datascienceclusters 2>/dev/null || echo "No DSC"
oc get applications.argoproj.io -n openshift-gitops 2>/dev/null || echo "No ArgoCD apps"
oc get authorino -n kuadrant-system 2>/dev/null || echo "No Authorino"
oc get pods -n redhat-ods-applications 2>/dev/null | grep -E 'maas-api|postgres' || echo "No MaaS components"
oc get llminferenceservice -A 2>/dev/null || echo "No models deployed"
```

Based on the results, determine the cluster state:

**State A: RHOAI not installed** (no RHOAI CSV, no DSC, no ArgoCD apps)
- Tell the user: "RHOAI is not installed on this cluster. MaaS requires RHOAI."
- Ask: "Would you like me to install RHOAI first? (This will run /install-rhoai)"
- If yes, invoke `Skill(install-rhoai)` with the appropriate branch argument
- After install-rhoai completes, continue to Phase 1

**State B: RHOAI installed but MaaS not installed** (RHOAI CSV exists, DSC exists, but no maas-api, no postgres, no instance-maas)
- Report what's installed
- Continue to Phase 1 (install MaaS platform)

**State C: MaaS platform installed but no models** (maas-api running, postgres running, but no LLMInferenceService)
- Report MaaS is installed
- If `--models-only` or no skip flags, continue to Phase 2 (deploy models)
- If `--verify-only`, skip to Phase 3

**State D: MaaS fully installed with models** (maas-api running, models deployed)
- Report everything is installed
- Unless `--skip-verify`, run Phase 3 (verification)
- If verification passes, report success and exit

Report to the user:
- Cluster URL, RHOAI version
- What's already installed vs what still needs to be done
- Which phases will be skipped and why

### Phase 1: Install MaaS Platform

**Skip if:** `--models-only` or `--verify-only`, or maas-api already running and healthy.

Run `make maas` in the background. Monitor with:
```
oc get application.argoproj.io/instance-maas -n openshift-gitops
oc get pods -n redhat-ods-applications | grep -E 'postgres|maas'
oc get gateway maas-default-gateway -n openshift-ingress
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")]}'
```

**Known issue — race condition:** If ModelsAsServiceReady shows "gateway not found" error, the install script now auto-detects this and triggers re-reconciliation. Monitor for this in the logs.

After completion, verify:
- `maas-api` deployment running
- `maas-controller` deployment running
- `postgres` deployment running
- Gateway Programmed=True
- ModelsAsServiceReady=True

### Phase 2: Deploy Models

**Skip if:** `--skip-models` or `--verify-only`.

**Step 1: Check GPU capabilities and MAAS_MODELS setting**

```bash
oc get nodes -l node-role.kubernetes.io/gpu -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null
oc get nodes -l node-role.kubernetes.io/gpu -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null
oc get nodes -l node-role.kubernetes.io/gpu --no-headers 2>/dev/null | wc -l
cat .env 2>/dev/null | grep MAAS_MODELS || echo "MAAS_MODELS not set"
```

**Step 2: If MAAS_MODELS is already set in .env**, use it as-is (user has already chosen).

**Step 3: If MAAS_MODELS is NOT set**, make a GPU-aware recommendation and ask:

**Rule: Deploy 1 GPU model per GPU node.** Pick the best model that fits.

| GPU Nodes | Allocatable RAM | Recommended Model |
|-----------|----------------|-------------------|
| 0 | — | No GPU model (simulator only for verify) |
| 1 | 60Gi+ (g6e.2xlarge, g5.4xlarge+) | **gpt-oss-20b** (16Gi request, 60Gi limit) |
| 1 | < 60Gi (g5.2xlarge ~30Gi) | **granite-tiny-gpu** (8Gi request, 24Gi limit) |
| 2+ | any | **gpt-oss-20b** on each node (or mix gpt-oss-20b + granite-tiny-gpu) |

Present the recommendation and let the user choose. Then update `MAAS_MODELS` in `.env` accordingly.

**Step 4: Deploy**

Run `make maas-model` in the background. Monitor with:
```
oc get pods -n llm
oc get llminferenceservice -n llm
oc get maasmodelref -n llm -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'
```

GPU models take 5-15 minutes (image pull + model loading). Report progress as pods transition through Init → Running → Ready.

After completion, verify:
- All LLMInferenceServices show Ready=True
- All MaaSModelRefs show phase=Ready
- All MaaSSubscriptions show phase=Active

### Phase 3: Verification

**Skip if:** `--skip-verify`.

Run `make maas-verify` in the background. This script:
1. Checks infrastructure health (7 checks)
2. Deploys a temporary simulator model
3. Tests API key creation, model listing, inference
4. Tests auth enforcement (401 without token)
5. Tests rate limiting (429 responses)
6. Cleans up temporary resources

Monitor the log for PASS/FAIL results.

After completion, report:
- Total passed / failed
- Any failures with details
- Note: verification uses its own temporary model and does NOT affect the models deployed in Phase 2

### Final Report

Summarize the installation result:
- Cluster URL
- MaaS API URL: `https://maas.<cluster-domain>/maas-api/v1/models`
- Dashboard URL for Gen AI studio
- Models deployed and their status
- Verification result (passed/failed count)
- Any warnings or issues encountered
- Log directory path
