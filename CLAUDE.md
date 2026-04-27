# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is a **GitOps repository** for deploying **RHOAI (Red Hat OpenShift AI) 3.x Nightly** builds on OpenShift clusters. It follows a hybrid approach:

- **Pre-GitOps Scripts**: Shell scripts for initial cluster setup (GPU nodes, pull secrets, ICSP)
- **GitOps Deployment**: ArgoCD ApplicationSets that automatically sync components from git
- **Remote References**: Uses [redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog) with local patches

**Key Principle**: This repository uses a declarative GitOps model where components are deployed by committing Kustomize configurations to git, which ArgoCD automatically syncs to the cluster.

## Repository Structure

```
rhoai-nightly/
├── scripts/                              # Pre-GitOps setup scripts
│   ├── add-pull-secret.sh               # Add quay.io/rhoai pull credentials
│   ├── create-icsp.sh                   # Create ImageContentSourcePolicy
│   ├── create-gpu-machineset.sh         # Create GPU MachineSet (g6e.2xlarge)
│   ├── create-cpu-machineset.sh         # Create CPU worker MachineSet (m6a.4xlarge)
│   ├── install-gitops.sh                # Install GitOps operator + ArgoCD
│   ├── deploy-apps.sh                   # Deploy root app (triggers GitOps)
│   ├── enable-uwm.sh                    # Enable User Workload Monitoring (part of `make infra`)
│   ├── install-maas.sh                  # Install MaaS platform ONLY (secrets, ArgoCD app, Authorino) — observability is separate
│   ├── uninstall-maas.sh               # Remove MaaS platform
│   ├── install-observability.sh        # Install/uninstall MaaS observability (Kuadrant, ServiceMonitors; requires UWM from make infra)
│   ├── install-evalhub.sh              # Install/uninstall eval-hub via dedicated instance-evalhub ArgoCD Application
│   ├── restart-catalog.sh              # Restart RHOAI catalog + re-resolve Subscription after catalog image flip
│   ├── setup-maas-model.sh             # Deploy/delete/status MaaS models
│   ├── verify-maas.sh                  # End-to-end MaaS verification
│   ├── status.sh                        # Show ArgoCD app status
│   ├── diagnose.sh                      # Comprehensive cluster diagnosis
│   ├── preflight-check.sh              # Quick cluster readiness check
│   ├── validate-config.sh              # Validate .env against cluster capabilities
│   ├── scale-machineset.sh              # Scale MachineSets
│   └── configure-repo.sh                # Update repo URLs for forks
│
├── bootstrap/                            # Bootstrap resources (applied by scripts)
│   ├── gitops-operator/                 # GitOps operator subscription
│   ├── argocd-instance/                 # ArgoCD instance config
│   ├── gpu-machineset/                  # GPU MachineSet templates
│   ├── cpu-machineset/                  # CPU MachineSet templates
│   ├── icsp/                            # ImageContentSourcePolicy
│   ├── external-secrets/                # ExternalSecret for pull-secret (Merge mode)
│   ├── cluster-monitoring-config/       # Enables user-workload monitoring (applied by scripts/enable-uwm.sh during `make infra`)
│   └── rhoaibu-cluster-nightly/         # Cluster-specific config
│
├── clusters/                             # Cluster definitions
│   ├── base/
│   │   └── kustomization.yaml           # Points to ArgoCD apps
│   └── overlays/
│       └── rhoaibu-cluster-nightly/     # Cluster-specific overlay
│
├── components/                           # GitOps-managed components
│   ├── argocd/
│   │   └── apps/
│   │       ├── cluster-operators-appset.yaml     # ApplicationSet for operators
│   │       ├── cluster-oper-instances-appset.yaml # ApplicationSet for instances
│   │       └── kustomization.yaml
│   │
│   ├── operators/                       # Operator subscriptions
│   │   ├── nfd/                         # Node Feature Discovery
│   │   ├── nvidia-operator/             # NVIDIA GPU Operator
│   │   ├── rhoai-operator/              # RHOAI operator + nightly catalog
│   │   ├── openshift-service-mesh/      # Service Mesh
│   │   ├── kueue-operator/              # Kueue for job queueing
│   │   ├── jobset-operator/             # JobSet for distributed workloads
│   │   ├── leader-worker-set/           # Leader-Worker pattern
│   │   ├── connectivity-link/           # Connectivity Link
│   │   └── cluster-observability-operator/ # COO (Perses CRDs for Observability dashboard)
│   │
│   └── instances/                       # Operator instances/configs
│       ├── nfd-instance/                # NFD NodeFeatureDiscovery CR
│       ├── nvidia-instance/             # ClusterPolicy for GPU
│       ├── rhoai-instance/              # base + overlays (maas, maas-observability)
│       ├── jobset-instance/             # JobSet config
│       ├── leader-worker-set-instance/  # Leader-Worker config
│       ├── connectivity-link-instance/  # Connectivity Link config
│       ├── maas-instance/               # MaaS Helm chart (PostgreSQL+PVC, Gateway)
│       ├── maas-observability/          # MaaS observability (TelemetryPolicy + Istio Telemetry)
│       └── maas-models/                # MaaS model manifests (kustomize)
│           ├── simulator/              # CPU-only mock model
│           ├── gpt-oss-20b/            # OpenAI gpt-oss-20b (GPU, vLLM CUDA)
│           └── granite-tiny-gpu/       # Granite 4.0-h-tiny FP8 (GPU, vLLM CUDA)
│
├── Makefile                             # Automation targets
├── .env.example                         # Configuration template
├── .gitignore                           # Git ignore rules
└── README.md                            # User documentation
```

## Development Workflows

### Default: Incremental Deployment (RECOMMENDED)

**This is the default workflow.** Run targets individually and verify each step before proceeding.

