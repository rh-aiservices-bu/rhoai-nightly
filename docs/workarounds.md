# Workarounds & Local Overrides

This repo deploys **RHOAI nightly** builds, so it routinely carries local
workarounds for upstream bugs, version skews, and OLM/GitOps quirks that a
stable release wouldn't need. They scatter across chart templates, overlays,
scripts, and (worst of all) live cluster state — which is easy to lose track
of. **This file is the canonical index.** When you add or retire a workaround,
update it here.

> **Last full audit: 2026-07-14** — fresh install of **RHOAI 3.5.0**
> (`rhoai-3.5-nightly`, channel `stable-3.x`) on a bare OCP 4.20.27 test
> cluster with the then-current workarounds deliberately stripped, to verify
> each one empirically. Evidence: `.tmp/workaround-audit-35.md`. Verdicts are
> folded in below; retired items moved to section E.

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
- **Status:** **Temporary.** In-repo on `main`. bu-nightly-2 still carries a
  **manual** copy until `clusters` is rebased (see C1).
- **Detection:** `oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.workloadSelector}'` — empty output == leak condition.
- **Remove when:** RHCL's wasm-shim stops emitting the field, **or** Kuadrant
  scopes its generated EnvoyFilter with a `workloadSelector`.
- **Refs:** `.tmp/issues/dashboard-gateway-kuadrant-wasm-leak.md`, issue #18.

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
  retired to section E).
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

## D. Known issues carrying **no** workaround

Documented so nobody hunts for a fix that isn't there.

- **ogx Playground breaks on in-place upgrade.** The ogx operator's ClusterRole
  lacks `configmaps/delete` **and** it never strips the stale `ca-bundle` volume
  from pre-existing deployments, so every Playground created before an ogx upgrade
  reports `Failed` (workload actually runs). No safe in-place fix — the CM is
  still mounted; granting `delete` or removing the CM wedges the pod. Remedy:
  delete + recreate the OGXServer (fresh instances use the clean, volume-less
  template). Recurs on the next in-place ogx upgrade.
- **GPU Observability panels blank.** Dashboards query
  `accelerator_gpu_utilization`; the operator emits `nvidia_gpu_utilization_ratio`.
  Upstream cross-repo mismatch (odh-dashboard ↔ opendatahub-operator); not fixable
  from this repo.
- **`/maas-api/v1/models` returns an empty list** (3.5.0) even with Ready
  MaaSModelRefs, after ~13s latency. Inference works via the per-model route
  prefix (`/llm/<model>/v1/...`); `verify-maas.sh` adapted. Upstream maas-api.
- **TelemetryPolicy labels not emitted** (3.5.0 + RHCL 1.4.1): the policy is
  Accepted+Enforced and its labels (`model`, `user`, `subscription`) are
  present in the wasm PluginConfig, but the data-plane metrics come out
  unlabelled (`kuadrant_allowed{}`; no tags on `istio_requests_total`) even
  after a gateway restart and with all label sources resolvable.
  Per-subscription usage panels lack breakdowns. Upstream RHCL wasm-shim.
- **TelemetryPolicy label with an unresolvable CEL source DISABLES token rate
  limiting** (RHCL 1.4.1): a single `NoSuchKey` (e.g.
  `auth.identity.subscription_info.costCenter`) aborts the wasm-shim's whole
  report task — token usage never reaches limitador, requests sail through
  with no 429s, **silently**. Our TelemetryPolicy now carries only labels
  whose sources exist (see the warning comment in
  `components/instances/maas-observability/base/gateway-telemetry-policy.yaml`).
  Detection: gateway envoy logs `Failed to evaluate message builder:
  CelError::Resolve { NoSuchKey(...) } ... Task failed`; limitador counters
  empty under traffic.
- **TelemetryPolicy spec UPDATES don't propagate to the wasm config**
  (RHCL 1.4.1): the operator observes the new generation and reports
  Accepted+Enforced, but the EnvoyFilter keeps the old labels — even across an
  operator restart. Only **delete + recreate** of the TelemetryPolicy forces a
  rebuild (ArgoCD selfHeal makes this a one-liner:
  `oc delete telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress`).
- **PersesDashboards created before Perses exists stay Degraded** with a stale
  `connection refused` condition (COO's perses-operator doesn't retry on a
  useful timescale). One-time fix: annotate the PersesDashboard CRs to nudge a
  reconcile. Candidate for automation in `install-observability.sh` if it
  recurs.

---

## E. Resolved / obsolete (do not re-add)

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
