---
name: install-rhoai
description: Install RHOAI nightly on a connected OpenShift cluster. Runs the full make all workflow (ICSP, CPU/GPU nodes, UWM, pull-secret, GitOps, deploy, sync) with intelligent skip detection for already-completed phases. Optionally installs MaaS + observability with GPU-aware model selection.
argument-hint: "[--branch <branch>] [--skip-gpu] [--skip-cpu] [--skip-maas] [--with-observability] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(cat *), Bash(grep *), Bash(LOGDIR=*), Bash(GITOPS_BRANCH=*), Bash(GITOPS_REPO_URL=*), Bash(PREFLIGHT_SKIP_SIZING=*), Bash(PREFLIGHT_SIM_INSTANCE_TYPE=*), Bash(MAAS_MODELS=*), Bash(for *), Bash(date *), Bash(cp *), Bash(git *), Bash(sed *), Bash(tee *), Bash(jq *), Bash(scripts/*), AskUserQuestion, Edit, Skill(install-maas)
---

# Install RHOAI on Connected Cluster

Run the full RHOAI nightly installation on a connected OpenShift cluster. Equivalent to `make all` (infra + secrets + gitops + deploy + sync) but with skip detection for already-completed phases, structured logging, and problem tracking. After RHOAI, optionally installs MaaS (platform-only) and observability (gated by a settle-gate, installed separately from MaaS).

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--branch <branch>` — git branch for ArgoCD to sync from (sets `GITOPS_BRANCH`). If not specified, auto-detect (see Branch Detection).
- `--skip-gpu` — skip GPU MachineSet creation (`make gpu`). Leaves `make maas-model` autodetect to pick `simulator`.
- `--skip-cpu` — skip CPU MachineSet creation (`make cpu`).
- `--skip-maas` — skip MaaS installation prompt at the end.
- `--with-observability` — after MaaS platform + models + verify succeed, also run `make observability` (settle-gated). Default: off. Observability is opt-in because the monitoring cascade is heavy on the control plane.
- `--force` — run all phases even if they appear already completed.

## Branch Detection

Determine the git branch to use, in priority order:
1. `--branch <branch>` argument (explicit override)
2. `GITOPS_BRANCH` from `.env` file (if .env exists — **do NOT create one**)
3. **Auto-detect from current git state**: `git branch --show-current`
4. Fallback: `main`

Detect repo URL the same way: `--repo-url` → `.env`'s `GITOPS_REPO_URL` → `git remote get-url origin` → `https://github.com/rh-aiservices-bu/rhoai-nightly`.

Inline env vars work end-to-end — `deploy-apps.sh` reads `GITOPS_BRANCH` at runtime and patches ArgoCD ApplicationSets + child Applications on the cluster. **No YAML commits are needed to test a feature branch.** `make configure-repo` (which mutates checked-in YAML) is reserved for permanent fork setups, not ephemeral test runs.

Log the detected branch and repo URL so the user can verify before proceeding.

## Execution Model — Long-Running Commands

Many phases run scripts that wait for cluster resources (node restarts, machine provisioning, operator installs). These can take 5-20 minutes each.

### Log Directory