```bash
# Phase 0: Cluster Preparation
make preflight       # Quick cluster readiness check
cp .env.example .env # Configure credentials (edit .env)
make validate-config # Validate .env against cluster capabilities

# Phase 1: Pre-GitOps Setup (run individually, verify each)
make secrets         # Add quay.io/rhoai credentials (pull-secret)
                     # VERIFY: oc get secret/pull-secret -n openshift-config

make icsp            # Create ImageContentSourcePolicy
                     # WAITS: ~10-15 min for all nodes to restart
                     # VERIFY: oc get nodes (all Ready)

make gpu             # Create GPU MachineSet (g6e.2xlarge, autoscale 1-3)
                     # WAITS: Until GPU node is Ready
                     # VERIFY: oc get nodes -l node-role.kubernetes.io/gpu

make cpu             # Create CPU worker MachineSet (m6a.4xlarge, autoscale 1-3)
                     # WAITS: Until CPU worker node is Ready
                     # VERIFY: oc get nodes -l node-role.kubernetes.io/worker

# Optional: Dedicate master nodes (after workers are Ready)
make dedicate-masters # Remove worker role from masters
                      # VERIFY: oc get nodes (masters no longer have worker role)

# Phase 2: Bootstrap GitOps
make gitops          # Install GitOps operator + ArgoCD
                     # WAITS: Until ArgoCD is ready
                     # VERIFY: oc get pods -n openshift-gitops

make deploy          # Deploy root app (triggers all ApplicationSets)
                     # VERIFY: oc get applications.argoproj.io -n openshift-gitops

# Phase 3: Monitor Deployment
make status          # Show ArgoCD application sync status
make diagnose        # Comprehensive cluster diagnosis
```

**Key principle**: After each step, STOP and verify before continuing. This allows for troubleshooting if issues occur.

### Autonomous Workflow

Use only when explicitly requested with "run autonomously" or "don't stop".

```bash
make all             # Runs: setup + bootstrap + sync + maas
                     # Each script waits for readiness before proceeding
```

## Common Commands

### Pre-GitOps Setup

```bash
make secrets         # Add quay.io/rhoai credentials to global pull secret
make icsp            # Create ImageContentSourcePolicy (triggers node restart)
make gpu             # Create GPU MachineSet (waits for node Ready)
make cpu             # Create CPU worker MachineSet (waits for node Ready)
make setup           # Run all pre-GitOps setup (secrets, icsp, gpu, cpu)
```

### GitOps Bootstrap

```bash
make gitops          # Install GitOps operator + ArgoCD instance
make deploy          # Deploy root app (triggers ApplicationSets)
make bootstrap       # Run gitops + deploy together
```

### Validation & Monitoring

```bash
make preflight       # Quick cluster readiness check (connection, nodes, basics)
make validate-config # Validate .env against cluster capabilities
make status          # Show ArgoCD application sync status
make diagnose        # Comprehensive cluster diagnosis (full health check)
```

### Maintenance Operations

```bash
make refresh         # GitOps refresh - pull latest from git (no sync)
                     # Use to see what changed in git vs cluster

make restart-catalog # Restart catalog pod and RHOAI operator
                     # Use after syncing new catalog image from git

make sync-disable    # Disable ArgoCD auto-sync (for manual changes)
make sync-enable     # Re-enable ArgoCD auto-sync
make refresh-apps    # Refresh from git AND sync all apps (one-time)
                     # Use when auto-sync is disabled to apply latest from git

make scale NAME=<machineset> REPLICAS=<N|+N|-N>
                     # Scale a MachineSet
                     # Examples:
                     #   make scale NAME=gpu-g6e-2xlarge REPLICAS=2
                     #   make scale NAME=gpu-g6e-2xlarge REPLICAS=+1
                     #   make scale NAME=cpu-m6a-4xlarge REPLICAS=-1

make dedicate-masters # Remove worker role from master nodes
                      # Must have Ready worker nodes first
```

### MaaS (Models as a Service)

```bash
make maas            # Install MaaS platform ONLY (secrets, ArgoCD app, Authorino SSL).
                     # Does NOT install the observability cascade — run `make observability`
                     # separately once the cluster is healthy.
make maas-model      # Deploy models (default: auto — inspects cluster GPU VRAM)
                     # Autodetect rules: no GPU -> simulator; GPU VRAM >=40Gi -> gpt-oss-20b;
                     # otherwise -> granite-tiny-gpu
                     # Override: make maas-model MODEL=simulator
                     # Or set MAAS_MODELS in .env: MAAS_MODELS=gpt-oss-20b granite-tiny-gpu
make maas-model-status # Show deployed model status
make maas-model-delete # Delete models (same MODEL= or MAAS_MODELS logic)
make maas-verify     # Full end-to-end verification (deploys temp model, tests, cleans up)
make maas-uninstall  # Remove MaaS platform (deletes ArgoCD app + secrets + Authorino SSL)
make observability   # Settle-gate → flip instance-rhoai to overlays/maas-observability
                     #   → wait for Perses/Tempo/OTel. Heavy on the control plane; refuses
                     #   if any master is >=75% memory (see Remediation #4).
make observability-uninstall # Reverse-flip instance-rhoai to overlays/maas; monitoring cascade tears down
```

Available models:
- `simulator` — CPU-only mock (~256Mi RAM, no real LLM)
- `gpt-oss-20b` — OpenAI gpt-oss-20b on vLLM GPU (1 GPU, 60Gi RAM)
- `granite-tiny-gpu` — RedHatAI Granite 4.0-h-tiny FP8 on vLLM GPU (1 GPU, 24Gi RAM)

Each model gets free tier (100 tokens/min, all authenticated users) and premium tier (100000 tokens/min, all authenticated users).

### Repository Configuration (for forks)

Three options, by durability:

1. **Inline env var (ephemeral, no file edits)** — for test runs / feature branches:
   ```bash
   GITOPS_BRANCH=my-feature-branch make deploy
   ```
   `scripts/deploy-apps.sh` reads `GITOPS_BRANCH` at runtime and patches ArgoCD ApplicationSets + every child Application on the cluster. The checked-in YAML is unchanged.

