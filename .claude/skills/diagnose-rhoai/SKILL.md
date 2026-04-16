---
name: diagnose-rhoai
description: Diagnose the state of an OpenShift cluster for RHOAI installation. Runs full health check, preflight, and config validation as appropriate based on install state.
argument-hint: "[--verbose]"
allowed-tools: Bash(make *), Bash(oc *), Bash(scripts/*), AskUserQuestion
---

# Diagnose RHOAI Cluster

Perform a comprehensive health check of the connected OpenShift cluster.

## Instructions

### Step 1: Run the diagnostic script

```bash
make diagnose
```

If `--verbose` was passed in `$ARGUMENTS`, run:
```bash
scripts/diagnose.sh --verbose
```

### Step 2: Determine install state from the output

Based on the diagnose output, determine the cluster's install state:

- **Bare cluster**: GitOps not installed, RHOAI not installed, MaaS not installed
- **Partially installed**: GitOps installed but RHOAI not ready, or RHOAI installed but MaaS not installed
- **Fully installed**: RHOAI and MaaS both installed

### Step 3: Run additional checks based on install state

**If bare or partially installed** — run preflight and config validation automatically:

```bash
make preflight
make validate-config
```

These answer "can we install?" and "will the config work?":
- Preflight checks prerequisites (connectivity, node health, credentials)
- Validate-config checks .env against GPU capabilities, model compatibility, branch existence

**If fully installed** — the diagnose output already covers health. Only run additional checks if diagnose showed warnings or failures.

### Step 4: Summarize and recommend

Present a unified summary combining all results. Key principles:

- **INFO** = not installed yet (expected, not a problem)
- **WARN** = something needs attention but isn't blocking (pending install plans, GPU contention, branch mismatch)
- **FAIL** = something is broken and must be fixed (nodes NotReady, credentials missing, CSVs stuck, MCP degraded)

Based on the combined output:
- If bare cluster with no issues: "Cluster is ready. Run `make all` to install."
- If bare cluster with config warnings: explain what to fix in .env first
- If fully installed and healthy: "Cluster is fully operational."
- If installed with degraded components: explain what's wrong and suggest `make` commands to fix

Do NOT recommend Claude skills (like `/install-rhoai`) — recommend `make` targets instead, since the user may be running from a terminal without Claude.
