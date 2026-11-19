# RHOAI Known Issues

Product issues found in **RHOAI 3.x nightlies** by this deployment (now
tracking **3.6**). Filed problems link to their full analysis — rows marked
"not filed" are summarized inline; workaround links go
to the exact steps.

Last audit: **2026-11-18** (cluster-n56g8, in-place upgrade 3.6.0-ea.2 →
`rhoai-3.6-nightly` / `rhods-operator.3.6.0`, RHCL 1.4.3). Retired as fixed or
not applicable on 3.6.0 GA: the dashboard-gateway Kuadrant wasm leak (RHCL
1.4.3, CONNLINK-1510), the MaaS gateway proxy OOM (CONNLINK-1567), the
unreachable Observability dashboard (RHOAIENG-80354 — the dashboard operator now
auto-detects Perses), the post-upgrade dashboard 503 (RHOAIENG-79525, fixed 3.5
GA), the ea.2 HTTP/2 hang, the playground API 401 (RHOAIENG-38993, fixed 3.6
EA1), and the "missing" per-subscription labels (a misdiagnosis — they are on
the Limitador counters). Details: the retired list in
[workarounds.md](workarounds.md). Retracted 2026-11-19 (OCP 5.0.1, RHCL
1.5.0): the `dashboard.maasPortal` "operator-enforced" Open row was a
misdiagnosis — the `dashboard.maasPortal: Managed` DSC flip verified working
on 2026-11-19 (portal operand + routes + browser login on both front doors);
the 2026-11-18 revert observation was never reproduced, and the operator
source (tag v3.6.0) contains no gate.

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
| OdhDashboardConfig CEL rule rejects deprecated `dashboardConfig` keys when they are absent | ArgoCD `instance-rhoai` SyncError: `spec.dashboardConfig: Invalid value: "object": no such key: externalModels evaluating rule: DEPRECATED: spec.dashboardConfig.externalModels must be removed or left unchanged` — the rule errors with a CEL `no such key` whenever the live object lacks the deprecated key, so external automation (ArgoCD) re-adding it is blocked | not filed | none needed: this repo's flag map is pruned to the operator-written overrides (`disableTracking`, `workbenchesV2`) |
| model-registry-operator resets a pre-existing `model-catalog-sources` ConfigMap | A user-managed `model-catalog-sources` CM in `rhoai-model-registries` that exists before the operator's first reconcile gets its `sources.yaml` reset to the template default `catalogs: []` — contradicting the operator docs ("created on first reconcile and never overwritten"). Detection: `oc get cm model-catalog-sources -n rhoai-model-registries -o jsonpath='{.data.sources\.yaml}'` shows `catalogs: []` after a git-managed version with content was applied | not filed | none: this repo dropped the git-managed override CM (Red Hat catalogs ship enabled in operator-owned `default-catalog-sources`); custom catalogs must use a differently-named CM |
| aiHub model-catalog activation times out (`kube-rbac-proxy` crashloop) (first observed on OCP5) | Pod `model-catalog-*` (ns `rhoai-model-registries`) has its `kube-rbac-proxy` container in CrashLoopBackOff → catalog activation never validates → 10-min deadline → `ActivationTimedOut` → the deployment is scaled to 0 → DSC `Ready=False` / `AIHubReady=ActivationTimedOut`. The `aihub.opendatahub.io/retry-activation` annotation triggers new attempts but they fail on the same crashloop. Root cause: the nightly's `odh-kube-rbac-proxy-rhel9` image (`registry.redhat.io/rhoai/odh-kube-rbac-proxy-rhel9@sha256:6cf3d253…`) panics on every container start — `panic: ConfigureServer may be called only once per Server` (kube-rbac-proxy.go:443, golang.org/x/net/http2; the binary invokes http2.ConfigureServer twice on the same server) — deterministic and flag-independent; TLS secret, configmap, and cert all verified valid. The same digest crashes `rhods-dashboard`'s kube-rbac-proxy sidecars identically (18h+ crashloop, deployment 0/2) — the RHOAI web console is down cluster-wide from the same image bug. The operator's DSC readiness signal is misleading — DSC reports `DashboardReady=True` while `rhods-dashboard` pods are 2/3 CrashLoopBackOff (the signal ignores the crashing kube-rbac-proxy sidecar). Detection: `oc logs -n rhoai-model-registries -l app=model-catalog -c kube-rbac-proxy` (panic) — only works during an activation attempt window (the deployment is scaled to 0 between attempts); or check `oc get pods -n redhat-ods-applications -l app=rhods-dashboard` (same crashloop, continuous) | not filed | none possible from the consumer side: the image digest is operator-pinned and the deployment aggressively reconciled. Wait for a nightly with a rebuilt `odh-kube-rbac-proxy-rhel9` (verify the digest changed), then re-trigger with `oc annotate catalog catalog -n rhoai-model-registries aihub.opendatahub.io/retry-activation=retry-<n> --overwrite`. RECOVERED 2026-11-19: the nightly's rebuilt odh-kube-rbac-proxy-rhel9 (digest 0f985e54… vs known-bad 6cf3d253…) landed; make restart-catalog re-resolved the CSV and aihub.opendatahub.io/retry-activation=retry-4 re-activated — dashboard 3/3, model-catalog 1/1, DSC Ready=True. The bug remains present in the 2026-11-17 build; recovery = this flow on any cluster still deploying 6cf3d253… |
| OpenShift 5.0 GA curated catalogs lack `rhbk-operator` and `cloudnative-pg`; RHBK itself is additionally entitlement-gated (first observed on OCP5) | Detection: `oc get packagemanifest rhbk-operator cloudnative-pg -n openshift-marketplace` (all NotFound from the curated catalogs) — the curated v5.0 operator catalogs ship neither package. CNPG is served by the one-off filtered catalog ([components/operators/keycloak-stack/catalogsource.yaml](../components/operators/keycloak-stack/catalogsource.yaml) → `quay.io/jharmison/keycloak-stack-catalog:v4.22.0`, remove-when curated v5.0 carries it). `keycloak-operator` (community upstream, same `k8s.keycloak.org` CRD family as RHBK 26) comes from the cluster's curated `community-operators` catalog. RHBK itself is additionally blocked: the `registry.redhat.io/rhbk/*` bundle digests are entitlement-gated and the cluster's OpenShift pull secret rejects every one ("Token rejected by upstream registry"), so swapping back from community means adding RHBK entitlements to the pull secret first | not filed (rig/catalog reality, not an upstream defect) | none needed for keycloak (community operator); the filtered catalog stays only for CNPG — delete it and re-point `cnpg-subscription.yaml` when the curated v5.0 indexes carry the package; swap keycloak back to RHBK (`rhbk-operator`, entries already in the filtered catalog) when RHBK entitlements exist |
| [RHCL wasm shim fails to load in the OCP5 sail envoy (fail-closed)](issues/rhcl-wasm-fail-closed.md) (first observed on OCP5) | After the [§E1 pod-bounce remedy](workarounds.md#e1-operators-cache-a-dependency-probe-at-startup-and-never-re-check) restores AuthPolicy `Accepted=True` on the gateway, **all `maas.apps` traffic returns 5xx** (500 in the 2026-11-19 ~22:2x–22:5x UTC window, 503 ~23:1x after envoy pod restarts, 500 again at 23:48) — MaaS inference AND the consumer-portal API — while `/maas-api/health` stays 200 (503 in the ~23:1x phase). Envoy fails the remote wasm fetch envoy-internally (`kuadrant-operator-wasm.openshift-operators.svc:8082/plugin.wasm`; server verified serving, NetworkPolicy allows it) and the plugin's `failure_policy: FAIL_RELOAD` fail-closes everything the policies govern (first observed 2026-11-19, RHCL 1.5.0 / OCP 5.0.1) | not filed — filing draft ready in the [issue](issues/rhcl-wasm-fail-closed.md), target CONNLINK + Kuadrant/kuadrant-operator mirror | none that restores traffic: keep enforcement (fail-closed) as the current honest state — the unenforced rollback is not cleanly reachable and is a security hole; see the issue file |

## Worked around in this deployment — you should NOT hit these

Product bugs we found that remain **unfixed upstream**; this deployment
carries a temporary workaround for each ("Workaround" links to it and its
removal condition) — except CONNLINK-1300, which upstream declined to fix, so
its guidance is permanent. If one of these symptoms appears anyway, the workaround
has regressed — tell the maintainers.

| Problem | Would look like | Jira | Workaround |
|---|---|---|---|
| Gateway load balancer provisioned half-dead on AWS | ~50% of external MaaS calls hang | not filed (OCPBUGS draft in [issue](issues/gateway-elb-crosszone-blackhole.md)) | [A11](workarounds.md#a11-maas-gateway-elb--enable-cross-zone-load-balancing) |
| Operators cache a failed dependency probe at startup | API-key creation 500s; components stuck NotReady after install. **2026-11-19 (RHCL 1.5.0 / OCP 5.0.1):** the pod-bounce remedy now restores `Accepted=True`, but the RHCL `kuadrant-wasm-shim` then fails to load in the ingress-operator sail envoy (fail-closed) → 5xx on **all `maas.apps` traffic** (MaaS inference AND portal API; `/health` stays 200) — [new issue](issues/rhcl-wasm-fail-closed.md). Pre-remedy blast radius: while the policies were unenforced, `GET /maas-api/v1/models` returned **200 anonymously** (MaaS API fully exposed) | [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) Review | [E1 auto-remedy](workarounds.md#e1-operators-cache-a-dependency-probe-at-startup-and-never-re-check) in the install script — on RHCL 1.5.0/OCP5 the remedy converts "unenforced (insecure, working)" into "enforced (secure, bricked)"; see the updated §E1 section |
| Telemetry label with a bad source silently disables rate limiting | No 429s ever; unlimited usage | [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300) **Closed / Won't Do** (2026-09-11) — no upstream fix coming | Safe-labels-only TelemetryPolicy config — **permanent guidance**: only add labels whose CEL source always resolves |

---

*Found something not listed? Root-cause it, add an entry with a filing draft
to [issues/](issues/README.md), and file it upstream — that's this repo's
[mission](../CLAUDE.md).*
