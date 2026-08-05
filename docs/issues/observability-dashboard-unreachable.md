# RHOAI Observability dashboard: "Unable to reach observability dashboards"

**Jira: [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354)**
"RHOAI Perses proxy not auto-configured — observability field on Dashboard CR
is never set" (filed 2026-08-03 by others, **In Progress**). Source-verified
here: that single unset field explains the whole failure. No separate filing
needed; a corroborating comment is drafted at the end.

## Symptom

RHOAI console → **Observe & monitor → Dashboard** renders:

```
Unable to reach observability dashboards
Unexpected token '<', "<!doctype "... is not valid JSON
```

Observed 2026-08-04 on cluster-tm9xb (RHOAI 3.5.0, released-track FBC
`f4183f7e`, COO 1.5.1, observability overlay active). Present since the
observability install (2026-07-31) — not an upgrade regression.

Server-side everything looks healthy, which is why scripted checks miss it:
`data-science-perses-0` is 1/1 Running, its Service answers on :8080, 7
Perses dashboards/datasources exist, 11 monitoring pods Running, and
`make diagnose` §11 reports the backend PASS.

## Root cause: `Dashboard.spec.observability.enabled` is never set

One unset field gates the entire observability bundle. Chain
(source-verified on the build running here, odh-dashboard `bb0a50ca` /
rhods-operator `a4e1eee6`):

1. `dashboard-operator/api/v1alpha1/dashboard_types.go` — `Observability.Enabled`
   is `+kubebuilder:default=false`.
2. `dashboard-operator/internal/controller/actions.go` — `deployObservabilityManifests`
   returns `ErrObservabilityDisabled` unless `spec.observability.enabled` is true,
   so **none** of `manifests/observability/rhoai/` is rendered.
3. **Nothing ever sets it**: rhods-operator's
   `internal/controller/modules/dashboard/handler.go` (`BuildModuleCR`) projects
   only `DSC.Spec.Components.Dashboard` + deploymentMode + components + gateway,
   and `DSCDashboard` has no observability field at all.

Live confirmation:

```bash
oc get dashboard default-dashboard -o jsonpath='{.spec.observability}'   # absent
oc get dashboard default-dashboard -o jsonpath='{.status.conditions}'
#   ObservabilityAvailable=False reason=Disabled "Observability is not enabled"
```

Two consequences, both observed:

- **The allow-rule NetworkPolicy is never deployed.** The bundle contains
  `manifests/observability/rhoai/network-policy.yaml` → NP
  `dashboard-perses-access` (ingress from ns `redhat-ods-applications`, pods
  `app.kubernetes.io/part-of: rhods-dashboard`, port 8080). It is **absent
  cluster-wide**. Meanwhile `perses-operator-access` (rhods-operator,
  RHOAIENG-41715, present in every build) selects the Perses pod with an
  Ingress policy admitting only the perses-operator — and once any Ingress
  policy selects a pod, everything not allowed is denied. So the dashboard is
  blocked purely because its counterpart rule was never rendered.
- **The RHOAI PersesDashboards are never created** — only component-owned ones
  (`dashboard-2-llm-d-traffic-admin`, `dashboard-3-maas-usage-admin`, …) exist;
  `dashboard-0-cluster*` / `dashboard-1-model*` are missing.

The proxy target itself is **correct** — `manifests/rhoai/base/federation-configmap.yaml`
module `perses` points at service `data-science-perses`, namespace
`redhat-ods-monitoring`, port 8080, matching the live Service exactly. The
`<!doctype` parse error is the BFF's HTML error page after its upstream
request times out.

### Evidence for the blocked path

From a dashboard pod, the Perses Service times out (packets dropped, exit 28):

```bash
POD=$(oc get pods -n redhat-ods-applications -l app=rhods-dashboard --no-headers | head -1 | awk '{print $1}')
oc exec -n redhat-ods-applications "$POD" -c rhods-dashboard -- \
  curl -s -m 5 -o /dev/null -w "%{http_code}\n" \
  http://data-science-perses.redhat-ods-monitoring.svc.cluster.local:8080/api/v1/dashboards
# → exit 28 (timeout). Expect 200 once reachable.
```

