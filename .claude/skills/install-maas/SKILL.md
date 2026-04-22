---
name: install-maas
description: Install MaaS (Models as a Service) on a connected RHOAI cluster. Installs the MaaS platform, deploys a GPU-aware auto-selected model, verifies, and optionally runs observability (settle-gated, separate step).
argument-hint: "[--branch <branch>] [--models-only] [--verify-only] [--skip-models] [--skip-verify] [--with-observability]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(cat *), Bash(grep *), Bash(git *), Bash(LOGDIR=*), Bash(MAAS_MODELS=*), Bash(GITOPS_BRANCH=*), Bash(scripts/*), Bash(date *), Bash(curl *), Bash(tee *), Bash(jq *), AskUserQuestion, Edit, Skill(install-rhoai)
---

# Install MaaS on Connected RHOAI Cluster

Install Models as a Service on an OpenShift cluster with RHOAI. Handles the full MaaS lifecycle:

1. Verify RHOAI is installed (offer to install if not)
2. Install MaaS platform only (`make maas`) — Postgres+PVC, Gateway, Authorino SSL
3. Deploy a GPU-appropriate model (`make maas-model` — autodetects)
4. Verify the installation (`make maas-verify`)
5. Optionally install observability as a separate, settle-gated step (`make observability`)

**`make maas` no longer installs observability.** The monitoring cascade (Perses, Tempo, OTel DaemonSet, MonitoringStack) is heavy on the control plane and is gated behind `make observability`, which refuses to run on a stressed cluster. This decoupling is intentional and shipped in the feature/maas-improvements branch — see `.tmp/plans/install-gotchas.md` for the OOM it prevents.

## Arguments

- `--branch <branch>` — git branch for ArgoCD (inline env var, no YAML commits). Auto-detects from git state if unset.
- `--models-only` — skip platform install, only deploy models
- `--verify-only` — skip install and models, only run `make maas-verify`
- `--skip-models` — install platform but don't deploy models
- `--skip-verify` — skip the verification step
- `--with-observability` — after the MaaS platform + models are healthy, also run `make observability`. Default is off.

## Branch Detection

Priority: `--branch` → `.env` `GITOPS_BRANCH` → `git branch --show-current` → `main`. Inline env var works with `make deploy` / `make maas` — **do not** mutate checked-in YAML for ephemeral test pointing.

Log the detected branch before proceeding. When invoking `install-rhoai`, pass the same branch.

## Execution Model — Long-Running Commands

### Log Directory

```bash
LOGDIR=.tmp/logs/maas-install-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

Save ALL command output there. Append cluster-state snapshots to `$LOGDIR/monitoring.log` every 60-120 seconds while something is running.

### Rules

1. **Pipe each step to its own log + run in background**:
   ```bash
   make maas 2>&1 | tee $LOGDIR/phase2-platform.log
   ```
   Use Bash `run_in_background: true`.

2. **Monitor every 30-60 seconds**:
   - Platform install: `oc get application.argoproj.io/instance-maas -n openshift-gitops`, `oc get pods -n redhat-ods-applications | grep -E 'postgres|maas'`, `oc get gateway -n openshift-ingress`
   - Model deploy: `oc get pods -n llm`, `oc get llminferenceservice -n llm`, `oc get maasmodelref -n llm`
   - Observability: `oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.path}'`, `oc get pods -n redhat-ods-monitoring`, `oc adm top nodes -l node-role.kubernetes.io/master`

3. **Cluster health snapshots** — append to `$LOGDIR/monitoring.log`:
   ```bash
   echo "=== $(date) phase=<name> ===" >> $LOGDIR/monitoring.log
   oc adm top nodes -l node-role.kubernetes.io/master --no-headers >> $LOGDIR/monitoring.log 2>&1
   oc get co --no-headers | grep -E "False|True.*True" >> $LOGDIR/monitoring.log 2>&1
   oc get pods -A --no-headers | grep -Ev "Running|Completed|Succeeded" >> $LOGDIR/monitoring.log 2>&1
   ```

4. **Report progress to the user** after each snapshot — call out anything concerning (rising master memory, Degraded COs, CrashLoopBackOff).

