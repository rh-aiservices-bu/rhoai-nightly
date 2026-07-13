# Workarounds & Local Overrides

This repo deploys **RHOAI nightly** builds, so it routinely carries local
workarounds for upstream bugs, version skews, and OLM/GitOps quirks that a
stable release wouldn't need. They scatter across chart templates, overlays,
scripts, and (worst of all) live cluster state — which is easy to lose track
of. **This file is the canonical index.** When you add or retire a workaround,
update it here.

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
- **Symptom without it:** RHOAI dashboard returns 503. `data-science-gateway`
  envoy crash-loops; envoy logs `no such field: 'allow_on_headers_stop_iteration'`.
- **Root cause:** With MaaS on, the Kuadrant/RHCL operator emits
  `EnvoyFilter/kuadrant-maas-default-gateway` with an **empty `workloadSelector`**,
  so istio injects its wasm into **every** gateway in `openshift-ingress` —
  including the dashboard gateway, which has no Kuadrant policy. Service Mesh 3
  **v3.3.5** (istio 1.26) rejects the wasm field `allow_on_headers_stop_iteration`
  that RHCL **v1.4.1**'s wasm-shim emits (v3.3.3 tolerated it). A wasm-shim ↔
  envoy ABI skew, **not** an "RHCL too old" problem (v1.4.1 already meets RHOAI's
  RHCL v1.3+ prerequisite).
- **Fix:** a second EnvoyFilter scoped by `workloadSelector` to only the
  dashboard gateway, `patch.operation: REMOVE` on the wasm HTTP filter. The MaaS
  gateway keeps its wasm; enforcement intact.