2. **`.env` override (persistent across sessions, still no file edits)**:
   ```bash
   echo "GITOPS_BRANCH=my-feature-branch" >> .env
   make deploy
   ```

3. **`make configure-repo` (permanent, mutates YAML — commit required)**:
   ```bash
   GITOPS_REPO_URL=https://github.com/my-fork/rhoai-nightly \
   GITOPS_BRANCH=my-default \
   make configure-repo
   ```
   Use only for permanent fork setups. Mutates `components/argocd/apps/*.yaml`, the cluster overlay patches, and the bootstrap `cluster-config-app.yaml`. Must be committed. **Not appropriate for ephemeral branch testing** — creates a commit that has to be reverted before merge.

### RHOAI Version Configuration

To change the RHOAI version, edit `components/operators/rhoai-operator/base/catalogsource.yaml` directly:

```yaml
# catalogsource.yaml - change the image tag
spec:
  image: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4-ea.2-nightly
  displayName: RHOAI 3.4 ea.2 Nightly
```

The subscription channel is set in `components/operators/rhoai-operator/base/patch-channel.yaml` (currently `beta` for EA builds).

```bash
# After editing, commit and push
git diff
git add -A && git commit -m "Update RHOAI catalog image"
git push

# If ArgoCD is already running, apply changes
make refresh-apps
make restart-catalog  # Force catalog pod to pull new image
```

**Catalog image examples:**
- `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4-ea.1-nightly`
- `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4-ea.2-nightly`

## Configuration (.env file)

Copy `.env.example` to `.env` and configure:

```bash
# Required: Quay.io credentials for RHOAI nightly images
QUAY_USER=your-username
QUAY_TOKEN=your-token

# Optional: GPU MachineSet configuration
GPU_INSTANCE_TYPE=g6e.2xlarge    # GPU instance type
GPU_REPLICAS=1                   # Initial replicas
GPU_ACCESS_TYPE=SHARED           # SHARED or PRIVATE
GPU_MIN=1                        # Minimum replicas (autoscaling)
GPU_MAX=3                        # Maximum replicas (autoscaling)
GPU_AZ=                          # Auto-detected if empty

# Optional: CPU Worker MachineSet configuration
CPU_INSTANCE_TYPE=m6a.4xlarge   # CPU instance type
CPU_REPLICAS=1                   # Initial replicas
CPU_VOLUME_SIZE=120              # Root volume size (GB)
CPU_MIN=1                        # Minimum replicas (autoscaling)
CPU_MAX=3                        # Maximum replicas (autoscaling)
CPU_AZ=                          # Auto-detected if empty

# Optional: GitOps configuration (for forks)
GITOPS_REPO_URL=https://github.com/your-username/rhoai-nightly
GITOPS_BRANCH=main

# RHOAI version: edit components/operators/rhoai-operator/base/catalogsource.yaml
# See "RHOAI Version Configuration" section above
```

## Pull Secret Management

The cluster pull-secret can be managed in two ways:

### Manual Mode (QUAY_USER/QUAY_TOKEN set)

When `QUAY_USER` and `QUAY_TOKEN` are set in `.env`:
- `scripts/add-pull-secret.sh` directly patches the cluster pull-secret
- Adds `quay.io/rhoai` credentials to the existing pull-secret
- Script is idempotent - safe to re-run

### External Secrets Mode (No credentials, bootstrap repo access)

When credentials are not set but user has access to the private bootstrap repo:
- External Secrets Operator is installed
- ClusterSecretStore connects to AWS Secrets Manager
- ExternalSecret syncs pull-secret from AWS

**Key configuration in `bootstrap/external-secrets/pull-secret-external.yaml`:**

```yaml
spec:
  target:
    name: pull-secret
    creationPolicy: Merge  # Critical: Merge into existing secret
```

**Why `creationPolicy: Merge`?**
- `Owner` (default): ExternalSecret owns the secret; deleting ExternalSecret cascade-deletes the pull-secret
- `Merge`: ExternalSecret merges data into existing pull-secret; secret survives ExternalSecret deletion

This allows seamless switching between modes without losing credentials.

### Switching Modes

**From External Secrets to Manual:**
```bash
# ExternalSecret will be ignored when QUAY_USER/QUAY_TOKEN are set
# The script detects ExternalSecret and skips if present, or you can delete it:
oc delete externalsecret pull-secret -n openshift-config
make secrets  # Uses manual mode
```

**From Manual to External Secrets:**
```bash
# Clear credentials from .env, ensure bootstrap repo access
make secrets  # Detects no credentials, uses External Secrets
```

## GitOps Patterns

### ApplicationSets

This repository uses two ApplicationSets to automatically sync components:

1. **cluster-operators-appset.yaml**: Syncs all directories in `components/operators/*` (git generator)
2. **cluster-oper-instances-appset.yaml**: Syncs specific directories in `components/instances/*` (list generator)

When you commit a new directory to `components/operators/` or add an entry to the instances ApplicationSet, ArgoCD automatically creates a corresponding Application and syncs it.

### ApplicationSet Sync Behavior (Important)

ApplicationSets use `applicationsSync: create-only` which has specific implications:

**Why `create-only`?**
- `make sync` enables auto-sync on Applications one-by-one to avoid overwhelming the API server
- Without `create-only`, the ApplicationSet would reset the syncPolicy back to the template's empty `syncPolicy: {}`
- This would disable auto-sync after `make sync` runs

**Implication: Template changes don't propagate to existing Applications**

When you modify the ApplicationSet template (e.g., change `targetRevision`, `repoURL`, or add new list elements), existing Applications are NOT updated. Only new Applications get the updated template.

**To apply template changes to existing Applications:**

```bash
# Option 1: Delete and let ApplicationSet recreate
oc delete application.argoproj.io/<app-name> -n openshift-gitops
# ApplicationSet recreates it with new template
make sync-app APP=<app-name>

# Option 2: Patch the Application directly
oc patch application.argoproj.io/<app-name> -n openshift-gitops \
  --type=merge -p '{"spec":{"source":{"targetRevision":"new-branch"}}}'
```