5. **Use `timeout: 600000`** for foreground make commands.

## Problem Tracking — Fix in Repo, Not on Cluster

Every unexpected symptom:
1. Capture in `$LOGDIR/monitoring.log` with a timestamp
2. Add a numbered entry to `.tmp/plans/install-gotchas.md` with symptom / detection / root cause / repo-side fix / cluster-side workaround
3. **Prefer code/script/YAML changes in the repo over hand-patching the cluster.** Cluster patch is a temporary unblocker; the durable fix is a commit.
4. After fix: re-run the failing phase; if a commit+push was needed, trigger ArgoCD refresh (`make refresh-apps`).

## Instructions

Run from the repo root.

### Phase 0: Preflight

```bash
oc whoami --show-server
oc get nodes
oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "No RHOAI CSV"
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "No DSC or not Ready"
oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.path}' 2>/dev/null || echo "No instance-rhoai"
oc get authorino authorino -n kuadrant-system 2>/dev/null || echo "No Authorino"
oc get pods -n redhat-ods-applications 2>/dev/null | grep -E 'maas-api|postgres' || echo "No MaaS components"
oc get pvc postgres-data -n redhat-ods-applications 2>/dev/null || echo "No postgres PVC"
oc get llminferenceservice -A 2>/dev/null || echo "No models deployed"
# Observability backend state (informational)
oc get perses -A 2>/dev/null || echo "No Perses CR (normal until make observability runs)"
```

State machine:

- **A — RHOAI not installed**: ask to invoke `Skill(install-rhoai, "--branch <branch>")`, then return to Phase 1.
- **B — RHOAI installed, MaaS not**: continue to Phase 1.
- **C — MaaS platform installed, no models**: skip to Phase 2.
- **D — MaaS + models deployed**: unless `--skip-verify`, jump to Phase 3.

Report cluster URL, RHOAI CSV version, DSC Ready state, what's already installed, and which phases will run.

### Phase 1: Install MaaS Platform

**Skip if**: `--models-only` or `--verify-only`, or `maas-api` Running and Healthy.

```bash
make maas 2>&1 | tee $LOGDIR/phase1-platform.log
```

`install-maas.sh` phases (no longer includes observability):
1. Preflight (RHOAI CSV, DSC, Authorino, cluster domain)
2. PostgreSQL secrets
3. ArgoCD Application (Helm chart — PostgreSQL+PVC + Gateway+GatewayClass)
4. Authorino SSL env vars
5. Wait for maas-api Ready, report Gateway programmed state

Monitor:
```bash
oc get application.argoproj.io/instance-maas -n openshift-gitops
oc get pods -n redhat-ods-applications | grep -E 'postgres|maas'
oc get pvc postgres-data -n redhat-ods-applications
oc get gateway maas-default-gateway -n openshift-ingress
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")]}'
```

**Known gotcha** (log in `install-gotchas.md` if hit): the RHOAI operator may cache a stale "gateway not found" error before ArgoCD creates the Gateway. `install-maas.sh` auto-triggers a re-reconciliation after 60s if this is detected. If it doesn't self-heal, the manual unblock is `oc annotate modelsasservice default-modelsasservice reconcile-trigger="$(date +%s)" --overwrite`. Root-cause fix belongs in the operator, not our repo.

Verify after completion:
- `maas-api` and `maas-controller` deployments Ready
- `postgres` Deployment Ready, backed by 20Gi PVC `postgres-data`
- Gateway Programmed=True
- ModelsAsServiceReady=True
- `instance-rhoai` ArgoCD Application source path is `components/instances/rhoai-instance/overlays/maas` (the default — no observability cascade)

### Phase 2: Deploy Models

**Skip if**: `--skip-models` or `--verify-only`.

```bash
make maas-model 2>&1 | tee $LOGDIR/phase2-maas-model.log
```

`setup-maas-model.sh` autodetects which model fits based on `nvidia.com/gpu.memory` labels:
- no GPU → simulator
- GPU VRAM ≥ 40 GiB (L40S, A100-40, H100, etc.) → gpt-oss-20b
- GPU VRAM < 40 GiB (T4, L4, A10, etc.) → granite-tiny-gpu

