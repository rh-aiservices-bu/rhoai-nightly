# RHOAI 3.x Nightly GitOps

Deploy RHOAI 3.x nightly builds using GitOps on OpenShift.

## Quick Start

### 1. Provision Cluster

Order **AWS with OpenShift Open Environment** from [demo.redhat.com](https://catalog.demo.redhat.com/):

- Recommended to allocate **3 master nodes** and **3 worker nodes**
- Wait for provisioning to complete

### 2. Login

```bash
oc login --token=<token> --server=https://api.<cluster>:6443
```

### 3. Configure Credentials (Choose One)

**Option A: Manual Credentials**
```bash
cp .env.example .env
# Edit .env with your quay.io credentials for quay.io/rhoai access
```

**Option B: External Secrets (Automatic)**

If you have git access to the [rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap) private repo, credentials are configured automatically via AWS Secrets Manager. No `.env` configuration needed.

### 4. Deploy

```bash
make
```

Or, to disable auto-sync after deployment (for manual cluster changes):

```bash
make all sync-disable
```

`make` (or `make all`) runs these phases:

**Phase 1: `infra`** - Infrastructure setup
- `icsp` - Configure registry mirror
- `cpu` - Create CPU MachineSet m6a.4xlarge (waits for node Ready)
- `gpu` - Create GPU MachineSet g6e.2xlarge (waits for node Ready)

**Phase 2: `secrets`** - Pull-secret configuration (auto-detects mode)
- If `QUAY_USER`/`QUAY_TOKEN` set → uses manual credentials
- If git access to bootstrap repo → uses External Secrets from AWS
- Installs External Secrets Operator if needed (self-contained, doesn't need GitOps)

**Phase 3: `gitops`** - GitOps installation
- Install GitOps operator + ArgoCD instance

**Phase 4: `deploy`** - ArgoCD apps
- Deploy cluster-config and ApplicationSets (sync disabled by default)

**Phase 5: `sync`** - Staged deployment
- Syncs all apps one-by-one in dependency order
- Enables auto-sync on each app after it's healthy

**Phase 6: `maas`** - Models as a Service
- Creates PostgreSQL secrets (generated password)
- Creates ArgoCD Application with Helm chart (Gateway, GatewayClass, PostgreSQL with 20Gi PVC)
- Configures Authorino SSL for MaaS API authentication
- Waits for Gateway and maas-api to be ready
- Does **not** install observability — run `make observability` separately
  once the cluster is healthy. The observability cascade is gated by a
  settle-gate because it puts substantial memory pressure on the control plane.

Optionally run `make dedicate-masters` to remove worker role from master nodes.

**Note:** After deployment, auto-sync is enabled. Run `make sync-disable` before making manual changes to the cluster, or ArgoCD will revert them.

## Individual Steps

Run steps individually if needed:

```bash
# Infrastructure
make icsp             # Apply ICSP (configure registry mirror)
make cpu              # Create CPU workers
make gpu              # Create GPU workers
make infra            # Run icsp + cpu + gpu

# Secrets (auto-detects mode)
make secrets          # Setup pull-secret (External Secrets or manual)

# GitOps
make gitops           # Install GitOps operator + ArgoCD

# Deploy
make deploy           # Deploy ArgoCD apps (sync disabled)

# Shortcuts
make setup            # Run infra + secrets (pre-GitOps setup)
make bootstrap        # Run gitops + deploy

# Sync
make sync             # Staged sync all apps in order (RECOMMENDED)
make sync-app APP=nfd # Sync a single app

# MaaS (Models as a Service)
make maas             # Install MaaS platform ONLY (secrets, Gateway, Authorino SSL)
                      # Does NOT install observability — run `make observability` separately
make maas-model       # Deploy a model (default: auto — picks by cluster GPU VRAM)
make maas-model-status # Show deployed model status
make maas-verify      # Full end-to-end verification
make maas-uninstall   # Remove MaaS platform
make observability    # Settle-gate → overlay flip → wait for Perses/Tempo/OTel
                      # Refuses to run when cluster isn't healthy (masters >=75% mem,
                      # Degraded operators, non-terminal pods, etc).
make observability-uninstall # Reverse-flip; monitoring cascade tears down
```

## Validation

```bash
make preflight       # Quick cluster readiness check
make validate-config # Validate .env against cluster capabilities
make status          # Show ArgoCD app status
make diagnose        # Comprehensive cluster diagnosis
```

## Other Commands

```bash
make refresh                             # GitOps refresh - pull latest from git (no sync)
make restart-catalog                     # Restart catalog pod and operator (force image pull)
make scale NAME=<machineset> REPLICAS=N  # Scale a MachineSet
make dedicate-masters                    # Remove worker role from masters
```

## MaaS (Models as a Service)

MaaS provides API key management, subscriptions, and rate limiting for LLM inference services on RHOAI.

### What Gets Deployed

| Component | Managed By | Description |
|-----------|-----------|-------------|
| PostgreSQL | Helm chart (ArgoCD) | Database for API key storage (20Gi PVC — size/storageClassName configurable via Helm values `postgres.persistence.size` / `postgres.persistence.storageClassName`; empty = cluster default) |
| Gateway + GatewayClass | Helm chart (ArgoCD) | LoadBalancer gateway for MaaS traffic |
| PostgreSQL secrets | install-maas.sh | Generated password, DB connection URL |
| Authorino SSL | install-maas.sh | Env vars for TLS trust |
| Observability (Kuadrant, ServiceMonitors, DSCI cascade) | install-observability.sh (`make observability`, separate step) | Lights up the RHOAI Observability dashboard. Settle-gated — refuses when cluster isn't healthy |
| UWM | scripts/enable-uwm.sh (`make uwm`, part of `make infra`) | Prerequisite for scraping MaaS metrics |
| TelemetryPolicy + Istio Telemetry | instance-maas-observability (ArgoCD) | Per-subscription/model/user metric labels |
| maas-api, maas-controller | RHOAI operator | Deployed automatically when DSC has modelsAsService: Managed |

### Install Platform

```bash
make maas
```

Auto-detects cluster domain and TLS cert name, creates secrets, deploys the Helm chart via ArgoCD (including a 20Gi PVC for PostgreSQL), and configures Authorino. ELB DNS propagation may take 2-5 minutes after install.

**Note:** `make maas` no longer auto-installs the observability stack. Run `make observability` separately once the cluster is healthy — the observability cascade (Perses, Tempo, OTel, MonitoringStack) puts significant memory pressure on the control plane and has its own settle-gate.

### Deploy Models

```bash
make maas-model                         # Autodetect: picks by cluster GPU VRAM
                                        #   no GPU           -> simulator
                                        #   GPU VRAM >=40 Gi -> gpt-oss-20b
                                        #   otherwise        -> granite-tiny-gpu
make maas-model MODEL=auto              # Same; explicit
make maas-model MODEL=simulator         # Deploy simulator only (CPU)
make maas-model MODEL=gpt-oss-20b       # Deploy gpt-oss-20b (GPU)
make maas-model MODEL=granite-tiny-gpu  # Deploy Granite tiny (GPU)
```

Available models:
- **simulator** — CPU-only mock (~256Mi RAM, instant startup)
- **gpt-oss-20b** — OpenAI gpt-oss-20b on vLLM CUDA (1 GPU, 60Gi RAM, 5-15 min startup)
- **granite-tiny-gpu** — RedHatAI Granite 4.0-h-tiny FP8 on vLLM CUDA (1 GPU, 24Gi RAM)

Each model gets two subscription tiers:
- **Free**: 100 tokens/min (all authenticated users)
- **Premium**: 100000 tokens/min (all authenticated users)

Configure default models in `.env`:
```bash
MAAS_MODELS=gpt-oss-20b granite-tiny-gpu
```

### Verify

```bash
make maas-verify   # Full end-to-end test (deploys temp model, tests API/auth/rate limits, cleans up)
```

### Manage Models

```bash
make maas-model-status                   # Show all deployed models
make maas-model-delete MODEL=simulator   # Delete one model
make maas-model-delete MODEL=all         # Delete all models
```

### Uninstall

```bash
make maas-uninstall   # Remove MaaS platform (cascade-deletes Gateway, PostgreSQL, secrets)
```

### Observability

Observability is installed separately from `make maas`:

```bash
make observability            # Settle-gate → flip instance-rhoai overlay → wait for Perses/Tempo/OTel
make observability-uninstall  # Reverse-flip; monitoring cascade tears down
```

The settle-gate refuses to run if any master is >=75% memory, the DSC/DSCI aren't Ready, there are non-terminal pods in core namespaces, or etcd is Degraded. This prevents the cascade from tipping an already-stressed control plane into OOM (as happened on cluster-hm2fl 2026-04-20).

Lights up the RHOAI 3.x Observability dashboard (request rate, success rate, GPU/CPU/memory, per-subscription usage).

The dashboard nav item appears in the RHOAI console because `components/instances/rhoai-instance/base/odh-dashboard-config.yaml` sets `observabilityDashboard: true`. It is visible only to dashboard admins (cluster-admin); non-admin users will not see it.

### Dry Run

```bash
make maas -- --dry-run        # Preview install without applying
make maas-uninstall -- --dry-run  # Preview uninstall
```

## Sync Control

After `make sync`, apps have auto-sync **ON** and will self-heal from git.

```bash
make sync-disable                        # Disable auto-sync (for manual changes)
make sync-enable                         # Re-enable auto-sync
make sync-app APP=<name>                 # Sync single app + enable auto-sync on it
make refresh-apps                        # Refresh from git AND sync all apps (one-time)
```

## Repository and Branch Selection

`make deploy` needs to tell ArgoCD which repo + branch to sync from. There are three ways.

### Ephemeral testing of a feature branch (recommended for PR/test runs)

Pass `GITOPS_BRANCH` inline — no file edits, no commits, no YAML mutation. `scripts/deploy-apps.sh` reads it at runtime and patches the ApplicationSets plus every child ArgoCD Application on the cluster:

```bash
git push origin my-feature-branch
GITOPS_BRANCH=my-feature-branch make deploy
GITOPS_BRANCH=my-feature-branch make sync
```

Also works for subsequent ops that fetch from git:

```bash
GITOPS_BRANCH=my-feature-branch make refresh-apps
```

### Persistent override via `.env`

Put `GITOPS_BRANCH` (and optionally `GITOPS_REPO_URL`) in `.env`. The Makefile sources `.env` automatically, so every subsequent `make` command picks it up without the inline prefix:

```bash
cat >> .env <<EOF
GITOPS_BRANCH=my-feature-branch
GITOPS_REPO_URL=https://github.com/my-fork/rhoai-nightly
EOF
make deploy
```

### Permanent fork setup — rewrites checked-in YAML

Only when you're hard-forking the repo and want the change to land in git:

```bash
GITOPS_REPO_URL=https://github.com/my-fork/rhoai-nightly \
GITOPS_BRANCH=my-default \
make configure-repo
git commit -am "chore: point GitOps at my fork"
```

`make configure-repo` mutates `components/argocd/apps/*.yaml` + `clusters/overlays/rhoaibu-cluster-nightly/patch-*.yaml` + `bootstrap/rhoaibu-cluster-nightly/cluster-config-app.yaml`. **Don't use it for transient test branches** — it creates a commit you'll have to revert before merging back.

## Adding or Modifying Components

When you add a new component or modify an ApplicationSet template, the changes won't automatically propagate to existing Applications. This is by design - ApplicationSets use `applicationsSync: create-only` to prevent overwriting the auto-sync settings that `make sync` enables.

**To add a new component:**

1. Create the component directory (e.g., `components/operators/my-operator/`)
2. Add the entry to the ApplicationSet if using the list generator
3. Commit and push to git
4. The new Application will be created automatically

**To update an existing Application after template changes:**

If you change the ApplicationSet template (e.g., `targetRevision`, `repoURL`), existing Applications won't update. To apply template changes:

```bash
# Delete the app - ApplicationSet will recreate it with new template
oc delete application.argoproj.io/<app-name> -n openshift-gitops

# Then sync the recreated app
make sync-app APP=<app-name>
```

## Requirements

- OpenShift 4.17+
- `oc` CLI
- One of:
  - quay.io credentials with access to `quay.io/rhoai` repos (manual mode)
  - Git access to [rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap) (External Secrets mode)

## External Secrets Mode

When you have access to the private bootstrap repo but no local credentials, the deployment automatically:

1. Installs External Secrets Operator
2. Creates ClusterSecretStore for AWS Secrets Manager
3. Applies AWS credentials from the bootstrap repo
4. Applies ExternalSecret to sync pull-secret from AWS
5. Pull-secret contains all required registry credentials

The External Secrets Operator is then adopted by ArgoCD during the sync phase.

**Verify External Secrets mode:**

```bash
oc get externalsecret pull-secret -n openshift-config
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'
```

**Switch to manual mode:**

Set `QUAY_USER` and `QUAY_TOKEN` in `.env`, then run:

```bash
make secrets  # Detects credentials, deletes ExternalSecret, uses manual mode
```