**When adding new components:**
- New Applications are created automatically with the current template
- No manual intervention needed for new apps

### Remote References with Local Patches

Components reference the [redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog) repository and apply local patches:

```yaml
# components/operators/nfd/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable?ref=main

patches:
  - target:
      kind: Subscription
      name: nfd
    path: patch-channel.yaml
```

This pattern allows:
- Leveraging upstream catalog definitions
- Applying local customizations via patches
- Version pinning via git refs

### Adding New Components

To add a new component (operator or instance):

```bash
# 1. Create component directory
mkdir -p components/operators/my-operator

# 2. Create kustomization.yaml
cat > components/operators/my-operator/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/redhat-cop/gitops-catalog/path/to/operator?ref=main
EOF

# 3. (Optional) Add patches
cat > components/operators/my-operator/patch.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-operator
spec:
  channel: stable
EOF

# Update kustomization.yaml to include patch
cat >> components/operators/my-operator/kustomization.yaml <<EOF
patches:
  - target:
      kind: Subscription
      name: my-operator
    path: patch.yaml
EOF

# 4. Commit and push
git add components/operators/my-operator/
git commit -m "Add my-operator"
git push

# 5. Verify ArgoCD syncs (wait ~1 minute)
oc get applications.argoproj.io -n openshift-gitops
oc get application.argoproj.io/my-operator -n openshift-gitops
```

The ApplicationSet will automatically detect the new directory and create an Application.

### Component Dependencies

Operators and instances have dependencies that must be respected:

**Deployment Order:**
1. Operators (all can deploy in parallel)
2. Instances (must wait for operators to be ready)

**Specific Dependencies:**
- `nvidia-instance` requires `nfd-instance` (NFD must label GPU nodes first)
- `rhoai-instance` requires `rhoai-operator` to be ready
- Service Mesh instances require Service Mesh operator

The ApplicationSets handle this by deploying all operators first, then all instances.

## MaaS (Models as a Service)

MaaS enables API key management, subscriptions, and rate limiting for LLM inference services. It uses a hybrid GitOps + imperative approach.

### Architecture

MaaS has three layers:

1. **GitOps (Helm chart)** - `components/instances/maas-instance/chart/`
   - PostgreSQL deployment with 20Gi PVC (size/storageClassName configurable via Helm values `postgres.persistence.size` / `postgres.persistence.storageClassName`; empty storageClassName = cluster default)
   - PostgreSQL Service
   - GatewayClass `openshift-default`
   - Gateway `maas-default-gateway` (LoadBalancer with cluster-specific hostname)

2. **Imperative (install-maas.sh)** - Things that can't be in git:
   - PostgreSQL secrets (`postgres-creds`, `maas-db-config`) — generated password
   - Authorino SSL env vars — no CR field, must `oc set env`
   - ArgoCD Application creation — injects cluster-specific values (`clusterDomain`, `certName`, `namespace`) into Helm chart
   - Does NOT install observability — that's its own operation (`make observability`)

3. **Operator-managed** - Deployed automatically when DSC has `modelsAsService: Managed`:
   - maas-api, maas-controller, payload-processing deployments
   - HTTPRoutes, AuthPolicies, NetworkPolicies

### Why Helm (not Kustomize)

The MaaS Gateway needs cluster-specific values (domain, TLS cert name) that vary per cluster. The instances ApplicationSet template assumes Kustomize and can't express Helm values. Instead, `install-maas.sh` creates the `instance-maas` ArgoCD Application directly with Helm source and injected values, bypassing the ApplicationSet.

### MaaS Install Flow

```
install-maas.sh:
  1. Preflight: check cluster, detect domain/cert/repo/branch
  2. Create PostgreSQL secrets (idempotent)
  3. Create instance-maas ArgoCD Application (Helm source with values)
     → ArgoCD syncs: GatewayClass, Gateway, PostgreSQL (Deployment + PVC + Service)
  4. Configure Authorino SSL env vars
  5. Validate: wait for maas-api, check health endpoint
```

**Note**: `install-maas.sh` used to call `install-observability.sh` as a final
phase. That coupling is now removed — observability is run separately with
`make observability` because its monitoring cascade is heavy on the control
plane and needs its own settle-gate. See the Remediation #4 section below.

### MaaS Uninstall Flow

```
uninstall-maas.sh:
  1. Remove Authorino SSL env vars
  2. Delete instance-maas ArgoCD Application (cascade-deletes all Helm resources)
  3. Delete PostgreSQL secrets
  4. Clean up stale DNS records
```

### DSC Configuration

The DataScienceCluster is split across base + overlays:

- `components/instances/rhoai-instance/base/datasciencecluster.yaml` has `modelsAsService.managementState: Removed` and `rawDeploymentServiceConfig: Headed`. Base is the safe no-MaaS baseline.
- `components/instances/rhoai-instance/overlays/maas/` patches `modelsAsService.managementState: Managed` — this is the default overlay the `instance-rhoai` ApplicationSet entry points at, so MaaS is on out of the box.
- `components/instances/rhoai-instance/overlays/maas-observability/` layers on top of `maas` and adds `DSCI.spec.monitoring.metrics.storage`, which triggers the rhods-operator Monitoring controller's full observability cascade (Perses, TempoStack, OpenTelemetryCollector DaemonSet, NodeMetricsEndpoint, MonitoringStack, ThanosQuerier). `scripts/install-observability.sh` flips the Application source to this overlay only after a settle-gate confirms the cluster is healthy enough to absorb the load.

With MaaS on (default), the operator attempts to deploy MaaS components as soon as DSC syncs, even before `install-maas.sh` runs. The operator tolerates the missing Gateway and retries until it appears.

### MaaS Model Management

Models are defined as kustomize manifests in `components/instances/maas-models/`. Each model directory contains:
- `llm/` — LLMInferenceService (the workload)
- `maas/` — MaaSModelRef + MaaSAuthPolicy + MaaSSubscription (free + premium tiers)

