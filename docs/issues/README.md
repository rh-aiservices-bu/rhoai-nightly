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

> `(D2b)` / `(D2c)` below are historical IDs from a retired triage scheme kept
> only because they appear in older notes and commit messages; there is no
> section D in [../workarounds.md](../workarounds.md).

| File | Jira | Status |
|---|---|---|
| [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md) | **NOT FILED** — draft ready, target **OCPBUGS** (OpenShift ingress/Gateway API); re-searched 2026-08-05, still nothing upstream | Open; workaround A11 — **precondition live on g767p 2026-08-05** (2 ELB IPs vs 1 node-AZ); **absent on multi-AZ bq4x2 2026-08-14** (2 IPs vs 2 node-AZs, 6/6 probes 200) — kept, since the remove-when is an upstream default change, not a per-cluster measurement |
| [playground-maas-autowiring.md](playground-maas-autowiring.md) (D2c) | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New, unassigned; fix [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) **Resolved/Done, fixVersion 3.6 EA1 only** — no rhoai-3.5 cherry-pick (re-checked 2026-08-05: #8364 absent from rhds rhoai-3.5) | Still present on 3.5 by build inspection — re-checked 2026-08-14 (dashboard `6fcb7882`): `280db9dc5` (#8364) is on rhds `main` but **not an ancestor of `rhoai-3.5`**, and the `VLLM_API_TOKEN` machinery is still in `llamastack_config.go` on that branch. Prepared comment in file |
| [servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md) (D2b) | **NOT FILED** — partial upstream fix #3812 merged (main/3.6 only, operator monitor only); identical-mechanism precedent [OCPBUGS-88022](https://issues.redhat.com/browse/OCPBUGS-88022) (NFD) | Open — re-confirmed fresh bq4x2 2026-08-14, both monitors still rejected; cluster-wide sweep found the same rejection in **5 namespaces** (redhat-ods-applications ×2, openshift-operators/otel, openshift-jobset-operator, openshift-gitops-operator) — scope unchanged from g767p 2026-08-05 |
| [telemetrypolicy-labels-not-emitted.md](telemetrypolicy-labels-not-emitted.md) | **NOT FILED** (CONNLINK-1132's fix shipped in RHCL 1.4.1 and does NOT cover this) | Open — re-confirmed bq4x2 2026-08-14, still RHCL 1.4.2: policy Accepted+Enforced and `model`/`subscription`/`user` present in the wasm EnvoyFilter, yet `kuadrant_allowed` carries only infra labels (container, instance, job, namespace, pod, pod_name, prometheus) |
| [ogx-upgrade-breaks-playgrounds.md](ogx-upgrade-breaks-playgrounds.md) | **NOT FILED** (nearest: [RHAIENG-6384](https://redhat.atlassian.net/browse/RHAIENG-6384), covers accumulation only) | Open — RBAC gap (no configmaps delete) still shipped in the 2026-08-14 nightly: `ogx-k8s-operator-manager-role` configmaps verbs are `create,get,list,patch,update,watch`. Symptom half is **not verifiable on a fresh install** (needs an in-place ogx upgrade) — held, not re-verified |
| [telemetrypolicy-removals-not-propagated.md](telemetrypolicy-removals-not-propagated.md) | **NOT FILED** — file as comment/linked bug on [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) (1.4.3, 3 customer cases; its comments describe this asymmetry but don't track it) | Open — re-proven bq4x2 2026-08-14 (add **3s**, remove **still unpropagated at 159s** while the policy reported Accepted+Enforced and its spec no longer held the label; delete+ArgoCD-recreate cleared it in ~10s); **severity escalated 2026-08-04**: a stale removed label hung every inference response on bu-nightly-2 |
| [observability-dashboard-unreachable.md](observability-dashboard-unreachable.md) | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress, fix PR [opendatahub-operator#3923](https://github.com/opendatahub-io/opendatahub-operator/pull/3923) still open (merged nowhere) | Open — re-proven on fresh bq4x2 2026-08-14 with the observability cascade already live (so DSCI carried `monitoring.metrics.storage`, the input #3923 projects): all four probes negative. A13 must be re-applied per cluster |
| [maas-payload-h2-endstream-hang.md](maas-payload-h2-endstream-hang.md) | **NOT FILED** — no Jira exists (re-searched 2026-08-05; closest: RHOAIENG-79535, different fix); fixed by [ai-gateway-payload-processing#419](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/419) with no Jira trail | ea.2 line only (incl. released `beta` channel) — **no regression**: re-verified on 3.5-nightly bq4x2 2026-08-14 against a new payload-processing image (`e2007ddc`, up from `84cee292`), h2 0.72s / 0.15s vs the 30s hang signature |
| [nightly-csv-name-static.md](nightly-csv-name-static.md) | **NOT FILED** — target RHOAI build/release eng (searched 2026-08-05: no build-project tracker found) | Open — mechanism unchanged on the 2026-08-14 nightly (CSV still `rhods-operator.3.5.0`); baseline on bq4x2 is healthy (`AtLatestKnown`, installed == offered), so the deadlock itself is only observable after a catalog bump. Mitigated by restart-catalog.sh image-aware guard (A6) |
| [duplicate-usage-tab-after-upgrade.md](duplicate-usage-tab-after-upgrade.md) | **NOT FILED** — needs **two** filings (RHOAIENG): maas-controller orphan + dashboard tab-key bug. Nearest existing: [RHOAIENG-60373](https://issues.redhat.com/browse/RHOAIENG-60373) Closed (added ownerRefs for *new* Perses resources only), [RHOAIENG-61344](https://issues.redhat.com/browse/RHOAIENG-61344) Closed (same cleanup-gap class) | Open — found 2026-08-07 on bu-nightly-2. Orphaned PersesDashboard from the rhoai-3.4-branch code shadows the 3.5 one, which becomes unreachable. **Proven GA-scope**: creator commit (2026-04-01) shipped in 3.4.0/3.4.1/3.4.2 GA + 3.5-ea.1; the move (07-07) never reached rhoai-3.4 — so any 3.4-GA + MaaS + COO cluster hits it on a 3.5 upgrade (developer's "interim build issue" read is contradicted by the build dates). bu-nightly-2: dashboard deleted manually by the developer 2026-08-07; **orphaned datasource still present**, reconcile-failing. Absent on fresh g767p, and again on fresh bq4x2 2026-08-14 (no duplicate PersesDashboard names) — consistent with upgrade-only scope |

## Open Jiras backing carried workarounds

| Workaround | Jira | Status |
|---|---|---|
| A1 dashboard-gateway wasm leak | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) **Resolved/Done 2026-08-05** (401 leg = MaaS #1313, in the nightly since ~2026-08-04); [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227) Resolved with no fix evidence; [RHOAIENG-77007](https://redhat.atlassian.net/browse/RHOAIENG-77007), [RHOAIENG-78869](https://redhat.atlassian.net/browse/RHOAIENG-78869) (3.6 GA) | **Leak still live 2026-08-14** despite the Resolved Jiras: Kuadrant's 3 EnvoyFilters + odh-model-controller's `maas-default-gateway-authn-ssl` remain selector-less. **Filing gap CLOSED 2026-08-14**: [CONNLINK-1510](https://redhat.atlassian.net/browse/CONNLINK-1510) (New, fixVersion **RHCL 1.4.3** due 09-03) tracks the Kuadrant-side mechanism — root cause [istio/istio#56417](https://github.com/istio/istio/issues/56417), fix is `workloadSelector` instead of `targetRef`, exactly as this ledger predicted |
| A2 gateway istio-proxy OOM | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) Closed; [RHOAIENG-79227](https://redhat.atlassian.net/browse/RHOAIENG-79227) Resolved (no fix); [RHOAIENG-79551](https://redhat.atlassian.net/browse/RHOAIENG-79551) **Closed/Duplicate 2026-08-14** (data-science-gateway scope) — no open Jira now carries a default-memory change; related [CONNLINK-1567](https://redhat.atlassian.net/browse/CONNLINK-1567) New (EnvoyFilter reconcile loop OOMKill, same gateway) | Open — re-measured bq4x2 2026-08-14: **1170Mi idle** (already over the 1Gi default before any load) rising to 1214–1226Mi under maas-verify |
| A11 gateway ELB cross-zone | **NOT FILED** — draft in [gateway-elb-crosszone-blackhole.md](gateway-elb-crosszone-blackhole.md), target OCPBUGS; re-searched 2026-08-14, still nothing upstream (nearest HCMFINOPS-271 is an NLB cost task, not a match) | Kept — precondition PRESENT on g767p 2026-08-05 (empty AZ enrolled), ABSENT on multi-AZ bq4x2 2026-08-14; removal gate is an upstream default change, not this measurement |
| A13 Dashboard.spec.observability manual patch (temporary) | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress, updated 2026-08-14; PRs opendatahub-operator#3923 + #3909, odh-dashboard#9078, GH issue #3910 — none merged | Temporary — re-proven needed on fresh bq4x2 2026-08-14 with the cascade already live; must be applied per cluster (detection in workarounds.md A13, needs `--show-managed-fields`) |
| E1 stale dependency probe (Kuadrant) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) **Review** (moved from Backlog by 2026-08-14), no fixVersion | Open — hit on r8mf7, fzgjg, tm9xb, g767p (2026-08-05), bq4x2 (2026-08-14); auto-remedied by install-maas.sh (now resolves the AuthPolicy by targetRef — the name flaps between builds) |
| TelemetryPolicy NoSuchKey kills rate limiting | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) Refinement, updated 2026-08-13 | RHCL 1.4.3 (due 2026-09-03); 3 customer cases attached 2026-08-04 |

**Filing queue** (drafts ready in the files above; statuses re-checked
2026-08-14): gateway-elb-crosszone (OCPBUGS), D2b bearerTokenFile (RHOAIENG —
cite #3812 + OCPBUGS-88022), TelemetryPolicy-labels (CONNLINK),
TelemetryPolicy-removals (**as comment/linked bug on CONNLINK-1300**),
ogx-upgrade (RHAIENG — link RHAIENG-6384), ea.2 H2 hang (RHOAIENG — link
RHOAIENG-79535), nightly-csv-name-static (build/release eng), ~~Kuadrant
EnvoyFilter-without-workloadSelector leak (CONNLINK)~~ — **filed by others as
CONNLINK-1510, removed from this queue 2026-08-14**, duplicate-usage-tab
(**two** RHOAIENG filings — maas-controller Perses orphan, and the dashboard
tab-keying bug; added 2026-08-07) — plus the prepared RHOAIENG-79529 comment in
the D2c file.