The deny side is `networkpolicy/perses-operator-access` in
`redhat-ods-monitoring`, owned by `Monitoring/default-monitoring` (the RHOAI
operator's Monitoring controller, not COO). It is *correct by itself* — the
problem is the missing counterpart above:

```yaml
spec:
  podSelector:
    matchLabels: {app.kubernetes.io/managed-by: perses-operator}   # matches data-science-perses-0
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: openshift-cluster-observability-operator}}
      podSelector: {matchLabels: {app.kubernetes.io/name: perses-operator}}
    ports: [{port: 8080, protocol: TCP}]
  policyTypes: [Ingress]
```

Distinct from [RHOAIENG-67929](https://redhat.atlassian.net/browse/RHOAIENG-67929)
(New), which covers the *operator* being blocked when COO runs outside its
expected namespace, symptom "No dashboards found".

## Steps to reproduce

1. RHOAI 3.5.0 with `make observability` (DSCI monitoring storage set, COO
   installed, Perses/Tempo/OTel cascade up).
2. Console → Observe & monitor → Dashboard → the error above.
3. `oc get dashboard default-dashboard -o jsonpath='{.spec.observability}'`
   → absent; `…-o jsonpath='{.status.conditions}'` →
   `ObservabilityAvailable=False reason=Disabled`.
4. `oc get networkpolicy -A | grep dashboard-perses-access` → nothing (the
   allow-rule was never rendered).
5. Run the in-pod curl above → timeout.

## Expected

RHOAI's own observability install path sets `Dashboard.spec.observability.enabled`
so the bundle renders: the `dashboard-perses-access` NetworkPolicy and the
RHOAI PersesDashboards get created, and the Observability page shows its
panels (request rate, success rate, GPU/CPU/memory, per-subscription usage).

## Prepared comment for RHOAIENG-80354

> Corroborating on 3.5.0 (released-track FBC `f4183f7e`, dashboard
> `bb0a50ca`, operator `a4e1eee6`), with the downstream blast radius: because
> `Dashboard.spec.observability.enabled` defaults false and no rhods-operator
> path sets it (`modules/dashboard/handler.go BuildModuleCR` projects only
> components/deploymentMode/gateway; `DSCDashboard` has no observability
> field), `deployObservabilityManifests` short-circuits on
> `ErrObservabilityDisabled` and the **entire** `manifests/observability/rhoai/`
> bundle is skipped. Two visible consequences: (1) NetworkPolicy
> `dashboard-perses-access` is never created, so with `perses-operator-access`
> (RHOAIENG-41715) selecting the Perses pod, dashboard→Perses is denied — a
> curl from a `rhods-dashboard` pod to
> `data-science-perses.redhat-ods-monitoring.svc:8080` times out; (2) the RHOAI
> PersesDashboards (`dashboard-0-cluster*`, `dashboard-1-model*`) are absent —
> only component-owned ones exist. The proxy target itself is correct
> (`federation-configmap.yaml` module `perses` → data-science-perses /
> redhat-ods-monitoring / 8080); the `Unexpected token '<'` the user sees is
> the BFF's HTML error page after the blocked upstream request times out.
> `Dashboard/default-dashboard` reports
> `ObservabilityAvailable=False reason=Disabled`.
>
> Addendum from a second cluster (same build): the NetworkPolicy is only half
> the blast radius. With `dashboard-perses-access` present and an in-pod curl
> from the dashboard pod to Perses returning 200, the page still fails
> identically — the frontend's `/perses/api/v1/...` fetch has no registered
> proxy route while `observability.enabled` is unset, so the SPA catch-all
> serves `index.html` (HTTP 200, text/html) and the JSON parse throws. Also
> confirming the documented workaround: the manual Dashboard patch survives
> reconciliation (the operator's SSA apply doesn't claim `spec.observability`),
> flips `ObservabilityAvailable=True reason=Deployed`, rolls the dashboard
> pods with the module, and the page loads.

## bu-nightly-2 evidence (2026-08-05): the network block is only half the bug

On bu-nightly-2 (3.5.0, same FBC) the `dashboard-perses-access` NetworkPolicy
existed (manually applied months earlier) and an in-pod curl from the
dashboard pod to Perses returned **200** — yet the page was still broken with
the same `Unexpected token '<'`. Proven cause: the frontend fetches
`/perses/api/v1/...` (path confirmed in the plugin bundle), and with
`observability.enabled` unset the backend never registers the `/perses`
proxy route, so the SPA catch-all returns `index.html` with HTTP 200 and the
JSON parse fails. The browser error is the missing proxy route, not the
NetworkPolicy — both are gated on the same flag.

## Workaround A13 (temporary): set the field manually

The Jira's documented workaround **works and persists** — contrary to the
earlier claim here that the module reconciler reverts it (it does not: the
rhods-operator's SSA apply doesn't own `spec.observability`, so a manual
merge-patch survives reconciliation). Verified live on bu-nightly-2
2026-08-05: field intact after reconcile, `ObservabilityAvailable=True
reason=Deployed`, dashboard pods rolled with the observability module, and
the `/perses/api` route began answering.

```bash
oc patch dashboard default-dashboard --type merge -p \
  '{"spec":{"observability":{"enabled":true,"persesService":{"name":"data-science-perses","namespace":"redhat-ods-monitoring","port":8080}}}}'
```

Carried as A13 in [../workarounds.md](../workarounds.md) because the
Observability dashboards are a feature under test and are untestable without
it. Remove when a nightly carries
[opendatahub-operator#3923](https://github.com/opendatahub-io/opendatahub-operator/pull/3923)
(the fix projects DSCI monitoring config into `Dashboard.Spec.Observability`;
detection: `oc get dashboard default-dashboard -o json | jq
'.metadata.managedFields[] | select(.manager != "kubectl-patch") |
.fieldsV1."f:spec"."f:observability"'` — non-null means the operator now owns
the field and the manual patch is redundant).