At the start of the install, create a timestamped log directory under `.tmp/logs/` (already gitignored):
```
LOGDIR=.tmp/logs/install-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

**Save ALL make output there.** Also periodically snapshot cluster state to `$LOGDIR/monitoring.log` (see "Cluster-state monitoring" below). This gives the user a persistent, browsable record for debugging and a timeline of how the install progressed.

### Rules for running make targets

1. **Pipe make targets to log files AND run in the background.** Example:
   ```
   make icsp 2>&1 | tee $LOGDIR/phase2-icsp.log
   ```
   Use Bash `run_in_background: true` so Claude can continue monitoring. This applies to: `make icsp`, `make cpu`, `make gpu`, `make uwm`, `make secrets`, `make gitops`, `make deploy`, `make sync`, `make maas`, `make maas-model`, `make observability`.

2. **Monitor background tasks** by tailing their log files every 30-60 seconds. Don't poll faster — make targets have their own wait loops already.

3. **Cluster-state monitoring (every 60-120 seconds while a phase is running)** — append to `$LOGDIR/monitoring.log`:
   ```
   echo "=== $(date) phase=<name> ===" >> $LOGDIR/monitoring.log
   oc adm top nodes -l node-role.kubernetes.io/master --no-headers >> $LOGDIR/monitoring.log 2>&1
   oc get co --no-headers | grep -E "False|True.*True" >> $LOGDIR/monitoring.log 2>&1
   oc get pods -A --no-headers | grep -Ev "Running|Completed|Succeeded" >> $LOGDIR/monitoring.log 2>&1
   ```
   Useful per-phase commands:
   - **ICSP**: `oc get mcp` (MCP update progress), `oc get nodes` (restart status)
   - **CPU/GPU**: `oc get machinesets -n openshift-machine-api`, `oc get machines -n openshift-machine-api`
   - **UWM**: `oc get pods -n openshift-user-workload-monitoring`
   - **GitOps**: `oc get csv -n openshift-gitops-operator`, `oc get pods -n openshift-gitops`
   - **Deploy/Sync**: `oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`
   - **Operators**: `oc get csv -A --no-headers | grep -v Succeeded` (want empty)
   - **Observability**: `oc get pods -n redhat-ods-monitoring`, `oc get perses -A`

4. **Report progress to the user** after each monitoring check — don't silently wait. Summarize what changed since the last snapshot. Call out anything concerning early (master memory climbing, a CO flipping Degraded, pods crashing).

5. **Use `timeout: 600000`** (10 minutes) for foreground make commands that might take a while. Never use the default 2-minute timeout for make targets.

6. **On failure**, tell the user the log file path and continue to the problem-tracking step below.

## Problem Tracking — Fix in Repo, Not on Cluster

Every unexpected symptom during an install goes through this loop:

1. **Capture** the symptom in `$LOGDIR/monitoring.log` with a timestamp and a pointer to the relevant phase log.
2. **Open `.tmp/plans/install-gotchas.md`** and either (a) cross-reference an existing entry or (b) add a new numbered entry with: symptom, detection commands, root cause, repo-side permanent fix, cluster-side temporary workaround (if any).
3. **Prefer code/script/YAML changes in the repo over hand-patching the cluster.** The repo fix is what makes the install reproducible. If a cluster patch is strictly needed to unblock progress (rare), apply it but ALSO land the permanent repo fix in the same session and re-sync.
4. **After the fix**: re-run the failing phase. If the fix required a commit+push, ensure ArgoCD picks it up (`make refresh-apps` or `oc annotate ... refresh=hard`).

Do not silently swallow errors. If the user hasn't seen a problem, they don't know it happened.

## Instructions

Run this from the repository root.

Run each phase sequentially. After each phase, verify success before continuing. If any phase fails, STOP, run the Problem Tracking loop, and ask the user how to proceed.

### Phase 0: Configuration Check

Read `.env` if present — **do not create one if it doesn't exist**. Scripts handle a missing `.env` (no-creds mode falls through to External Secrets; no `GITOPS_BRANCH` falls through to git-state detection).

**Step 1: Check .env**
```bash
ls -la .env 2>/dev/null || echo "NO_ENV_FILE (using defaults + git state + args)"
```

**Step 2: Present effective configuration**

Show the user the effective config that will be used (not forcing them to edit .env unless they want to):

```
Configuration:
  Credentials:  [Manual (QUAY_USER set) | External Secrets (no creds, bootstrap repo accessible) | Not configured]
  Branch:       [<--branch arg> | <.env GITOPS_BRANCH> | <current git branch>]
  Repo:         [<.env GITOPS_REPO_URL> | <git remote origin>]
  GPU config:   [<.env GPU_* overrides> | defaults (g6e.2xlarge, 1-3)]
  CPU config:   [<.env CPU_* overrides> | defaults (m6a.4xlarge, 1-3)]
  MaaS models:  [<.env MAAS_MODELS> | 'auto' (default — cluster-inspected at deploy time)]
