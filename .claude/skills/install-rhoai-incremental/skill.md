---
name: install-rhoai-incremental
description: Install RHOAI nightly incrementally — syncs one ArgoCD app at a time with cluster health checks between each. Safer than /install-rhoai for clusters that have been unstable.
argument-hint: "[--branch <branch>] [--skip-gpu] [--skip-cpu] [--skip-infra] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(LOGDIR=*), Bash(GITOPS_BRANCH=*), Bash(for *), Bash(date *), AskUserQuestion
---

# Install RHOAI Incrementally

Install RHOAI nightly one component at a time, with cluster health checks between each ArgoCD app sync. This is the safe version of `/install-rhoai` — designed for clusters that have been unstable or where you want maximum visibility.

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--branch <branch>` — git branch for ArgoCD to sync from (sets `GITOPS_BRANCH`). Default: `main`
- `--skip-gpu` — skip GPU MachineSet creation
- `--skip-cpu` — skip CPU MachineSet creation
- `--skip-infra` — skip all infra phases (ICSP, CPU, GPU, pull-secret) — go straight to GitOps
- `--force` — run all phases even if they appear already completed

## Key Difference from /install-rhoai

The regular install runs `make sync` which enables auto-sync on all apps in sequence within a single script. This skill instead:

1. Runs `make deploy` to create apps with sync DISABLED
2. Syncs ONE app at a time using `make sync-app APP=<name>`
3. After each app syncs, runs a **cluster health gate** before proceeding
4. Reports status to the user at every step
5. Pauses and asks the user before continuing if anything looks unhealthy

## Cluster Health Gate

Run this check after EVERY app sync. This is the core safety mechanism.

```bash
echo "=== Health Gate $(date) ==="
echo "NODES:"
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,SCHED:.spec.unschedulable,DISK:.status.conditions[?(@.type=="DiskPressure")].status'
echo
echo "PROBLEM PODS:"
oc get pods -A | grep -icE 'CrashLoopBackOff|Error|ImagePullBackOff|Evicted|ContainerStatusUnknown'
echo
echo "APP STATUS:"
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null
echo
echo "CSVs:"
oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver|openshift-gitops' | awk '{printf "%-50s %-40s %s\n", $1, $2, $NF}'
```

**Health gate rules:**
- If any schedulable node has DiskPressure → STOP and ask the user
- If problem pods increased by more than 5 since last check → WARN the user, ask if they want to continue
- If the app just synced is not Healthy after 5 minutes → WARN and ask
- If a CSV is stuck in "Installing" for more than 5 minutes → WARN and ask

## Log Directory

```
LOGDIR=.tmp/logs/install-incremental-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

Save health gate outputs to `$LOGDIR/health-gates.log` (append with timestamps).

## Sync Order

Follow this exact order (from `scripts/lib/common.sh` SYNC_ORDER). Each group represents a logical tier — after completing each group, run the health gate.

### Group 1: Foundation
```
external-secrets-operator
instance-external-secrets
nfd
instance-nfd
nvidia-operator
instance-nvidia
```

Sync each app individually with `make sync-app APP=<name>`. After each app:
1. Wait for the app to show Synced + Healthy (check every 10s, timeout 5 min)
2. For operator apps, also wait for CSV to be Succeeded
3. Run the health gate

