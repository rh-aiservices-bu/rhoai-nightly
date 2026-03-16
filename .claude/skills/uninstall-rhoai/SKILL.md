---
name: uninstall-rhoai
description: Uninstall RHOAI from a connected OpenShift cluster. Runs undeploy (ArgoCD apps) + clean (leftover operators/CSVs) with intelligent assessment and progress reporting.
argument-hint: "[--dry-run] [--skip-undeploy] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(LOGDIR=*), Bash(for *), Bash(date *), AskUserQuestion
---

# Uninstall RHOAI from Connected Cluster

Remove all RHOAI components from an OpenShift cluster. This is the inverse of `/install-rhoai` — it runs `make undeploy` (ArgoCD cascade deletion) then `make clean` (leftover operators/CSVs), with intelligent skip detection and progress monitoring.

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--dry-run` — show what would be deleted without making changes (passes `DRY_RUN=true`)
- `--skip-undeploy` — skip ArgoCD app deletion (use when apps are already removed)
- `--force` — run all phases even if they appear already completed

## Execution Model

Uninstall phases can take several minutes each (ArgoCD cascade deletion waits for managed resources to be removed). Follow the same background execution and monitoring pattern as the install skill.

### Log Directory

At the start of the uninstall, create a timestamped log directory under `.tmp/logs/` (already gitignored):
```
LOGDIR=.tmp/logs/uninstall-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```
Save ALL make target and manual command output there.

### Rules for running commands:

1. **Run make targets in the background with log capture.** For example:
   ```
   make undeploy SKIP_CONFIRM=true 2>&1 | tee $LOGDIR/phase1-undeploy.log
   ```
   Use Bash `run_in_background: true` so Claude can continue monitoring.

2. **Monitor background tasks** by checking their log files with `tail -50 $LOGDIR/phase<N>-<name>.log`. Check every 15-30 seconds.

3. **While a background task is running**, run monitoring commands in parallel to give the user visibility:
   - **Undeploy**: `oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null || echo "No apps remaining"`
   - **Clean**: `oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver|openshift-gitops' | awk '{print $2, $1}' || echo "No CSVs"`
   - **Namespaces**: `oc get namespaces --no-headers 2>/dev/null | grep -E 'redhat-ods|rhoai|nvidia|nfd|kueue|jobset|lws|kuadrant|cert-manager|nfs' || echo "No managed namespaces"`
   - **Operator pods**: `oc get pods -n openshift-operators --no-headers 2>/dev/null`

4. **Report progress to the user** after each monitoring check.

5. **Use timeout: 600000** (10 minutes) for any foreground commands that might take a while.

6. **Save monitoring snapshots** to the log directory:
   ```
   echo "=== $(date) ===" >> $LOGDIR/monitoring.log
   oc get applications.argoproj.io -n openshift-gitops --no-headers >> $LOGDIR/monitoring.log 2>&1
   oc get csv -A --no-headers >> $LOGDIR/monitoring.log 2>&1
   ```

7. **On failure**, tell the user the log file path so they can review the full output.

## Instructions

You MUST run this from the repository root.

### Phase 0: Preflight — Cluster Assessment

First, verify cluster connection and assess what's currently installed. Run ALL of these checks in parallel:

```
oc whoami --show-server
oc get clusterversion
oc get nodes --no-headers | wc -l
oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null || echo "No ArgoCD apps"
oc get applicationsets.argoproj.io -n openshift-gitops --no-headers 2>/dev/null || echo "No ApplicationSets"
oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver' | awk '{printf "%-50s %-40s %s\n", $2, $1, $NF}'
oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null | awk '{printf "%-40s %-40s\n", $2, $1}'
oc get pods -n openshift-operators --no-headers 2>/dev/null
oc get datascienceclusters 2>/dev/null || echo "No DSC"
oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null | grep -E 'rhoai|rhods' || echo "No RHOAI catalog"
```

Based on the results, categorize what's on the cluster into:

**RHOAI-installed components** (things we need to remove):
- ArgoCD Applications and ApplicationSets (from `make deploy`)
- Operators we installed: NFD, NVIDIA, RHOAI, Service Mesh, Kueue, JobSet, LeaderWorkerSet, Connectivity Link, NFS Provisioner, External Secrets, cert-manager
- OLM dependency operators pulled in automatically: authorino, dns-operator, limitador, kuadrant
- Operator instances: DataScienceCluster, ClusterPolicy, NodeFeatureDiscovery, etc.
- Custom CatalogSources (rhoai-catalog-nightly)
- Managed namespaces: redhat-ods-*, nvidia-gpu-operator, openshift-nfd, etc.

