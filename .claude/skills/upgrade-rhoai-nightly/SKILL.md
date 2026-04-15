---
name: upgrade-rhoai-nightly
description: Upgrade RHOAI nightly on the rhoaibu-cluster-nightly cluster. Updates catalog image, subscription channel, console banner, commits, pushes, and executes the safe upgrade procedure with monitoring.
argument-hint: "<image-with-digest> (e.g. quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4-ea.2@sha256:abc123...)"
allowed-tools: Bash(make *), Bash(oc *), Bash(git *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(sleep *), Bash(LOGDIR=*), Bash(for *), Bash(STATUS=*), Bash(date *), Bash(GIT_EDITOR=*), Read, Edit, Write, AskUserQuestion, Agent, Monitor
---

# Upgrade RHOAI Nightly on rhoaibu-cluster-nightly

Upgrade the RHOAI nightly build on the production cluster by updating git-managed configuration files and executing the safe upgrade procedure from CLUSTERS.md.

## Arguments

`$ARGUMENTS` must contain the full image reference with digest. Example:
```
quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4-ea.2@sha256:c0177f06608f4d2244c4998d5d4aaa5e377843226360b476f48a1f17fba06247
```

Parse the image reference to extract:
- **Tag**: e.g., `rhoai-3.4-ea.2` (the part between `:` and `@`)
- **Digest**: e.g., `sha256:c0177f06...` (the part after `@`)
- **Version**: e.g., `3.4` (extracted from tag pattern `rhoai-X.Y-*`)
- **Qualifier**: e.g., `ea.2` (the part after `rhoai-X.Y-`)
- **Display name**: e.g., `RHOAI 3.4 EA2 Nightly` (human-readable)
- **Banner text**: e.g., `RHOAI 3.4 EA2 Nightly Build - Mar 10, 2026` (with today's date)

**Channel logic:**
- Do NOT compute the channel from the qualifier. After the rebase step in Phase 0, read the channel value from `components/operators/rhoai-operator/base/patch-channel.yaml` — that file already contains the correct channel as maintained on main.
- Only update the channel if the user explicitly requests a channel change. In that case, verify the target channel exists in the catalog: `oc get packagemanifest rhods-operator -n openshift-marketplace -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'`

If the image reference is missing or cannot be parsed, ask the user for it. Do NOT guess.

## Execution Model

Follow the same background execution and log capture pattern as the uninstall-rhoai skill.

### Log Directory

```
LOGDIR=.tmp/logs/upgrade-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

## Instructions

Run from the repository root. Execute phases in order.

### Phase 0: Preflight

Run ALL of these checks in parallel:

```
oc whoami --show-server
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'
git branch --show-current
git fetch origin
git rev-list --count HEAD..origin/main
oc get csv -n redhat-ods-operator --no-headers 2>/dev/null
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
oc get pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null
```

**Branch check:** Confirm we are on the `clusters` branch. If not, stop and tell the user.

**Squash + rebase check:** Before rebasing, check if there are multiple commits on `clusters` ahead of `main` that should be squashed:

1. Count commits ahead: `git rev-list --count origin/main..HEAD`
2. If more than 1 commit ahead, show them: `git log --oneline origin/main..HEAD`
3. Ask the user: "clusters has N commits ahead of main. Squash into one before rebasing? (Recommended for clean history)"
4. If yes: `git reset --soft origin/main && git commit -m "<squash message summarizing all changes>"`

Then check if `clusters` is behind `origin/main` (rev-list count > 0):
- Show how many commits behind
- Show what's on main that's not on clusters: `git log --oneline HEAD..origin/main`
- Ask the user: "clusters is N commits behind main. Want to rebase before upgrading? (Recommended to pick up latest fixes)"
- If yes: `git rebase origin/main` then `git push --force-with-lease`
- If no: proceed without rebasing

**Upgrade path check:** Determine if OLM has a direct upgrade edge from the installed CSV to the target.

1. Get the installed CSV version: `oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}'`
2. Read the target channel from `components/operators/rhoai-operator/base/patch-channel.yaml` (the channel value after rebase)
3. Query the catalog for available versions on the target channel:
   ```
   oc get packagemanifest rhods-operator -n openshift-marketplace -o jsonpath='{range .status.channels[*]}{.name}: {.currentCSV}{"\n"}{end}'
   ```
4. If the installed CSV was from a different channel than the target, or if there's a version gap (e.g., skipping ea.1 to go to ea.2), warn the user:
   - "Installed CSV `rhods-operator.X.Y.Z` was on channel `<old>`. Target `rhods-operator.A.B.C` is on channel `<new>`. OLM may not have a direct upgrade path."
   - "Recommend: delete the old subscription/CSV and let ArgoCD recreate it on the new channel (clean install of operator only — DSC and application resources are preserved)."
   - Ask user: "Delete old subscription/CSV for a clean install? (Recommended when skipping versions or switching channels)"
   - Store the user's answer for use in Phase 2

**Report to user:**
- Cluster URL and OCP version
- Current RHOAI CSV version
- Current catalog image (from pod)
- Target image (from arguments)
- Upgrade path status (direct upgrade or clean install needed)
- ArgoCD app health summary
- Any apps that are not Synced/Healthy (flag as warnings)

Ask user to confirm before proceeding.

### Phase 1: Git Changes

Read each file before editing. Update these 4 files:

**1. `components/operators/rhoai-operator/base/catalogsource.yaml`**
- Update `spec.image` tag (e.g., `rhoai-3.4-ea.2-nightly`)
- Update `spec.displayName` (e.g., `RHOAI 3.4 EA2 Nightly`)

**2. `components/operators/rhoai-operator/base/patch-channel.yaml`**
- Do NOT change the channel unless the user explicitly requests it. The channel from main (after rebase) is already correct.
- If the user requests a channel change, update the `value` for the channel op and verify the channel exists in the catalog first.

**3. `components/operators/rhoai-operator/overlays/pinned/kustomization.yaml`**
- Update the `value` with full image reference including digest: `quay.io/rhoai/rhoai-fbc-fragment:rhoai-X.Y@sha256:...`
- Update the comment above with build identifier and date

**4. `clusters/overlays/rhoaibu-cluster-nightly/console-notification/base/console-notification.yaml`**
- Update `spec.text` with new banner text (e.g., `RHOAI 3.4 EA2 Nightly Build - Mar 10, 2026`)

After editing, show the full diff to the user: `git diff`

Commit and push:
```
git add components/operators/rhoai-operator/ clusters/overlays/rhoaibu-cluster-nightly/
git commit -m "Upgrade RHOAI to <version> <qualifier> nightly build"
git push
```

### Phase 2: Cluster Upgrade

Follow the safe upgrade procedure from CLUSTERS.md exactly. Run each step sequentially.

**Continuous Health Monitoring:** At the start of Phase 2, launch a background Monitor that polls cluster health every 30 seconds throughout the entire upgrade process. This runs concurrently with all other Phase 2 steps and provides real-time visibility into cluster state. Use the Monitor tool with a script like:

```
while true; do
  echo "$(date +%H:%M:%S) CSV: $(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods || echo 'none')"
  echo "$(date +%H:%M:%S) App: $(oc get application.argoproj.io/rhoai-operator -n openshift-gitops -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null)"
  echo "$(date +%H:%M:%S) DSC: $(oc get datascienceclusters default-dsc -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)"
  problem_pods=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -vE 'Running|Completed' | head -5)
  [ -n "$problem_pods" ] && echo "$(date +%H:%M:%S) PROBLEM PODS: $problem_pods"
  bad_nodes=$(oc get nodes --no-headers 2>/dev/null | grep -v ' Ready')
  [ -n "$bad_nodes" ] && echo "$(date +%H:%M:%S) BAD NODES: $bad_nodes"
  echo "---"
  sleep 30
done
```

Set `persistent: true` and stop the monitor after Phase 3 final verification is complete.

**Step 1: Disable auto-sync**
```
make sync-disable
```
This prevents race conditions during the upgrade.

**Step 2: Clean install (if user chose this in preflight) or standard sync**

**If clean install was chosen:**
```
# Delete old subscription and CSVs — DSC and app resources are preserved
oc delete subscription rhods-operator -n redhat-ods-operator --ignore-not-found
oc get csv -n redhat-ods-operator --no-headers -o name | grep rhods | xargs -I {} oc delete {} -n redhat-ods-operator --ignore-not-found
```

**Then sync all apps (both paths):**
```
make sync
```
Run in the background with log capture. This syncs rhoai-operator, which applies the new CatalogSource and Subscription. If old subscription was deleted, ArgoCD recreates it on the new channel. Monitor progress with:
```
tail -20 $LOGDIR/phase2-sync.log
```

**Step 3: Restart catalog pod**
After sync completes:
```
make restart-catalog
```
This forces the catalog pod to pull the new image, then restarts the operator.

**Step 4: Monitor the operator upgrade**

Wait for the new CSV to appear and reach `Succeeded`. Poll every 30 seconds:
```
oc get csv -n redhat-ods-operator --no-headers
```

Also monitor pods:
```
oc get pods -n redhat-ods-operator --no-headers
oc get pods -n redhat-ods-applications --no-headers | head -20
```

**What to watch for:**
- Old CSV transitioning from `Succeeded` to `Replacing` (standard upgrade)
- New CSV appearing with `Installing` then `Succeeded`
- Operator pod restarting with new image
- Application pods rolling out
- If pods are stuck in ContainerCreating on a single node for >5 minutes, delete them to allow rescheduling to a different node

If the CSV stays in `Installing` for more than 10 minutes:
- Check operator logs: `oc logs -n redhat-ods-operator -l name=rhods-operator --tail=50`
- Report to user and ask how to proceed

**Step 5: Verify RHOAI deployment**
```
oc get datascienceclusters
oc get csv -n redhat-ods-operator --no-headers
oc get pods -n redhat-ods-applications --no-headers
```

Wait until DataScienceCluster shows Ready and pods are Running.

**Step 6: Re-enable auto-sync**
```
make sync-enable
```

### Phase 3: Final Verification

Run ALL of these in parallel:

```
# CSV status
oc get csv -n redhat-ods-operator --no-headers

# DSC conditions (Ready, ComponentsReady, individual components)
oc get datascienceclusters default-dsc -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}){"\n"}{end}'

# ArgoCD apps
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers

# Problem pods (not Running or Completed)
oc get pods -n redhat-ods-applications --no-headers | grep -vE 'Running|Completed' || echo "All pods Running or Completed"

# Catalog pod image — verify the SHA matches the target digest
oc get pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly -o jsonpath='{.items[0].spec.containers[0].image}'

# Console banner
oc get consolenotification banner-nightly -o jsonpath='{.spec.text}'

# Routes
oc get routes -n redhat-ods-applications --no-headers

# Operator pods
oc get pods -n redhat-ods-operator --no-headers
```

**Catalog image verification:** Confirm the catalog pod image digest matches the target digest from the arguments. If they don't match, flag as an error — the catalog pod may not have pulled the new image.

**DSC conditions to check:**
- `Ready` must be `True`
- `ComponentsReady` must be `True`
- Individual component conditions with status `False` and reason `Removed` are expected (disabled components)
- Any component with status `False` and reason other than `Removed` is a warning

### Final Report

Summarize the upgrade result:
- Cluster URL and OCP version
- Previous RHOAI version → New RHOAI version
- CSV status (Succeeded / other)
- Catalog image SHA matches target: yes/no
- DataScienceCluster status (Ready + component summary)
- ArgoCD apps summary (how many Synced/Healthy)
- Routes available
- Console banner text
- Any warnings or issues encountered

### Rollback (if needed)

If the upgrade fails and user wants to rollback:
```
git revert HEAD
git push
make sync
make restart-catalog
oc get csv -n redhat-ods-operator -w
```
