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

## No workaround carried

The rig functions without the page (metrics are still collected and
queryable via Prometheus/Thanos), so per repo policy this is documented and
tracked, not worked around. If a demo needs it before the fix ships, an admin
can apply the missing `dashboard-perses-access` NetworkPolicy from the
dashboard repo's `manifests/observability/rhoai/network-policy.yaml` into
`redhat-ods-monitoring` — note that patching `Dashboard.spec.observability`
directly is reverted by the rhods-operator module reconciler.
