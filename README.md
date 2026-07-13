# RHOAI 3.x Nightly GitOps

Deploy Red Hat OpenShift AI (RHOAI) 3.x **nightly** builds onto an OpenShift cluster
using GitOps (ArgoCD). One `make` command — or one Claude Code skill — takes a bare
cluster to a fully synced RHOAI install, with optional Models-as-a-Service (MaaS),
observability, and Eval Hub.

## How it works

- **Pre-GitOps scripts** prepare the cluster (registry mirror, GPU/CPU nodes, pull-secret).
- **ArgoCD ApplicationSets** sync every component from this git repo.
- **Two ways to drive it:** `make` targets, or Claude Code skills (`/install-rhoai`, `/install-maas`, …).

New here? Start with [Provision a cluster](docs/demo-env.md), then
[Install with make](docs/install-make.md).

## Prerequisites

- **OpenShift 4.20+ cluster** (cluster-admin) and the **`oc` CLI**. No cluster yet?
  → [Provision one on demo.redhat.com](docs/demo-env.md) (also covers `oc` install and login).
- **Registry credentials — one is required** (the install can't pull RHOAI images without them):
  - quay.io credentials with `quay.io/rhoai` access (manual mode), **or**
  - read access to the private [rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap) repo (External Secrets mode).
- **GPU capacity** for GPU models (AWS `g6e.2xlarge`; us-east-2 recommended). CPU-only clusters can still run the `simulator` model.
- **For MaaS observability:** control-plane nodes must be **`m6a.2xlarge`** or larger — set at order time, since masters can't be resized later.
- Optional: [Claude Code](https://claude.com/claude-code) to drive the install via skills.

## Quick Start

**1. Log in and clone**

```bash
oc login --token=<token> --server=https://api.<cluster>:6443
git clone https://github.com/rh-aiservices-bu/rhoai-nightly.git && cd rhoai-nightly
```

**2. Configure pull-secret credentials** — **required, you can't install without one** (details: [Configuration](docs/configuration.md#pull-secret-credentials)):

- **Manual:** `cp .env.example .env`, then set `QUAY_USER` / `QUAY_TOKEN` for `quay.io/rhoai`.
- **External Secrets:** if you don't have quay access but have **read access to the private [bootstrap repo](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap)**, credentials sync from AWS automatically — no `.env` needed. The repo is private, so **request access early** (open an issue or ask a `rh-aiservices-bu` maintainer) — it can take time to be granted.

> Have neither? You can't install yet — sort out one of the two above first.

**3. Install** — pick one:

```bash
make                 # full install: infra → secrets → gitops → deploy → sync → maas (platform)
```

…or in Claude Code:

```
/install-rhoai
```

**4. Watch it come up**

```bash
make status          # ArgoCD app sync status
make diagnose        # full health check
```

**5. Add a model (optional)**

```bash
make maas-model      # GPU-aware model auto-selection
```

> `make` installs RHOAI + the MaaS **platform**. It does not deploy a model or install
> observability — those are separate steps (`make maas-model`, `make observability`).

Full walkthroughs: **[Install with make](docs/install-make.md)** · **[Install with Claude](docs/install-claude.md)**.

## Documentation

| Guide | What it covers |
|-------|----------------|
| [Provision a cluster](docs/demo-env.md) | Order an AWS OpenShift environment on demo.redhat.com and log in with `oc` |
| [Install with make](docs/install-make.md) | Full and step-by-step install via `make`; validation; sync control |
| [Install with Claude](docs/install-claude.md) | Drive the same install from Claude Code skills |
| [MaaS (Models as a Service)](docs/maas.md) | Platform, models, observability, verification |
| [Eval Hub](docs/evalhub.md) | TrustyAI evaluation harness (EvalHub + MLflow + DSPA) — opt-in |
| [Configuration](docs/configuration.md) | `.env` reference: pull-secret modes, node sizing, models, repo/branch selection |
| [Uninstall](docs/uninstall.md) | Remove RHOAI, MaaS, observability, Eval Hub |
| [Workarounds](docs/workarounds.md) | Canonical index of local workarounds for upstream/nightly bugs — what, why, and when to remove |

Working on the repo internals? See [CLAUDE.md](CLAUDE.md) for architecture and GitOps patterns.

## Command cheat-sheet

```bash
# Full lifecycle
make                  # Full install (infra → secrets → gitops → deploy → sync → maas)
make all sync-disable # Two targets: run 'all', then 'sync-disable' (leaves auto-sync off)

# Phases (run individually — see docs/install-make.md)
make infra            # icsp + cpu + gpu + uwm
make secrets          # pull-secret (auto-detects manual vs External Secrets)
make gitops           # GitOps operator + ArgoCD
make deploy           # create ArgoCD apps (sync disabled)
make sync             # staged sync in dependency order

# MaaS (see docs/maas.md)
make maas             # platform only (no observability)
make maas-model       # deploy a GPU-aware model
make maas-verify      # end-to-end test
make observability    # settle-gated observability cascade

# Eval Hub
make evalhub          # EvalHub + MLflow + DSPA

# Diagnostics
make preflight        # quick readiness check
make validate-config  # check .env vs cluster
make status           # ArgoCD status
make diagnose         # full diagnosis

# Uninstall (see docs/uninstall.md)
make undeploy         # remove ArgoCD apps
make clean            # undeploy + leftover operators

make help             # full target list
```
