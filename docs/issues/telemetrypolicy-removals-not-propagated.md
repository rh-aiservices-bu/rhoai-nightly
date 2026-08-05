# TelemetryPolicy label REMOVALS never propagate to the wasm config (RHCL 1.4.2)

**Jira: NOT FILED** — filing target: CONNLINK (RHCL). This file is the
ready-to-file draft. **File it referencing
[CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300)** (see
below) rather than as an isolated report.

Found 2026-08-01 on cluster-tm9xb (RHOAI 3.5.0 nightly, RHCL 1.4.2) during a
controlled propagation experiment. Supersedes the RHCL 1.4.1-era
"spec updates don't propagate at all" issue: on 1.4.2 propagation is
**asymmetric** — additions apply within seconds, removals never apply.

> **Re-verified 2026-08-05** (fresh install, cluster-g767p, nightly built
> 2026-08-05, RHCL 1.4.2): addition propagated to the EnvoyFilter in **≤5s**;
> removal still absent from the EnvoyFilter after **120s** with the policy
> reporting Accepted=True/Enforced=True throughout. Delete+recreate (ArgoCD
> selfHeal) cleaned it in ~15s. Inference stayed healthy during the probe (the
> probe label is a resolvable literal — the hang below needs an unresolvable
> stale source).
>
> **CONNLINK-1300 linkage (checked 2026-08-05):** 1300 (Refinement, fixVersion
> RHCL 1.4.3, now attached to 3 customer cases) tracks the *unresolvable
> stale-label → CEL NoSuchKey → rate limiting silently disabled* leg. Its
> comments **describe this removal-propagation bug as a workaround obstacle**
> ("I had to delete the tenant cr and create it again because TelemetryPolicy
> changes were not propagated to the WASM EnvoyFilter") but do NOT track it,
> and the response-stream hang below appears nowhere in it. So: comment on
> 1300 with the propagation asymmetry + stream-hang evidence, and get either a
> scope extension or a linked bug. Related same-class finding from Kuadrant's
> security audit: CONNLINK-1443 (fail-open on pipeline build error).

## Summary

Adding a label to an Enforced Kuadrant `TelemetryPolicy` reaches the generated
wasm EnvoyFilter within seconds. **Removing** a label does not — the
EnvoyFilter keeps emitting-config for the deleted label indefinitely (>10 min
observed, no convergence), while the policy reports `Accepted=True,
Enforced=True` with `observedGeneration` current. The stale label config
survives until the policy is deleted and recreated.

Consequence: label cleanups, renames, and security-motivated removals (e.g.
dropping a label whose CEL source turned unresolvable — the CONNLINK-1300
rate-limit killer) silently do nothing. The operator says Enforced; the data
plane runs the old config.

## Severity escalation (2026-08-04, cluster bu-nightly-2): a stale removed
## label HANGS every inference response on the gateway

Live production impact observed, far beyond missing metrics: a `costCenter`
label that had been removed from the TelemetryPolicy weeks earlier was still
present in the generated wasm config (this bug). Its CEL source no longer
resolved, and the wasm-shim's **response-phase** evaluation failed on every
inference request:

```
wasm log kuadrant-wasm-shim: Failed to evaluate message builder:
  CelError::Resolve { NoSuchKey("costCenter") }
```

Effect: every `POST /…/v1/chat/completions` through the gateway returned the
complete response body and then **never terminated the stream** — no chunked
terminator/END_STREAM — so every client hung to its own read timeout (curl
`-m 30` → exactly 30.0s), on **both** HTTP/2 and HTTP/1.1, streaming and
non-streaming. Envoy never wrote an access-log line for these requests (the
stream never completed inside envoy). OpenAI-style SDKs hang per call.

Proof of mechanism: deleting the TelemetryPolicy (ArgoCD selfHeal recreated
it from git within a second; Kuadrant regenerated the wasm config without
`costCenter` immediately) fixed it instantly — same request went from 30s
client-timeout to **0.55s (H2) / 0.18s (H1.1)**, CelErrors stopped. A second
cluster (tm9xb) with identical build + identical EnvoyFilter content but no
stale label never exhibited the hang.

Two product asks follow:
1. Propagate removals (this issue's core ask).
2. A CEL evaluation failure in the wasm-shim's response path must fail open
   for stream lifecycle — log and skip the label, never withhold end-of-stream
   from the client.

## Steps to reproduce

1. RHOAI 3.5.0 with MaaS; RHCL 1.4.2; a `TelemetryPolicy` targeting
   `maas-default-gateway`, Accepted+Enforced.
2. Add a label with a static source:
   ```bash
   oc patch telemetrypolicy maas-telemetry -n openshift-ingress --type=merge \
     -p '{"spec":{"metrics":{"default":{"labels":{"audit_probe":"\"1\""}}}}}'
   ```
3. Within seconds, `oc get envoyfilter kuadrant-maas-default-gateway
   -n openshift-ingress -o json | grep audit_probe` → present. (Additions
   propagate — this half works.)
4. Remove the label:
   ```bash
   oc patch telemetrypolicy maas-telemetry -n openshift-ingress --type=json \
     -p '[{"op":"remove","path":"/spec/metrics/default/labels/audit_probe"}]'
   ```
5. Wait. The EnvoyFilter still contains `audit_probe` after 10+ minutes;
   policy shows Accepted=True Enforced=True, `metadata.generation` ==
   `status.observedGeneration`.
6. Remedy check: `oc delete telemetrypolicy maas-telemetry -n openshift-ingress`
   and recreate it (GitOps selfHeal or re-apply) → the EnvoyFilter is rebuilt
   without the stale label.

## Expected

A spec change that the operator acknowledges (generation observed, Enforced
reported) is reflected in the generated data-plane config — removals the same
as additions.

## Workaround

Delete + recreate the TelemetryPolicy after any label removal (with ArgoCD
selfHeal, deletion alone suffices — it is recreated from git).
