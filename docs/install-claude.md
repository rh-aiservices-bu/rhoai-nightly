# Install with Claude Code

This repository ships [Claude Code](https://claude.com/claude-code) **skills** that
drive the same `make`-based install, but with intelligent skip detection, structured
logging, problem tracking, and conversational prompts when a decision is needed.

This is an alternative to [Install with make](install-make.md) — the underlying
actions are identical. Use whichever you prefer.

## Prerequisites

- Everything from [Install with make → Prerequisites](install-make.md#prerequisites):
  a logged-in OpenShift 4.20+ cluster and pull-secret credentials.
- [Claude Code](https://claude.com/claude-code) running in this repository directory.
  The skills are defined under `.claude/skills/` and are picked up automatically.

## Skills

Type these as slash commands in Claude Code.

| Skill | Purpose |
|-------|---------|
| `/install-rhoai` | Full install — equivalent to `make all` (infra, secrets, gitops, deploy, sync) with skip detection. Optionally continues into MaaS + observability. |
| `/install-maas` | Install MaaS on a cluster that already has RHOAI: platform, a GPU-aware model, verification, and optional observability. |
| `/install-evalhub` | Install (or uninstall) Eval Hub — TrustyAI EvalHub + MLflow + DSPA. Orthogonal to MaaS/observability. |
| `/diagnose-rhoai` | Full cluster health check — runs diagnosis, preflight, and config validation as appropriate. |
| `/uninstall-rhoai` | Remove RHOAI — runs `undeploy` + `clean` with assessment and progress reporting. |
| `/upgrade-rhoai-nightly` | Upgrade the nightly build (catalog image + channel) with the safe upgrade procedure. |

## Full install

In Claude Code, from the repo directory:

```
/install-rhoai
```

The skill:

1. Checks the cluster connection and assesses what's already done (so re-runs are safe).
2. Runs the install phases, **skipping** any that are already complete.
3. Streams progress and writes logs; surfaces problems as it goes.
4. Asks before consequential or ambiguous steps (e.g. GPU sizing, MaaS model choice).

Useful arguments:

```
/install-rhoai --skip-gpu              # CPU-only cluster
/install-rhoai --skip-maas             # RHOAI only, no MaaS
/install-rhoai --with-observability    # also run the observability cascade
/install-rhoai --branch my-feature     # sync ArgoCD from a feature branch
/install-rhoai --force                 # re-run phases even if detected complete
```

## Add MaaS and models

If RHOAI is already installed (via `make` or `/install-rhoai --skip-maas`):

```
/install-maas                  # platform + GPU-aware model + verify
/install-maas --models-only    # just (re)deploy models
/install-maas --with-observability
```

See [MaaS](maas.md) for what gets deployed and the available models.

## Add Eval Hub

```
/install-evalhub               # EvalHub + MLflow + DSPA (opt-in, orthogonal to MaaS)
/install-evalhub --uninstall
```

See [Eval Hub](evalhub.md) for prerequisites (needs a default StorageClass) and what
gets deployed.

## Diagnose

```
/diagnose-rhoai
```

Run this anytime to get a read on cluster and install state — it's the
Claude-driven equivalent of `make diagnose` + `make preflight` + `make validate-config`.

## Uninstall

```
/uninstall-rhoai
```

See [Uninstall](uninstall.md) for the full teardown story (RHOAI, MaaS,
observability, Eval Hub) via both Claude and `make`.

## Relationship to `make`

The skills call the same `scripts/` and `make` targets documented in
[Install with make](install-make.md). Anything a skill does, you can do by hand with
`make`; the skills add orchestration, idempotency, and logging on top. Mix and match
freely — e.g. install with `make`, then `/diagnose-rhoai` to check it.