`setup-maas-model.sh` deploys/deletes models using `oc kustomize`. It reads `MAAS_MODELS` from `.env` for default model selection (default: `gpt-oss-20b`).

### MaaS Verification

`verify-maas.sh` runs 6 phases:
1. Infrastructure health (Gateway, PostgreSQL, maas-api, maas-controller, Authorino, health endpoint)
2. Deploy temporary simulator model + MaaS resources
3. API verification (create API key, list models, test inference)
4. Auth enforcement (reject unauthenticated + invalid token requests)
5. Rate limiting (trigger 429 responses)
6. Cleanup (remove all temporary test resources)

The verify script is self-contained — it deploys its own temporary model and does NOT affect persistently deployed models.

### MaaS Debugging Commands

```bash
# Check MaaS infrastructure
oc get application.argoproj.io/instance-maas -n openshift-gitops
oc get gateway maas-default-gateway -n openshift-ingress
oc get gatewayclass openshift-default

# Check operator-managed MaaS
oc get modelsasservice -A
oc get deployment maas-api maas-controller -n redhat-ods-applications
oc get pods -n redhat-ods-applications | grep -E "maas|postgres|payload"

# Check models
oc get llminferenceservice -n llm
oc get maasmodelref -n llm -o wide
oc get maassubscription -n models-as-a-service
oc get maasauthpolicy -n models-as-a-service
oc get pods -n llm

# Check health
curl -sk https://maas.<cluster-domain>/maas-api/health
# 200 = healthy, 401 = auth working (unauthenticated)

# Check Authorino SSL
oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env}'
```

## MaaS Observability

Observability lights up the RHOAI 3.x Observability dashboard (request rate, success rate, GPU/CPU/memory, per-subscription usage) for MaaS. It layers OpenShift user-workload monitoring + MaaS-specific TelemetryPolicy/ServiceMonitors + the Kuadrant observability toggle.

**Installed separately from MaaS.** `install-maas.sh` used to call `install-observability.sh` as a final phase, but that coupling was removed. The monitoring cascade (Perses, Tempo, OTel DaemonSet, MonitoringStack, NodeMetrics) puts substantial memory pressure on the control plane — it now has its own entrypoint with a settle-gate that refuses to fire if masters are >=75% memory or the cluster isn't otherwise healthy. Run `make observability` when the cluster is ready.

**Dashboard visibility:** `components/instances/rhoai-instance/base/odh-dashboard-config.yaml` sets `spec.dashboardConfig.observabilityDashboard: true` so the **Observability** nav item appears in the RHOAI console. This requires cluster-admin (or equivalent dashboard admin) permissions to see — non-admin users will NOT see the nav item even when the flag is true.

**Dashboard backend (Perses):** The Observability tab proxies to a Perses Service in `redhat-ods-monitoring` on port 8080. The RHOAI operator's Monitoring controller owns the Perses lifecycle end-to-end — it runs `deployPerses`, `deployPersesTempoIntegration`, `deployPersesPrometheusIntegration`, `deployOpenTelemetryCollector`, and `deployNodeMetricsEndpoint` on every reconcile, creating the Perses CR (named `data-science-perses`), its datasources, the Tempo integration, the OTel collector, the node-metrics endpoint, and the per-RHOAI `PersesDashboard` resources automatically.

The only thing we need to provide is the **Cluster Observability Operator (COO)** so the `Perses`, `PersesDatasource`, and `PersesDashboard` CRDs are registered on the cluster:

- `components/operators/cluster-observability-operator/` — COO Subscription (channel `stable`, AllNamespaces into `openshift-operators`).

Once COO is installed, the RHOAI operator does everything else. No custom Perses resources are managed in this repo — creating our own would conflict with (and be continuously overwritten by) the operator, and our v1alpha1 CR would clash with the operator's v1alpha2 preference. If the Observability tab is blank, check that COO is subscribed and the `perses.perses.dev` CRD exists; the operator reconciles the rest.

### Architecture

MaaS observability has three layers:

1. **Infrastructure (`make infra` / `make uwm`)** - `bootstrap/cluster-monitoring-config/`
   - `cluster-monitoring-config` ConfigMap with `enableUserWorkload: true`
   - Applied by `scripts/enable-uwm.sh` as part of `make infra`. UWM is a
     foundational cluster capability other workloads may depend on; owning it
     at the infra stage makes dependencies clearer and avoids stacking UWM's
     memory overhead on top of the observability cascade at install time.

2. **GitOps (Kustomize)** - `components/instances/maas-observability/base/`
   - Kuadrant `TelemetryPolicy/maas-telemetry` (adds `model`, `user`, `subscription`, `organization_id`, `cost_center` labels on gateway metrics)
   - Istio `Telemetry/latency-per-subscription` (per-subscription request-duration label)
   - Synced by the `instance-maas-observability` ArgoCD Application created by the instances ApplicationSet.

3. **Imperative (install-observability.sh)** - Things that can't be in git:
   - Verifies UWM is already enabled (fails fast with pointer to `make uwm` if not)
   - Kuadrant CR patch (`spec.observability.enable=true`) — triggers the Kuadrant operator to manage its own PodMonitors
   - Conditional Limitador/Authorino ServiceMonitors (skipped if the operator already covers those targets)
   - Conditional Istio Gateway metrics Service + ServiceMonitor (only applied when `maas-default-gateway` deployment exists)

### Install Flow

```
install-observability.sh:
  1. Preflight: cluster connection, Kuadrant + Istio Telemetry CRDs
  2. Phase A: VERIFY UWM is enabled (fails with pointer to `make uwm` if not)
  3. Phase B: patch Kuadrant CR -> spec.observability.enable=true
  4. Phase C: apply limitador-servicemonitor IF no existing monitor covers it
  5. Phase D: apply authorino-server-metrics-servicemonitor IF no existing monitor covers /server-metrics
  6. Phase E: apply istio-gateway-service + servicemonitor IF maas-default-gateway deployment present
```

