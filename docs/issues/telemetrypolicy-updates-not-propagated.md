# TelemetryPolicy spec updates are never propagated to the generated wasm config — only delete+recreate works (RHCL 1.4.1)

**Jira: NOT FILED** — filing target: CONNLINK (RHCL). This file is the ready-to-file draft.

## Summary

Editing an existing `TelemetryPolicy`'s spec (e.g. changing the label set) has
no effect on the data plane: the operator observes the new generation and
reports **Accepted=True, Enforced=True** for it, but the generated EnvoyFilter
/ wasm PluginConfig keeps the OLD label configuration — verified to survive
even a Kuadrant operator restart. Only **deleting and recreating** the
TelemetryPolicy forces a rebuild of the wasm config.

This silently strands clusters on stale telemetry config: the status says the
new spec is enforced when it is not.

## Reproduce

1. RHCL 1.4.1, TelemetryPolicy with label set A on a gateway; confirm A in the
   generated EnvoyFilter's wasm PluginConfig.
2. Edit the policy to label set B.
3. Policy status: Accepted/Enforced at the new generation.
4. EnvoyFilter PluginConfig: still label set A. Restarting the kuadrant
   operator does not help.
5. Delete + recreate the policy → PluginConfig now shows B.

## Impact

Any GitOps flow managing TelemetryPolicies (ArgoCD apply-on-change) silently
diverges from the data plane; users must know to delete+recreate on every spec
change.

## Expected

Spec updates reconcile into the wasm config like creation does; or at minimum
the status must not report Enforced for a generation that isn't.
