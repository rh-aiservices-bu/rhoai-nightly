# MaaS Usage PersesDatasources reference SA-token Secrets no controller creates — every Usage dashboard panel 401s

**Status:** NOT FILED (draft below) — target **RHOAIENG** (odh-observability /
maas-controller usage-logs stack), with a mirror on
[github.com/opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service)
(the defect ships in maas-controller's bundle, so GitHub fix velocity matters).
The designed `usage-logs-loki` switch artifacts ARE carried (imperative,
documented — see **Workaround**); they bypass rather than fix the orphaned
references, and the switched path currently fails for a second-stage reason.
**Found:** 2026-11-23, OpenShift 5.0.1 + RHOAI
`rhods-operator.3.6.0` nightly (`rhoai-3.6-nightly`, catalog digest
`sha256:864736d5…`).

## Symptom

Every panel of the MaaS **Usage** view of the Observability dashboard errors:

```
Loki query_range error: 401 - {"errorType":"proxy","error":"Unauthorized"}
```

The usage-logs tenancy proxy (`deploy/usage-logs-tenancy-proxy`, ns
`redhat-ods-monitoring`) logs the rejection on every datasource request:

```
Auth extraction failed: TokenReview: [invalid bearer token, token lookup failed]
```

The dashboard infrastructure itself is healthy: LokiStack
`data-science-usage-logs-lokistack` Ready (odh-observability controller, from
DSCI `monitoring.usageLogs`), DSCI `UsageLogsCollectorAvailable=True`, gateway
Service present, perses server Running. Annotating the DSCI to force a reconcile
and restarting the dashboard operator do not help — the orphaned reference has
no reconciliation path (Root cause).

## Root cause

The maas-controller usage-logs bundle (upstream
[opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service)
@ `0697c1d`, `deployment/components/observability/usage-logs/dsci-managed/`)
renders the PersesDatasources `usage-logs-multi-tenancy` and `usage-logs-all` in
ns `redhat-ods-monitoring` whose HTTPProxy specs reference Secrets
`usage-logs-multi-tenancy-secret` / `usage-logs-all-secret`. **No code path in
models-as-a-service, odh-observability, or odh-dashboard creates those Secrets**
— a GitHub-wide search for `usage-logs-multi-tenancy-secret` hits only the
datasource template itself.

The credential model those Secrets belong to was already retired: the
odh-observability controller contains
`cleanupLegacyPersesDatasourceSATokenSecrets()`
([actions.go](https://github.com/opendatahub-io/odh-observability/blob/main/internal/controller/actions.go)),
which actively **deletes** operator-owned shared SA-token Secrets for Perses
datasources ("Pre-scoping Perses datasources used shared SA-token Secrets.
Remove only …"), replaced by per-request auth via
`client.kubernetesAuth.enable: true` — which these datasources also carry. So
each datasource simultaneously carries the new authentication mechanism **and**
an orphaned legacy secret reference.

Runtime effect: the RHOAI perses server resolves the missing Secret to an
empty/invalid credential and still sends `Authorization: Bearer …`; the tenancy
proxy (TokenReview-based, no audience restriction — any valid k8s token would
pass) rejects it. The orphan is at the template level — there is no
secret-creation path anywhere in the stack, so no reconcile nudge can repair it.

## Detection

```bash
# Datasource carries both mechanisms: a legacy secret ref AND kubernetesAuth
oc get persesdatasource usage-logs-multi-tenancy -n redhat-ods-monitoring -o yaml \
  | grep -B3 -A6 'secret:\|kubernetesAuth'

# The referenced Secret does not exist
oc get secret usage-logs-multi-tenancy-secret -n redhat-ods-monitoring   # NotFound
oc get secret usage-logs-all-secret -n redhat-ods-monitoring             # NotFound

# Tenancy proxy rejects every datasource request
oc logs -n redhat-ods-monitoring deploy/usage-logs-tenancy-proxy \
  | grep "Auth extraction failed"

# Usage panels: 401 wrapped as a proxy error (as rendered in the dashboard)
# Loki query_range error: 401 - {"errorType":"proxy","error":"Unauthorized"}
```

## Workaround

Carried (imperative, documented): the designed `usage-logs-loki` artifacts —
Secret `usage-logs-loki` in the MaaS infra namespace plus SA
`redhat-ai-gateway-infra/usage-logs-loki-reader` and ClusterRoleBinding
`usage-logs-loki-reader` → ClusterRole `usage-tenancy-proxy` (full artifact
description in
[maas-api-logs-proxy-identity-bypass.md](maas-api-logs-proxy-identity-bypass.md)).
They make maas-controller repoint both datasources at maas-api's read-only,
per-user-scoped Loki proxy (RHAI-22640, commit `a6adc1a`) — bypassing the
tenancy proxy and the orphaned Secret refs entirely; activated on the
reprovision cluster (2026-11-23), and the datasources repointed as designed.
The switched path still fails identically (all panels 401) for the
identity-contract reason documented in
[maas-api-logs-proxy-identity-bypass.md](maas-api-logs-proxy-identity-bypass.md)
— the artifacts are kept because they are the designed mechanism and will be
correct once either upstream fix lands. REMOVE-WHEN: the MaaS Usage dashboard
renders data without the maas-api-Loki switch — i.e. when either upstream issue
is fixed (the orphaned secret references are dropped/minted, or the /v1/logs
identity contract is made serviceable).

## References

- [RHAI-22640](https://issues.redhat.com/browse/RHAI-22640) — the maas-api Loki
  read proxy (`patchPersesDatasourceMaaSAPILoki` switch, secret
  `usage-logs-loki`)
- [models-as-a-service commit a6adc1a](https://github.com/opendatahub-io/models-as-a-service/commit/a6adc1a)
  (2026-11-10) — implements the usage-logs-loki switch
- Upstream bundle:
  `deployment/components/observability/usage-logs/dsci-managed/` (datasource
  templates carrying the orphaned refs)
- odh-observability
  [`internal/controller/actions.go`](https://github.com/opendatahub-io/odh-observability/blob/main/internal/controller/actions.go)
  — `cleanupLegacyPersesDatasourceSATokenSecrets()`: the retired credential
  model these refs belong to
- Related finding: the Usage dashboard moved from PromQL (Limitador counters) to
  Loki-backed panels on this nightly — supersedes the premise of
  [maas-usage-dashboard-total-suffix.md](maas-usage-dashboard-total-suffix.md)
  (its 2026-11-23 Disposition note); that issue remains valid only for builds
  carrying the PromQL-based panels.

## Filing draft (RHOAIENG; mirror on models-as-a-service GitHub)

> **Title:** DSCI-managed usage-logs PersesDatasources reference static SA-token
> Secrets that no controller creates — all Usage dashboard panels fail with 401
>
> **Component:** maas-controller usage-logs bundle (dsci-managed) /
> odh-observability Perses datasources; environment: RHOAI
> `rhods-operator.3.6.0` nightly (`rhoai-3.6-nightly`), OpenShift 5.0.1, DSCI
> `monitoring.usageLogs` on, LokiStack `data-science-usage-logs-lokistack`
> Ready, `UsageLogsCollectorAvailable=True`
>
> The maas-controller usage-logs bundle
> (`deployment/components/observability/usage-logs/dsci-managed/`) renders
> PersesDatasources `usage-logs-multi-tenancy` and `usage-logs-all` in ns
> `redhat-ods-monitoring` whose HTTPProxy specs reference Secrets
> `usage-logs-multi-tenancy-secret` / `usage-logs-all-secret`. No code path in
> models-as-a-service, odh-observability, or odh-dashboard creates those Secrets
> — a GitHub-wide search for `usage-logs-multi-tenancy-secret` hits only the
> datasource template itself. The references are leftovers of the retired shared
> SA-token credential model: odh-observability's
> `cleanupLegacyPersesDatasourceSATokenSecrets()`
> (`internal/controller/actions.go`) exists precisely to delete such Secrets,
> and its replacement is per-request `client.kubernetesAuth.enable: true` —
> which the same datasources also carry. The perses server resolves the missing
> Secret to an empty/invalid credential and still sends
> `Authorization: Bearer …`; the TokenReview-based usage-logs tenancy proxy
> rejects every request:
> `Auth extraction failed: TokenReview: [invalid bearer token, token lookup failed]`.
> Every Usage dashboard panel errors:
> `Loki query_range error: 401 - {"errorType":"proxy","error":"Unauthorized"}`.
> The rest of the stack is healthy (LokiStack Ready, gateway Service present,
> perses Running), and neither a DSCI reconcile nudge nor a dashboard-operator
> restart changes anything — the bundle has no secret-creation path, so the
> reference is orphaned at the template level. Expected: either the bundle stops
> referencing the Secrets (it already carries `kubernetesAuth`, the replacement
> mechanism) or a controller mints them; as shipped, the dsci-managed usage-logs
> dashboards are unusable.
