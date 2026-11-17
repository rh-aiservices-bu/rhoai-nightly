# Workarounds & Rig Internals (developer doc)

Audience: people maintaining **this GitOps repo** and its clusters. For the
product-facing list of RHOAI bugs (what users/managers should know), see
[known-issues.md](known-issues.md); for per-issue analysis and Jira drafts,
[issues/](issues/README.md).

We carry the **minimum workarounds**: only when the rig cannot function
without one, always **Temporary** with a Jira and a remove-when condition,
removed as soon as a nightly ships the fix.

> **Strip-audit: 2026-07-31** — on a fresh 3.5.0 install (cluster-tm9xb,
> catalog `rhoai-3.5-nightly`, operator `dca3c007`, SM 3.4.0): every A-entry
> was removed, the cluster installed bare, and only proven-needed entries were
> re-added. Removed as fixed upstream: feast RBAC (both gaps), ai-gateway
> NetworkPolicy RBAC, payload-processing NetworkPolicy, gen-ai :8321 egress,
> trustyai pods/log RBAC for EvalHub.
>
> **Re-check: 2026-08-04** — after the in-place upgrade to the released-track
> FBC `f4183f7e` (operator `0017d555`), each entry was re-checked against the
> live cluster. A1 re-proven needed (Kuadrant's filters are still
> selector-less on this build). **A2 confirmed needed by measurement** — the
> istio-proxy holds ~1450Mi steady, 40% above the 1Gi default it would revert
> to, so it would OOMKill on restart before serving a request; no strip test
> warranted. **A11 strip-tested and did not reproduce, but was kept** — the
> precondition (an ELB enrolled in an AZ with no instances) is absent on this
> single-AZ cluster; the upstream behavior is unchanged. See its entry.
> **A8 was removed**: RHOAIENG-76548 is Resolved and the DSC reports
> `Ready=True`; on 3.5 the condition it keyed on was also renamed
> (`ModelsAsServiceReady` → `AIGatewayReady`), so on this build the tolerance
> could no longer fire at all. **Caveat for ea.2 clusters:** bu-nightly-2 still
> emits the old condition name, so there the tolerance *was* live — if that
> cluster still exhibits `Tenant CR not available yet`, `make observability`
> and `make evalhub` will now abort at the settle-gate instead of continuing.
> That is the intended sequencing (upgrade first, then run those targets), and
> aborting is the safe direction, but it is a behavior change for that cluster
> until it is upgraded.
>
> **Fresh-install audit: 2026-08-05** — full install on cluster-g767p (OCP
> 4.20.32, single-AZ us-east-2a) from the floating `rhoai-3.5-nightly` built
> 2026-08-05 13:55Z (operator `b3e086ed`/image `676d1a94`, maas `58e59dec` —
> carries models-as-a-service#1313, dashboard `51128b23`). Every entry below
> re-verified against that build; per-entry dates updated. Environment change
> found on OCP **4.20.32**: there is **no `servicemeshoperator3` OLM operator
> at all** — the ingress operator embeds the sail library and runs istiod
> directly (`managed-by=sail-library`, istio 1.26.8, no Subscription/CSV).
> The observability settle-gate now requires the SM CSV only when a
> servicemeshoperator3 Subscription exists, and gates on istiod health
> otherwise.
>
> **Fresh-install audit: 2026-08-14** — full install on cluster-bq4x2 (OCP
> 4.20.32, **multi-AZ**: nodes in us-east-2a + us-east-2c) from the
> `rhoai-3.5-nightly` built 2026-08-14 03:44Z, digest-pinned for the run
> (catalog `bda8c789`, operator image `3dbb64be`, maas-api `c73403cb`,
> maas-controller `80c4e932`, dashboard `6fcb7882`, payload-processing
> `e2007ddc`). **Every tracked component moved** since the 2026-08-05 build,
> so no entry was given a "nothing moved" pass. Scope: base + MaaS + GPU model
> (gpt-oss-20b on an L40S) + observability + evalhub.
>
> **Result: nothing qualified for removal — every workaround re-verified as
> still load-bearing.** The `--fixes` hunt over the `rhoai-3.5` branch found no
> commit citing any of RHOAIENG-80354 (A13), -80043 (A1), -68589/-79227/-79551
> (A2) or -67925 (E1), and each entry's own Detection command then confirmed
> the bug live on the cluster. Two notes for future audits: the nightly tag was
> frozen 2026-08-05 → 2026-08-14 and has resumed rebuilding; and on OCP 4.20
> `make icsp` completes in ~90s with **no node reboot** (registries.conf is
> applied via a crio reload), not the 10–15 min this repo's docs predicted —
> corrected across CLAUDE.md, docs/install-make.md and the install-rhoai skill
> in the same pass.
>
> **Upgrade audit: 2026-10-16** — cluster-n56g8, in-place upgrade from
> 3.6.0-ea.2 to the 3.6.0 GA line (catalog `rhoai-3.6-nightly`, CSV
> `rhods-operator.3.6.0`, channel `stable-3.x`, RHCL 1.4.3). Every entry was
> re-checked; **A1, A2 and A13 were retired** (A1/A2 by strip test with a
> 30-min soak, A13 because 3.6 no longer needs it — it was never applied on
> n56g8), and six `docs/issues/` ledger files plus two known-issues rows were
> dropped. Each retirement and its evidence is in the list under section A.
> Also changed: `install-observability.sh` script Phase A2 (unrelated to
> workaround A2) no longer scrubs
> `openshift.io/cluster-monitoring` from `redhat-ods-applications` — 3.6.0 GA
> sets it there on every DSCI reconcile, so scrubbing only fought the operator.
> Still carried and still needed: A5, A6, A11, B, C2, E1, E2, F1, F2.

---

## A. Workarounds carried in this repo

> Numbering is historical and gappy by design: **A1–A4, A7–A10, A12, A13 and C1
> were retired** as their upstream fixes shipped (A8's removal is written up in
> the header above, the 2026-10-16 retirements below; the rest are in git
> history). A missing letter means "removed", never "misplaced" — don't
> renumber, since the letters are cited from issue files, scripts and commit
> messages.
>
> **Retired 2026-10-16** (cluster-n56g8, `rhoai-3.6-nightly` /
> `rhods-operator.3.6.0`):
>
> - **A1** (dashboard-gateway Kuadrant wasm strip EnvoyFilter,
>   `dashboard-gateway-wasm-strip.yaml`) — strip test: deleted
>   `strip-kuadrant-wasm-dashboard-gateway`; the `data-science-gateway` HTTP
>   filter chain was byte-identical before/after (cors, ext_authz, fault,
>   grpc_stats, lua, router, istio.alpn/metadata_exchange/stats — no wasm);
>   istio-proxy 87–98Mi over a 30-min soak incl. load, 0 restarts, 0 OOM. Fixed
>   upstream by RHCL 1.4.3 ([CONNLINK-1510](https://redhat.atlassian.net/browse/CONNLINK-1510)
>   Closed, fixVersion 1.4.3 — every `kuadrant-*` EnvoyFilter now carries a
>   `workloadSelector`). `make diagnose` keeps a regression detector ("Kuadrant
>   Wasm Leak": FAIL on any selector-less EnvoyFilter inserting wasm).
> - **A2** (MaaS gateway istio-proxy 2Gi via the `deployment` key of the
>   `maas-default-gateway-options` parametersRef ConfigMap; the ConfigMap and
>   its `service` key stay for A11) — strip test: removed the key, gateway
>   rolled to the 1Gi default; 72/72 concurrent gpt-oss-20b chat requests
>   (3×24, mixed streaming) returned 200 and `make maas-verify` ALL PASS; peak
>   327Mi, steady ~300Mi over 30 min, 0 restarts, 0 OOM (3.5 measured
>   1170–1226Mi). [CONNLINK-1567](https://redhat.atlassian.net/browse/CONNLINK-1567)
>   Closed, fixVersion 1.4.3.
> - **A13** (manual `Dashboard.spec.observability` patch) — never applied on
>   n56g8: on 3.6 the dashboard operator auto-detects Perses (odh-dashboard
>   #9269, "fix(RHOAIENG-80354): auto-detect Perses service");
>   `ObservabilityAvailable=True reason=Deployed`, `dashboard-perses-access`
>   NetworkPolicy present, `/perses/*` on the dashboard backend returns Perses
>   JSON. [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354)
>   Closed/Done, fixVersion 3.5 GA. The field stays unset **by design**, so any
>   detection keyed on `spec.observability` or its managedFields is a false
>   positive — `make diagnose` now keys on the `ObservabilityAvailable`
>   condition. Ledger file `observability-dashboard-unreachable.md` deleted.
> - **Ledger `maas-payload-h2-endstream-hang.md`** (ea.2 HTTP/2 END_STREAM
>   hang) — its own delete condition is met: the released `beta` channel moved
>   past 3.5.0-ea.2 (now 3.6.0-ea.2). Never filed; fixed by
>   ai-gateway-payload-processing#419.
> - **Ledger `dsc-maas-deprecated-field-ignored.md`** — fixed in 3.6.0 GA: DSC
>   storage is v3 (no `kserve.modelsAsService`) and the v2→v3 conversion maps a
>   legacy `kserve.modelsAsService: Managed` to `aigateway.modelsAsAService:
>   Managed` (rhods-operator rhoai-3.6
>   `api/datasciencecluster/v2/datasciencecluster_conversion.go`, #4137,
>   2026-10-07). Affected 3.6.0-ea.2 only; never filed.
> - **Ledger `telemetrypolicy-labels-not-emitted.md`** — misdiagnosis, not a
>   bug: on RHCL 1.4.3 the labels land on the Limitador counters
>   (`authorized_hits` carries model/subscription/user;
>   `authorized_calls`/`limited_calls` carry subscription/user), matching the
>   upstream MaaS docs ("model label is only available on authorized_hits");
>   `kuadrant_allowed` was never the target. Not filed (correctly).
> - **Ledger `gitops-catalog-ose-cli-latest.md`** — symptom gone:
>   `registry.redhat.io/openshift4/ose-cli:latest` resolves again,
>   `job-gpu-console-plugin` Completed, `nvidia-operator` Synced/Healthy. The
>   upstream hygiene PR [redhat-cop/gitops-catalog#490](https://github.com/redhat-cop/gitops-catalog/pull/490)
>   (stop using `:latest`) is still open.
> - **Ledger `playground-maas-autowiring.md`** — not applicable on 3.6: the
>   fake-token machinery is gone ([RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993)
>   Closed, fixVersion 3.6 EA1) and this repo tracks 3.6 only.
>   [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529) stays
>   open on Jira for 3.5.
> - **known-issues.md row "Dashboard dead (503) after an in-place upgrade"** —
>   [RHOAIENG-79525](https://redhat.atlassian.net/browse/RHOAIENG-79525)
>   Closed/Done, fixVersion 3.5 GA.
> - **Reworded, not retired:** [CONNLINK-1300](https://redhat.atlassian.net/browse/CONNLINK-1300)
>   (TelemetryPolicy NoSuchKey disables rate limiting) is Closed / Won't Do
>   (2026-09-11), so the safe-labels-only TelemetryPolicy config is permanent
>   guidance, and `telemetrypolicy-removals-not-propagated.md` must be filed as
>   a standalone CONNLINK bug rather than a comment on 1300.
> - **docs/issues/trustyai-lmeval-crd-type-mismatch.md** (opened and retired
>   the same day) — the 2026-10-15 `rhoai-3.6-nightly` operator shipped a
>   boolean TrustyAI module CRD vs the DSC's `allow`/`deny` strings
>   (`ProvisioningSucceeded=Error`). Fixed by rhods-operator `4f8c88949`; the
>   2026-10-16 build (`b14cd97f`) re-applied the string CRD ~10 min after the
>   operator restarted and the error cleared. Never needed a workaround.


### A5. ArgoCD application-controller — 4Gi memory

- **File:** `bootstrap/argocd-instance/patch-controller-resources.yaml`
- **Without it:** app-controller OOMKills at the operator-default 2Gi with the
  full app set (measured ~2.2Gi steady; 1932Mi on fresh g767p 2026-08-05
  before MaaS/observability apps even landed). **Permanent** sizing.

### A6. Catalog re-resolution guards — `restart-catalog.sh`

- **File:** `scripts/restart-catalog.sh`
- **Without it:** after a catalog image flip with an unchanged CSV name, OLM
  never re-resolves; naive Subscription deletion orphans the CSV into a
  `ConstraintsNotSatisfiable` deadlock. **Permanent** (OLM behavior).

### A11. MaaS gateway ELB — enable cross-zone load balancing

- **File:** `components/instances/maas-instance/chart/templates/maas-gateway-options.yaml`
  (`service` key)
- **Without it:** ~half of external MaaS requests hang (TLS timeout). The AWS
  classic ELB is provisioned with cross-zone off and can enroll an AZ with no
  cluster instances — that AZ's DNS IP black-holes TLS.
- **Found 2026-07-31** (tm9xb, single-AZ cluster); annotating the Service fixed
  the dead IP immediately. Upstream target is **OCPBUGS** (OpenShift
  ingress/Gateway API — no RHOAI component owns the Service):
  [issues/gateway-elb-crosszone-blackhole.md](issues/gateway-elb-crosszone-blackhole.md)
- **Strip-tested 2026-08-04 — did NOT reproduce, and we kept it anyway.**
  Removed the annotation, confirmed the AWS cloud-controller pushed the
  attribute change (`Updating load-balancer attributes` in
  `openshift-cloud-controller-manager`), then probed every LB IP every 10s:
  40/40 samples returned 200 on both IPs over 7 minutes. The reason is
  topology, not a fix — every MachineSet is in `us-east-2c` and the ELB is
  currently enrolled only in an AZ that holds instances, so there is no empty
  AZ to black-hole. Nothing in OpenShift or AWS changed.
- **Remove when:** OpenShift provisions the gateway LB with cross-zone enabled
  (or as an NLB) by default — *not* merely when a given cluster's IPs all
  answer. The old wording tested only today's topology, so it went green on any
  single-AZ cluster and would have deleted a workaround that silently returns
  the moment a cluster's nodes and its ELB's subnets stop overlapping.
- **Detection** (does this cluster have the precondition?): more distinct
  `dig +short maas.<domain>` IPs than AZs containing Ready nodes
  (`oc get nodes -L topology.kubernetes.io/zone`) means an empty AZ is enrolled
  and the annotation is actively load-bearing.
- **Precondition ABSENT 2026-08-14** (fresh bq4x2, **multi-AZ**: nodes in
  us-east-2a + us-east-2c): 2 ELB IPs vs 2 node-bearing AZs — equal, so no
  empty AZ is enrolled here and the annotation is not load-bearing *on this
  cluster*. All 6 per-IP probes (2 IPs × 3 rounds) returned 200. **Kept
  regardless**: the remove-when is an upstream change (OpenShift provisioning
  the gateway LB cross-zone or as an NLB by default), which has not happened.
  This run is a worked example of why that wording was corrected — the old
  per-cluster phrasing would have gone green here and retired a workaround that
  was demonstrably load-bearing on g767p nine days earlier.
- **Precondition PRESENT 2026-08-05** (fresh g767p): 2 ELB IPs vs 1 AZ with
  nodes (all MachineSets in us-east-2a) — the empty-AZ enrollment is real on
  this cluster, and with the annotation applied both IPs answer 200. First
  cluster since tm9xb where the workaround is demonstrably load-bearing, not
  just precautionary. Still unfiled upstream (OCPBUGS search 2026-08-05 found
  nothing covering cross-zone/empty-AZ on Gateway API classic ELBs).

---

## B. Structural GitOps / ordering accommodations (permanent)

| What | Where | Why |
|---|---|---|
| **Service Mesh operator NOT GitOps-managed** | *(intentionally absent from `components/operators/`)* | On OCP 4.20+ the **ingress operator owns** istio for Gateway API. Through 4.20.30 that meant owning a `servicemeshoperator3` subscription (Manual approval, pinned istio); from **4.20.32** there is no SM OLM operator at all — the ingress operator embeds the **sail library** and runs istiod directly (`managed-by=sail-library`). Either way, a GitOps-managed subscription fights it and can kill every gateway. See C2. |
| `maas-db-config` mirrored into `redhat-ai-gateway-infra` | `scripts/install-maas.sh` / `uninstall-maas.sh` | 3.5.0 moved maas-api there; PostgreSQL stays in `redhat-ods-applications` |
| `SkipDryRunOnMissingResource=true` on ~15 CRs | rhoai / maas / evalhub / nfs / nfd+nvidia / connectivity-link kustomizations | CRs sync before operator-created CRDs exist |
| `ignoreDifferences` — Subscription `installPlanApproval`; ClusterPolicy licensing | `components/argocd/apps/*-appset.yaml` | Operators mutate these fields |
| `applicationsSync: create-only` + `Prune=false` | `components/argocd/apps/*-appset.yaml` | Preserves per-app auto-sync patches from `make sync` |
| `IgnoreExtraneous` | nvidia-instance kustomization | NVIDIA operator injects non-schema fields |
| External Secrets `creationPolicy: Merge` | `bootstrap/external-secrets/pull-secret-external.yaml` | ExternalSecret deletion must not clobber the pull-secret |
| Authorino SSL via `oc set env` | `scripts/install-maas.sh` | No Authorino CR field for it |
| Generated Postgres password (imperative) | `scripts/install-maas.sh` | Can't be declarative in a public repo |
| Gateway/MaaS reconcile nudge | `scripts/install-maas.sh` | Operator may cache "gateway not found" pre-ArgoCD |
| Stale-DNS cleanup on uninstall | `scripts/uninstall-maas.sh` | LB DNS records don't auto-remove |
| Observability settle-gate + master-memory thresholds | `scripts/install-observability.sh`, `scripts/lib/cluster-health.sh` | Monitoring cascade is memory-heavy (cluster-hm2fl OOM, 2026-04-20) |
| UWM enabled at bootstrap | `bootstrap/cluster-monitoring-config/` | Foundational; avoids stacking overhead at observability install |

---

## C. Operational warnings

### C2. Service Mesh InstallPlans queued on Manual approval — review before approving

Where Gateway API is in use, the ingress operator owns the `servicemeshoperator3`
subscription (Manual approval, pinned to its istio version). Queued plans for
newer SM versions are **not** forgotten upgrades — they're versions the ingress
operator chose not to take. Evidence both ways: on OCP 4.20.27 (2026-07-14
audit) SM 3.4.0 refused the pinned istio as EOL and every gateway died; on
4.20.30 (r8mf7, tm9xb) SM 3.4.0 was auto-approved by F1 and all gateways work.
So: don't blind-approve on a shared/prod cluster — check the OCP z-stream's
istio pin first. (See also F1: `make sync` currently auto-approves these.)

On OCP **4.20.32+** this whole class disappears: no servicemeshoperator3
subscription exists (istiod is run by the ingress operator's embedded sail
library), so there is nothing to approve — but the guard stays for older
z-streams and for clusters upgraded from them.

---

## E. Install-time hazards — transient, known remedy

### E1. Operators cache a dependency probe at startup and never re-check

**The most common install-time failure class in this stack.** The tell: a
`Ready=False` / `Accepted=False` whose message names a dependency that
demonstrably exists. Confirmed instances: TrustyAI ("InferenceServices CRD does
not exist" — CRD present) and Kuadrant ("Gateway API provider is not installed"
— istiod Running; consequence: zero AuthConfigs, `POST /v1/api-keys` → 500
AUTH_FAILURE). Reproduced on every fresh cluster to date (r8mf7, fzgjg, tm9xb,
g767p 2026-08-05, bq4x2 2026-08-14 — Kuadrant CR's own message says "please
restart Kuadrant Operator pod once dependency has been installed"). On bq4x2
`install-maas.sh` hit and auto-remedied it inline ("Kuadrant operator cached a
missing Gateway API provider — restarting it"; AuthPolicy `maas-gateway-auth`
Accepted=True immediately after), leaving the operator pod 5 minutes younger
than its authorino/limitador siblings — a cheap post-hoc tell that E1 fired.
Jira: [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925)
— **moved Backlog → Review as of 2026-08-14**, so a fix is in flight. No
fixVersion yet; keep the auto-remedy until a nightly stops reproducing it.

**Gotcha:** the MaaS gateway AuthPolicy's *name* is not stable across builds
(`maas-gateway-auth` vs `gateway-default-auth`, and it can flap back after an
operator restart) — `install-maas.sh` resolves it by targetRef since
2026-08-05; older revisions hardcoded the name and reported "cannot evaluate
§E1 guard" when it differed.

**Remedy — delete the operator pod.** `oc rollout restart` does NOT work (OLM
reverts the annotation; silent no-op):

```bash
oc delete pods -n redhat-ods-operator -l name=rhods-operator            # trustyai / DSC
oc delete pod  -n openshift-operators -l control-plane=controller-manager,app=kuadrant
```

`install-maas.sh` auto-remedies the Kuadrant case (waits for the AuthPolicy
condition to materialize, then bounces the pod on the known message).

### E2. `make maas-model` times out on gpt-oss-20b (cold image cache)

The wait budget (900s) is shorter than a cold pull + vLLM load (~18 min: two
large images then engine init). If there's no CrashLoop/ImagePull error it's
just slow — watch `oc get pods -n llm -w` to 2/2. Candidate fix: raise the GPU
timeout in `scripts/setup-maas-model.sh` to ~1500s. (2026-08-05 g767p: script
exited 0 at ~17 min with the pod still 1/2 — vLLM finished loading ~4 min
later; the hazard is now "script declares done before the model serves" rather
than a hard timeout.) **Reproduced identically 2026-08-14** (bq4x2, L40S):
exit 0 at ~17 min with the pod at 1/2 and the MaaSModelRef reporting
`Unhealthy`; serving ~4 min later. Two runs on different clusters now agree on
the shape, which strengthens the case for the ~1500s fix.

---

## F. Defects in this repo's own scripts

### F1. `make sync` blanket-approves EVERY pending InstallPlan in `openshift-operators`

`scripts/sync-apps.sh` approves all unapproved plans with no CSV filter — on a
cluster with an ingress-owned SM subscription this violates C2 and can upgrade
Service Mesh as a side effect. Check before `make sync` on shared clusters:

```bash
oc get installplan -n openshift-operators \
  -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[0],APPROVED:.spec.approved
```

Fix (todo): filter to the CSV being synced + deny-list `servicemeshoperator3`.

### F2. `make cpu` hangs 20 min when `CPU_MIN=0`

`create-cpu-machineset.sh` waits for a Ready node even with scale-to-zero, which
never succeeds until a workload demands a node. Kill the wait once the
MachineSet + MachineAutoscaler exist. Fix (todo): skip the wait when replicas=0.