### Uninstall Flow

```
install-observability.sh --uninstall:
  1. Patch Kuadrant CR -> spec.observability.enable=false
  2. Delete ServiceMonitors/Services labelled app.kubernetes.io/part-of=maas-observability
     and app.kubernetes.io/managed-by=maas-observability
  3. LEAVES bootstrap/cluster-monitoring-config ConfigMap in place (other workloads may depend on UWM)
  4. Does NOT touch the GitOps instance-maas-observability Application
```

### Verification Commands

```bash
# UWM enabled
oc get cm cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload
oc get pods -n openshift-user-workload-monitoring

# Kuadrant observability enabled
oc get kuadrant -n kuadrant-system -o jsonpath='{.items[0].spec.observability.enable}'

# GitOps resources
oc get telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress
oc get telemetry.telemetry.istio.io latency-per-subscription -n openshift-ingress

# ServiceMonitors
oc get servicemonitor,podmonitor -n kuadrant-system
oc get servicemonitor,service -n openshift-ingress -l app.kubernetes.io/part-of=maas-observability
oc get servicemonitor kserve-llm-models -n llm  # scrapes vllm:* metrics from LLMInferenceService pods

# ArgoCD app
oc get application.argoproj.io/instance-maas-observability -n openshift-gitops

# End-to-end: fire inference, wait ~2 min, open RHOAI console -> Observability dashboard
# Or run:
make diagnose  # section 9 = Observability
```

## Eval Hub

Eval Hub is a TrustyAI evaluation harness layered on top of RHOAI. It's
opt-in (not part of `make all`) and orthogonal to MaaS and observability —
turning eval-hub on or off does not affect either of the other two
features. `make evalhub` / `make evalhub-uninstall` toggle it.

### Architecture

Eval-hub is shipped as its own ArgoCD Application (`instance-evalhub`),
not as a Kustomize overlay on `instance-rhoai`. This keeps eval-hub
orthogonal to the MaaS / observability flips that DO modify the
`instance-rhoai` overlay path. The composition is:

| Feature | Mechanism | Lifecycle |
|---|---|---|
| MaaS | `instance-rhoai` overlay flip (`overlays/maas`) | `make maas` / `make maas-uninstall` |
| MaaS observability | `instance-rhoai` overlay flip (`overlays/maas-observability`) | `make observability` / `make observability-uninstall` |
| Eval-hub | Standalone `instance-evalhub` Application | `make evalhub` / `make evalhub-uninstall` |

`make evalhub` mirrors the `install-maas.sh` pattern: detect repo URL +
branch from the existing `instance-rhoai` Application, then `oc apply` an
ArgoCD Application manifest pointed at `components/instances/evalhub/`.
`make evalhub-uninstall` deletes that Application; the
`resources-finalizer.argocd.argoproj.io` finalizer cascade-prunes
EvalHub, MLflow, DSPA, and the evalhub-tenant namespace + RBAC + Job.

### What it deploys

- `EvalHub/evalhub` (TrustyAI) in `redhat-ods-applications`
- `MLflow/mlflow` (10Gi RWO PVC) in `redhat-ods-applications`
- `DataSciencePipelinesApplication/dspa` in `evalhub-tenant` ns —
  brings up its own MinIO with external route, MariaDB, pipeline API
  server, and supporting controllers
- `evalhub-tenant` namespace + RBAC (Role `evalhub-jobs-dspa-api`,
  RoleBindings to `ds-pipeline-dspa` and `evalhub-redhat-ods-applications-job`)
- `Job/update-secret-minio` — hook Job that patches DSPA's
  `ds-pipeline-s3-dspa` secret to point at the in-cluster MinIO

All manifests live at `components/instances/evalhub/`.

### Why it's opt-in (not in `make all`)

- **Storage class dependency.** MLflow and DSPA-managed MinIO each ask
  for an RWO PVC. Without a default StorageClass, both sit Pending.
- **CRD/sync ordering.** `EvalHub`, `MLflow`, and DSPA CRDs only exist
  on RHOAI 3.x nightly. ArgoCD will retry but reports Degraded for a
  few minutes on first install.
- **Privileged hook Job.** `update-secret-minio` runs with a SA bound
  to `ClusterRole/edit` (namespace-scoped). Acceptable for a demo rig;
  noted for awareness.
- **Demo-grade MinIO posture.** DSPA enables `enableExternalRoute: true`
  and `podToPodTLS: false` — fine for a demo cluster.

### Settle-gate

Before creating the Application, `scripts/install-evalhub.sh` runs a
lightweight gate (no master-memory check — eval-hub deploys ~5 worker
pods, no DaemonSet, no control-plane cascade):

1. `rhods-operator` CSV in `redhat-ods-operator` is `Succeeded`
2. `DataScienceCluster/default-dsc` Ready=True;
   `DSCInitialization/default-dsci` Available=True / Degraded≠True
3. At least one default StorageClass exists

After the Application is created, the script waits up to 600s for
`EvalHub` to reach `status.phase=Ready`, MLflow + DSPA + `evalhub-tenant`
ns to come up, then runs a 120s pod-readiness check on
`redhat-ods-applications` (eval-hub + mlflow pods) and `evalhub-tenant`
(DSPA + MinIO pods). Pod-readiness is warn-only — the Application is
already created by then.

### Verification commands

```bash
# Eval-hub resources reconciled
oc get evalhub,mlflow,dspa -A
oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}'

# Pods Running
oc get pods -n redhat-ods-applications | grep -E 'evalhub|mlflow'
oc get pods -n evalhub-tenant

# Hook Job completed
oc get job update-secret-minio -n evalhub-tenant

# DSPA pipeline routes
oc get route -n evalhub-tenant

# ArgoCD Application status
oc get application.argoproj.io/instance-evalhub -n openshift-gitops
```

## Script Implementation Details

### Script Behavior

All scripts follow these patterns:

1. **Validate cluster connection** before running
2. **Check if resource already exists** (idempotent)
3. **Apply configuration** via `oc apply -k` (Kustomize)
4. **Wait for readiness** before returning (except where noted)
5. **Provide clear status messages** (color-coded)

### Wait Times

Expected wait times for each script:

- `secrets`: Immediate in Manual mode; ~30s-1min in External Secrets mode (waits for operator + sync)
- `icsp`: 10-15 minutes (waits for all nodes to restart)
- `gpu`: 5-10 minutes (waits for GPU node Ready)
- `cpu`: 5-10 minutes (waits for CPU worker node Ready)
- `gitops`: 2-3 minutes (waits for GitOps operator + ArgoCD)
- `deploy`: Immediate (creates apps, sync happens async)
- `maas`: 3-5 minutes (creates secrets, ArgoCD app, waits for Gateway + maas-api, then runs observability install)
- `observability`: ~3-5 minutes (settle-gate check, overlay flip, wait for Perses/Tempo/OTel to reconcile, then Kuadrant patch + conditional ServiceMonitors). Run separately from `make maas`.
- `evalhub`: ~3-5 minutes (lightweight settle-gate, creates instance-evalhub Application, waits for EvalHub Ready + MLflow + DSPA + evalhub-tenant). Orthogonal to MaaS / observability.
- `evalhub-uninstall`: ~30 seconds (deletes instance-evalhub Application; resources-finalizer cascade-prunes EvalHub/MLflow/DSPA + evalhub-tenant ns).
- `maas-model` (simulator): ~30 seconds (CPU, no image pull needed after first time)
- `maas-model` (GPU models): 5-15 minutes (image pull ~8GB + vLLM model loading)
- `maas-verify`: ~3 minutes (deploys temp model, runs tests, cleans up)
- `maas-uninstall`: ~30 seconds (deletes ArgoCD app + secrets)

### Script Options

Most scripts support both CLI arguments and environment variables:

```bash
# Via CLI arguments
scripts/create-gpu-machineset.sh --instance-type g6e.4xlarge --replicas 2

# Via environment variables
GPU_INSTANCE_TYPE=g6e.4xlarge GPU_REPLICAS=2 scripts/create-gpu-machineset.sh

# Via .env file (loaded by Makefile)
# Edit .env, then run:
make gpu
```

## Security Guidelines

**CRITICAL: This is a PUBLIC repository. Never commit secrets.**

### Pre-Commit Checklist

Before running `git commit`, verify:

- [ ] No hardcoded passwords/tokens in scripts
- [ ] No API keys in YAML files
- [ ] No base64-encoded secrets
- [ ] Environment variables used for all credentials
- [ ] `git diff --staged` reviewed for sensitive data

### Secret Scanning

Run before committing:

```bash
# Scan for potential secrets
grep -r -i "password=\|token=\|auth.*:" --include="*.sh" --include="*.yaml" .

# Check for base64 encoded strings (potential secrets)
grep -r -E "[A-Za-z0-9+/]{40,}={0,2}" --include="*.sh" --include="*.yaml" .

# Review staged changes
git diff --staged
```

### Secret Handling Rules

1. **Credentials**: Always use environment variables, never hardcode
   ```bash
   # CORRECT
   --auth-basic="${QUAY_USER}:${QUAY_TOKEN}"

   # WRONG - never do this
   --auth-basic="user:actualpassword123"
   ```

2. **Files to NEVER commit**:
   - `.env` files (except `.env.example`)
   - `*credentials*` files
   - `*secret*.txt`, `*secret*.json`
   - `*.key`, `*.pem` files
   - Any file with actual tokens, passwords, or API keys

3. **Safe patterns** (these are OK):
   - Secret **names** like `userDataSecret:`, `credentialsSecret:`
   - References like `oc get secret/pull-secret`
   - Environment variable references like `${QUAY_TOKEN}`

### .gitignore Protection

The `.gitignore` file is configured to prevent common secret files from being committed:

```gitignore
.env
.env.*
!.env.example
*.credentials
*credentials*
*secret*.txt
*secret*.json
*.key
*.pem
```

### If a Secret is Accidentally Committed

**DO NOT just delete it** - it remains in git history.

1. Delete the entire repository on GitHub/GitLab
2. Remove local `.git` directory: `rm -rf .git`
3. Reinitialize: `git init`
4. **Rotate the exposed credential immediately**
5. Recreate repository and push clean history

## Troubleshooting

### Common Issues

**Problem**: ICSP script hangs waiting for nodes
- **Cause**: Nodes are restarting to apply ICSP
- **Solution**: Wait 10-15 minutes. Check `oc get mcp` for status
- **Debug**: `oc get nodes -w` to watch nodes restart

**Problem**: GPU node not appearing
- **Cause**: Availability zone has no GPU capacity
- **Solution**: Specify different AZ with `--az` or `GPU_AZ` env var
- **Debug**: Check AWS EC2 console for g6e.2xlarge availability

**Problem**: ArgoCD apps not syncing
- **Cause**: ApplicationSet repo URL or branch is pointing at the wrong place
- **Solution (ephemeral fix)**: `GITOPS_BRANCH=correct-branch make deploy` — patches ArgoCD in-place, no YAML commit needed
- **Solution (permanent)**: `make configure-repo` with correct `GITOPS_REPO_URL` / `GITOPS_BRANCH`, then commit the YAML changes
- **Debug**: `oc get applicationsets -n openshift-gitops -o yaml`, `oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,REPO:.spec.source.repoURL,BRANCH:.spec.source.targetRevision`

**Problem**: RHOAI operator stuck in "Installing"
- **Cause**: Catalog pod may need restart to pull new image
- **Solution**: Run `make restart-catalog` to restart catalog and operator pods
- **Debug**: `oc get pods -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly`

**Problem**: "error: Unknown command" when running make targets
- **Cause**: Scripts don't have execute permissions
- **Solution**: Makefile automatically adds execute permissions with `chmod +x`
- **Debug**: Check script permissions with `ls -la scripts/`

### Debugging Commands

