# RHOAI Known Issues

Product issues found in **RHOAI 3.x nightlies** by this deployment (now
tracking **3.6**). Each problem links to its full analysis; workaround links go
to the exact steps.

Last audit: **2026-10-16** (cluster-n56g8, in-place upgrade 3.6.0-ea.2 →
`rhoai-3.6-nightly` / `rhods-operator.3.6.0`, RHCL 1.4.3). Retired as fixed or
not applicable on 3.6.0 GA: the dashboard-gateway Kuadrant wasm leak (RHCL
1.4.3, CONNLINK-1510), the MaaS gateway proxy OOM (CONNLINK-1567), the
unreachable Observability dashboard (RHOAIENG-80354 — the dashboard operator now
auto-detects Perses), the post-upgrade dashboard 503 (RHOAIENG-79525, fixed 3.5
GA), the ea.2 HTTP/2 hang, the playground API 401 (RHOAIENG-38993, fixed 3.6
EA1), and the "missing" per-subscription labels (a misdiagnosis — they are on
the Limitador counters). Details: the retired list in
[workarounds.md](workarounds.md).

Previous audit: **2026-08-14** (fresh install on cluster-bq4x2, OCP 4.20.32,
multi-AZ, `rhoai-3.5-nightly` built 2026-08-14 03:44Z, digest `bda8c789`) —
every row then listed re-checked against a live cluster on that build, Jira statuses
re-pulled the same day. Nothing was resolved by the new build; one previously
unfiled mechanism is now tracked upstream as CONNLINK-1510.

## Open — you may hit these

| Problem | What you'll see | Jira | Workaround |
|---|---|---|---|
| [Playgrounds break after an RHOAI (ogx) upgrade](issues/ogx-upgrade-breaks-playgrounds.md) | Playgrounds created before the upgrade show `Failed` (workload still runs) | not filed | Delete + recreate the playground; recurs next upgrade |
| [Some component metrics silently never collected](issues/servicemonitors-bearertokenfile.md) | Two operator controllers absent from Prometheus; recurring `InvalidConfiguration` warning events | not filed | none |
| [Removing a telemetry label doesn't take effect](issues/telemetrypolicy-removals-not-propagated.md) | Deleted TelemetryPolicy labels keep flowing; policy reports Enforced | not filed (found 2026-08-01) | Admin: delete the policy; ArgoCD recreates it clean |
| [Two "Usage" tabs on the Observability dashboard after an upgrade](issues/duplicate-usage-tab-after-upgrade.md) | Observe → Observability shows `Usage` twice; the second tab can't be clicked, and the one that renders shows no data. The current 3.5 Usage dashboard (rate-limited requests, consumption table) is unreachable. Hits any cluster that ran MaaS + observability on 3.4 GA (or 3.5-ea.1) and upgraded to 3.5 | not filed (found 2026-08-07; needs 2 filings) | Admin, optional: `oc delete persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-applications` plus its `kuadrant-prometheus-datasource` — both are unowned, nothing recreates them |
| [Ray and TrustyAI stay on old versions after a 3.6 upgrade](issues/upgrade-36-deployment-selector-immutable.md) | After upgrading to 3.6.0, DataScienceCluster stays NotReady (`RayReady`, `TrustyAIReady=DeployFailed`); their operators keep running the pre-upgrade build | not filed | none (do not hand-delete; report it) |
| [Pipelines module NotReady after a 3.6 upgrade](issues/upgrade-36-aipipelines-servicemonitor-owner.md) | DataScienceCluster `AIPipelinesReady=False` (`MonitoringReconcileFailed`); pipelines themselves keep running | not filed | none |
| [Some RHOAI component metrics fail to scrape on 3.6](issues/servicemonitors-tls-servername-platform-prometheus.md) | Cluster admin: several `redhat-ods-applications` metrics targets down with x509 errors | not filed | none |
| [MaaS "Usage" dashboard is empty](issues/maas-usage-dashboard-total-suffix.md) | Observe → Observability → Usage shows no data despite live MaaS traffic | not filed | none |
| [Nightly-to-nightly upgrades never happen via OLM](issues/nightly-csv-name-static.md) | Cluster admin: catalog serves a newer nightly but the operator never upgrades; Subscription says `AtLatestKnown` | not filed (build/release eng) | Admin: [`make restart-catalog`](workarounds.md#a6-catalog-re-resolution-guards--restart-catalogsh) — its image-aware guard does the required clean reinstall |

## Worked around in this deployment — you should NOT hit these

Product bugs we found that remain **unfixed upstream**; this deployment
carries a temporary workaround for each ("Workaround" links to it and its
removal condition) — except CONNLINK-1300, which upstream declined to fix, so
its guidance is permanent. If one of these symptoms appears anyway, the workaround
has regressed — tell the maintainers.

| Problem | Would look like | Jira | Workaround |
|---|---|---|---|
| Gateway load balancer provisioned half-dead on AWS | ~50% of external MaaS calls hang | not filed (OCPBUGS draft in [issue](issues/gateway-elb-crosszone-blackhole.md)) | [A11](workarounds.md#a11-maas-gateway-elb--enable-cross-zone-load-balancing) |
| Operators cache a failed dependency probe at startup | API-key creation 500s; components stuck NotReady after install | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | [E1 auto-remedy](workarounds.md#e1-operators-cache-a-dependency-probe-at-startup-and-never-re-check) in the install script |
| Telemetry label with a bad source silently disables rate limiting | No 429s ever; unlimited usage | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) **Closed / Won't Do** (2026-09-11) — no upstream fix coming | Safe-labels-only TelemetryPolicy config — **permanent guidance**: only add labels whose CEL source always resolves |

---

*Found something not listed? Root-cause it, add an entry with a filing draft
to [issues/](issues/README.md), and file it upstream — that's this repo's
[mission](../CLAUDE.md).*
