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

---

## A. Workarounds carried in this repo

### A1. Dashboard gateway — strip leaked Kuadrant wasm

- **File:** `components/instances/maas-instance/chart/templates/dashboard-gateway-wasm-strip.yaml`
- **Without it:** `data-science-gateway` istio-proxy OOMKilled (exit 137,
  CrashLoopBackOff) once Kuadrant programs enforcement — dashboard dead.
  Kuadrant's wasm config leaks onto the dashboard gateway it was never meant for.
- **Jira:** [RHOAIENG-80043](https://redhat.atlassian.net/browse/RHOAIENG-80043)
  (+77007, 78869)
- **Verified needed 2026-07-31** (tm9xb, SM 3.4.0): stripped it → OOM ×6 within
  minutes of Kuadrant programming its EnvoyFilters.
- **Re-confirmed 2026-08-04** on FBC `f4183f7e`: models-as-a-service#1313 gave
  `payload-processing` a `workloadSelector` (that's the RHOAIENG-80043 401 leg,
  now fixed), but the OOM leg is Kuadrant-owned and untouched —
  `kuadrant-maas-default-gateway`, `kuadrant-auth-*` and
  `kuadrant-ratelimiting-*` still carry `targetRefs` only, which Istio ignores
  without `ENABLE_ENHANCED_RESOURCE_SCOPING`, so they still leak. Detection:
  ```bash
  oc get envoyfilter -n openshift-ingress -o json | \
    jq -r '.items[] | select(.spec.workloadSelector == null) | .metadata.name'
  ```
  Any `kuadrant-*` name in that output means the leak is live and A1 is needed.
- **Remove when:** a bare install keeps the dashboard gateway at 1/1 with
  Kuadrant policies enforced on the MaaS gateway.

### A2. MaaS gateway — raise istio-proxy memory to 2Gi

- **File:** `components/instances/maas-instance/chart/templates/maas-gateway-options.yaml`
  (`deployment` key, via the Gateway's `infrastructure.parametersRef`)
- **Without it:** `maas-default-gateway` envoy OOMKilled at istio's 1Gi default
  once the Kuadrant wasm enforcement config lands (AuthPolicy +
  TokenRateLimitPolicy) — MaaS endpoint dead.
- **Jira:** [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589)
  Resolved; open siblings 79227, 79551
- **Verified needed 2026-07-31** (tm9xb): stripped it → OOM ×5 at 1Gi.
- **Remove when:** a bare install survives Kuadrant enforcement under
  `maas-verify` load with the default limit.

### A5. ArgoCD application-controller — 4Gi memory

- **File:** `bootstrap/argocd-instance/patch-controller-resources.yaml`
- **Without it:** app-controller OOMKills at the operator-default 2Gi with the
  full app set (measured ~2.2Gi steady). **Permanent** sizing.

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

### A13. Observability dashboard — set `Dashboard.spec.observability` manually (TEMPORARY)

- **Applied:** cluster-side patch (not in git — one-time `oc patch`, survives
  reconciliation because the rhods-operator's SSA apply doesn't own the field):
  ```bash
  oc patch dashboard default-dashboard --type merge -p \
    '{"spec":{"observability":{"enabled":true,"persesService":{"name":"data-science-perses","namespace":"redhat-ods-monitoring","port":8080}}}}'
  ```
- **Without it:** Observe & monitor → Dashboard is dead ("Unexpected token
  '<'"): nothing sets `spec.observability.enabled`, so the dashboard backend
  never registers the `/perses` proxy route (the SPA catch-all returns HTML to
  a JSON fetch) and the observability bundle (NetworkPolicy, RHOAI
  PersesDashboards) is never rendered. Details:
  [issues/observability-dashboard-unreachable.md](issues/observability-dashboard-unreachable.md)
- **Jira:** [RHOAIENG-80354](https://redhat.atlassian.net/browse/RHOAIENG-80354)
  (In Progress; fix PR
  [opendatahub-operator#3923](https://github.com/opendatahub-io/opendatahub-operator/pull/3923))
- **Why carried:** the Observability dashboards are themselves a feature under
  test; without the patch they are untestable. Applied bu-nightly-2 2026-08-05;
  verified `ObservabilityAvailable=True reason=Deployed`, pods rolled,
  `/perses/api` answering.
- **Remove when:** a nightly carries opendatahub-operator#3923. Detection —
  the operator owns the field (manual patch redundant):
  ```bash
  oc get dashboard default-dashboard -o json | jq -r \
    '.metadata.managedFields[] | select(.manager | test("kubectl") | not) | .fieldsV1["f:spec"]["f:observability"] // empty'
  ```
  Non-empty output = operator projects it; delete the manual field ownership by
  re-applying without it or simply leave (operator now authoritative) and drop
  this entry.

---

## B. Structural GitOps / ordering accommodations (permanent)

| What | Where | Why |
|---|---|---|
| **Service Mesh operator NOT GitOps-managed** | *(intentionally absent from `components/operators/`)* | On OCP 4.20+ the **ingress operator owns** the `servicemeshoperator3` subscription for Gateway API (Manual approval, pinned to its istio version). A GitOps-managed subscription fights it and can kill every gateway. See C2. |
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

---

## E. Install-time hazards — transient, known remedy

### E1. Operators cache a dependency probe at startup and never re-check

**The most common install-time failure class in this stack.** The tell: a
`Ready=False` / `Accepted=False` whose message names a dependency that
demonstrably exists. Confirmed instances: TrustyAI ("InferenceServices CRD does
not exist" — CRD present) and Kuadrant ("Gateway API provider is not installed"
— istiod Running; consequence: zero AuthConfigs, `POST /v1/api-keys` → 500
AUTH_FAILURE). Reproduced on every fresh cluster to date (r8mf7, fzgjg, tm9xb).
Jira: [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925).

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
timeout in `scripts/setup-maas-model.sh` to ~1500s.

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
