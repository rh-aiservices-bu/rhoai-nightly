# Install with make

Install RHOAI 3.x nightly on a connected OpenShift cluster using `make`. You can
run the whole thing in one command, or run each phase individually and verify as
you go (recommended the first time).

Prefer to drive this from Claude Code? See [Install with Claude](install-claude.md).
No cluster yet? See [Provision a cluster](demo-env.md).

## Prerequisites

- An OpenShift 4.20+ cluster, logged in with `oc` (see [Provision a cluster](demo-env.md)).
- Pull-secret credentials configured — see
  [Configuration → Pull-secret credentials](configuration.md#pull-secret-credentials).
- This repository cloned locally.

Quick readiness check:

```bash
make preflight        # connection, nodes, basic capabilities
make validate-config  # .env vs cluster capabilities (run after configuring .env)
```

## Option A — Full install (one command)

```bash
make
```

`make` (alias for `make all`) runs every phase in order:

| Phase | Target | What it does |
|-------|--------|--------------|
| 1 | `infra` | `icsp` (registry mirror) → `cpu` (m6a.4xlarge MachineSet) → `gpu` (g6e.2xlarge MachineSet) → `uwm` (user-workload monitoring). Waits for nodes to become `Ready`. |
| 2 | `secrets` | Configures the pull-secret. Auto-detects manual (`QUAY_USER`/`QUAY_TOKEN`) vs External Secrets. |
| 3 | `gitops` | Installs the GitOps operator + ArgoCD instance. |
| 4 | `deploy` | Creates the ArgoCD apps / ApplicationSets (auto-sync **disabled**). |
| 5 | `sync` | Syncs every app one-by-one in dependency order, enabling auto-sync as each becomes healthy. |
| 6 | `maas` | Installs the MaaS **platform only** (PostgreSQL + PVC, Gateway, Authorino TLS). |

> `make all` installs the MaaS **platform**. It does **not** deploy a model and does
> **not** install observability — those are separate, deliberate steps
> (`make maas-model`, `make observability`). See [MaaS](maas.md).

To install but leave ArgoCD auto-sync **off** (so you can make manual cluster changes
without ArgoCD reverting them):

```bash
make all sync-disable
```

Expect the full run to take **30–60+ minutes**, dominated by `icsp` node restarts
(~10–15 min) and GPU/CPU node provisioning (~5–10 min each).

## Option B — Step by step (install part or all)

Run phases individually and verify between each. This is the best way to install
**only part** of the stack or to troubleshoot.

### Phase 1 — Infrastructure

```bash
make icsp     # registry mirror; triggers a rolling node restart (~10–15 min)
              # VERIFY: oc get mcp   (all UPDATED=True)   oc get nodes (all Ready)

make cpu      # CPU worker MachineSet (m6a.4xlarge); waits for node Ready
              # VERIFY: oc get nodes -l node-role.kubernetes.io/worker

make gpu      # GPU MachineSet (g6e.2xlarge); waits for node Ready
              # VERIFY: oc get nodes -l nvidia.com/gpu.present=true

make uwm      # enable user-workload monitoring (needed later for MaaS observability)

make infra    # shortcut: icsp + cpu + gpu + uwm
```

Skip what you don't need — e.g. omit `make gpu` for a CPU-only cluster (you'll use
the `simulator` MaaS model instead of a GPU model).

### Phase 2 — Pull-secret

```bash
make secrets  # auto-detects manual vs External Secrets mode
              # VERIFY: oc get secret pull-secret -n openshift-config
```

See [Configuration → Pull-secret credentials](configuration.md#pull-secret-credentials)
for both modes.

### Phase 3 — GitOps bootstrap

```bash
make gitops   # GitOps operator + ArgoCD
              # VERIFY: oc get pods -n openshift-gitops

make deploy   # create ArgoCD apps (sync disabled)
              # VERIFY: oc get applications.argoproj.io -n openshift-gitops
```

`make bootstrap` runs `gitops` + `deploy` together.

### Phase 4 — Sync

```bash
make sync                 # staged sync of all apps in dependency order (RECOMMENDED)
make sync-app APP=nfd     # sync a single app
```

After `make sync`, every app has **auto-sync ON** and self-heals from git.

> **RHOAI only, no MaaS:** stop here. `make setup bootstrap sync` runs phases 1–5
> (everything except the MaaS platform). Add MaaS later with `make maas` when you want
> it. (`make`/`make all` would also run phase 6, the MaaS platform.)

### Optional — Dedicate masters

On a small cluster you can free the masters from running workloads once worker
nodes are `Ready`:

```bash
make dedicate-masters     # removes the worker role from master nodes
```

## Verify the install

```bash
make status      # ArgoCD application sync status
make diagnose    # full health check (connectivity, config, RHOAI, MaaS)
```

All ArgoCD applications should report `Synced` / `Healthy`. The RHOAI console appears
under the OpenShift console's application launcher (the grid icon) once the
DataScienceCluster is `Ready`.

## Sync control

ArgoCD auto-sync reverts manual cluster changes. Toggle it when you need to
experiment:

```bash
make sync-disable    # turn off auto-sync on all apps (before manual changes)
make sync-enable     # turn it back on
make refresh         # pull latest from git WITHOUT syncing (see the diff)
make refresh-apps    # refresh from git AND sync (one-time; keeps current sync setting)
```

## What's next

- **[MaaS](maas.md)** — deploy models, run observability, verify end-to-end
- **[Eval Hub](evalhub.md)** — `make evalhub` (TrustyAI EvalHub + MLflow + DSPA; opt-in)
- **[Configuration](configuration.md)** — `.env` reference; point ArgoCD at a fork/branch
- **[Uninstall](uninstall.md)** — tear it all down

## Troubleshooting

| Symptom | Try |
|---------|-----|
| ICSP step "hangs" | Nodes are restarting. Watch `oc get mcp` / `oc get nodes -w` (~10–15 min). |
| GPU node never appears | The AZ may lack `g6e` capacity. Set `GPU_AZ` in `.env` or try another region. |
| Apps not syncing | Wrong repo/branch on the ApplicationSet — see [Configuration → Repository & branch](configuration.md#repository-and-branch-selection). |
| RHOAI operator stuck "Installing" | `make restart-catalog` to force a catalog image pull. |

For anything else: `make diagnose`.
