# OpenShift AI issues encountered by this repo

**This directory is the repo's primary output.** The mission is to surface
RHOAI bugs on nightlies early so they get fixed in the product before release
— one file per **current** upstream issue, with symptom, root cause, detection,
workaround (if any), and Jira status.

Working rules:

- **Every issue gets filed upstream.** Files marked NOT FILED contain a
  ready-to-file draft; unfiled entries are backlog, not an end state.
- **Delete a file once its issue is no longer relevant** (fix verified on a
  current nightly, or the workaround it justified is gone). Git history is the
  ledger; this directory holds only what's live.
- Workarounds are the exception; the few we carry are indexed in
  [../workarounds.md](../workarounds.md) (developer doc) with Jira +
  remove-when conditions. [../known-issues.md](../known-issues.md) is the
  product-facing summary of these issues for cluster users/managers.

## Current issues

> `(D2b)` below is a historical ID from a retired triage scheme kept only
> because it appears in older notes and commit messages; there is no
> section D in [../workarounds.md](../workarounds.md).

| File | Jira | Status |
|---|---|---|
| [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md) | **NOT FILED** — draft ready, target **OCPBUGS** (OpenShift ingress/Gateway API); re-searched 2026-08-05, still nothing upstream | Open; workaround A11 — **precondition live on g767p 2026-08-05** (2 ELB IPs vs 1 node-AZ); **absent on multi-AZ bq4x2 2026-08-14** (2 IPs vs 2 node-AZs, 6/6 probes 200) — kept, since the remove-when is an upstream default change, not a per-cluster measurement |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) (D2b) | **NOT FILED** — partial upstream fix #3812 merged (main/3.6 only, operator monitor only); identical-mechanism precedent [OCPBUGS-88022](https://issues.redhat.com/browse/OCPBUGS-88022) (NFD) | Open — re-confirmed fresh bq4x2 2026-08-14, both monitors still rejected; cluster-wide sweep found the same rejection in **5 namespaces** (redhat-ods-applications ×2, openshift-operators/otel, openshift-jobset-operator, openshift-gitops-operator) — scope unchanged from g767p 2026-08-05 |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | **NOT FILED** (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384), covers accumulation only) | Open — RBAC gap (no configmaps delete) still shipped in the 2026-08-14 nightly: `ogx-k8s-operator-manager-role` configmaps verbs are `create,get,list,patch,update,watch`. Symptom half is **not verifiable on a fresh install** (needs an in-place ogx upgrade) — held, not re-verified |
| [telemetrypolicy-removals-not-propagated.md](telemetrypolicy-removals-not-propagated.md) | **NOT FILED** — file as a **standalone CONNLINK bug** (the planned vehicle, a comment on [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300), is dead: 1300 was Closed / Won't Do 2026-09-11) | Open — re-proven bq4x2 2026-08-14 (add **3s**, remove **still unpropagated at 159s** while the policy reported Accepted+Enforced and its spec no longer held the label; delete+ArgoCD-recreate cleared it in ~10s); **severity escalated 2026-08-04**: a stale removed label hung every inference response on bu-nightly-2 |
| [nightly-csv-name-static.md](nightly-csv-name-static.md) | **NOT FILED** — target RHOAI build/release eng (searched 2026-08-05: no build-project tracker found) | Open — mechanism unchanged on the 2026-08-14 nightly (CSV still `rhods-operator.3.5.0`); baseline on bq4x2 is healthy (`AtLatestKnown`, installed == offered), so the deadlock itself is only observable after a catalog bump. Mitigated by restart-catalog.sh image-aware guard (A6) |
| [duplicate-usage-tab-after-upgrade.md](duplicate-usage-tab-after-upgrade.md) | **NOT FILED** — needs **two** filings (RHOAIENG): maas-controller orphan + dashboard tab-key bug. Nearest existing: [RHOAIENG-60373](https://issues.redhat.com/browse/RHOAIENG-60373) Closed (added ownerRefs for *new* Perses resources only), [RHOAIENG-61344](https://issues.redhat.com/browse/RHOAIENG-61344) Closed (same cleanup-gap class) | Open — found 2026-08-07 on bu-nightly-2. Orphaned PersesDashboard from the rhoai-3.4-branch code shadows the 3.5 one, which becomes unreachable. **Proven GA-scope**: creator commit (2026-04-01) shipped in 3.4.0/3.4.1/3.4.2 GA + 3.5-ea.1; the move (07-07) never reached rhoai-3.4 — so any 3.4-GA + MaaS + COO cluster hits it on a 3.5 upgrade (developer's "interim build issue" read is contradicted by the build dates). bu-nightly-2: dashboard deleted manually by the developer 2026-08-07; **orphaned datasource still present**, reconcile-failing. Absent on fresh g767p, and again on fresh bq4x2 2026-08-14 (no duplicate PersesDashboard names) — consistent with upgrade-only scope |
| [upgrade-36-deployment-selector-immutable.md](upgrade-36-deployment-selector-immutable.md) | **NOT FILED** — target RHOAIENG (rhods-operator platform/module deploy) | Open — found n56g8 2026-10-16 on the in-place 3.6.0-ea.2 → 3.6.0 upgrade (both 10-15 and 10-16 `rhoai-3.6-nightly` builds): `kuberay-operator` and `trustyai-service-operator-controller-manager` can't be patched (`spec.selector` immutable — injected `part-of`/`app.opendatahub.io/<c>` labels dropped from the selector), stay on ea.2 images; DSC `Ready=False`. **Verify the 3.5 → 3.6 path before filing** |
| [upgrade-36-aipipelines-servicemonitor-owner.md](upgrade-36-aipipelines-servicemonitor-owner.md) | **NOT FILED** — target RHOAIENG (AI Pipelines module migration) | Open — same upgrade: leftover `DataSciencePipelines` CR still controls the DSPO ServiceMonitor, so `AIPipelines` reports `MonitoringReconcileFailed`; DSC `Ready=False`. Verify the 3.5 → 3.6 path before filing |
| [servicemonitors-tls-servername-platform-prometheus.md](servicemonitors-tls-servername-platform-prometheus.md) | **NOT FILED** — target RHOAIENG (monitoring + trainer / model-registry / odh-model-controller / ogx) | Open — 3.6.0 GA moved `redhat-ods-applications` to platform monitoring; 7 component metrics targets `up=0` on x509 name mismatches (stale upstream-namespace `serverName`; ogx monitor selector also matches other components' Services) |
| [maas-usage-dashboard-total-suffix.md](maas-usage-dashboard-total-suffix.md) | **NOT FILED** — target RHOAIENG (maas-controller) | Open — `dashboard-3-maas-usage-admin` queries `*_total` (12 queries); Limitador (RHCL 1.4.3) exports the names without `_total` → Usage panels empty. Re-confirmed n56g8 2026-10-16 |

## Open Jiras backing carried workarounds

| Workaround | Jira | Status |
|---|---|---|
| A11 gateway ELB cross-zone | **NOT FILED** — draft in [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md), target OCPBUGS; re-searched 2026-08-14, still nothing upstream (nearest HCMFINOPS-271 is an NLB cost task, not a match) | Kept — precondition PRESENT on g767p 2026-08-05 (empty AZ enrolled), ABSENT on multi-AZ bq4x2 2026-08-14; removal gate is an upstream default change, not this measurement |
| E1 stale dependency probe (Kuadrant) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) **Review** (moved from Backlog by 2026-08-14), no fixVersion | Open — hit on r8mf7, fzgjg, tm9xb, g767p (2026-08-05), bq4x2 (2026-08-14); auto-remedied by install-maas.sh (now resolves the AuthPolicy by targetRef — the name flaps between builds) |
| TelemetryPolicy NoSuchKey kills rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) **Closed / Won't Do 2026-09-11** | No fix coming — the safe-labels-only TelemetryPolicy config is **permanent guidance**, not a pending workaround |

**Filing queue** (drafts ready in the files above; statuses re-checked
2026-08-14, pruned 2026-10-16): gateway-elb-crosszone (OCPBUGS), D2b
bearerTokenFile (RHOAIENG — cite #3812 + OCPBUGS-88022),
TelemetryPolicy-removals (**standalone CONNLINK bug** — CONNLINK-1300 is
Closed / Won't Do, so the comment route is gone), ogx-upgrade (RHAIENG — link
RHAIENG-6384), nightly-csv-name-static (build/release eng), duplicate-usage-tab
(**two** RHOAIENG filings — maas-controller Perses orphan, and the dashboard
tab-keying bug; added 2026-08-07).

Dropped from the queue 2026-10-16 (n56g8, RHOAI 3.6.0 GA) — see the retired
list in [../workarounds.md](../workarounds.md): TelemetryPolicy-labels
(misdiagnosis — the labels land on Limitador counters, not `kuadrant_allowed`),
ea.2 H2 hang (delete condition met — `beta` moved past 3.5.0-ea.2),
3.6 deprecated `kserve.modelsAsService` ignored (fixed in 3.6.0 GA by the v2→v3
conversion; ea.2-only), gitops-catalog ose-cli `:latest` (symptom gone;
redhat-cop/gitops-catalog#490 still open), and the RHOAIENG-79529 playground
comment (not applicable on 3.6).
