# RHOAI Known Issues

Product issues found in **RHOAI 3.5 nightlies** by this deployment. Each
problem links to its full analysis; workaround links go to the exact steps.
Last audit: **2026-08-05** (fresh install on cluster-g767p, OCP 4.20.32,
`rhoai-3.5-nightly` built 2026-08-05) — every row below re-checked against a
live cluster on that build, Jira statuses re-pulled the same day.

## Open — you may hit these

| Problem | What you'll see | Jira | Workaround |
|---|---|---|---|
| [Playground's llama-stack API unusable outside the UI](issues/playground-maas-autowiring.md) | UI chat works, but direct API calls to the playground endpoint 401; 401 noise in pod logs at startup | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New; full fix [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) targets 3.6 EA1, no 3.5 backport | [Patch a real MaaS key into the playground](issues/playground-maas-autowiring.md#workaround--minimal-token-only) (only needed for direct API use) |
| [Per-subscription usage metrics missing labels](issues/telemetrypolicy-labels-not-emitted.md) | Per-subscription Observability breakdowns empty | not filed (RHCL wasm-shim) | none |
| [Playgrounds break after an RHOAI (ogx) upgrade](issues/ogx-upgrade-breaks-playgrounds.md) | Playgrounds created before the upgrade show `Failed` (workload still runs) | not filed | Delete + recreate the playground; recurs next upgrade |
| [Some component metrics silently never collected](issues/servicemonitors-bearertokenfile.md) | Two operator controllers absent from Prometheus; recurring `InvalidConfiguration` warning events | not filed | none |
| [Removing a telemetry label doesn't take effect](issues/telemetrypolicy-removals-not-propagated.md) | Deleted TelemetryPolicy labels keep flowing; policy reports Enforced | not filed (found 2026-08-01) | Admin: delete the policy; ArgoCD recreates it clean |
| [Observability dashboard unreachable](issues/observability-dashboard-unreachable.md) | Observe & monitor → Dashboard shows "Unable to reach observability dashboards / not valid JSON" out of the box; metrics still collected | [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354) In Progress (fix PR #3923 still open) | [A13](workarounds.md#a13-observability-dashboard--set-dashboardspecobservability-manually-temporary) — a one-line `oc patch`, **must be applied on each cluster** (done: bu-nightly-2 + g767p, 2026-08-05) |
| Dashboard dead (503) after an in-place RHOAI upgrade | Whole dashboard "no healthy upstream"; operator logs `spec.selector … field is immutable` | [RHOAIENG-79525](https://redhat.atlassian.net/browse/RHOAIENG-79525) Testing | Admin: `oc delete deployment rhods-dashboard -n redhat-ods-applications` — operator recreates it correctly (hit on tm9xb 2026-08-04 upgrading to 3.5.0 released FBC) |
| [Two "Usage" tabs on the Observability dashboard after an upgrade](issues/duplicate-usage-tab-after-upgrade.md) | Observe → Observability shows `Usage` twice; the second tab can't be clicked, and the one that renders shows no data. The current 3.5 Usage dashboard (rate-limited requests, consumption table) is unreachable | not filed (found 2026-08-07; needs 2 filings) | Admin, optional: `oc delete persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-applications` plus its `kuadrant-prometheus-datasource` — both are unowned, nothing recreates them |
| [Nightly-to-nightly upgrades never happen via OLM](issues/nightly-csv-name-static.md) | Cluster admin: catalog serves a newer nightly but the operator never upgrades; Subscription says `AtLatestKnown` | not filed (build/release eng) | Admin: [`make restart-catalog`](workarounds.md#a6-catalog-re-resolution-guards--restart-catalogsh) — its image-aware guard does the required clean reinstall |

## Worked around in this deployment — you should NOT hit these

Product bugs we found that remain **unfixed upstream**; this deployment
carries a temporary workaround for each ("Workaround" links to it and its
removal condition). If one of these symptoms appears anyway, the workaround
has regressed — tell the maintainers.

| Problem | Would look like | Jira | Workaround |
|---|---|---|---|
| Kuadrant wasm config leaks onto the dashboard gateway → OOM crash-loop | RHOAI dashboard unreachable | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) Resolved (401 leg only — the leak itself is still live 2026-08-05 and untracked on the Kuadrant side) | [A1](workarounds.md#a1-dashboard-gateway--strip-leaked-kuadrant-wasm) |
| MaaS gateway proxy OOMs at its default memory limit | All MaaS API calls dead | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) + siblings | [A2](workarounds.md#a2-maas-gateway--raise-istio-proxy-memory-to-2gi) |
| Gateway load balancer provisioned half-dead on AWS | ~50% of external MaaS calls hang | not filed (OCPBUGS draft in [issue](issues/gateway-elb-crosszone-blackhole.md)) | [A11](workarounds.md#a11-maas-gateway-elb--enable-cross-zone-load-balancing) |
| Operators cache a failed dependency probe at startup | API-key creation 500s; components stuck NotReady after install | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | [E1 auto-remedy](workarounds.md#e1-operators-cache-a-dependency-probe-at-startup-and-never-re-check) in the install script |
| Telemetry label with a bad source silently disables rate limiting | No 429s ever; unlimited usage | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) → RHCL 1.4.3 | Safe-labels-only TelemetryPolicy config |

---

*Found something not listed? Root-cause it, add an entry with a filing draft
to [issues/](issues/README.md), and file it upstream — that's this repo's
[mission](../CLAUDE.md).*
