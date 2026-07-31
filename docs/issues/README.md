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
| [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md) | **NOT FILED** — draft ready, target **OCPBUGS** (OpenShift ingress/Gateway API) | Open; workaround A11 |
| [playground-maas-autowiring.md](playground-maas-autowiring.md) (D2c) | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New, unassigned; defect 1 fixed on main only ([RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993), not on rhoai-3.5) | Open; prepared comment in file |
| [maas-catalog-bare-model-url.md](maas-catalog-bare-model-url.md) (D2a) | **NOT FILED** (lineage: [RHOAIENG-76220](https://redhat.atlassian.net/browse/RHOAIENG-76220)) | Open — confirmed tm9xb 2026-07-31 |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) (D2b) | **NOT FILED** | Open — confirmed tm9xb 2026-07-31 |
| [telemetrypolicy-labels-not-emitted.md](telemetrypolicy-labels-not-emitted.md) | **NOT FILED** | Open |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | **NOT FILED** (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384)) | Open — recurs on every in-place ogx upgrade |
| [telemetrypolicy-removals-not-propagated.md](telemetrypolicy-removals-not-propagated.md) | **NOT FILED** (target CONNLINK) | Open — proven by controlled experiment, tm9xb 2026-08-01 (RHCL 1.4.2) |

## Open Jiras backing carried workarounds

| Workaround | Jira | Status |
|---|---|---|
| A1 dashboard-gateway wasm leak | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) (filed by us 2026-07-31), [RHOAIENG-77007](https://redhat.atlassian.net/browse/RHOAIENG-77007), [RHOAIENG-78869](https://redhat.atlassian.net/browse/RHOAIENG-78869) (3.6 GA) | Open — re-proven on tm9xb (SM 3.4.0) |
| A2 gateway istio-proxy OOM | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) Resolved; open siblings [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227), [RHOAIENG-79551](https://redhat.atlassian.net/browse/RHOAIENG-79551) | Open — re-proven on tm9xb |
| A8 Tenant-CR settle-gate tolerance | [RHOAIENG-76548](https://redhat.atlassian.net/browse/RHOAIENG-76548) | Resolved — DSC Ready first-try on tm9xb; tolerance inert, remove after one more clean install |
| E1 stale dependency probe (Kuadrant) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | Open — hit on r8mf7, fzgjg, tm9xb; auto-remedied by install-maas.sh |
| TelemetryPolicy NoSuchKey kills rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) | RHCL 1.4.3 (due 2026-09-03) |

**Filing queue** (drafts ready in the files above): gateway-elb-crosszone
(OCPBUGS), D2a, D2b, TelemetryPolicy-labels, TelemetryPolicy-removals,
ogx-upgrade — plus the prepared RHOAIENG-79529 comment in the D2c file.