```

**Step 3: Ask once**

"Does this configuration look correct? (Yes to proceed, otherwise tell me what to change.)"

If the user wants changes, help them edit `.env` OR pass them as inline env vars / CLI flags. Don't insist on .env creation.

### Phase 1: Preflight

Run `make preflight 2>&1 | tee $LOGDIR/phase1-preflight.log`.

The preflight covers:
- Cluster connection + OCP version
- Node Ready count
- **Control-plane health** (new): master sizing vs. 32 GiB floor, master memory/CPU pressure, ClusterOperators (Available, Degraded). This refuses to run on undersized masters unless `PREFLIGHT_SKIP_SIZING=1` is set.
- MCP state
- GPU presence
- Credentials mode
- Install state inventory (ICSP, pull-secret, GitOps, RHOAI, MaaS)

If preflight exits 1 (FAIL), STOP. Don't try to work around a FAILed preflight — the most common cause is undersized masters, and ignoring it caused the cluster-hm2fl OOM on 2026-04-20.

If preflight exits 2 (WARN), continue but note the warnings in `$LOGDIR/phase1-preflight.log` and surface them to the user.

### Phase 2: ICSP (Registry Mirror)

**Skip if**: `oc get imagecontentsourcepolicy` shows an ICSP exists AND all nodes are Ready.

Run `make icsp 2>&1 | tee $LOGDIR/phase2-icsp.log` in background. Monitor with `oc get mcp` and `oc get nodes`. Expect 10-15 min for node reboots.

Verify: `oc get nodes` — all Ready.

### Phase 3: CPU Workers

**Skip if**: `--skip-cpu` OR a CPU worker MachineSet already has Ready replicas.

Run `make cpu 2>&1 | tee $LOGDIR/phase3-cpu.log` in background. Monitor `oc get machinesets -n openshift-machine-api`.

Verify: at least one dedicated worker node Ready.

### Phase 4: GPU Workers

**Skip if**: `--skip-gpu` OR a GPU MachineSet already has Ready replicas.

Run `make gpu 2>&1 | tee $LOGDIR/phase4-gpu.log` in background. Monitor machines + the eventual `nvidia.com/gpu.present=true` label on the new node.

Verify: GPU node Ready, then wait ~3-5 min for the NVIDIA GPU operator's node feature discovery to populate `nvidia.com/gpu.memory` and `nvidia.com/gpu.product` labels (they're needed by `make maas-model`'s autodetect in Phase 10).

### Phase 5: UWM (User Workload Monitoring)

**Skip if**: `scripts/enable-uwm.sh --check` exits 0 (UWM already enabled).

Run `make uwm 2>&1 | tee $LOGDIR/phase5-uwm.log`.

This enables `enableUserWorkload: true` in `cluster-monitoring-config`. UWM is owned at the infra stage (not `install-observability.sh`) because:
- UWM is a foundational capability other workloads may depend on
- UWM's memory overhead is ~5-10% of a small master — landing it while the cluster is idle avoids stacking it on top of the observability cascade later

Verify: `prometheus-user-workload-0` pod appears in `openshift-user-workload-monitoring` within ~2 min.

### Phase 6: Pull Secret

**Skip if**: pull-secret already contains `quay.io/rhoai`.

Run `make secrets 2>&1 | tee $LOGDIR/phase6-secrets.log` in background. External Secrets mode may take a few minutes (operator install + ClusterSecretStore + sync).

Verify: `oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' | grep -c quay` returns ≥ 1.

### Phase 7: GitOps Operator + ArgoCD

**Skip if**: GitOps operator CSV exists and ArgoCD pods are Running.

Run `make gitops 2>&1 | tee $LOGDIR/phase7-gitops.log` in background. Monitor CSV + pods.

Verify: all openshift-gitops pods Running/Ready.

### Phase 8: Deploy Apps

**Skip if**: ArgoCD Applications already exist AND point at the correct branch. If they exist but point at wrong branch, re-run deploy — it re-patches them.

Always pass the branch inline. Example:
```
GITOPS_BRANCH=<detected-branch> make deploy 2>&1 | tee $LOGDIR/phase8-deploy.log
```

`deploy-apps.sh` creates apps with sync DISABLED, then patches both ApplicationSets and every child Application to point at the requested branch. This happens on the cluster — the checked-in YAML is not modified.

Verify: `oc get applications.argoproj.io -n openshift-gitops` lists all expected apps.

### Phase 9: Sync Apps

**Skip if**: all apps Synced + Healthy (rare on fresh install).

Run `make sync 2>&1 | tee $LOGDIR/phase9-sync.log` in background. This is the longest phase (15-30 min). Monitor frequently:
```
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
oc get csv -A --no-headers | grep -v Succeeded
```

Report progress as apps transition Unknown → Progressing → Healthy.

Known gotcha (reference `.tmp/plans/install-gotchas.md` §1): if the `:rhoai-3.4-nightly` catalog image is broken upstream, the rhods-operator will CrashLoopBackOff. The branch currently pins to `:rhoai-3.4` as a workaround. If you still see CrashLoops, run `scripts/restart-catalog.sh` (which bounces pods AND deletes the Subscription so OLM re-resolves).

Verify: all apps Synced + Healthy; `oc get csv -A | grep -v Succeeded` empty or only transient.

### Phase 10: MaaS (Platform) — Optional

