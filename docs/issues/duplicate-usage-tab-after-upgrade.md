# Observability dashboard shows two "Usage" tabs after an upgrade — one dead, and it hides the real one

**Jira: NOT FILED** — this file is the ready-to-file draft. It contains **two
separate bugs with different owners**, and they need **two filings**:

1. **maas-controller** (RHOAIENG) — relocated its Perses resources across
   namespaces without adopting or pruning the originals, which were created
   with no `ownerReference` and so can never be garbage-collected.
2. **RHOAI dashboard / Observability tab strip** (RHOAIENG) — keys tabs on
   `metadata.name` alone, ignoring `metadata.project`, producing duplicate DOM
   ids, a double-selected tabset, and a tab that cannot be selected.

Bug 2 is latent on a clean cluster and stays a landmine after bug 1 is fixed.

Found 2026-08-07 on **bu-nightly-2** (RHOAI 3.5.0, nightly `3a41d1ee` built
2026-08-05). **Not reproducible on a fresh install**: cluster-g767p runs the
byte-identical build and shows one tab.

**Who is affected — the trigger is narrower than "an upgrade".** What matters
is whether the cluster *existed continuously across the 2026-08-04
`maas-controller` change* that moved its Perses output between namespaces:

- bu-nightly-2 created the old object on **2026-07-25**, was still running when
  the controller rolled on **2026-08-04**, and kept it. Affected.
- g767p was installed **2026-08-05**, after the move, so it only ever created
  the new object. Clean.

A cluster that merely took a nightly-to-nightly catalog bump across 2026-08-04
is affected exactly the same way — no CSV version change is required. Any
cluster installed after 2026-08-04 is permanently clean.

## Summary

The **Observe → Observability dashboard** tab strip renders:

```
Cluster | Models | LLM Traffic | LLM Utilization | Usage | Usage | LLM Performance
```

Two tabs are labelled `Usage`. They are backed by two different
`PersesDashboard` CRs that **share the name `dashboard-3-maas-usage-admin`** in
two different namespaces, both with `spec.config.display.name: "Usage"`.

This is not cosmetic. The **stale** dashboard wins and the **current** one is
unreachable, so the operator loses the rate-limiting and token-consumption
panels added in 3.5 — and the tab that does render cannot load data either,
because its datasource is orphaned too.

## Evidence

```
$ oc get persesdashboards.perses.dev -A          # bu-nightly-2 (upgraded)
NAMESPACE                 NAME                                  CREATED
redhat-ods-applications   dashboard-3-maas-usage-admin          2026-07-25T01:35:05Z   <-- ORPHAN
redhat-ods-monitoring     dashboard-0-cluster-admin             2026-04-30T13:20:37Z
redhat-ods-monitoring     dashboard-1-model                     2026-04-30T13:20:37Z
redhat-ods-monitoring     dashboard-1-model-admin               2026-07-24T20:20:36Z
redhat-ods-monitoring     dashboard-2-llm-d-traffic-admin       2026-08-04T22:01:54Z
redhat-ods-monitoring     dashboard-3-llm-d-utilization-admin   2026-08-04T22:01:54Z
redhat-ods-monitoring     dashboard-3-maas-usage-admin          2026-08-04T21:56:08Z   <-- CURRENT
redhat-ods-monitoring     dashboard-4-llm-d-performance-admin   2026-08-04T22:01:54Z

# g767p (fresh install of the same build): the same 7 minus the orphan.
```

| | `redhat-ods-applications` (orphan) | `redhat-ods-monitoring` (current) |
|---|---|---|
| `ownerReferences` | **`null`** | `maas.opendatahub.io/v1alpha1 Config/default` (controller=true) |
| labels | `app.kubernetes.io/name: maas-api`, `maas.opendatahub.io/tenant-name: default-tenant` (3.4 tenant scheme) | `app.kubernetes.io/component: perses` |
| last `maas-controller` Apply | **frozen 2026-08-04T21:53:43Z** | live — 2026-08-07T16:41:28Z |
| datasource ref | `kuadrant-prometheus-datasource` | `data-science-prometheus-datasource` |
| Limitador metrics | `authorized_calls`, `limited_calls` | `authorized_calls_total`, `limited_calls_total` |
| panels | 6 — `totalErrors`, Title Case | 7 — adds `totalRateLimited`, `tokenConsumptionOverTime` table |
| variables | `user, subscription, model` | `user, subscription, model, `**`view_by`** |

The `redhat-ods-monitoring` copy is **byte-identical between the two clusters**
(`diff` empty), confirming this is upgrade history and not a build difference.