- **Status:** **Temporary.** In-repo on `main` (PR #17). **Not yet on `clusters`**
  → bu-nightly-2 is currently held up by a **manual** EnvoyFilter of the same
  name. Rebase `clusters` onto `main`, then delete the manual copy.
- **Detection:** `oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.workloadSelector}'` — empty output == leak condition.
- **Remove when:** RHCL ships a wasm-shim matching Service Mesh's envoy, **or**
  Kuadrant scopes its generated EnvoyFilter with a `workloadSelector`.
- **Refs:** `.tmp/issues/dashboard-gateway-kuadrant-wasm-leak.md`, issue #18.

### A2. MaaS gateway — raise istio-proxy memory to 2Gi

- **File:** `components/instances/maas-instance/chart/templates/maas-gateway-options.yaml`
  (+ explanatory comment in `gateway.yaml`)
- **Symptom without it:** `maas-default-gateway` envoy OOMKilled (exit 137,
  CrashLoopBackOff); MaaS endpoint unreachable.
- **Root cause:** istio's default proxy memory limit is 1Gi; envoy + the
  Kuadrant wasm enforcement config settles at ~1.4Gi.
- **Fix:** a `parametersRef` ConfigMap strategic-merge-patches the
  auto-provisioned Gateway Deployment to set istio-proxy `limits.memory: 2Gi`
  (sidecar annotations don't apply to gateway-controller-provisioned pods).
- **Status:** **Permanent** (memory tuning; no upstream knob). In-repo.

### A3. Perses datasource — correct secret name

- **File:** `components/instances/rhoai-instance/overlays/maas-observability/kuadrant-persesdatasource-fix.yaml`
- **Symptom without it:** every MaaS panel on the RHOAI Observability dashboard
  shows "document not found".
- **Root cause:** the RHOAI ModelsAsService controller generates a
  PersesDatasource referencing `cluster-prometheus-datasource-secret` (only
  exists in `redhat-ods-monitoring`), but the datasource lives in
  `redhat-ods-applications` where the secret is `kuadrant-prometheus-datasource-secret`.
- **Fix:** publish the corrected datasource via GitOps, annotate
  `opendatahub.io/managed: "false"` (stop the operator overwriting it), and use
  sync-option `Replace=true` (ownership blocks strategic-merge).
- **Status:** **Temporary** (upstream controller bug). In-repo (observability overlay).
- **Remove when:** RHOAI controller emits the correct secret reference.

### A4. Perses → Prometheus TLS — service-CA injection

- **File:** `components/instances/rhoai-instance/overlays/maas-observability/service-ca-injection.yaml`
- **Symptom without it:** Perses → Thanos Querier TLS handshake fails; blank panels.
- **Fix:** a ConfigMap annotated `service.beta.openshift.io/inject-cabundle: 'true'`
  so OpenShift populates the CA bundle Perses needs for TLS verification.
- **Status:** **Permanent** (TLS bootstrap). In-repo (observability overlay).

### A5. NVIDIA operator — local base without console-plugin

- **File:** `components/operators/nvidia-operator/` (references local `base/`
  instead of the upstream gitops-catalog overlay)
- **Symptom without it:** OCP console crashes (`u.healthHandler is not a function`)
  on OCP 4.20.x.
- **Root cause:** OCPBUGS-59972 in the GPU operator console plugin.
- **Fix:** fork to a local base that excludes the console-plugin entirely.
- **Status:** **Permanent until OCP fix.** In-repo.

### A6. ArgoCD application-controller — 4Gi memory

- **File:** `bootstrap/argocd-instance/patch-controller-resources.yaml`
- **Symptom without it:** app-controller OOMKills at the operator-default 2Gi
  once the full app-set reconciles (~2.2Gi steady on bu-nightly-2), crash-looping
  and stalling every sync.
- **Fix:** request 2Gi / limit 4Gi.
- **Status:** **Permanent.** In-repo.

### A7. Catalog re-resolution — `restart-catalog.sh` guards

- **File:** `scripts/restart-catalog.sh` (`make restart-catalog`)
- **Symptom without it:** after a catalog image flip where the CSV **name** is
  unchanged, OLM treats the operator as "already installed" and never re-resolves;
  naively deleting the Subscription orphans the running CSV → namespace-wide
  `ConstraintsNotSatisfiable` deadlock.
- **Fix:** same-version guard (skip Subscription delete unless the resolved
  version changed or `--force-resub` is passed); poll PackageManifests scoped to
  the Subscription's own catalog until the new head is serving; fail loud (exit 2)
  rather than orphan a CSV on an unconfirmed head.
- **Status:** **Permanent** (OLM behavior). In-repo.

### A8. DSC — `llamastackoperator: Removed`, `ogx: Managed`

- **File:** `components/instances/rhoai-instance/base/datasciencecluster.yaml`
- **Symptom without it:** Gen AI Studio **Playground** tab disappears; the gen-ai
  BFF starts with an empty LlamaStack URL.
- **Root cause:** llamastack is deprecated in RHOAI 3.5 and replaced by `ogx`
  (the LlamaStack backend for the Playground). Leaving llamastack `Managed` is a
  no-op that **blocks** `ogx` from enabling.
- **Status:** **Permanent** (product deprecation). In-repo.

---

## B. Structural GitOps / ordering workarounds (permanent)

Model-inherent — not tied to a broken build. Brief, because they're stable.

| What | Where | Why |
|---|---|---|
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
**Action:** rebase `clusters` onto `main`, confirm ArgoCD adopts the chart-managed
EnvoyFilter, then delete the manual one.

### C2. Prerequisite operators set to Manual InstallPlan approval (bu-nightly-2)

Service Mesh, OpenTelemetry, RHCL, Authorino, and web-terminal default to Manual
approval in the shared `openshift-operators` OperatorGroup. Future catalog bumps
silently **queue** upgrades; no GitOps hook approves them. Approve with:

```
oc patch installplan <name> -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
```

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

---

## E. Resolved / obsolete (do not re-add)

Kept as a short tombstone list so these don't get "rediscovered":

- **3.4 catalog `readOnlyRootFilesystem` crashloop** — resolved by catalog pin.
- **`CLUSTER_AUDIENCE` literal-arg 401s (3.4)** — fixed upstream (MaaS PR #790).
- **Perses `v1alpha1` write-storm** — resolved with COO 1.5.1.
- **COO 1.5.0 perses-server `--web.tls-min-version` crash** — resolved with COO 1.5.1.
- **`maas-controller-perses-fix` ClusterRole/Binding** — redundant since MaaS
  PR #818; candidate for removal if it still lingers on the `clusters` branch.
