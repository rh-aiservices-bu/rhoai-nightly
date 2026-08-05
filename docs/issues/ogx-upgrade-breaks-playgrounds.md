# In-place ogx operator upgrade breaks every pre-existing Playground: stale ca-bundle volume + ClusterRole lacks configmaps/delete

**Jira: NOT FILED** — filing target: RHOAIENG/RHAIENG, component OGX/Gen AI. This file is the ready-to-file draft.

> **Status check 2026-08-05:** unfixed everywhere. The cleanup code exists
> upstream (`ogx-k8s-operator` `configmap_reconciler.go`
> `cleanupOldGeneratedConfigMaps`, since #295/#309, 2026-06), but
> `config/rbac/role.yaml` ClusterRole `manager-role` still grants configmaps
> only `create/get/list/patch/update/watch` — **no `delete`** — on upstream
> HEAD, rhds `main`, and rhds `rhoai-3.5`. Confirmed live on the 2026-08-05
> nightly (g767p): `ClusterRole/ogx-k8s-operator-manager-role` ships without
> configmaps delete. [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384)
> (New, no progress, triage-bot comment only) covers only the low-severity
> accumulation half — the upgrade breakage remains unfiled.

## Detection

```bash
# RBAC half (works on any cluster, no upgrade needed):
oc get clusterrole ogx-k8s-operator-manager-role -o json | \
  jq -c '.rules[] | select(.resources // [] | index("configmaps")) | .verbs'
# BUG present: verbs list lacks "delete".

# Full symptom (only after an in-place ogx upgrade with pre-existing playgrounds):
oc get ogxserver -A   # pre-upgrade instances report Failed
# operator logs: configmaps ... is forbidden: cannot delete / template mismatch
```

## Summary

After an in-place upgrade of the ogx operator (RHOAI 3.5 line), every
`OGXServer` (Gen AI playground backend) created **before** the upgrade reports
`Failed` — although the workload pod actually runs. Two compounding defects:

1. The ogx operator's ClusterRole lacks `configmaps/delete`, so it cannot
   clean up the old generated ConfigMaps it wants to replace (see also
   RHAIENG-6384, "OGX operator does not clean up old generated ConfigMaps
   after spec changes" — New).
2. The operator never strips the now-obsolete `ca-bundle` volume from
   pre-existing Deployments, so reconcile of old instances can never converge
   on the new template.

There is **no safe in-place fix**: the stale ConfigMap is still mounted, so
granting `delete` (or removing the CM manually) wedges the running pod.

## Remedy (manual, recurs every ogx upgrade)

Delete + recreate the OGXServer — fresh instances use the clean, volume-less
template. All playground-local state/config customizations are lost (which on
3.5 also re-triggers the broken MaaS auto-wiring, RHOAIENG-79529).

## Reproduce

1. RHOAI 3.x with a working Gen AI playground (OGXServer Ready).
2. Upgrade to a build with a newer ogx operator (template without ca-bundle).
3. OGXServer goes `Failed`; operator logs show configmaps delete forbidden /
   deployment template mismatch; pod keeps running old spec.

## Expected

Upgrades reconcile pre-existing OGXServers to the new template (including
removing obsolete volumes), with the RBAC needed to do so.
