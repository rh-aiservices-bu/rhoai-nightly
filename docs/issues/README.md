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

| File | Jira | Status |
|---|---|---|
| [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md) | **NOT FILED** — draft ready, target **OCPBUGS** (OpenShift ingress/Gateway API); re-searched 2026-08-05, still nothing upstream | Open; workaround A11 — **precondition live on g767p 2026-08-05** (2 ELB IPs vs 1 node-AZ) |
| [playground-maas-autowiring.md](playground-maas-autowiring.md) (D2c) | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New, unassigned; fix [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) **Resolved/Done, fixVersion 3.6 EA1 only** — no rhoai-3.5 cherry-pick (re-checked 2026-08-05: #8364 absent from rhds rhoai-3.5) | Still present on 3.5 by build inspection (dashboard `51128b23` predates the fix). Prepared comment in file |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) (D2b) | **NOT FILED** — partial upstream fix #3812 merged (main/3.6 only, operator monitor only); identical-mechanism precedent [OCPBUGS-88022](https://issues.redhat.com/browse/OCPBUGS-88022) (NFD) | Open — re-confirmed fresh g767p 2026-08-05, both monitors rejected |
| [telemetrypolicy-labels-not-emitted.md](telemetrypolicy-labels-not-emitted.md) | **NOT FILED** (CONNLINK-1132's fix shipped in RHCL 1.4.1 and does NOT cover this) | Open — re-confirmed g767p 2026-08-05 on RHCL 1.4.2 |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | **NOT FILED** (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384), covers accumulation only) | Open — RBAC gap (no configmaps delete) confirmed shipped in the 2026-08-05 nightly; unfixed on all branches |
| [telemetrypolicy-removals-not-propagated.md](telemetrypolicy-removals-not-propagated.md) | **NOT FILED** — file as comment/linked bug on [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) (1.4.3, 3 customer cases; its comments describe this asymmetry but don't track it) | Open — re-proven g767p 2026-08-05 (add ≤5s, remove >120s); **severity escalated 2026-08-04**: a stale removed label hung every inference response on bu-nightly-2 |
| [observability-dashboard-unreachable.md](observability-dashboard-unreachable.md) | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress, fix PR [opendatahub-operator#3923](https://github.com/opendatahub-io/opendatahub-operator/pull/3923) still open (merged nowhere) | Open — re-proven on fresh g767p 2026-08-05; A13 must be re-applied per cluster |
| [maas-payload-h2-endstream-hang.md](maas-payload-h2-endstream-hang.md) | **NOT FILED** — no Jira exists (re-searched 2026-08-05; closest: RHOAIENG-79535, different fix); fixed by [ai-gateway-payload-processing#419](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/419) with no Jira trail | ea.2 line only (incl. released `beta` channel) — verified FIXED on 3.5-nightly g767p 2026-08-05 (`84cee292`, h2 0.75s) |
| [nightly-csv-name-static.md](nightly-csv-name-static.md) | **NOT FILED** — target RHOAI build/release eng (searched 2026-08-05: no build-project tracker found) | Open — mechanism unchanged on the 2026-08-05 nightly; mitigated by restart-catalog.sh image-aware guard (A6) |

## Open Jiras backing carried workarounds

| Workaround | Jira | Status |
|---|---|---|
| A1 dashboard-gateway wasm leak | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) **Resolved/Done 2026-08-05** (401 leg = MaaS #1313, in the nightly since ~2026-08-04); [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227) Resolved with no fix evidence; [RHOAIENG-77007](https://redhat.atlassian.net/browse/RHOAIENG-77007), [RHOAIENG-78869](https://redhat.atlassian.net/browse/RHOAIENG-78869) (3.6 GA) | **Leak still live 2026-08-05** despite the Resolved Jiras: Kuadrant's 3 EnvoyFilters + odh-model-controller's `maas-default-gateway-authn-ssl` remain selector-less. The Kuadrant-side mechanism has NO CONNLINK bug — filing gap |
| A2 gateway istio-proxy OOM | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) Closed; [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227) Resolved (no fix); [RHOAIENG-79551](https://redhat.atlassian.net/browse/RHOAIENG-79551) In Progress (data-science-gateway scope; candidate fix #3904 unmerged) | Open — re-measured g767p 2026-08-05: 1217Mi under maas-verify vs 1Gi default |
| A11 gateway ELB cross-zone | **NOT FILED** — draft in [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md), target OCPBUGS | Kept — precondition PRESENT on g767p 2026-08-05 (empty AZ enrolled); load-bearing there |
| A13 Dashboard.spec.observability manual patch (temporary) | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress; PR #3923 still open | Temporary — re-proven needed on fresh g767p 2026-08-05; must be applied per cluster (detection in workarounds.md A13, needs `--show-managed-fields`) |
| E1 stale dependency probe (Kuadrant) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | Open — hit on r8mf7, fzgjg, tm9xb, g767p (2026-08-05); auto-remedied by install-maas.sh (now resolves the AuthPolicy by targetRef — the name flaps between builds) |
| TelemetryPolicy NoSuchKey kills rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) Refinement | RHCL 1.4.3 (due 2026-09-03); 3 customer cases attached 2026-08-04 |

**Filing queue** (drafts ready in the files above; statuses re-checked
2026-08-05): gateway-elb-crosszone (OCPBUGS), D2b bearerTokenFile (RHOAIENG —
cite #3812 + OCPBUGS-88022), TelemetryPolicy-labels (CONNLINK),
TelemetryPolicy-removals (**as comment/linked bug on CONNLINK-1300**),
ogx-upgrade (RHAIENG — link RHAIENG-6384), ea.2 H2 hang (RHOAIENG — link
RHOAIENG-79535), nightly-csv-name-static (build/release eng), Kuadrant
EnvoyFilter-without-workloadSelector leak (CONNLINK — the generic mechanism
behind A1; only the MaaS-side symptom was ever filed) — plus the prepared
RHOAIENG-79529 comment in the D2c file.