**Skip if**: `--skip-maas`.

`make maas` installs the MaaS platform only (Postgres+PVC, Gateway, Authorino SSL). Observability is no longer installed as part of this phase — see Phase 11.

Run: `make maas 2>&1 | tee $LOGDIR/phase10-maas.log`. Expect 3-5 min.

Verify: `oc get gateway maas-default-gateway -n openshift-ingress` Programmed=True, `oc get deployment maas-api -n redhat-ods-applications` Ready.

Then deploy a model:

```
make maas-model 2>&1 | tee $LOGDIR/phase10-maas-model.log
```

`make maas-model` autodetects which model fits:
- no GPU nodes → simulator
- GPU `nvidia.com/gpu.memory` ≥ 40 GiB → gpt-oss-20b
- otherwise → granite-tiny-gpu

**Do not hardcode model recommendations in this skill** — the script is the source of truth. If the autodetect returned granite-tiny-gpu on a cluster where you expected gpt-oss-20b, most likely cause is the GPU operator hasn't populated the `nvidia.com/gpu.memory` label yet (lag ~3-5 min after node Ready). The script emits a warning in that case and falls back to granite-tiny-gpu.

Verify: `oc get llminferenceservice -n llm` Ready=True for the deployed model; `oc get maasmodelref -n llm` Ready; model pod Running in `llm` namespace.

Quick smoke test: `make maas-verify 2>&1 | tee $LOGDIR/phase10-maas-verify.log` — exit 0 means auth + rate limiting + inference all work.

### Phase 11: Observability — Opt-In, Settle-Gated

**Run only if**: `--with-observability` was passed AND Phase 10 (MaaS) ran. Default is skip.

`make observability` runs a settle-gate, flips the `instance-rhoai` ArgoCD Application from `overlays/maas` to `overlays/maas-observability`, and waits for Perses/Tempo/OTel/MonitoringStack pods to Ready. The overlay flip adds `DSCI.spec.monitoring.metrics.storage`, which triggers the rhods-operator Monitoring controller's full observability cascade.

Run: `make observability 2>&1 | tee $LOGDIR/phase11-observability.log`.

The settle-gate will **refuse** if any of the following are true:
- Required operator CSVs (rhods, COO, opentelemetry, servicemesh, authorino, limitador) are not Succeeded
- DSC or DSCI Ready != True
- Any pod in redhat-ods-applications / kuadrant-system / openshift-monitoring is non-terminal
- etcd ClusterOperator is Degraded
- Any master is at ≥75% memory (via `oc adm top nodes`)

If the gate refuses, don't override — fix the underlying condition and retry. The gate exists specifically to prevent the 2026-04-20 cluster-hm2fl OOM pattern.

Verify after flip: Perses, TempoStack, OpenTelemetryCollector DaemonSet, MonitoringStack pods Running in `redhat-ods-monitoring`. Masters stay < 75%.

Rerun `make maas-verify` — should still exit 0 with observability active.

### Phase 12: Full Diagnostic Verification

Regardless of earlier skips:

```
make diagnose 2>&1 | tee $LOGDIR/phase12-diagnose.log
```

Expected end-state:
- 0 FAIL entries in `make diagnose`
- All ArgoCD apps Synced + Healthy
- DSC Ready=True, DSCI Ready=True
- rhods-operator 3 pods Running
- If Phase 10 ran: maas-api + gateway + model Ready
- If Phase 11 ran: Perses CR present with Service on :8080 in redhat-ods-monitoring
- Masters steady-state < 75% memory (< 60% on a cluster larger than m6a.2xlarge)

If any check fails, run the Problem Tracking loop — update `.tmp/plans/install-gotchas.md` with symptom + root cause + repo-side fix, not just a cluster-side patch.

### Final Report

Summarize:
- Cluster URL, OCP version, node count (masters / workers / GPU)
- Branch + repo used for GitOps
- ArgoCD app status (Synced+Healthy / Progressing / Degraded counts)
- RHOAI operator CSV
- DSC status
- MaaS status (skipped / installed / which models deployed / maas-verify result)
- Observability status (skipped / installed / settle-gate verdict / dashboard backend ready)
- Phases skipped (and why)
- **Problems encountered** (with pointers to `.tmp/plans/install-gotchas.md` entries and the commits that landed repo-side fixes)
- Log directory path for the whole run

If this run was a test of a feature branch, remind the user the branch still needs to be reviewed/merged before it's available to others; ephemeral test-pointing isn't persistent.