**Cluster infrastructure** (things we keep):
- OpenShift GitOps operator and ArgoCD (needed for redeployment)
- ICSP / ImageContentSourcePolicy
- MachineSets (CPU/GPU workers)
- Pull secret credentials
- The `packageserver` CSV (built-in OLM)

Report to the user:
- Cluster URL and OCP version
- What will be removed (with counts: N ArgoCD apps, N operators, N namespaces)
- What will be kept and why
- Which phases will be skipped and why (e.g., "No ArgoCD apps found, skipping undeploy")

### Phase 1: Undeploy ArgoCD Apps

**Skip if:** `--skip-undeploy` was passed, or no ArgoCD Applications exist.

This phase removes all ArgoCD Applications with cascade deletion (ArgoCD deletes the managed resources before removing the app), then removes ApplicationSets.

Run `make undeploy SKIP_CONFIRM=true` in the background. Monitor with:
```
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
```

The undeploy script:
1. Disables ApplicationSets (prevents app recreation during deletion)
2. Deletes apps in reverse dependency order (instances first, then operators)
3. Waits up to 5 minutes per app for cascade deletion
4. Force-removes finalizers on timeout
5. Deletes ApplicationSets
6. Cleans up managed namespaces

Report progress as apps disappear. After completion, verify:
```
oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l
oc get applicationsets.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l
```

Both should be 0.

### Phase 2: Clean Leftover Operators

**Skip if:** No operator CSVs remain (other than packageserver and openshift-gitops).

After undeploy, OLM leaves behind CSVs and running operator pods even though Subscriptions were deleted. This phase removes them.

Run `make clean SKIP_CONFIRM=true` in the background. Monitor with:
```
oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver|openshift-gitops' | awk '{print $2, $1}'
oc get pods -n openshift-operators --no-headers 2>/dev/null
```

The clean script:
1. Deletes operator instances (DataScienceCluster, ClusterPolicy, NodeFeatureDiscovery, etc.)
2. Deletes all Subscriptions and CSVs in managed namespaces
3. Deletes Service Mesh subscriptions/CSVs in openshift-operators
4. Removes custom CatalogSources

After completion, verify no RHOAI-related CSVs remain:
```
oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver|openshift-gitops'
```

### Phase 3: Verify Cleanup

After both phases complete, run a comprehensive verification. Run ALL in parallel:

```
oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null || echo "No apps"
oc get applicationsets.argoproj.io -n openshift-gitops --no-headers 2>/dev/null || echo "No appsets"
oc get csv -A --no-headers 2>/dev/null | grep -vE 'packageserver|openshift-gitops' || echo "No extra CSVs"
oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null | grep -v openshift-gitops || echo "No extra subscriptions"
oc get pods -n openshift-operators --no-headers 2>/dev/null || echo "No operator pods"
oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null | grep -E 'rhoai|rhods' || echo "No RHOAI catalogs"
oc get datascienceclusters 2>/dev/null || echo "No DSC"
oc get namespaces --no-headers 2>/dev/null | grep -E 'redhat-ods|rhoai|nvidia|nfd|kueue|jobset|lws|kuadrant' || echo "No managed namespaces"
```

If anything remains that should have been cleaned up, report it clearly and offer to manually remove it.

**Common leftovers to watch for:**
- CSVs in `openshift-operators` for dependency operators (authorino, dns, limitador, kuadrant) — `clean.sh` only targets Service Mesh CSVs in openshift-operators, not all of them
- External-secrets-operator CSV — may not be covered if it was installed outside ArgoCD
- NFS provisioner CSV — may linger in openshift-operators

If leftovers are found, delete them directly:
```
oc delete csv <csv-name> -n openshift-operators --ignore-not-found
oc delete subscription <sub-name> -n openshift-operators --ignore-not-found
```

### Final Report

Summarize the uninstall result:
- Cluster URL and OCP version
- What was removed:
  - ArgoCD apps deleted (count)
  - Operators removed (list)
  - Namespaces cleaned up (list)
  - CatalogSources removed
- What remains (intentionally kept):
  - OpenShift GitOps operator + ArgoCD
  - ICSP
  - MachineSets (CPU/GPU)
  - Pull secret
- Any warnings or issues encountered
- Phases that were skipped (and why)
- How to redeploy: `make deploy && make sync` (or `/install-rhoai`)
