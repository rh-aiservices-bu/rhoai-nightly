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
| [playground-maas-autowiring.md](playground-maas-autowiring.md) (D2c) | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New, unassigned, not linked to its fix; fix [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) in Review, fixVersion 3.6 EA1 only — no rhoai-3.5 backport PR exists (checked 2026-08-03) | Narrowed 2026-08-04: **UI chat works** on current build; remaining defect = fake static token breaks direct API use. Prepared comment in file |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) (D2b) | **NOT FILED** | Open — confirmed tm9xb 2026-07-31 |
| [telemetrypolicy-labels-not-emitted.md](telemetrypolicy-labels-not-emitted.md) | **NOT FILED** | Open |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | **NOT FILED** (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384)) | Open — recurs on every in-place ogx upgrade |
| [telemetrypolicy-removals-not-propagated.md](telemetrypolicy-removals-not-propagated.md) | **NOT FILED** (target CONNLINK) | Open — proven by controlled experiment, tm9xb 2026-08-01 (RHCL 1.4.2) |
| [observability-dashboard-unreachable.md](observability-dashboard-unreachable.md) | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress (filed by others) | Open — found tm9xb 2026-08-04; root cause source-verified, corroborating comment drafted |
| [maas-payload-h2-endstream-hang.md](maas-payload-h2-endstream-hang.md) | **NOT FILED** — no Jira exists; fixed by [ai-gateway-payload-processing#419](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/419) with no Jira trail | ea.2 line only (incl. released `beta` channel) — live re-confirmed bu-nightly-2 2026-08-03; main unaffected |

## Open Jiras backing carried workarounds

| Workaround | Jira | Status |
|---|---|---|
| A1 dashboard-gateway wasm leak | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) (filed 2026-07-31 by A. Coughlin; covers the whole EnvoyFilter-leak family incl. IPP → dashboard-POST 401s), [RHOAIENG-77007](https://redhat.atlassian.net/browse/RHOAIENG-77007), [RHOAIENG-78869](https://redhat.atlassian.net/browse/RHOAIENG-78869) (3.6 GA) | In Review — upstream fix [#1313](https://github.com/opendatahub-io/models-as-a-service/pull/1313) merged 2026-07-31, not yet in a nightly |
| A2 gateway istio-proxy OOM | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) Resolved; open siblings [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227), [RHOAIENG-79551](https://redhat.atlassian.net/browse/RHOAIENG-79551) | Open — re-proven on tm9xb |
| A11 gateway ELB cross-zone | **NOT FILED** — draft in [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md), target OCPBUGS | Kept — strip-tested 2026-08-04 and did not reproduce, but only because this cluster is single-AZ; upstream behavior unchanged |
| A12 catalog digest pin (temporary) | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) | Temporary — revert `catalogsource.yaml` to `:rhoai-3.5-nightly` once a nightly carries the fix |
| E1 stale dependency probe (Kuadrant) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | Open — hit on r8mf7, fzgjg, tm9xb; auto-remedied by install-maas.sh |
| TelemetryPolicy NoSuchKey kills rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) | RHCL 1.4.3 (due 2026-09-03) |

**Filing queue** (drafts ready in the files above): gateway-elb-crosszone
(OCPBUGS), D2b, TelemetryPolicy-labels, TelemetryPolicy-removals,
ogx-upgrade, ea.2 H2 hang — plus the prepared RHOAIENG-79529 comment in the
D2c file.
