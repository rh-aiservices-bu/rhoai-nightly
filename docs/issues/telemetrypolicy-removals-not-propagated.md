# TelemetryPolicy label REMOVALS never propagate to the wasm config (RHCL 1.4.2)

**Jira: NOT FILED** — filing target: CONNLINK (RHCL). This file is the
ready-to-file draft.

Found 2026-08-01 on cluster-tm9xb (RHOAI 3.5.0 nightly, RHCL 1.4.2) during a
controlled propagation experiment. Supersedes the RHCL 1.4.1-era
"spec updates don't propagate at all" issue: on 1.4.2 propagation is
**asymmetric** — additions apply within seconds, removals never apply.

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
