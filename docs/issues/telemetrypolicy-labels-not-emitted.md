# TelemetryPolicy labels with fully resolvable sources are never emitted on data-plane metrics (RHCL 1.4.1, 1.4.2)

**Jira: NOT FILED** — filing target: CONNLINK (RHCL), wasm-shim. This file is the ready-to-file draft.

> Re-verified 2026-08-01 on **RHCL 1.4.2** (fresh 3.5.0 install, cluster-tm9xb):
> `kuadrant_allowed` in UWM carries only infra labels 80+ min after the policy
> Accepted+Enforced, with the label config demonstrably present in the
> `kuadrant-maas-default-gateway` EnvoyFilter and inference traffic flowing.
> (Config propagation itself works on 1.4.2 — a label added to the policy
> reached the EnvoyFilter within seconds — so this is squarely an emission
> bug, not a propagation one.)
>
> Re-verified again 2026-08-05 (fresh install, cluster-g767p, nightly built
> 2026-08-05, RHCL 1.4.2): same result — wasm `requestData` carries
> `metrics.labels.{model,subscription,user}`, policy Enforced, traffic 200s,
> zero series in UWM with any of the three labels; `kuadrant_allowed` label
> set = infra only.
>
> **Jira triangulation 2026-08-05:** still nothing filed for this.
> [CONNLINK-1132](https://redhat.atlassian.net/browse/CONNLINK-1132) (Closed)
> was the nearest candidate — wasm-shim filtered response-property CEL out of
> request-only actions — but its fix (wasm-shim#378, v0.14.0) shipped **in RHCL
> 1.4.1**, and this bug reproduces on 1.4.2, so it is not covered by 1132.
> CONNLINK-1300 remains the unresolvable-source complement (see below).

## Summary

RHOAI 3.5.0 + RHCL 1.4.1/1.4.2: a Kuadrant `TelemetryPolicy` adding labels (`model`,
`user`, `subscription`) on the MaaS gateway reports **Accepted=True,
Enforced=True**, and the labels are demonstrably present in the generated wasm
PluginConfig — but data-plane metrics come out unlabelled: `kuadrant_allowed{}`
carries no custom tags, `istio_requests_total` gains nothing. Verified after
gateway pod restart and with every label source individually resolvable (no
CEL errors in envoy logs — distinguishing this from CONNLINK-1300).

Per-subscription/per-model usage breakdowns are therefore impossible on
dashboards even though the policy machinery reports full success.

## Distinct from CONNLINK-1300

CONNLINK-1300 covers an *unresolvable* CEL source (NoSuchKey) aborting the
report task. This issue is the complement: **all sources resolvable, no error
logged, labels still absent**. Either the wasm-shim never attaches the labels
to the metrics it emits, or the emission path ignores the telemetry config
entirely.

## Detection

```bash
# 1. Policy Enforced and config present in the wasm EnvoyFilter:
oc get telemetrypolicy maas-telemetry -n openshift-ingress \
  -o jsonpath='{.status.conditions}'         # expect Accepted=True, Enforced=True
oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o json \
  | grep -o 'metrics.labels.[a-z_]*' | sort -u   # expect model/subscription/user

# 2. Fire authenticated inference traffic, wait ~2 min, then:
TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://$THANOS/api/v1/query" \
  --data-urlencode 'query=kuadrant_allowed' \
  | jq -r '[.data.result[].metric | keys] | flatten | unique | join(",")'
# BUG: only infra labels (container,endpoint,instance,job,namespace,pod,...).
# FIXED: model / subscription / user present.
```

## Steps to reproduce

1. RHOAI 3.5.0 with MaaS, RHCL 1.4.1 or 1.4.2, UWM enabled.
2. Apply a TelemetryPolicy on `maas-default-gateway` with e.g.
   `model: request.path` (trivially resolvable source).
3. Fire authenticated inference traffic; wait 2 min.
4. Query `kuadrant_allowed` in UWM — no `model` label appears.
5. `oc get telemetrypolicy` shows Accepted+Enforced; wasm PluginConfig in the
   generated EnvoyFilter contains the label config; envoy logs show no CEL or
   task errors.

## Expected

Labels configured in an Enforced TelemetryPolicy appear on the wasm-emitted
metrics.