**Control that rules out a titling quirk:** `dashboard-1-model` and
`dashboard-1-model-admin` are *both* titled "Models" and exist on **both**
clusters, yet only one "Models" tab renders. The UI does filter the non-admin
variant — so the duplicate really is two admin dashboards, not a display-name
collision the UI would normally absorb.

### The controller handoff

`maas-controller` (`odh-maas-controller-rhel9@sha256:d3adc683...`) was rolled at
`2026-08-04T21:53:58Z`. Its `managedFields` show the exact moment it stopped
writing to the old namespace and started writing to the new one:

```
redhat-ods-applications/dashboard-3-maas-usage-admin:  Apply 2026-08-04T21:53:43Z   <- last write ever
redhat-ods-monitoring/dashboard-3-maas-usage-admin:    Apply 2026-08-07T16:41:28Z   <- still writing
```

## Source-level root cause

**It is a namespace move, not a rename.** The resource name
`dashboard-3-maas-usage-admin` and the title `Usage` are byte-identical in
`red-hat-data-services/models-as-a-service` on both `origin/rhoai-3.4` and
`origin/rhoai-3.5` (`deployment/components/observability/observability/dashboards/usage-dashboard.yaml`);
only panels and queries changed.

The move is commit **`fbe914c4` — "feat: usage dashboard to query DSC metric
store (#985)"** (2026-07-01), present on `origin/rhoai-3.5`, absent from
`origin/rhoai-3.4`. Its message states it plainly:

> "moving the creation of observability resources that are related to the usage
> dashboard from per-tenant to global reconciliation in the LifecycleReconciler
> … The dashboard is now created in the monitoring namespace"

**3.4 path** — rendered into the *application* namespace as part of the tenant
bundle (`maas-controller/pkg/platform/tenantreconcile/pipeline.go`), then
applied by `tenantreconcile/apply.go:120`:

```go
childNs := u.GetNamespace()
if childNs != "" && childNs == tenant.Namespace {
    controllerutil.SetControllerReference(tenant, u, scheme)
} else {
    setTenantTrackingLabels(u, tenant)   // cross-namespace: labels ONLY, no ownerRef
}
```

The tenant CR lives in `models-as-a-service` and the dashboard in
`redhat-ods-applications`, so it took the `else` branch — which is exactly why
the stale object has tracking labels and **no `ownerReference`**.

**3.5 path** — `maas-controller/pkg/controller/maas/self_deployment_controller.go:495`
`ensureUsageDashboard` renders into `--monitoring-namespace` and sets a
controller reference to `Config/default`.

### Why nothing ever prunes it

1. The 3.4-era object has **no `ownerReferences` at all**, so Kubernetes GC has
   nothing to cascade from.
2. The 3.5 controller only creates/updates the dashboard. Its sole
   `PersesDashboard` delete path is ownership-gated
   (`self_deployment_controller.go:581`, `skipping deletion of unowned
   usage-logs resource`) — the stale object is unowned, in another namespace,
   and not part of the usage-logs bundle. Three independent reasons it is never
   touched.
3. There is no label-selector prune, no `DeleteAllOf`, and no upgrade migration
   anywhere in `maas-controller` for Perses resources.
4. The ODH operator's generic GC is label-driven on
   `platform.opendatahub.io/part-of`. The dashboard-operator's Perses
   dashboards carry it; the MaaS ones carry neither that label nor an ownerRef,
   so they sit outside GC's reach entirely.

**Precedent for the fix being asked for:** this same repo *did* ship an upgrade
migration for an analogous namespace move — `8d8f7d1f` "feat: migrate
maas-db-config secret to infrastructure namespace on upgrade (#1149)". The
dashboard move got no equivalent.

### Why the UI shows both (bug 2, in code)

`packages/observability/src/perses/perses-client/perses-client.ts` fetches the
global cross-project list (`/api/v1/dashboards`), so both copies return. Then
`packages/observability/src/utils/dashboardUtils.ts` `filterDashboards` dedupes
on `metadata.name` only, with no notion of project:

```ts
.filter(({ metadata: { name } }) => {
  if (name.endsWith(PERSES_DASHBOARD_ADMIN_SUFFIX)) { return true; }  // both are -admin -> both kept
  return !names.has(`${name}${PERSES_DASHBOARD_ADMIN_SUFFIX}`);
})
```

Both copies end in `-admin`, so both survive the filter — and both carry
`display.name: "Usage"`.

### Related Jira

- [RHOAIENG-60373](https://issues.redhat.com/browse/RHOAIENG-60373) **Closed** —
  *"Add owner reference to Perses resources created by maas-controller"*. This
  is what gave the 3.5 copy its `Config/default` ownerRef. It did **not**
  address already-created unowned copies, which is precisely this bug.
- [RHOAIENG-61344](https://issues.redhat.com/browse/RHOAIENG-61344) Closed —
  *"MaaS controller bundle not cleaned up on DSC disable or uninstall"*, same
  class of cleanup gap.
- [RHOAIENG-69213](https://issues.redhat.com/browse/RHOAIENG-69213) New — COO
  v1.5.0 vs the 3.4 Observability dashboard; different bug, same area.

No issue or commit anywhere describes duplicate Perses dashboards or a
migration for the relocated one — searched 2026-08-07.

### The orphan is live, not inert

`perses-operator` keeps pushing it into the Perses server, so it is a real
dashboard rather than a UI caching artifact:

```
info Reconciling PersesDashboard: redhat-ods-applications/dashboard-3-maas-usage-admin
info Dashboard updated: dashboard-3-maas-usage-admin
```

The backend confirms it — `GET /perses/api/api/v1/dashboards` returns **8**
dashboards on bu-nightly-2 and **7** on g767p (Perses "project" == namespace).

Its companion `persesdatasource.perses.dev/kuadrant-prometheus-datasource` in
`redhat-ods-applications` is orphaned the same way (`ownerReferences: null`,
same 2026-07-25 timestamp) and **fails to reconcile every 16 minutes**:

```
ERROR Reconciler error {"controller":"persesdatasource",
  "PersesDatasource":{"name":"kuadrant-prometheus-datasource","namespace":"redhat-ods-applications"},
  "error":"configmaps \"prometheus-web-tls-ca\" not found"}
```

That ConfigMap only exists in `redhat-ods-monitoring`. Even if it resolved, the
orphan's PromQL uses the pre-rename metric names without `_total`.

### UI behaviour (bug 2)

Both tabs carry the **identical** `href`, the **identical** DOM `id`, and both
report `aria-selected="true"`:

```
tab[4] "Usage"  href=...&dashboard=dashboard-3-maas-usage-admin  id=pf-tab-dashboard-3-maas-usage-admin-...  aria-selected=true
tab[5] "Usage"  href=...&dashboard=dashboard-3-maas-usage-admin  id=pf-tab-dashboard-3-maas-usage-admin-...  aria-selected=true
```

Clicking the second does nothing — selection stays on the first. Only the
`redhat-ods-applications` copy ever renders (verified by panel titles: Title
Case, `Total Errors`, no `view_by`).

## Detection

```bash
# Duplicate PersesDashboard names across namespaces => duplicate tabs.
oc get persesdashboards.perses.dev -A \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | uniq -d

# Orphans: any PersesDashboard/PersesDatasource with no ownerReference is
# unreclaimable and is almost certainly a pre-upgrade leftover.
oc get persesdashboards.perses.dev,persesdatasources.perses.dev -A -o json | jq -r '
  .items[] | select((.metadata.ownerReferences // []) | length == 0)
  | "\(.kind) \(.metadata.namespace)/\(.metadata.name) created=\(.metadata.creationTimestamp)"'
```

Clean result: no duplicate names, and every object owned. On a fresh 3.5
install both commands return nothing.

## Is this self-inflicted by this repo's upgrade procedure? No.

Asked and checked, because it is the first question a triager will raise:

- **This repo manages no Perses resources.** The stale CR's `managedFields`
  name **`maas-controller`** as field manager — not ArgoCD, not `kubectl`. The
  product created it; we never wrote to it.
- **The missing `ownerReference` is product code**, not configuration:
  `tenantreconcile/apply.go:120` takes the labels-only `else` branch for any
  resource outside the tenant's namespace. Nothing an operator of the cluster
  can influence.
- **No cleanup mechanism has a handle on it — and this does not depend on how
  the upgrade was performed.** Checked on the live object 2026-08-07:

  ```
  ownerReferences:                   NONE     -> Kubernetes GC has nothing to cascade from
  labels matching /olm|operator/:    {}       -> OLM CSV replacement cannot reclaim it
  platform.opendatahub.io/part-of:   ABSENT   -> the ODH generic GC cannot select it
  finalizers:                        none
  ```

  For contrast `redhat-ods-monitoring/dashboard-0-cluster-admin` carries both an
  ownerRef (`Dashboard/default-dashboard`) *and* `part-of: dashboard`. The orphan
  has neither. Combined with the code facts below — maas-controller's only Perses
  delete path is ownership-gated, and the RHOAI monitoring controller deletes
  only the Tempo dashboard by exact name — **no upgrade mechanism, normal OLM
  edge or clean reinstall, has anything to act on.** `restart-catalog.sh`
  (workarounds.md §A6) reclaims operator-*owned* resources; this object is owned
  by nothing, so that step is neither cause nor cure.

- **The `app.kubernetes.io/managed-by: maas-observability` label on the orphan
  is upstream's, not this repo's** — a name collision worth pre-empting, since
  this repo uses the same label value elsewhere. Upstream sets it in
  `deployment/components/observability/observability/dashboards/kustomization.yaml`
  (kustomization literally named `maas-observability`) on `origin/rhoai-3.4`.
  This repo creates **no** `PersesDashboard` at all, and applies its own
  identically-valued label only to the TelemetryPolicy and Istio Telemetry in
  `openshift-ingress`. The orphan's field manager is `maas-controller`.

  Corroboration from the same bundle: it also ships
  `prometheus-web-tls-ca-configmap.yaml`. In 3.4 the CA ConfigMap and the
  dashboard were deployed together into the application namespace; the move took
  the CA to `redhat-ods-monitoring` and stranded the dashboard, which is exactly
  why the orphaned datasource now fails with `configmaps "prometheus-web-tls-ca"
  not found`.
- **Upstream already owns this class of bug.**
  [RHOAIENG-60373](https://issues.redhat.com/browse/RHOAIENG-60373) fixed
  ownership for newly-created Perses resources without migrating existing ones,
  and `8d8f7d1f` shipped a migration for an analogous namespace move.
- **The blast radius is customers.** `fbe914c4` is on `rhoai-3.5` and absent
  from `rhoai-3.4`, so any supported 3.4 → 3.5 upgrade with MaaS enabled
  crosses this move. This is not a nightly-rig artifact.

**Known limit of this analysis, stated precisely.** No 3.4-GA → 3.5-GA OLM
upgrade was *observed*; the argument above is from the object's ownership state
and from code. That distinction was checked rather than assumed:

- bu-nightly-2 retains exactly **one** InstallPlan, `install-v6lfz`, created
  `2026-08-05T16:19:42Z` — this repo's `restart-catalog.sh` deletes the
  Subscription, which cascade-removes prior InstallPlans, so the upgrade history
  for the relevant window is **gone and cannot be reconstructed** from the
  cluster.
- No second upgraded cluster exists to compare: a sweep of all 14 kubeconfig
  contexts on 2026-08-07 found RHOAI installed on only two — bu-nightly-2
  (8 dashboards, 1 orphan) and the fresh g767p (7, none).
- The namespace handoff is timestamped `2026-08-04T21:53`, roughly 18.5 hours
  *before* that CSV reinstall, so the reinstall did not perform the relocation.

This is why the argument is deliberately built on ownership rather than on
upgrade mechanics: an object with no ownerRef, no OLM labels and no GC label
cannot be reclaimed by *any* path, so the distinction between a normal edge and a
clean reinstall does not affect the conclusion. It would be falsified by finding
either (a) a cleanup routine that selects on something this object does carry, or
(b) that the 3.4 dashboard is only created under a configuration unique to this
rig — but the 3.4 path is the ordinary tenant reconcile that runs for any MaaS
tenant.

## Consequence

- The 3.5 Usage dashboard (rate-limited requests, token-consumption table,
  `view_by`) is **unreachable** on any cluster upgraded across the move.
- The tab that does render queries a datasource that cannot reconcile, so it
  shows no data.
- Every upgraded cluster carries a permanently unreclaimable CR pair.

## No workaround carried

This degrades the Observability UX; it does not block deployment or testing, so
per the repo [mission](../../CLAUDE.md) it is documented and filed rather than
worked around.

Cluster admins who want the real dashboard back can delete the two orphans —
they are unowned, so nothing recreates them:

```bash
oc delete persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-applications
oc delete persesdatasource kuadrant-prometheus-datasource -n redhat-ods-applications
```

This is a per-cluster manual action, deliberately **not** automated in this repo.

## Filing drafts

**Filing 1 — maas-controller (RHOAIENG).** *MaaS Perses dashboard/datasource
orphaned in `redhat-ods-applications` after namespace relocation.* Include: the
two-object table, the `managedFields` handoff timestamps, the absent
`ownerReference` on the originals, and the failing datasource reconcile loop.
Ask for the controller to either adopt (set `ownerReferences` and move) or
delete its prior-namespace objects on startup, and for all created objects to
carry an `ownerReference` from the outset.

**Filing 2 — RHOAI dashboard (RHOAIENG).** *Observability tab strip renders
duplicate, unselectable tabs when two PersesDashboards share a name across
namespaces.* Include: the identical `href`/DOM `id`, both tabs
`aria-selected=true`, the second tab being inert, and that the older dashboard
shadows the newer. Ask for tabs to be keyed on `project + name` and for a
dedupe/disambiguation rule. Note this is reproducible independently of bug 1 by
creating any two same-named dashboards in different namespaces.
