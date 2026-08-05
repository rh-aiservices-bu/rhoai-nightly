---
name: cleanup-stale-projects
description: Audit and delete stale RHOAI dashboard projects (empty shells and all-stopped projects) using scripts/cleanup-stale-projects.sh. Use when the user asks to clean up old/stale/abandoned AI projects or reclaim storage from unused workbenches and models.
---

# Clean Up Stale AI Projects

Audit RHOAI dashboard projects on the connected cluster and delete the stale
ones. `scripts/cleanup-stale-projects.sh` does the classification, dry-run,
and deleting; this skill wraps it in an investigate → dry-run → present
options → approve → execute → verify flow, and adds the deeper investigations
the script can't do (borderline cases, unattributed namespaces, off-scope
residue).

**Deletion is irreversible.** PVC contents (workbench home dirs, model
caches) are the one thing that cannot be recovered. Never delete anything the
user has not explicitly approved in this conversation — approval of one batch
does not extend to later batches.

## Arguments

Parse optional arguments:
- `--empty-days <N>` — age threshold for empty shells (default: 30)
- `--stopped-days <N>` — idle threshold for stopped projects (default: 30)
- `--audit-only` — produce the report and recommendations, delete nothing

## What the script classifies

| Class | Meaning | Age basis | Data loss on delete |
|---|---|---|---|
| EMPTY | No workloads, PVCs, or pods — namespace + RBAC only | Namespace creation | None |
| STOPPED | All workbenches stopped AND all models `serving.kserve.io/stop=true`, zero running pods | Last human touch (newest stop annotation / resource creation) | PVC contents |
| ACTIVE | Anything running or un-stopped | — | Never deleted by the script |

Each row includes `owner=` (dashboard requester annotation, else first
User rolebinding, else `admin-created`).

Scope is namespaces labelled `opendatahub.io/dashboard=true` only. Infra
namespaces that carry the label (`llm`, `evalhub-tenant`,
`models-as-a-service`) are hard-excluded in the script.

Model `status.lastTransitionTime` is NOT a staleness signal — operator
upgrades bump it on every CR. Stop annotations and creation timestamps are
the trustworthy signals.

## Instructions

Run from the repository root, against the cluster `oc` is logged in to.

### Step 1: Verify cluster

```bash
oc whoami --show-server
```

Confirm with the user this is the intended cluster if there is any ambiguity
(recent context mentioning multiple clusters, unfamiliar server URL).

### Step 2: Audit + dry-run

```bash
scripts/cleanup-stale-projects.sh          # full picture
scripts/cleanup-stale-projects.sh --delete-empty <N> --delete-stopped <M> --dry-run
```

The dry-run prints the exact `Will delete:` list for the thresholds without
touching anything.

### Step 3: Investigate borderline cases

Before presenting, investigate anything on (or suspiciously near) the delete
list that fits these patterns. This is what separates a safe cleanup from a
regrettable one:

1. **Recently-idle STOPPED projects (within ~2× the threshold)** — pull the
   actual last-touch evidence so the user can judge:
   ```bash
   oc get notebooks.kubeflow.org -n <ns> -o json | jq -r \
     '.items[] | .metadata.name + " stopped=" + (.metadata.annotations["kubeflow-resource-stopped"] // "never")'
   ```
   A workbench stopped 3 weeks ago reads very differently from one stopped
   5 months ago, even if both cross a 30-day line.

2. **Big storage holders** — call out any project holding ≥40Gi of PVCs by
   name; that is the irreversible part.

3. **Recently-emptied namespaces** — an EMPTY namespace only days old, or one
   whose gateway/playground resources were recently deleted by other
   operations, may be about to be repopulated by its owner. Recommend keeping
   anything under ~14 days regardless of threshold.

4. **Unattributed namespaces (`owner=admin-created`)** — these were created
   by `oc apply`, not through the dashboard. Two follow-ups:
   - Check for the **imported-YAML anomaly**: resource `creationTimestamp`s
     *older than the namespace itself* mean the project was applied from
     exported manifests (the API server accepts client-supplied timestamps).
     All resource ages in such a project are fake; judge by namespace age and
     pod log activity instead.
   - If the name smells like shared infrastructure (`openldap`, `*-server`,
     `*-operator-*`, databases), dispatch a background investigation agent
     before proposing deletion: what does it run, is it wired into cluster
     auth/config, does anything reference its Service DNS, do its logs show
     recent connections, is it externally exposed (Route/LoadBalancer)?
     Require a USED/UNUSED verdict with evidence.

5. **Broken-but-running projects** (CrashLooping stacks, RefsInvalid models)
   are ACTIVE by classification and out of the script's reach. List them
   separately with owner + evidence; deleting them (or just their broken CRs)
   is a per-case user decision executed with plain `oc delete`.

6. **Pod-restart red herring** — pod `startTime` after a node drain, upgrade,
   or hibernation wake is NOT user activity. Check container logs for actual
   requests (a Jupyter server with no HTTP requests since restart is idle).

### Step 4: Present options and get approval

Present a readable summary, not a raw dump:
- EMPTY: count, age range, and the dry-run list
- STOPPED: per-project idle time, owner, PVC Gi — flag the borderline and
  big-storage rows from Step 3
- ACTIVE + excluded: shown for reassurance about what will not be touched
- Borderline findings and your keep/delete recommendation for each

Then ask which thresholds/exclusions to apply. Offer concrete options
(e.g. "defaults", "conservative: also keep everything under 45d", "custom").
Keeps go in `--exclude ns1,ns2`. `--audit-only` invocations stop here.

Do not proceed without the user approving the actual dry-run list.

### Step 5: Execute

```bash
scripts/cleanup-stale-projects.sh --delete-empty <N> --delete-stopped <M> [--exclude ...]
```

The script re-verifies each namespace immediately before deleting it and
skips anything whose state changed since the audit. Deletes are async
(`--wait=false`). Any approved per-case deletions from Step 3.5 (broken CRs,
agent-verified infra namespaces) are done with plain `oc delete` alongside.

### Step 6: Verify termination

Namespaces with model CRs can take several minutes to finalize. Poll until
clear (background the wait if it is long):

```bash
oc get ns -l opendatahub.io/dashboard=true --no-headers | grep Terminating
oc get pv | grep -E "Released|Failed"    # PVs should drain to nothing
```

If a namespace is stuck Terminating for >10 minutes, inspect
`oc get ns <ns> -o jsonpath='{.status.conditions}'` — the usual cause is a
finalizer on a model CR whose controller is unhealthy. Report it rather than
force-removing finalizers; a stuck finalizer on this rig is usually a product
bug worth a `docs/issues/` entry (see CLAUDE.md mission).

### Step 7: Report

Summarize: number deleted per class, storage reclaimed (sum of pvcGi),
anything skipped by the pre-delete re-verification, anything still
terminating, borderline cases kept and why, and the ACTIVE projects left
untouched.

## What this skill does NOT do

- Widen the label selector. Non-dashboard namespaces are found only through
  Step 3 investigations, each individually approved.
- Tenant notification. If the cluster has active tenants, remind the user
  that STOPPED deletions lose PVC data and a heads-up in the tenant channel
  may be warranted before large purges.
- Force finalizer removal on stuck namespaces.