**Special waits in this group:**
- After `nfd` + `instance-nfd`: verify `oc get nodefeaturediscovery -A` shows a CR
- After `nvidia-operator` + `instance-nvidia`: verify `oc get clusterpolicy` exists (GPU driver pods take a while — don't wait for them, just verify the CR exists)

### Group 2: Dependent Operators
```
cert-manager
openshift-service-mesh
kueue-operator
leader-worker-set
instance-lws
jobset-operator
instance-jobset
connectivity-link
instance-kuadrant
nfs-provisioner
instance-nfs
```

Sync each individually. Same pattern: sync → wait for Synced+Healthy → wait for CSV if operator → health gate.

**Special waits in this group:**
- After `connectivity-link` + `instance-kuadrant`: Kuadrant pulls in dependency operators (authorino, limitador, dns-operator). These create additional CSVs. Wait for them.
- After `instance-nfs`: verify `oc get storageclass nfs` exists

### Group 3: RHOAI
```
rhoai-operator
instance-rhoai
```

This is the most critical group. Extra care:

**After `rhoai-operator`:**
1. Wait for catalog source pod to be running: `oc get pods -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly`
2. Wait for RHOAI CSV to be Succeeded: `oc get csv -n redhat-ods-operator | grep rhods`
3. Wait for DSCInitialization to be Ready: `oc get dscinitialization default-dsci -o jsonpath='{.status.phase}'`
4. Run health gate
5. **Ask the user**: "RHOAI operator is installed. Ready to deploy the DataScienceCluster instance?"

**After `instance-rhoai`:**
1. Wait for DataScienceCluster to exist: `oc get datascienceclusters`
2. Wait for DSC phase to be Ready (this can take 5-10 minutes)
3. Run final health gate

## Instructions

### Phase 0: Preflight

Same as `/install-rhoai` — check cluster connection, assess what's installed, report plan.

Run ALL of these checks in parallel:
```
oc whoami --show-server
oc get clusterversion
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,SCHED:.spec.unschedulable,DISK:.status.conditions[?(@.type=="DiskPressure")].status'
oc get imagecontentsourcepolicy 2>/dev/null || echo "No ICSP"
oc get machinesets -n openshift-machine-api
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' 2>/dev/null
oc get csv -n openshift-gitops-operator 2>/dev/null | grep gitops || echo "No GitOps operator"
oc get applications.argoproj.io -n openshift-gitops 2>/dev/null || echo "No ArgoCD apps"
oc get pods -n openshift-gitops 2>/dev/null || echo "No openshift-gitops namespace"
oc get datascienceclusters 2>/dev/null || echo "No DSC"
oc get pods -A | grep -icE 'CrashLoopBackOff|Error|ImagePullBackOff|Evicted|ContainerStatusUnknown'
```

Report:
- Cluster URL, OCP version, node count
- Current problem pod count (baseline for health gates)
- What's already installed vs what needs to be done
- Which phases will be skipped

### Phase 1-4: Infrastructure (same as /install-rhoai)

Skip if `--skip-infra` was passed. Otherwise run ICSP, CPU, GPU, pull-secret same as the regular install skill. Each phase runs in the background with monitoring.

### Phase 5: GitOps Operator + ArgoCD

Same as regular install. Run `make gitops` if needed, verify ArgoCD is running.

### Phase 6: Deploy Apps (sync DISABLED)

Run `make deploy` (with optional `GITOPS_BRANCH`). This creates all ArgoCD Applications but does NOT enable auto-sync. Verify all apps exist:

```
oc get applications.argoproj.io -n openshift-gitops --no-headers | wc -l
```

Should show the expected count (currently 20 apps based on SYNC_ORDER).

### Phase 7: Incremental Sync

This is where the incremental skill diverges. Instead of `make sync`, sync apps one at a time:

```bash
# For each app in SYNC_ORDER:
make sync-app APP=<app-name>
```

After each app:
1. Wait for Synced + Healthy (poll every 10s, timeout 5 min)
2. If it's an operator app, wait for CSV Succeeded
3. Run health gate
4. If health gate fails → ask user before continuing
5. Log everything to `$LOGDIR/health-gates.log`

Report to user after each app:
```
[3/20] nfd: Synced + Healthy, CSV nfd.v4.19.0 Succeeded
       Health: 17 nodes OK, 0 DiskPressure, 2 problem pods (baseline: 2)
       Proceeding to instance-nfd...
```

### Phase 8: Final Validation

After all apps are synced:

```
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
oc get csv -A --no-headers | grep -vE 'packageserver|openshift-gitops'
oc get datascienceclusters
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status'
oc get pods -A | grep -icE 'CrashLoopBackOff|Error|ImagePullBackOff|Evicted|ContainerStatusUnknown'
```

### Final Report

Summarize:
- Cluster URL and OCP version
- Branch used for GitOps
- Apps synced: N/N Synced+Healthy
- Problem pods: before vs after
- DiskPressure: any nodes affected?
- RHOAI operator CSV status
- DataScienceCluster status
- Any warnings or pauses during install
- Log directory path for full details
