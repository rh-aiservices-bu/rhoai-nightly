# TelemetryPolicy labels with fully resolvable sources are never emitted on data-plane metrics (RHCL 1.4.1, 1.4.2)

**Jira: NOT FILED** — filing target: CONNLINK (RHCL), wasm-shim. This file is the ready-to-file draft.

> Re-verified 2026-08-01 on **RHCL 1.4.2** (fresh 3.5.0 install, cluster-tm9xb):
> `kuadrant_allowed` in UWM carries only infra labels 80+ min after the policy
> Accepted+Enforced, with the label config demonstrably present in the
> `kuadrant-maas-default-gateway` EnvoyFilter and inference traffic flowing.
> (Config propagation itself works on 1.4.2 — a label added to the policy
> reached the EnvoyFilter within seconds — so this is squarely an emission
> bug, not a propagation one.)

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
