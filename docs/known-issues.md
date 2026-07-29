# Known Issues, Workarounds & Local Overrides

This repo deploys **RHOAI nightly** builds, so it routinely hits upstream bugs,
version skews, and OLM/GitOps quirks that a stable release wouldn't. Some we work
around; some we simply live with. **This file is the canonical index of both.**

Two kinds of entry live here, and the distinction matters when you're debugging:

1. **Things we work around** (sections A–C) — a fix exists in this repo, or as
   manual cluster state. If one of these regresses, the workaround stopped
   working; go read it.
2. **Things that are just broken** (sections D–F) — no fix, or no *declarative*
   fix. If you hit one of these, you are not doing anything wrong and there is
   nothing to repair. Knowing that up front saves the afternoon.

When you add or retire either kind, update this file.

> **Scope note:** section E covers install-time failures that look alarming but
> have a known one-command remedy — most of them are operators caching a
> dependency probe at startup. Section F tracks defects in *this repo's own*
> scripts. Both are here because "the install failed and I don't know why" is the
> same question regardless of whose bug it is.

> **Last full audit: 2026-07-14** — fresh install of **RHOAI 3.5.0**
> (`rhoai-3.5-nightly`, channel `stable-3.x`) on a bare OCP 4.20.27 test
> cluster with the then-current workarounds deliberately stripped, to verify
> each one empirically. Evidence: `.tmp/workaround-audit-35.md`. Verdicts are
> folded in below; retired items moved to section G.

Legend:

- **In-repo** — committed; ArgoCD/scripts carry it. Safe across cluster rebuilds.
- **Manual (cluster-only)** — applied by hand on a cluster, **not** in git. At
  risk of being forgotten / lost on reconcile or rebuild.
- **Temporary** — tied to a specific broken build; has a "remove when" condition.
- **Permanent** — structural to the hybrid GitOps model or an upstream design
  gap with no CR/GitOps expression.

> Branch note: production cluster **bu-nightly-2** syncs from the **`clusters`**
> branch; the test cluster syncs from **`main`**. A fix merged to `main` is not
> live on bu-nightly-2 until `clusters` is rebased onto `main`. Check currency
> per-item below.

---

## A. Load-bearing bug / version-skew workarounds

These fix an active bug or version mismatch. Remove each only when its
"remove when" condition is met.

### A1. Dashboard gateway — strip leaked Kuadrant wasm

- **File:** `components/instances/maas-instance/chart/templates/dashboard-gateway-wasm-strip.yaml`
- **Symptom without it (SM 3.3.5):** RHOAI dashboard returns 503;
  `data-science-gateway` envoy crash-loops; envoy logs
  `no such field: 'allow_on_headers_stop_iteration'`.
- **Root cause:** With MaaS on, the Kuadrant/RHCL operator emits
  `EnvoyFilter/kuadrant-maas-default-gateway` with an **empty `workloadSelector`**,
  so istio injects its wasm into **every** gateway in `openshift-ingress` —
  including the dashboard gateway, which has no Kuadrant policy. RHCL v1.4.1's
  wasm-shim config contains `allow_on_headers_stop_iteration`, which some
  Service Mesh envoy builds reject.
