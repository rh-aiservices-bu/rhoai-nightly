# RHOAI Known Issues

Product issues found in **RHOAI 3.5 nightlies** by this deployment. Each
problem links to its full analysis; workaround links go to the exact steps.
Last audit: **2026-07-31** (fresh 3.5.0 install, cluster-tm9xb).

## Open — you may hit these

| Problem | What you'll see | Jira | Workaround |
|---|---|---|---|
| [Playground chat with a MaaS model fails](issues/playground-maas-autowiring.md) | First message → 404 "Server error", model looks healthy in the picker | [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) New | [Register the model as an AI asset endpoint](issues/playground-maas-autowiring.md#workaround-a--register-the-model-as-a-custom-ai-asset-endpoint-durable-supported) (pending live verification) |
| [MaaS catalog advertises the wrong model URL](issues/maas-catalog-bare-model-url.md) | API clients trusting the catalog URL get 404 | not filed (draft ready) | Use `https://maas.<domain>/<namespace>/<model>/v1` |
| [Per-subscription usage metrics missing labels](issues/telemetrypolicy-labels-not-emitted.md) | Per-subscription Observability breakdowns empty | not filed (RHCL wasm-shim) | none |
| [Playgrounds break after an RHOAI (ogx) upgrade](issues/ogx-upgrade-breaks-playgrounds.md) | Playgrounds created before the upgrade show `Failed` (workload still runs) | not filed | Delete + recreate the playground; recurs next upgrade |
| [Some component metrics silently never collected](issues/servicemonitors-bearertokenfile.md) | Two operator controllers absent from Prometheus; recurring `InvalidConfiguration` warning events | not filed | none |
| [Removing a telemetry label doesn't take effect](issues/telemetrypolicy-removals-not-propagated.md) | Deleted TelemetryPolicy labels keep flowing; policy reports Enforced | not filed (found 2026-08-01) | Admin: delete the policy; ArgoCD recreates it clean |

## Worked around in this deployment — you should NOT hit these

Product bugs we found that remain **unfixed upstream**; this deployment
carries a temporary workaround for each ("Workaround" links to it and its
removal condition). If one of these symptoms appears anyway, the workaround
has regressed — tell the maintainers.

| Problem | Would look like | Jira | Workaround |
|---|---|---|---|
| Kuadrant wasm config leaks onto the dashboard gateway → OOM crash-loop | RHOAI dashboard unreachable | [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043) | [A1](workarounds.md#a1-dashboard-gateway--strip-leaked-kuadrant-wasm) |
| MaaS gateway proxy OOMs at its default memory limit | All MaaS API calls dead | [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589) + siblings | [A2](workarounds.md#a2-maas-gateway--raise-istio-proxy-memory-to-2gi) |
| Gateway load balancer provisioned half-dead on AWS | ~50% of external MaaS calls hang | not filed (OCPBUGS draft in [issue](issues/gateway-elb-crosszone-blackhole.md)) | [A11](workarounds.md#a11-maas-gateway-elb--enable-cross-zone-load-balancing) |
| Operators cache a failed dependency probe at startup | API-key creation 500s; components stuck NotReady after install | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Backlog | [E1 auto-remedy](workarounds.md#e1-operators-cache-a-dependency-probe-at-startup-and-never-re-check) in the install script |
| Telemetry label with a bad source silently disables rate limiting | No 429s ever; unlimited usage | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) → RHCL 1.4.3 | Safe-labels-only TelemetryPolicy config |

---

*Found something not listed? Root-cause it, add an entry with a filing draft
to [issues/](issues/README.md), and file it upstream — that's this repo's
[mission](../CLAUDE.md).*