**Do not hardcode recommendations in this skill.** The script is the source of truth. To override, the user sets `MAAS_MODELS=...` inline or in .env (accepting a space-separated list).

If the autodetect returned granite-tiny-gpu on a cluster with large GPUs, the `nvidia.com/gpu.memory` label may not be populated yet (GPU operator feature discovery lag; 3-5 min after GPU node Ready). The script warns and falls back safely. To force after the labels land: `make maas-model-delete MODEL=granite-tiny-gpu && make maas-model`.

Monitor:
```bash
oc get pods -n llm
oc get llminferenceservice -n llm
oc get maasmodelref -n llm -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'
```

GPU models take 5-15 min (image pull ~8GB + vLLM model load). Non-GPU simulator is ~30 sec.

Verify after completion:
- LLMInferenceService Ready=True
- MaaSModelRef phase=Ready
- MaaSSubscription entries for free + premium tiers phase=Active

### Phase 3: Verify

**Skip if**: `--skip-verify`.

```bash
make maas-verify 2>&1 | tee $LOGDIR/phase3-verify.log
```

Six phases:
1. Infrastructure health (Gateway, postgres, maas-api, maas-controller, Authorino, health endpoint)
2. Deploys a temporary simulator model + MaaS resources
3. API verification (create API key, list models, test inference)
4. Auth enforcement (401 without token, 401 with invalid token)
5. Rate limiting (trigger 429 responses)
6. Cleanup (removes the temporary resources — does NOT touch models deployed in Phase 2)

Expected exit 0. Report the passed/failed count to the user.

### Phase 4: Observability — Optional, Settle-Gated

**Run only if**: `--with-observability`.

```bash
make observability 2>&1 | tee $LOGDIR/phase4-observability.log
```

`install-observability.sh` flow:
1. Preflight (CRDs present)
2. Verify UWM is enabled (fails fast with "run make uwm" if not)
3. Scrub `openshift.io/cluster-monitoring` label from MaaS namespaces (avoids duplicate scrapes)
4. **Settle-gate**: refuses if any of — required CSVs not Succeeded, DSC/DSCI not Ready, non-terminal pods in core namespaces, etcd Degraded, masters ≥75% memory.
5. **Overlay flip**: patches `instance-rhoai` Application source from `overlays/maas` to `overlays/maas-observability`. Waits up to 10 min for ArgoCD to reconcile DSCI metrics and the RHOAI operator to create the Perses CR.
6. Kuadrant CR verification, conditional Limitador/Authorino ServiceMonitors, Istio Gateway metrics monitor, KServe LLM models monitor.

If the settle-gate refuses, don't override — fix the underlying condition and retry. The gate exists specifically to prevent the cluster-hm2fl 2026-04-20 OOM pattern.

Monitor:
```bash
oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.path}'  # should flip to overlays/maas-observability
oc get dscinitialization default-dsci -o jsonpath='{.spec.monitoring.metrics}'  # should populate
oc get pods -n redhat-ods-monitoring
oc get perses -n redhat-ods-monitoring
oc adm top nodes -l node-role.kubernetes.io/master  # must stay <75%
```

Verify after completion:
- `instance-rhoai` source path is `components/instances/rhoai-instance/overlays/maas-observability`
- DSCI `.spec.monitoring.metrics.storage` populated
- Perses, TempoStack, OpenTelemetryCollector DaemonSet, MonitoringStack pods Running in `redhat-ods-monitoring`
- Masters never exceeded 75% during the flip
- Re-run `make maas-verify` — still exits 0

### Final Report

Summarize:
- Cluster URL + RHOAI CSV
- MaaS API URL: `https://maas.<cluster-domain>/maas-api/v1/models`
- Gen AI Studio dashboard URL
- Models deployed + their Ready state
- `maas-verify` result (passed/failed count)
- Observability status: skipped / installed / settle-gate verdict / Perses backend ready state
- **Problems encountered** (with pointers to `.tmp/plans/install-gotchas.md` entries and any repo-side commits that landed fixes)
- Log directory path

If this run tested a feature branch, remind the user the branch is still only visible to ArgoCD's runtime patch — merge+land is still required for the change to be visible to others.