- **3.5.0 audit:** the leak itself is **unchanged** on RHOAI 3.5.0 + RHCL 1.4.1.
  Whether it *breaks* depends on the SM build's envoy flags:
  - **SM 3.1.0** (what OCP 4.20's ingress operator installs on a fresh cluster)
    runs envoy with `--allow-unknown-static-fields` → the field only WARNs;
    dashboard works and MaaS auth + token rate limiting are fully functional.
  - **SM 3.3.5** (prod bu-nightly-2) hard-rejects → crash-loop.
- **Fix:** a second EnvoyFilter scoped by `workloadSelector` to only the
  dashboard gateway, `patch.operation: REMOVE` on the wasm HTTP filter. A
  harmless no-op where envoy tolerates the field; load-bearing where it doesn't.
- **Ordering is load-bearing (found 2026-07-29, cluster-r8mf7):** the strip filter
  carries `spec.priority: 100`. istio orders EnvoyFilters by
  (priority, creationTimestamp, name). At default priority 0 the REMOVE was ordered
  by creation time only — and the MaaS chart creates it at install time, whereas
  Kuadrant generates `kuadrant-maas-default-gateway` (the INSERT) whenever its
  operator *first* reconciles the AuthPolicy, which can be much later (here:
  strip 14:21:02, Kuadrant 15:00:56 — the moment the Kuadrant operator was
  restarted per **E1**). REMOVE-before-INSERT = wasm survives.
- **Second failure mode on SM 3.4.0 (not the `allow_on_headers_stop_iteration`
  rejection):** when the wasm does survive, the dashboard gateway envoy enters a
  **remote wasm-fetch retry loop** (~1/s, `Wasm remote code fetch is unstable and
  may cause a crash`), leaks memory, and is **OOMKilled (exit 137) at its 1Gi
  limit** → CrashLoopBackOff → dashboard 503. Same user-visible symptom, different
  mechanism — do not assume a 503 here means the unknown-field rejection.
- **Status:** **Temporary.** In-repo on `main`. bu-nightly-2 still carries a
  **manual** copy until `clusters` is rebased (see C1) — that manual copy predates
  the `priority` fix and should be updated.
- **Detection:** `oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.workloadSelector}'` — empty output == leak condition.
  Effectiveness check (the leak being present does NOT mean the strip is working):
  ```bash
  oc get pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=data-science-gateway \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount} {.items[0].status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
  # non-zero restarts + OOMKilled == strip is NOT effective
  oc get envoyfilter -n openshift-ingress -o json | jq -r '.items[]|"\(.spec.priority // 0) \(.metadata.creationTimestamp) \(.metadata.name)"' | sort
  # strip must sort AFTER kuadrant-maas-default-gateway
  ```
- **Remove when:** RHCL's wasm-shim stops emitting the field, **or** Kuadrant
  scopes its generated EnvoyFilter with a `workloadSelector`.
- **Refs:** `.tmp/issues/dashboard-gateway-kuadrant-wasm-leak.md`, issue #18.

### A1b. ai-gateway-operator — grant `update` on NetworkPolicies

- **File:** `components/instances/maas-instance/chart/templates/ai-gateway-networkpolicy-rbac.yaml`
- **Symptom without it:** `DataScienceCluster` stuck `AIGatewayReady=False` (and
  therefore `Ready=False`) even though the MaaS data plane (gateway, catalog,
  inference) is fully working. Operator log:
  `failed to remove owner references from object ...maas-controller-allow-monitoring...
  networkpolicies ... is forbidden: ai-gateway-operator cannot update ...`.
- **Root cause:** on the rhoai-3.5 nightly (seen 2026-07-22, maas commit
  `fba7cbf4`) the operator-shipped `ai-gateway-manager-role` ClusterRole grants
  `create/delete/get/list/patch/watch` on `networkpolicies` but **not `update`**.
  The ModelsAsService controller calls `Update()` to strip owner references and
  is denied.
- **Fix:** a supplementary ClusterRole/Binding adding the missing `update` verb,
  bound to the `ai-gateway-operator` SA (additive to the operator's own role).
- **Status:** **Temporary** (operator RBAC gap in the current nightly). In-repo.
- **Detection:** `oc auth can-i update networkpolicies -n redhat-ods-applications --as=system:serviceaccount:redhat-ods-applications:ai-gateway-operator` → `no`.
- **Remove when:** the operator CSV's `ai-gateway-manager-role` includes
  `networkpolicies` `update`.

### A2. MaaS gateway — raise istio-proxy memory to 2Gi

- **File:** `components/instances/maas-instance/chart/templates/maas-gateway-options.yaml`
  (+ explanatory comment in `gateway.yaml`)
- **Symptom without it:** `maas-default-gateway` envoy OOMKilled (exit 137,
  CrashLoopBackOff); MaaS endpoint unreachable.
- **Root cause:** istio's default proxy memory limit is 1Gi; envoy + the
  Kuadrant wasm enforcement config exceeds it **at rest**.
- **3.5.0 audit:** measured **1299Mi idle → 1456Mi under light traffic** on a
  fresh 3.5.0 install (SM 3.1.0) — over the 1Gi default before any load.
  Confirmed still needed; the parametersRef mechanism applies cleanly on 3.5.0.
- **Status:** **Permanent** (memory tuning; no upstream knob). In-repo.

### A3. MaaS gateway → payload-processing NetworkPolicy

- **File:** `components/instances/maas-instance/chart/templates/payload-processing-allow-maas-gateway.yaml`
- **Symptom without it:** every inference request through the MaaS gateway
  fails with HTTP 500 after a ~10s stall; gateway envoy logs
  `ext_proc_error_gRPC_error_14 { ... connection_timeout }`.
- **Root cause (3.5.0):** the operator-generated
  `NetworkPolicy/payload-processing` in `openshift-ingress` only allows :9004
  ingress from pods labelled `gateway-name: data-science-gateway`, but the
  ext_proc token-usage calls come from the **maas-default-gateway** envoys.
- **Fix:** a supplementary additive NetworkPolicy allowing the MaaS gateway
  pods (NetworkPolicies union, so no fight with the operator's own policy).
- **Status:** **Temporary** (upstream operator bug, found in the 3.5.0 audit).
  In-repo.
- **Remove when:** the operator's NetworkPolicy covers the MaaS gateway pods.

### A4. TrustyAI operator — pods/log grant for EvalHub

- **File:** `components/instances/evalhub/trustyai-operator-pod-logs-rbac.yaml`
- **Symptom without it:** `EvalHub/evalhub` stuck in phase `Pending`,
  `Ready=False`: "attempting to grant RBAC permissions not currently held:
  {pods/log get}".
- **Root cause (3.5.0):** the trustyai-service-operator creates a Role granting
  `pods/log get` (in `redhat-ods-applications` and again in each tenant
  namespace) but its own RBAC doesn't hold that permission — Kubernetes
  escalation prevention rejects the create.
- **Fix:** namespaced Role + RoleBinding pairs granting the operator SA
  `pods/log get` in `redhat-ods-applications` and `evalhub-tenant` (a new
  tenant namespace would need its own pair; kept namespaced for least
  privilege).
- **Status:** **Temporary** (upstream CSV RBAC gap, found in the 3.5.0 audit).
  In-repo.
- **Remove when:** the trustyai operator CSV ships the permission itself.

### A5. ArgoCD application-controller — 4Gi memory

- **File:** `bootstrap/argocd-instance/patch-controller-resources.yaml`
- **Symptom without it:** app-controller OOMKills at the operator-default 2Gi
  once the full app-set reconciles, crash-looping and stalling every sync.
- **3.5.0 audit:** measured **2164Mi** with the full 22-app set synced —
  already above the 2Gi default. Confirmed still needed (matches bu-nightly-2's
  ~2.2Gi steady).
- **Fix:** request 2Gi / limit 4Gi.
- **Status:** **Permanent.** In-repo.

### A6. Catalog re-resolution — `restart-catalog.sh` guards

- **File:** `scripts/restart-catalog.sh` (`make restart-catalog`)
- **Symptom without it:** after a catalog image flip where the CSV **name** is
  unchanged, OLM treats the operator as "already installed" and never re-resolves;
  naively deleting the Subscription orphans the running CSV → namespace-wide
  `ConstraintsNotSatisfiable` deadlock.
- **Fix:** same-version guard (skip Subscription delete unless the resolved
  version changed or `--force-resub` is passed); poll PackageManifests scoped to
  the Subscription's own catalog until the new head is serving; fail loud (exit 2)
  rather than orphan a CSV on an unconfirmed head.
- **Status:** **Permanent** (OLM behavior). In-repo. (Not build-specific — not
  re-tested in the 3.5.0 audit.)

### A7. DSC — `ogx: Managed`

- **File:** `components/instances/rhoai-instance/base/datasciencecluster.yaml`
- **Symptom without it:** Gen AI Studio **Playground** tab missing; the gen-ai
  BFF starts with an empty LlamaStack URL.
- **3.5.0 audit:** the operator defaults ogx to **Removed**
  (`OGXReady=False Removed`), so the explicit `Managed` is still required. The
  companion `llamastackoperator: Removed` we used to carry is now unnecessary —
  on 3.5.0 the component is off when unset and no longer blocks ogx (entry
  retired to section G).
- **Status:** **Permanent** (product default). In-repo.

### A8. 3.5.0 "Tenant CR not available yet" — settle-gate/verify accommodations

- **Files:** `scripts/install-observability.sh`, `scripts/install-evalhub.sh`
  (settle-gates), `scripts/verify-maas.sh` (WARN instead of FAIL)
- **Symptom without them:** `make observability` / `make evalhub` refuse to run
  and `make maas-verify` reports a false FAIL, because
  `DataScienceCluster` never reaches `Ready=True`.
- **Root cause (3.5.0 skew):** the operator's ModelsAsService controller waits
  for a legacy `Tenant` CR that the newer maas-controller no longer creates (it
  creates `MaasTenantConfig` + `AITenant`, both Ready). MaaS is fully
  functional — `make maas-verify` passes 13/13 — but
  `ModelsAsServiceReady=False: Tenant CR not available yet` pins DSC NotReady
  forever.
- **Fix:** the gates/verify tolerate exactly that condition signature (message
  match on "Tenant CR not available"); everything else still blocks.
- **Status:** **Temporary** (operator/component version skew). In-repo.
- **Remove when:** the operator build stops waiting for the legacy Tenant CR
  (DSC goes Ready=True with MaaS Managed).

### A9. feast-operator — grant `get` on `apiservers.config.openshift.io`

- **File:** `components/instances/rhoai-instance/base/feast-operator-apiserver-rbac.yaml`
- **Symptom without it:** `DataScienceCluster` stuck `Ready=False` with
  `Some modules are not ready: feastoperator`
  (`FeastOperatorReady=False reason=DeploymentsNotReady msg=0/1 deployments ready`),
  even though all ArgoCD Applications are Synced+Healthy. Pod
  `feast-operator-controller-manager-*` is in CrashLoopBackOff; its log ends with
  `ERROR setup unable to read APIServer TLS profile, refusing to start with unknown
  TLS posture ... apiservers.config.openshift.io "cluster" is forbidden`.
  Because the settle-gate in `scripts/install-observability.sh` requires
  `DSC Ready=True` and only tolerates the §A8 "Tenant CR" signature,
  `make observability` aborts.
- **Root cause (3.5.0 nightly, seen 2026-07-29 on cluster-r8mf7):** two feast
  operators ship. The DSC-owned `opendatahub-feast-operator` is healthy and
  creates `FeastOperator/default-feastoperator`, which deploys
  `feast-operator-controller-manager`. That controller reads the cluster
  APIServer TLS profile at startup and hard-exits if denied, but neither shipped
  ClusterRole (`feast-operator-manager-role`, `opendatahub-feast-manager-role`)
  grants `config.openshift.io/apiservers`. Does not self-heal — the RBAC comes
  from the operator bundle.
- **Fix:** a supplementary ClusterRole/Binding granting `get/list/watch` on
  `apiservers`, bound to the `feast-operator-controller-manager` SA in
  `redhat-ods-applications` (additive; RBAC rules union, so no fight with the
  operator's reconcile).
- **Status:** **Temporary** (operator CSV RBAC gap in the current nightly). In-repo.
- **Detection:**
  `oc auth can-i get apiservers.config.openshift.io --as=system:serviceaccount:redhat-ods-applications:feast-operator-controller-manager` → `no`, or
  `oc get clusterrole feast-operator-manager-role -o json | jq '[.rules[]|select(.apiGroups[]?=="config.openshift.io")]|length'` → `0`.
- **Remove when:** the operator CSV's feast ClusterRole includes
  `config.openshift.io/apiservers get`.

### A10. gen-ai-ui — allow egress to LlamaStack on :8321

- **File:** `components/instances/rhoai-instance/base/gen-ai-lsd-egress-networkpolicy.yaml`
- **Symptom without it:** the Gen AI Studio **Playground** shows
  *"You need at least one model — Looks like your project is missing at least one
  model to use the playground"* in **every** project, regardless of whether the
  project has AI assets or MaaS models. `/gen-ai/api/v1/lsd/models` returns
  **504**; `/maas/models`, `/aaa/models` and `/lsd/status` all return 200.
- **Root cause (3.5.0, found 2026-07-29 on cluster-r8mf7):** the playground's
  model list comes from the LlamaStack distribution (OGXServer) in the *user's
  project* namespace, served on port **8321**. The operator-shipped egress policy
  `gen-ai-allow-ports` (owned by `Dashboard/default-dashboard`) permits only
  5353→openshift-dns, 8243→maas-ui, 8343→mlflow-ui, 6443→any, 443/80→any —
  **8321 is missing**, so the BFF's call is silently dropped and hangs until the
  gateway 504s. In `ChatbotMain.tsx` the empty state is gated on
  `hasNoModels = models.length === 0`, where `models` is the LlamaStack list
  (`useFetchLlamaModels`) — *not* the MaaS-aware `hasModels` on line 107 — so an
  unreachable LlamaStack reads as "no models".
- **Fix:** a second, additive NetworkPolicy selecting the same `deployment:
  gen-ai-ui` pods and allowing egress TCP 8321. Kubernetes unions egress rules
  across all policies selecting a pod, so this grants the port without modifying
  the operator-owned policy (which is reconciled continuously). Destination is
  deliberately not namespace-scoped — LlamaStack distributions are created on
  demand in arbitrary user project namespaces.
- **Status:** **Temporary** (upstream dashboard NetworkPolicy gap). In-repo.
- **Detection / verification:**
  ```bash
  oc get networkpolicy gen-ai-allow-ports -n redhat-ods-applications \
    -o json | jq -r '.spec.egress[] | "\([.ports[]?.port]|join(","))"'   # 8321 absent?
  POD=$(oc get pods -n redhat-ods-applications --no-headers | grep '^gen-ai-ui' | head -1 | awk '{print $1}')
  oc exec -n redhat-ods-applications $POD -- \
    curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 20 \
    http://lsd-genai-playground-service.<project>.svc.cluster.local:8321/v1/models
  # blocked: 000 after ~20s (dropped)   working: 200 in ~0.01s
  ```
  Verified with the operator policy at its original 5 rules and only the
  supplementary policy present: BFF→LlamaStack 200 in 0.012s, `/lsd/models` 200.
- **Remove when:** the dashboard's own `gen-ai-allow-ports` includes 8321.

---

## B. Structural GitOps / ordering workarounds (permanent)

Model-inherent — not tied to a broken build. Brief, because they're stable.

| What | Where | Why |
|---|---|---|
| **Service Mesh operator NOT GitOps-managed** | *(removed from `components/operators/` in the 3.5.0 audit)* | On OCP 4.20+ the **ingress operator owns** the `servicemeshoperator3` subscription for Gateway API (annotation `ingress.operator.openshift.io/owned`): channel `stable`, **`installPlanApproval: Manual`**, and it approves only the SM version matching its hardcoded istio pin (v1.26.2 → SM 3.1.0 on 4.20). A GitOps-managed subscription fights it, and with Automatic approval pulls SM 3.4.0 — which **refuses istio v1.26.2 as EOL**, leaving the GatewayClass unaccepted and every gateway (MaaS + dashboard) dead. The SM operator now arrives automatically when the first GatewayClass is created. **Never approve queued SM InstallPlans beyond the ingress operator's chosen version** (see C2). |
| `maas-db-config` mirrored into `redhat-ai-gateway-infra` | `scripts/install-maas.sh` / `scripts/uninstall-maas.sh` | RHOAI 3.5.0 moved maas-api into `redhat-ai-gateway-infra` and it reads the DB secret there; PostgreSQL stays in `redhat-ods-applications` (fully-qualified connection URL) |
| `SkipDryRunOnMissingResource=true` on ~15 CRs | rhoai / maas / evalhub / nfs / nfd+nvidia / connectivity-link / postgres kustomizations | CRs sync before their operator-created CRDs/namespaces exist |
| `ignoreDifferences` — Subscription `installPlanApproval`; ClusterPolicy `driver.licensingConfig.secretName` | `components/argocd/apps/*-appset.yaml` | Operators mutate these fields; masks perpetual drift |
| `applicationsSync: create-only` + `Prune=false` | `components/argocd/apps/*-appset.yaml` | Preserves per-app auto-sync patches `make sync` applies; keeps singletons alive if their App is removed |
| `IgnoreExtraneous` | `components/instances/nvidia-instance/base/kustomization.yaml` | NVIDIA operator injects non-schema fields |
| External Secrets `creationPolicy: Merge` | `bootstrap/external-secrets/pull-secret-external.yaml` | Deleting the ExternalSecret must not clobber the global pull-secret |
| Authorino SSL via `oc set env` | `scripts/install-maas.sh` | No Authorino CR field for SSL cert env vars |
| Generated Postgres password (imperative secret) | `scripts/install-maas.sh` | Can't be declarative in a public git repo |
| Gateway/ModelsAsService reconcile nudge | `scripts/install-maas.sh` | Operator may cache "gateway not found" before ArgoCD creates it; annotate to re-trigger |
| Stale-DNS cleanup on uninstall | `scripts/uninstall-maas.sh` | LoadBalancer DNS records don't auto-remove |
| Observability settle-gate + master-memory OOM thresholds (32GiB floor, 80% abort) | `scripts/install-observability.sh`, `scripts/lib/cluster-health.sh` | Empirical from the cluster-hm2fl OOM (2026-04-20); the monitoring cascade is memory-heavy |
| UWM enabled at bootstrap | `bootstrap/cluster-monitoring-config/` | Foundational; owned at infra stage so the cascade doesn't stack UWM overhead at install time |

---

## C. Manual cluster-state — NOT in git (at risk)

The easiest to lose track of. Prefer moving each into git.

### C1. Dashboard EnvoyFilter on bu-nightly-2 (manual)

The GitOps version (A1) is on `main` but not `clusters`, so bu-nightly-2 is held
up by a hand-applied `strip-kuadrant-wasm-dashboard-gateway` EnvoyFilter.
**Action:** rebase `clusters` onto `main`; the chart template has the same
name/namespace, so ArgoCD adopts the manual object in place — nothing to delete.

### C2. Service Mesh InstallPlans queued on Manual approval — DO NOT approve

On clusters where Gateway API is in use, the **ingress operator** owns the
`servicemeshoperator3` subscription and deliberately sets
`installPlanApproval: Manual`, approving only the SM version matching the OCP
release's istio pin. Queued InstallPlans for newer SM versions (e.g. 3.4.0 on
OCP 4.20) are **not** forgotten upgrades — approving them can break every
gateway (SM 3.4.0 refuses istio v1.26.2 as EOL; verified in the 3.5.0 audit).
Other operators in `openshift-operators` (OTel, RHCL, Authorino) declare
`Automatic` in git; the appset's `ignoreDifferences` on `installPlanApproval`
means ArgoCD won't fight live changes to that field either way.

---

## D. Known issues (not worked around)

Documented so nobody hunts for a fix that isn't there. Split by whether a fix
is on the way: **D1** items just need a newer build (nothing to do but wait);
**D2** items have no upstream fix — some carry a manual remedy, some are
genuinely stuck and may warrant filing/escalation.

### D1. Tracked upstream — fix in flight (self-resolves on a future nightly)

- **`/maas-api/v1/models` empty catalog — maas-api ↔ maas-controller version
  skew (recurring nightly risk).** When the catalog is empty despite a Ready
  MaaSModelRef, MaaS models disappear from **every** project's Gen AI Studio
  playground (the dashboard populates each project's model picker from this
  cluster-wide catalog, *not* from in-namespace resources). Root cause is a skew
  between the two MaaS images the operator vendors:
  - the **maas-api** builds the list, then (older behavior) **probes** each
    model at `<status.endpoint>/v1/models`;
  - the **maas-controller** sets `MaaSModelRef.status.endpoint`.
  The break is the one combination *probing maas-api + BBR base endpoint* (`/`):
  the probe hits the maas-api's **own** `/v1/models` route and recurses until it
  times out (~13s, fail-closed) → the model is excluded → empty list. Two
  independent upstream fixes remove the hazard, and current nightlies have them:
  **#1142** makes the controller prefer the **path-based** endpoint
  (`.../<ns>/<model>`) so the probe reaches the model; **#1208** removes the
  maas-api probe entirely (models included by readiness). The 2026-07-14 build
  had *neither* and was broken; builds from 2026-07-17 on are fine.
  **Because this repo tracks the latest floating nightly, the skew can reappear
  on any given day's build** — so `verify-maas.sh` now asserts the catalog lists
  the deployed model (a FAIL, not a WARN). Detection when it recurs: empty
  `/maas-api/v1/models`, a storm of self-directed `GET /v1/models` in the
  maas-api log, and `MaaSModelRef.status.endpoint` == bare `/`. Tracked:
  [RHOAIENG-76220](https://redhat.atlassian.net/browse/RHOAIENG-76220)
  (Resolved) — "/v1/models returns empty list on BBR-enabled clusters due to
  endpoint preference selecting model-routing base URL".
- **MaaS models hidden from the Gen AI playground — dashboard ↔ operator
  condition-rename skew.** Even with a healthy, populated catalog (BFF
  `/api/v1/maas/models` and `/maas-api/v1/models` both return the model), the
  Gen AI Studio playground shows "No available model deployments" and the MaaS
  models never appear as AI-asset endpoints. Root cause is a name skew:
  - the **operator** renamed the MaaS module `modelsasservice` → `aigateway`,
    so its DSC readiness condition is now **`AIGatewayReady`** (live cluster:
    `AIGatewayReady=True`, no `ModelsAsServiceReady` condition at all — see
    operator-side context in
    [ai-gateway-operator#47](https://github.com/opendatahub-io/ai-gateway-operator/issues/47), closed);
  - the **dashboard** still gates the `modelAsService` feature area on a
    `customCondition` requiring a DSC condition literally named
    **`ModelsAsServiceReady == True`** — hardcoded in *both*
    `packages/gen-ai/frontend/src/odh/extensions.ts` (playground) and
    `packages/maas/frontend/src/odh/odhExtensions/odhExtensions.ts` (MaaS admin
    / AI-assets area). Present in downstream **and** current upstream ODH HEAD.
  Feature-area availability is a hard **AND** of feature-flag ∧ customCondition
  (`frontend/src/concepts/areas/utils.ts`), so setting
  `OdhDashboardConfig.spec.dashboardConfig.modelAsService: true` does **not**
  override it — the customCondition is an independent gate on the (now absent)
  condition name. **No GitOps fix exists** from this repo: we can't inject a
  DSC status condition (operator-owned) and can't patch the frontend (baked into
  the `odh-dashboard-rhel9` image).
  **Tracked & being fixed operator-side:**
  [RHOAIENG-78159](https://redhat.atlassian.net/browse/RHOAIENG-78159) (Review,
  no fixVersion yet) — the operator will **re-surface `ModelsAsServiceReady`**
  on the DSC (derived from the AIGateway module's `modelsAsAService` state), so
  the dashboard code is left unchanged and the gate satisfies again. Note the
  Jira title spells it `ModelsAsAServiceReady` (extra "A"); the dashboard
  constant is `ModelsAsServiceReady` — the two strings must match exactly or the
  gate stays broken. Because main tracks the floating nightly, this
  **self-resolves** the day a build ships the restored condition. Detection:
  MaaS catalog non-empty but playground empty; `oc get datasciencecluster
  default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'`
  shows `AIGatewayReady` and no `ModelsAsServiceReady`.

### D2. Unfixed — no upstream fix (manual remedy or genuinely stuck)

- **GPU Observability panels blank.** *Status: untracked — no known fix.*
  Dashboards query `accelerator_gpu_utilization`; the operator emits
  `nvidia_gpu_utilization_ratio`. Upstream cross-repo mismatch (odh-dashboard ↔
  opendatahub-operator); not fixable from this repo.
- **TelemetryPolicy labels not emitted** (3.5.0 + RHCL 1.4.1): *Status:
  untracked — no known fix (upstream RHCL wasm-shim).* the policy is
  Accepted+Enforced and its labels (`model`, `user`, `subscription`) are
  present in the wasm PluginConfig, but the data-plane metrics come out
  unlabelled (`kuadrant_allowed{}`; no tags on `istio_requests_total`) even
  after a gateway restart and with all label sources resolvable.
  Per-subscription usage panels lack breakdowns. Upstream RHCL wasm-shim.
- **TelemetryPolicy label with an unresolvable CEL source DISABLES token rate
  limiting** (RHCL 1.4.1): *Status: mitigated in-repo (labels dropped);
  underlying RHCL bug unfixed.* a single `NoSuchKey` (e.g.
  `auth.identity.subscription_info.costCenter`) aborts the wasm-shim's whole
  report task — token usage never reaches limitador, requests sail through
  with no 429s, **silently**. Our TelemetryPolicy now carries only labels
  whose sources exist (see the warning comment in
  `components/instances/maas-observability/base/gateway-telemetry-policy.yaml`).
  Detection: gateway envoy logs `Failed to evaluate message builder:
  CelError::Resolve { NoSuchKey(...) } ... Task failed`; limitador counters
  empty under traffic.
- **TelemetryPolicy spec UPDATES don't propagate to the wasm config**
  (RHCL 1.4.1): *Status: manual remedy — delete + recreate; recurs on every
  spec change.* the operator observes the new generation and reports
  Accepted+Enforced, but the EnvoyFilter keeps the old labels — even across an
  operator restart. Only **delete + recreate** of the TelemetryPolicy forces a
  rebuild (ArgoCD selfHeal makes this a one-liner:
  `oc delete telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress`).
- **ogx Playground breaks on in-place upgrade.** *Status: manual remedy —
  delete + recreate the OGXServer; recurs each ogx upgrade.* The ogx operator's
  ClusterRole lacks `configmaps/delete` **and** it never strips the stale
  `ca-bundle` volume from pre-existing deployments, so every Playground created
  before an ogx upgrade reports `Failed` (workload actually runs). No safe
  in-place fix — the CM is still mounted; granting `delete` or removing the CM
  wedges the pod. Remedy: delete + recreate the OGXServer (fresh instances use
  the clean, volume-less template). Recurs on the next in-place ogx upgrade.
- **PersesDashboards created before Perses exists stay Degraded** with a stale
  `connection refused` condition (COO's perses-operator doesn't retry on a
  useful timescale): *Status: manual remedy — annotate to nudge a reconcile;
  one-time.* One-time fix: annotate the PersesDashboard CRs to nudge a
  reconcile. Candidate for automation in `install-observability.sh` if it
  recurs.

---

### D2a. MaaS catalog advertises the bare gateway base as the model URL

- **Symptom:** `make maas-verify` reports **11 passed / 3 failed** — inference
  404, unauthenticated 404 (expected 401/403), and "No 429 responses". All three
  are the *same* bug: the test URL is wrong, so every request 404s before auth or
  rate limiting is reached. Reproduces on repeated runs; not timing.
- **Detection:**
  ```bash
  oc get maasmodelref <model> -n llm -o jsonpath='{.status.endpoint}{"\n"}'
  # https://maas.apps.<domain>/           <- bare base, WRONG
  curl -sk "$MAAS/maas-api/v1/models" -H "Authorization: Bearer $KEY" | jq '.data[0]|{id,url}'
  # url is the same bare base; expected https://maas.apps.<domain>/llm/<model>
  ```
- **Root cause (3.5.0 nightly, 2026-07-29):** maas-controller sets
  `MaaSModelRef.status.endpoint` to the BBR base (`/`) instead of the path-based
  `/<ns>/<model>`; maas-api echoes it as the catalog `url`. This is the
  pre-#1142 BBR-endpoint bug resurfacing in a *new* variant — the catalog is
  **populated** here (discovery worked), only the `url` field is wrong, so the
  empty-catalog guard in `verify-maas.sh` does not trigger.
- **The data plane is NOT broken.** Verified against the correct path:
  inference 200, no-auth 401, invalid token 403, and 5 rapid free-tier requests
  gave `200 200 429 429 429`. Auth and rate limiting both work.
- **Blast radius:** anything that trusts the catalog `url` builds a 404 — which
  is how this reaches the Gen AI playground (see D2c; the LlamaStack provider
  `base_url` is derived from it via `ensureVLLMCompatibleURL`).
- **Fix:** none available — maas-controller/maas-api behavior. Optional
  hardening: make `verify-maas.sh` fall back to `${HOST}/${NS}/${MODEL}` when
  `.data[0].url` has an empty path, and WARN naming this bug, so a genuine
  data-plane regression isn't masked by a metadata bug.
- **Remove when:** `MaaSModelRef.status.endpoint` reports the path-based URL.

### D2b. Two operator ServiceMonitors rejected by UWM (`bearerTokenFile`)

- **Symptom:** none user-visible — `make diagnose` is green and the Observability
  dashboard loads. But two components' metrics are silently never scraped.
- **Detection:**
  ```bash
  oc get events -n redhat-ods-applications --field-selector type=Warning,reason=InvalidConfiguration \
    -o jsonpath='{range .items[*]}{.involvedObject.name}: {.message}{"\n"}{end}'
  # controller-manager-metrics-monitor / odh-model-controller-metrics-monitor:
  #   rejected due to invalid configuration: endpoints[0]: it accesses file system
  #   via bearer token file which Prometheus specification prohibits
  ```
- **Root cause (3.5.0):** both ServiceMonitors set
  `endpoints[0].bearerTokenFile`. The prometheus-operator backing OpenShift
  user-workload monitoring prohibits filesystem token access for tenant workloads
  and rejects the whole object. The modern equivalent is
  `authorization.credentials` with a Secret reference.
- **Owners (cannot be fixed in-repo):** `DataScienceCluster/default-dsc` and
  `Kserve/default-kserve` — reconciled by the RHOAI operator, so a local patch is
  reverted, and there is no DSC field to override them.
- **Impact:** RHOAI controller-manager and odh-model-controller metrics are
  absent from UWM. MaaS/gateway/vLLM metrics are unaffected (those come from the
  Kuadrant monitors, `istio-gateway-metrics` and `kserve-llm-models`), so the
  Observability dashboard still populates — but panels fed by these two
  controllers stay empty. Easy to misread as "observability is broken".
- **Diagnosis note:** invisible to resource-existence checks — the objects exist
  and look correct; only Prometheus's rejection *event* reveals they are inert.
- **Fix:** none available — upstream must switch to `authorization.credentials`.

### D2c. Playground MaaS provider gets `api_token: "fake"` — no declarative fix

- **Symptom:** with §A10 in place the playground loads, but a MaaS-backed model
  still yields no completions and the LlamaStack pod logs, on every refresh:
  ```
  ERROR list_provider_model_ids() failed  error=Error code: 401  provider=VLLMInferenceAdapter
  WARNING Model refresh skipped  provider_id=maas-vllm-inference-<N>
  ```
- **Root cause (3.5.0, found 2026-07-29):** the gen-ai BFF builds the OGXServer
  container env in
  `packages/gen-ai/bff/internal/integrations/kubernetes/token_k8s_client.go`.
  Installing a MaaS model *requires* the user token (~line 1802,
  `"user auth token is required to install MaaS models"`) and threads it into
  `generateLlamaStackConfig` for the run.yaml — but the env-var builder (~line
  1600) only resolves `modelSecrets[model.ModelName]`, i.e. **service-account
  token secrets that exist for in-project deployments**. A MaaS model has no such
  secret, so it falls to the `else` branch and gets `Value: "fake"`. The run.yaml's
  `api_token` resolves from that env var, so LlamaStack authenticates to MaaS with
  `Bearer fake` → 401 → zero models registered.
- **Why there is no in-repo workaround:** the OGXServer CR is created on demand by
  the dashboard when a user creates a playground, in that user's project namespace,
  with a per-playground provider index. There is nothing static to patch in git.
- **Manual remedy (per playground, lost when the playground is recreated):**
  ```bash
  NS=<project>; LSD=lsd-genai-playground
  MAAS=https://maas.apps.<cluster-domain>
  KEY=$(curl -sk -X POST "$MAAS/maas-api/v1/api-keys" \
        -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
        -d '{"name":"playground","subscription":"<model>-free"}' | jq -r .key)
  IDX=$(oc get ogxserver $LSD -n $NS -o json \
        | jq -r 'paths(objects) as $p | select(getpath($p).name? == "VLLM_API_TOKEN_1") | ($p|join("."))' \
        | sed 's/.*\.//')
  oc patch ogxserver $LSD -n $NS --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/workload/overrides/env/$IDX/value\",\"value\":\"$KEY\"}]"
  ```
  Verified on cluster-r8mf7: after the patch the pod restarts,
  `list_provider_model_ids() returned` (no 401), and LlamaStack registers
  `maas-vllm-inference-1/publishers/llm/models/gpt-oss-20b`.
- **Upstream fix needed:** thread the MaaS user token (or a minted MaaS API key)
  into `VLLM_API_TOKEN_<N>` for `ModelSourceTypeMaaS` models instead of defaulting
  to `"fake"`.

---

## E. Install-time hazards — transient, with a known remedy

Not workarounds (nothing to carry in git) and not permanent breakage. These are
failures a fresh install hits, that look serious, and that clear with one
command once you recognise the shape.

### E1. Operators cache a dependency probe at startup and never re-check

**The single most common install-time failure class in this stack.** An operator
probes for a dependency once at startup, caches the answer, and never
re-evaluates. The tell: a `Ready=False` / `Accepted=False` whose message names a
dependency that **demonstrably does exist**.

Confirmed instances (both on a fresh install, 2026-07-29):

| Component | Message | Reality |
|---|---|---|
| `TrustyAI/default-trustyai` | `InferenceServices CRD does not exist, please enable serving component first` | CRD present, `KserveReady=True`. Condition set 14:16:21, CRD created 14:16:43 — lost a 22s race. |
| `AuthPolicy/maas-gateway-auth` | `[Gateway API provider (istio / envoy gateway)] is not installed, please restart Kuadrant Operator pod` | istiod Running. Consequence: **zero AuthConfigs** → Authorino enforces nothing → `POST /v1/api-keys` returns 500 with `X-MaaS-Username=absent`, while every structural MaaS check passes. |

**Remedy — delete the operator pod. `oc rollout restart` does NOT work:** OLM
owns these Deployments and reverts the `restartedAt` annotation, so no new
ReplicaSet is created. `oc rollout status` still reports "successfully rolled
out" (it is describing the already-healthy pods), the ReplicaSet hash is
unchanged, and pod AGE does not reset — a silent no-op.

```bash
oc delete pods -n redhat-ods-operator -l name=rhods-operator          # trustyai / DSC components
oc delete pod  -n openshift-operators -l control-plane=controller-manager   # kuadrant
```

Verify the fix took: ReplicaSet hash and pod AGE actually changed, then re-read
the condition. `lastTransitionTime` is NOT proof of a re-check — it only moves
when the condition *value* changes, so a stale-False and a repeatedly-re-failing
False look identical.

**Generalises:** any `PreConditionFailed` / `Accepted=False` referencing a
resource that exists is this pattern. Remedy is always "delete the operator pod".

### E2. `make maas-model` times out on gpt-oss-20b (cold image cache)

- **Symptom:** `make maas-model` deploys correctly, waits, then exits
  `make: *** [maas-model] Error 1` at ~900s while the pod is still
  `PodInitializing`. The model comes up fine minutes later — only the wait budget
  is wrong.
- **Measured on a fresh cluster (cold cache, g6e.2xlarge / L40S):**

  | Stage | Elapsed |
  |---|---|
  | `modelcar-gpt-oss-20b:1.5` pull (weights, ~8GB), init container | 0 → ~12m |
  | `vllm-cuda-rhel9:3.3.0` pull (runtime), main container | ~12m → ~14m30s |
  | vLLM engine init + weight load + CUDA graph capture | ~14m30s → ~18m |
  | **Total to 2/2 Ready** | **~18 min** vs a **15 min** budget |

- **Root cause:** the GPU timeout assumes one image pull; gpt-oss-20b pulls
  **two** large images sequentially before vLLM even starts loading.
- **Distinguish from a real failure:** check for CrashLoopBackOff /
  ImagePullBackOff. Absent means it is just slow — `oc get pods -n llm -w` until
  2/2, then `oc get llminferenceservice -n llm`.
- **Beware exit-code masking:** `make maas-model 2>&1 | tee log` returns **tee's**
  status (0), so a wrapper reports success while make failed. Use
  `${PIPESTATUS[0]}` or `set -o pipefail`.
- **Candidate fix:** raise the GPU-model timeout in `scripts/setup-maas-model.sh`
  from 900s to ~1500s, and distinguish "still pulling images" from "vLLM loading"
  in the progress output.

---

## F. Defects in this repo (not upstream)

### F1. `make sync` blanket-approves EVERY pending InstallPlan in `openshift-operators`

- **Symptom (benign on a greenfield sandbox, hazardous elsewhere):** during the
  `opentelemetry-operator` sync step the log reads
  `Auto-approving InstallPlan: install-5vplb`. That plan was **not** OpenTelemetry:
  ```bash
  oc get installplan install-5vplb -n openshift-operators \
    -o jsonpath='{.spec.clusterServiceVersionNames[0]}{"\n"}'
  # servicemeshoperator3.v3.4.0
  ```
  `make sync` silently upgraded Service Mesh 3.1.0 → 3.4.0 as a side effect of
  installing OTel.
- **Root cause:** `scripts/sync-apps.sh:87-94` selects *all* InstallPlans with
  `spec.approved==false` in `openshift-operators` and approves each, with **no
  filter on `spec.clusterServiceVersionNames`**. Any Manual-approval subscription
  parked in that namespace is approved by whichever app sync runs next.
- **Why it matters:** section **C2** records that Service Mesh InstallPlans on
  Manual approval must **NOT** be approved where the ingress operator owns the SM
  subscription — approving them can disrupt the ingress data plane. `make sync`
  currently does exactly that, unconditionally. The two entries are in direct
  conflict.
- **Outcome observed (cluster-r8mf7, greenfield, no ingress-owned SM sub):**
  harmless. SM 3.4.0 reached Succeeded, `oc get co ingress` stayed
  True/False/False, and MaaS on SM 3.4.0 passed inference (200), auth (401/403)
  and rate limiting (429).
- **Check before running `make sync` on a shared/prod cluster:**
  ```bash
  oc get installplan -n openshift-operators \
    -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[0],APPROVED:.spec.approved
  ```
- **Fix:** filter the auto-approve loop to the CSV the sync step is waiting on,
  and/or keep a deny-list (`servicemeshoperator3`) that is never auto-approved.
  Log every skipped plan so the decision stays visible. `scripts/diagnose.sh`
  already refuses to *recommend* approving SM plans; `sync-apps.sh` does not yet
  honour the same rule.

### F2. `make cpu` hangs 20 min when `CPU_MIN=0` (scale-to-zero)

- **Symptom:** `make cpu` creates the MachineSet + MachineAutoscaler successfully
  (replicas=0, min=0, max=3), then blocks at "Waiting for CPU worker node to be
  Ready" until it times out and exits 1. The infrastructure is actually fine.
- **Root cause:** `scripts/create-cpu-machineset.sh:228-229` is commented
  *"Always wait for CPU worker node to be Ready"* and does so regardless of
  replica count. With `CPU_MIN=0` the autoscaler deliberately provisions nothing
  until a Pending pod demands it, so the wait can never succeed.
- **Still present** (verified 2026-07-29): no `REPLICAS -gt 0` guard around the
  wait loop.
- **Workaround:** kill the target once the MachineSet + MachineAutoscaler exist;
  the autoscaler provisions a node when workloads land.
- **Fix:** guard the wait with `if [[ "$REPLICAS" -gt 0 ]]`, and when MIN=0 log
  that the MachineSet is scale-to-zero and exit 0 immediately after creation.

---

## G. Resolved / obsolete (do not re-add)

Kept as a short tombstone list so these don't get "rediscovered":

- **Perses datasource secret-name fix** (`kuadrant-persesdatasource-fix.yaml`) —
  obsolete on RHOAI 3.5.0: the datasource layout was restructured; all
  PersesDatasources live in `redhat-ods-monitoring` referencing secrets that
  exist there. Verified end-to-end (proxy queries succeed; 4/4 dashboards
  Available). Removed in the 2026-07-14 audit.
- **Perses service-CA injection ConfigMap** (`service-ca-injection.yaml`) —
  obsolete on 3.5.0: the operator provisions `prometheus-web-tls-ca` itself;
  Perses↔Prometheus TLS works with zero configuration from us. Removed in the
  2026-07-14 audit.
- **NVIDIA local base without console-plugin** (OCPBUGS-59972) — obsolete:
  the console fix (OCPBUGS-61785) shipped in OCP 4.20.z ≥ Dec 2025. The
  component references the upstream gitops-catalog overlay again
  (console-plugin included, channel `stable` → v26.3.3 verified healthy on
  4.20.27). Removed in the 2026-07-14 audit.
- **DSC `llamastackoperator: Removed`** — unnecessary on 3.5.0: unset defaults
  to off and no longer blocks ogx (only `ogx: Managed` is still required — A7).
- **GitOps-managed `openshift-service-mesh` component** — removed; the ingress
  operator owns the SM subscription on OCP 4.20+ (see B / C2). An interim
  `stable-3.3` channel pin existed for a few hours during the audit and was
  superseded the same day.
- **MaaS CRD-rename operator re-vendor lag** (ea.2: payload-processing expected
  `inference.opendatahub.io`, operator shipped `maas.opendatahub.io`) — fixed
  in the 3.5.0 GA operator (embeds the renamed CRDs; payload-processing
  Running).
- **3.4 catalog `readOnlyRootFilesystem` crashloop** — resolved by catalog pin.
- **`CLUSTER_AUDIENCE` literal-arg 401s (3.4)** — fixed upstream (MaaS PR #790).
- **Perses `v1alpha1` write-storm** — resolved with COO 1.5.1.
- **COO 1.5.0 perses-server `--web.tls-min-version` crash** — resolved with COO 1.5.1.
- **`maas-controller-perses-fix` ClusterRole/Binding** — redundant since MaaS
  PR #818; candidate for removal if it still lingers on the `clusters` branch.
