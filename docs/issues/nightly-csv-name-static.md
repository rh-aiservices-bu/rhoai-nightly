# Post-GA nightly FBCs reuse the GA CSV name — OLM can never deliver a nightly upgrade

**Jira: NOT FILED** — filing target: RHOAI build/release engineering
(RHOAI-Build-Config owns the FBC generation). This file is the ready-to-file
draft.

Found 2026-08-05 on cluster-tm9xb (RHOAI 3.5.0) when the
`rhoai-3.5-nightly` tag rebuilt after 3.5.0 GA.

## Summary

Every post-GA rebuild of the `rhoai-3.5-nightly` FBC ships its head bundle as
CSV `rhods-operator.3.5.0` — the same name as the GA release and as every
other nightly on the line. OLM resolves upgrades by CSV name and
replaces/skipRange edges, so a cluster already running any build named
`rhods-operator.3.5.0` reports `AtLatestKnown` and **never upgrades**, no
matter how many newer nightlies the catalog serves. `registryPoll` refreshes
the catalog content on schedule and it changes nothing.

Observed concretely (tm9xb, 2026-08-05):

- Installed CSV `rhods-operator.3.5.0`, operator image
  `registry.redhat.io/rhoai/odh-rhel9-operator@sha256:0017d555…` (built from
  the 2026-08-04 FBC `f4183f7e`).
- Catalog updated to the 2026-08-05 nightly (index `3a41d1ee…`), whose
  packagemanifest offers CSV `rhods-operator.3.5.0` with operator image
  `…@sha256:676d1a94…`.
- Same name, different bundle → Subscription stays `AtLatestKnown`; no
  InstallPlan is ever generated.

Consequence for anyone consuming nightlies: the entire OLM update machinery
is inert on a nightly line after GA. The only way to move a cluster from
nightly N to nightly N+1 is a manual clean reinstall — delete the
Subscription + CSV and let OLM install fresh from the updated catalog
(operands survive; verified on this rig, but it is operator surgery no
customer-shaped consumer should need).

Pre-GA nightlies did not have this problem: EA builds carried distinct
versions (`3.5.0-ea.2` etc.), so each rebuild produced a new head with a real
upgrade edge.

## Steps to reproduce

1. Install RHOAI from a nightly FBC whose head is `rhods-operator.3.5.0`
   (channel `stable-3.x`, `installPlanApproval: Automatic`).
2. Point the CatalogSource at a newer build of the same nightly tag (or wait
   for `registryPoll` after the tag moves).
3. Catalog pod re-pulls; `oc get packagemanifest` shows the new bundle
   (different `containerImage` digest) under the same CSV name.
4. `oc get subscription rhods-operator -n redhat-ods-operator` →
   `state: AtLatestKnown`; the operator deployment keeps the old image
   indefinitely.

## Expected

Nightly bundles carry unique, ascending versions (e.g.
`3.5.0-nightly.20260805` or build-suffixed `3.5.0+1785937189` with matching
CSV names) and a `replaces`/`skipRange` chain, so OLM can deliver
nightly-to-nightly upgrades the way it delivers release upgrades.

## Workaround

Clean reinstall on every nightly bump (catalog pod must already be serving
the new content first — see `scripts/restart-catalog.sh` ordering):

```bash
oc delete subscription rhods-operator -n redhat-ods-operator
oc delete csv rhods-operator.3.5.0 -n redhat-ods-operator
# ArgoCD selfHeal recreates the Subscription; OLM installs the new bundle.
```
