# The `clusters` Branch (deployed clusters)

This document lives on `main` and describes the **`clusters` branch**, which
extends `main` with the configuration our long-lived deployments run
(currently **bu-nightly-2** / `rhoaibu-cluster-nightly`). Keeping the doc on
`main` means the runbook is visible without checking out the deployment
branch; the branch itself carries only config.

## How `clusters` extends `main`

| Aspect | main | clusters |
|--------|------|----------|
| RHOAI catalog | Floating tag (`base/catalogsource.yaml`) | **SHA256-pinned** via `components/operators/rhoai-operator/overlays/pinned/` |
| ApplicationSets | 2 (operators, instances) | 3 (adds `cluster-config-appset` → `components/configs/*`) |
| RBAC | none | `components/configs/rbac/` — `cluster-admin-extra` + `rhods-admins` groups per cluster overlay |
| Console banner | none | `clusters/overlays/<cluster>/console-notification/` (cluster identity + build date) |
| Target revision | `main` | `clusters` |

Unique paths on `clusters`:

```
CLUSTERS.md                     # (originally here; now maintained on main)
clusters/overlays/
├── default/
└── rhoaibu-cluster-nightly/    # banner + cluster-config appset patch
components/argocd/apps/cluster-config-appset.yaml
components/configs/rbac/        # admin groups (base + per-cluster overlays)
components/operators/rhoai-operator/overlays/pinned/
```

> **Drift warning:** the `clusters` branch has historically accumulated
> cluster-only fixes that never made it into main's ledger (e.g.
> `maas-controller-perses-fix` RBAC, `kuadrant-persesdatasource-fix`,
> `service-ca-injection` in the maas-observability overlay). When touching
> the branch, check for such strays and either upstream them to main with a
> docs/workarounds.md entry or delete them if obsolete.

## Pinned vs floating catalog

- `base/` (main, test rigs): floating tag, registry-polled every 15 min —
  always the newest nightly, may break at any time. That's the mission.
- `overlays/pinned/` (clusters): exact digest — reproducible, upgrades happen
  only when a human bumps the pin.

## Upgrading RHOAI on a deployed cluster

**The canonical procedure is the `upgrade-rhoai-nightly` skill**
(`.claude/skills/upgrade-rhoai-nightly/SKILL.md`) — invoke it with the full
image reference including digest. It handles: rebase of `clusters` onto
`main`, the pinned-overlay + banner edits, channel selection (read from
`patch-channel.yaml` after rebase — covers channel switches like
`beta` → `stable-3.x`), the version-gap / channel-switch clean-install path
(delete Subscription + CSVs, ArgoCD recreates), `sync-disable` →
`make sync` → `make restart-catalog` → monitored CSV rollout →
`sync-enable`, verification, and rollback.

### Known upgrade-path breakages (verified 2026-08-04 dress rehearsal, tm9xb)

Expect these on any in-place upgrade into 3.5.0 builds; each has a proven
remedy — see the skill's Phase 2 for the operational steps:

1. **Dashboard 503 cluster-wide after upgrade**
   ([RHOAIENG-79525](https://redhat.atlassian.net/browse/RHOAIENG-79525)):
   the operator can't patch the immutable `spec.selector` on the pre-existing
   `rhods-dashboard` Deployment while the Service selector IS updated →
   empty endpoints. Remedy:
   `oc delete deployment rhods-dashboard -n redhat-ods-applications`
   (operator recreates it; recovery <1 min). Sweep for siblings
   (maas-controller [RHOAIENG-78140], workbenches [RHOAIENG-79547]): every
   Service in `redhat-ods-applications` / `redhat-ai-gateway-infra` must have
   non-empty EndpointSlices; grep operator logs for `field is immutable`.
2. **EnvoyFilter scoping check** (RHOAIENG-80043): after the upgrade,
   `oc get envoyfilter payload-processing -n openshift-ingress -o
   jsonpath='{.spec.workloadSelector}'` must be non-empty (builds ≥
   maas commit `58e59dec`). The Kuadrant filter
   (`kuadrant-maas-default-gateway`) is still selector-less — the A1
   dashboard-gateway wasm strip **stays in place**.
3. **Existing playgrounds break** (ogx upgrade issue,
   `docs/issues/ogx-upgrade-breaks-playgrounds.md`): tenants must delete +
   recreate playgrounds. MaaS API keys survive (postgres untouched).
4. **H2 close verification** (the reason bu-nightly-2 leaves ea.2): an
   HTTP/2 chat completion against the gateway must finish in <1s, not hang
   to the client timeout — see `docs/issues/maas-payload-h2-endstream-hang.md`
   for the exact curl.

## Troubleshooting (branch-specific)

- **DSCInitialization not ready after operator restart** — wait for the
  operator pods, then `make sync-app APP=instance-rhoai`.
- **CRD-not-found during sync** — `make sync-app APP=rhoai-operator` first
  (installs CRDs), then the instance app.
- **instance-nvidia OutOfSync but Healthy** — cosmetic ClusterPolicy drift;
  expected.
- **Catalog pod didn't pull the new image** — delete the pod:
  `oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly`,
  then verify its image. Note the **same-CSV-name trap**: if the new catalog's
  channel head has the *same* CSV name as the installed one (e.g. two
  different builds both named `rhods-operator.3.5.0`), a catalog swap alone
  is an OLM no-op — `restart-catalog.sh --force-resub` deletes the
  Subscription, and the same-name CSV must be deleted as well before OLM
  installs the new image.

## Creating a new cluster overlay

1. Copy `clusters/overlays/rhoaibu-cluster-nightly` → `clusters/overlays/<my-cluster>`.
2. Update the console-notification banner text.
3. Add `components/configs/rbac/overlays/<my-cluster>/` with your admin-group
   patches.
4. Point `clusters/overlays/<my-cluster>/patch-cluster-config-appset.yaml` at
   your overlays.
5. `oc apply -k clusters/overlays/<my-cluster>` and sync.

## Related

- `README.md`, `CLAUDE.md` — general repo docs
- `docs/known-issues.md` / `docs/workarounds.md` / `docs/issues/` — the
  product-bug ledger (maintained on main; the `clusters` branch inherits it
  on rebase)
