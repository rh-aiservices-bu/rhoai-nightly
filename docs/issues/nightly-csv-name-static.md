# Post-GA nightly FBCs reuse the GA CSV name — OLM can never deliver a nightly upgrade

**Jira: NOT FILED** — filing target: RHOAI build/release engineering
(RHOAI-Build-Config owns the FBC generation). This file is the ready-to-file
draft.

Found 2026-08-05 on cluster-tm9xb (RHOAI 3.5.0) when the
`rhoai-3.5-nightly` tag rebuilt after 3.5.0 GA.

> **Jira search 2026-08-05:** nothing tracks this (nearest misses:
> RHOAIENG-75776/75777 EA-CSV naming/stuck-subscription variants,
> RHOAIENG-80314 Jenkins FBC version tracer). No build-config commit
> addresses it either. This repo's carried mitigation is
> `scripts/restart-catalog.sh`'s image-aware guard (workarounds.md A6):
> CSV names equal + bundle images differ → clean reinstall.
>
> **Baseline recorded 2026-08-14** (cluster-bq4x2, nightly `bda8c789`) — a
> *baseline*, not a re-verification: the deadlock is only observable after a
> catalog bump. Subscription `AtLatestKnown`, installed CSV
> `rhods-operator.3.5.0`, installed operator image == offered image
> (`3dbb64be…`) — i.e. the healthy no-pending-upgrade state. Mechanism
> unchanged (the CSV name is still static across nightlies). **Still unfiled**;
> searched again 2026-08-14, no build/release-eng tracker found
> (RHOAIENG-80314 and RHOAIENG-75776 are adjacent FBC/versioning issues, but
> neither covers CSV-name reuse).

## Detection

```bash
# Baseline (any healthy cluster): record what OLM thinks is latest.
oc get subscription rhods-operator -n redhat-ods-operator \
  -o jsonpath='{.status.state} {.status.installedCSV}{"\n"}'   # AtLatestKnown rhods-operator.3.5.0

# The bug is live when the catalog serves a NEWER bundle under the SAME name.
# NB: two packagemanifests named rhods-operator exist (redhat-operators + the
# nightly catalog) and a bare `oc get packagemanifest rhods-operator` resolves
# to the RELEASED catalog — the label selector is required or the comparison
# reports a false positive on every healthy cluster:
INSTALLED=$(oc get deployment rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
OFFERED=$(oc get packagemanifest -l catalog=rhoai-catalog-nightly \
  -o jsonpath='{.items[?(@.metadata.name=="rhods-operator")].status.channels[?(@.name=="stable-3.x")].currentCSVDesc.annotations.containerImage}' 2>/dev/null)
echo "installed=$INSTALLED"; echo "offered=  $OFFERED"
# Different digests + Subscription AtLatestKnown = OLM will never upgrade; use restart-catalog.sh.
```

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