```bash
# Check cluster connection
oc whoami --show-server
oc get nodes

# Check ArgoCD
oc get pods -n openshift-gitops
oc get applications.argoproj.io -n openshift-gitops
oc get applicationsets.argoproj.io -n openshift-gitops

# Check operators
oc get csv -A | grep -E "rhoai|nvidia|nfd"
oc get subscriptions -A

# Check RHOAI
oc get datascienceclusters -A
oc get pods -n redhat-ods-operator
oc get pods -n redhat-ods-applications

# Check GPU
oc get nodes -l nvidia.com/gpu.present=true
oc describe node -l node-role.kubernetes.io/gpu | grep -A5 "Capacity:\|Allocatable:"

# Check MachineSets
oc get machinesets -n openshift-machine-api
oc get machines -n openshift-machine-api

# Check ICSP
oc get imagecontentsourcepolicy
oc get mcp  # MachineConfigPool status
```

## Requirements

- **OpenShift**: 4.17+ (tested on 4.17)
- **CLI**: `oc` (OpenShift CLI)
- **Credentials**: quay.io credentials with access to `quay.io/rhoai` repos
- **Cluster**: AWS cluster with GPU availability (us-east-2 recommended)
- **Resources**: Sufficient quota for GPU instances (g6e.2xlarge) and CPU workers (m6a.4xlarge)

## Best Practices

### When Working with This Repository

1. **Always verify cluster connection** before running commands (`make preflight`)
2. **Use incremental workflow** unless explicitly requested to run autonomously
3. **Wait for each phase to complete** before proceeding to the next
4. **Review git diffs** before committing to ensure no secrets are included
5. **Use environment variables** for all credentials and configuration
6. **Commit small, focused changes** to components for easier troubleshooting
7. **Verify ArgoCD sync status** after committing new components

### When Adding Components

1. **Reference gitops-catalog** when possible instead of duplicating resources
2. **Use patches** for customizations rather than copying entire manifests
3. **Include namespace** in resource definitions if not openshift-gitops
4. **Add sync-options annotation** if resources may not exist initially:
   ```yaml
   commonAnnotations:
     argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
   ```
5. **Test locally** with `oc apply -k` before committing
6. **Document dependencies** if the component requires other components first

### When Troubleshooting

1. **Check ArgoCD app status first**: `make status`
2. **Review ArgoCD logs** for sync errors: `oc logs -n openshift-gitops deployment/openshift-gitops-server`
3. **Validate Kustomize locally**: `oc kustomize components/path/to/component`
4. **Check operator CSV status**: `oc get csv -A`
5. **Review component pods**: `oc get pods -n <namespace>`

## Key Files Reference

| File | Purpose |
|------|---------|
| `Makefile` | Automation targets and workflow orchestration |
| `.env.example` | Configuration template (copy to `.env`) |
| `.env` | Local configuration (gitignored, never commit) |
| `.gitignore` | Prevents committing secrets and temp files |
| `README.md` | User-facing documentation |
| `CLAUDE.md` | AI assistant guidance (this file) |
| `scripts/*.sh` | Pre-GitOps setup automation scripts |
| `bootstrap/*/kustomization.yaml` | Bootstrap resource definitions |
| `bootstrap/external-secrets/pull-secret-external.yaml` | ExternalSecret with Merge policy for pull-secret |
| `clusters/base/kustomization.yaml` | Root cluster configuration |
| `components/argocd/apps/*.yaml` | ApplicationSet definitions |
| `components/operators/*/kustomization.yaml` | Operator subscriptions |
| `components/instances/*/kustomization.yaml` | Operator instance configurations |
| `components/instances/maas-instance/chart/` | MaaS Helm chart (PostgreSQL + PVC, Gateway) |
| `components/instances/maas-observability/base/` | MaaS observability GitOps manifests (TelemetryPolicy, Istio Telemetry) |
| `bootstrap/cluster-monitoring-config/` | UWM ConfigMap applied by `scripts/enable-uwm.sh` during `make infra` |
| `scripts/enable-uwm.sh` | Enable UWM (idempotent merge; --check / --dry-run modes) |
| `scripts/install-maas.sh` | MaaS install (secrets, ArgoCD app, Authorino, default observability) |
| `scripts/install-observability.sh` | MaaS observability install/uninstall (UWM, Kuadrant, ServiceMonitors) |
| `scripts/uninstall-maas.sh` | MaaS uninstall (cascade delete + cleanup) |

## Related Repositories

- **This Repository**: [rh-aiservices-bu/rhoai-nightly](https://github.com/rh-aiservices-bu/rhoai-nightly) - GitOps deployment for RHOAI nightly builds
- **Bootstrap Repository**: [rh-aiservices-bu/rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap) - Private bootstrap repo with External Secrets configuration
- **Upstream Catalog**: [redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog) - Community GitOps catalog for OpenShift operators
- **MaaS Upstream**: [opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service) - MaaS docs, samples, and deployment manifests
- **RHOAI Documentation**: [Red Hat OpenShift AI docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)

## Notes for AI Assistants

- This repository uses **GitOps** - changes are deployed by committing to git, not by running oc commands
- Scripts in `scripts/` are **pre-GitOps only** - they run before ArgoCD is installed
- **Exception**: `install-maas.sh`, `uninstall-maas.sh`, `install-observability.sh`, `install-evalhub.sh`, `enable-uwm.sh`, and `restart-catalog.sh` run **after** ArgoCD — they create secrets, patch ArgoCD Applications (overlay flips), or apply cluster-wide config that can't be purely declarative. `install-maas.sh`, `install-observability.sh`, and `install-evalhub.sh` are independent; none invokes another.
- After ArgoCD is running, **all changes go through git commits**, not scripts (except MaaS secrets/Authorino)
- The **default workflow is incremental** - stop after each phase unless user requests autonomous run
- **Never commit secrets** - this is a public repository
- All file paths should be **absolute** when referencing in responses
- When suggesting changes, show both the **file content** and the **git workflow** to apply it
