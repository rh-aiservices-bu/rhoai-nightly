# OpenShift AI issues encountered by this repo

**This directory is the repo's primary output.** The mission is to surface
RHOAI bugs on nightlies early so they get fixed in the product before release
— one file per upstream issue, with symptom, root cause, detection, workaround
(if any), and Jira status.

Working rules:

- **Every issue gets filed upstream.** Files marked NOT FILED contain a
  ready-to-file draft; unfiled entries are backlog, not an end state.
- When a nightly fixes an issue, update the file (fixed-in build/Jira) rather
  than deleting it — the ledger is also the record of what this rig caught.
- Workarounds are the exception, not the rule; the few we carry are indexed in
  [../known-issues.md](../known-issues.md) with Jira + remove-when conditions.


Full Jira sweep of every entry below. "3.5 GA" fixVersion = the unreleased
2026-08-19 GA — fixes reach nightlies earlier, so **verify per build** (each
entry's Detection command) before removing a workaround. Live-verified notes
are from cluster-fzgjg (`rhods-operator.3.5.0`, installed 2026-07-30).

| Entry | Jira(s) | Status | Verdict |
|---|---|---|---|
| A1 wasm leak / `allow_on_headers_stop_iteration` | [RHOAIENG-77007](https://redhat.atlassian.net/browse/RHOAIENG-77007) (field vs istio 1.26), [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) (empty-workloadSelector leak, filed 2026-07-31), [RHOAIENG-79550](https://redhat.atlassian.net/browse/RHOAIENG-79550), [RHOAIENG-78869](https://redhat.atlassian.net/browse/RHOAIENG-78869) (3.6 GA) | Backlog / New / Review | **OPEN — keep workaround** |
| A1b NetworkPolicy `update` RBAC | — | — | **NOT FILED** (candidate) |
| A2 MaaS gateway istio-proxy OOM | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) Resolved (no fixVersion); open siblings [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227), [RHOAIENG-79551](https://redhat.atlassian.net/browse/RHOAIENG-79551), [RHOAIENG-71755](https://redhat.atlassian.net/browse/RHOAIENG-71755) | mixed | **Keep 2Gi** |
| A3 payload-processing NetworkPolicy | [RHOAIENG-75511](https://redhat.atlassian.net/browse/RHOAIENG-75511) (selector → `gateway.istio.io/managed`); adjacent [RHOAIENG-71268](https://redhat.atlassian.net/browse/RHOAIENG-71268) (OCP 4.22 deny-all, 3.4.3) | Resolved | **FIXED — verify then remove** |
| A4 trustyai pods/log for EvalHub | [RHOAIENG-77020](https://redhat.atlassian.net/browse/RHOAIENG-77020) (+[RHOAIENG-77693](https://redhat.atlassian.net/browse/RHOAIENG-77693)) | Resolved, 3.5 GA | **FIXED — verify then remove** |
| A7 DSC `ogx: Managed` | [RHOAIENG-77869](https://redhat.atlassian.net/browse/RHOAIENG-77869) (default → Managed for OGX GA) | Resolved | **FIXED — verify then remove** |
| A8 "Tenant CR not available yet" | [RHOAIENG-76548](https://redhat.atlassian.net/browse/RHOAIENG-76548) (+76563, 77589, 76928 — all Resolved) | Resolved, 3.5 GA | **FIXED — keep settle-gate anyway** |
| A9 feast `apiservers` RBAC | [RHOAIENG-79331](https://redhat.atlassian.net/browse/RHOAIENG-79331) | Closed, 3.5 GA | **FIXED — live-verified on fzgjg** (CSV role now grants it) |
| A9 feast `notebooks` RBAC (2nd gap) | — | — | **NOT FILED** (candidate; evidence: 3.5.0 grants notebooks only in `opendatahub-feast-manager-role`, not the controller SA's `feast-operator-manager-role`) |
| A10 gen-ai egress :8321 | [RHOAIENG-79633](https://redhat.atlassian.net/browse/RHOAIENG-79633) | Closed/Done, 3.5 GA | **FIXED — verify then remove** |
| D1 ea.2 H2 END_STREAM hang | — (fixed upstream with **no Jira trail**: framework `a8bbe6a6` via ODH `a846538`; adjacent [RHOAIENG-79535](https://redhat.atlassian.net/browse/RHOAIENG-79535), [RHOAIENG-79619](https://redhat.atlassian.net/browse/RHOAIENG-79619)) | — | Fixed in 3.5.0 image `84cee292`; ea.2 line never gets it |
| D1 empty MaaS catalog | [RHOAIENG-76220](https://redhat.atlassian.net/browse/RHOAIENG-76220) | Resolved | fixed (already recorded) |
| D1 `ModelsAsServiceReady` gate | [RHOAIENG-78159](https://redhat.atlassian.net/browse/RHOAIENG-78159) + dashboard-side fix `3e5b156a0` (accepts `AIGatewayReady`) | fixed | **RESOLVED dashboard-side — live-verified on fzgjg** (picker works with only `AIGatewayReady`) |
| D2 GPU panels blank | [RHOAIENG-79543](https://redhat.atlassian.net/browse/RHOAIENG-79543) (collector drops DCGM metrics before rename; +72523, 71953) | Review | OPEN |
| D2 TelemetryPolicy labels never emitted | — (nearest: [RHOAIENG-79318](https://redhat.atlassian.net/browse/RHOAIENG-79318) Resolved, NoSuchKey variant only) | — | **NOT FILED** (candidate) |
| D2 NoSuchKey disables rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) (+RHOAIENG-79318, 76060 Resolved) | Refinement, RHCL 1.4.3 (due 2026-09-03) | OPEN until RHCL 1.4.3 |
| D2 TelemetryPolicy updates don't propagate | — | — | **NOT FILED** (candidate) |
| D2 ogx playground breaks on upgrade | — (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384) stale ConfigMaps, New) | — | **NOT FILED** for the 3.5 incarnation |
| D2 PersesDashboards stay Degraded | [RHOAIENG-76396](https://redhat.atlassian.net/browse/RHOAIENG-76396) Closed/**Obsolete**, [COO-1727](https://redhat.atlassian.net/browse/COO-1727) Closed/Not-a-Bug | closed without fix | No active tracker |
| D2a bare catalog URL (current variant) | — (lineage [RHOAIENG-76220](https://redhat.atlassian.net/browse/RHOAIENG-76220) Resolved covers the old discovery variant; indirectly in 79529's asks) | — | **NOT FILED** as its own bug (candidate) |
| D2b ServiceMonitors `bearerTokenFile` | — (precedent: [RHOAIENG-19954](https://redhat.atlassian.net/browse/RHOAIENG-19954), Kueue, 2.19) | — | **NOT FILED** for 3.5 (candidate) |
| D2c playground auto-wiring (3 defects) | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) (all three; our workaround B is its documented workaround); defect 1 fixed on main by [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) (`280db9dc5`, ephemeral MaaS keys); related 69083, 38779 | New (unassigned) | OPEN — defects 2+3 unaddressed; defect 2's root = D2a (maas-api side) |
| E1 Kuadrant caches missing provider | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) | Backlog (since 2026-06-10) | OPEN — install-maas.sh auto-remedies |
| E1 trustyai no self-heal on CRD arrival | [RHOAIENG-77786](https://redhat.atlassian.net/browse/RHOAIENG-77786) (fix PR opendatahub-operator#3822) | Resolved, 3.5 GA | **FIXED — verify then retire remedy** |
| E2 / F1 / F2 | — | — | ours / not Jira-worthy |

**Filing candidates** (unfiled, we hold the evidence): A1b, A9-notebooks,
D1-H2-hang (fixed but no trail — for the record/backport question),
D2-TelemetryPolicy-labels, D2-TP-update-propagation, D2-ogx-upgrade, D2a
current variant, D2b. Each NOT-FILED issue file in this directory contains its ready-to-file draft.

**Source verification of the "fixed" claims (2026-07-31, fetched clones of
opendatahub-io + red-hat-data-services):**

- Every fix claimed for 3.5 **is genuinely on the `rhoai-3.5` branch**: A3
  (MaaS NP selector `gateway.istio.io/managed`, `networkpolicy.yaml:39` — on
  3.5 the operator no longer creates the NP at all), A4 (trustyai
  `pods/log` in `prefetched-manifests/trustyai/.../manager-rbac.yaml:277`,
  landed Jul 17), A7 (OGX default → Managed, opendatahub-operator
  `creation.go:72` via `09266f69c2`, Jul 17), A10 (gen-ai egress 8321,
  `networkpolicy.yaml:47`, cherry-pick of #8948, Jul 29), E1-trustyai
  (self-heal `1dbd1cbb0d` #3822 + follow-up `a26713a739` #3848, both
  ancestors of rhoai-3.5).
- **All of those are ABSENT from `rhoai-3.5-ea.2`** — the ea.2 line lacks
  every one (frozen before the fixes landed). A cluster on ea.2 (bu-nightly-2)
  needs the full A-section; a 3.5.0 cluster can start retiring A3/A4/A7/A10 +
  the E1-trustyai remedy after per-build Detection checks.
- **The one true main-vs-3.5 contradiction:** D2c defect-1 (RHOAIENG-38993,
  `280db9dc5` ephemeral-key rework) is on `main` and `rhoai-3.6-ea.1` only —
  **not cherry-picked to `rhoai-3.5`** (verified via branch --contains). 3.5
  keeps the fake-token env plus a `maas-`-prefix-gated runtime override.
- **A9-notebooks nuance:** the feast manifests themselves DO carry the
  notebooks rule (even ea.2's vendored `role.yaml:131`); on 3.5 the
  controller-manager ClusterRole is generated by the `odh-feast-module-operator`
  wrapper image, whose rendering drops the rule (live 3.5.0 cluster verified
  lacking it). The bug is in the wrapper's RBAC generation.
- A3 side-note: the ea.2 operator-side NP fix (`f2d9751e`) still sits on
  unmerged `cherry-pick/rhoai-3.5-ea.2/...` branches — ea.2 will never get it.

## Files

| File | Jira |
|---|---|
| [maas-payload-h2-endstream-hang.md](maas-payload-h2-endstream-hang.md) | not filed (fixed upstream, no trail) |
| [playground-maas-autowiring.md](playground-maas-autowiring.md) | RHOAIENG-79529 |
| [maas-catalog-bare-model-url.md](maas-catalog-bare-model-url.md) | not filed |
| [feast-operator-notebooks-rbac.md](feast-operator-notebooks-rbac.md) | not filed |
| [ai-gateway-networkpolicy-update-rbac.md](ai-gateway-networkpolicy-update-rbac.md) | not filed |
| [telemetrypolicy-labels-not-emitted.md](telemetrypolicy-labels-not-emitted.md) | not filed |
| [telemetrypolicy-updates-not-propagated.md](telemetrypolicy-updates-not-propagated.md) | not filed |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | not filed |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) | not filed |
