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
│   ├── create-gpu-machineset.sh         # Create GPU MachineSet (g5.2xlarge)
│   ├── create-cpu-machineset.sh         # Create CPU worker MachineSet (m6a.4xlarge)
│   ├── install-gitops.sh                # Install GitOps operator + ArgoCD
│   ├── deploy-apps.sh                   # Deploy root app (triggers GitOps)
│   ├── status.sh                        # Show ArgoCD app status
│   ├── validate.sh                      # Validate cluster state
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
│   │   └── nfs-provisioner/             # NFS Provisioner for RWX storage
│   │
│   └── instances/                       # Operator instances/configs
│       ├── nfd-instance/                # NFD NodeFeatureDiscovery CR
│       ├── nvidia-instance/             # ClusterPolicy for GPU
│       ├── rhoai-instance/              # DataScienceCluster + configs
│       ├── jobset-instance/             # JobSet config
│       ├── leader-worker-set-instance/  # Leader-Worker config
│       ├── connectivity-link-instance/  # Connectivity Link config
│       └── nfs-instance/                # NFSProvisioner CR (creates 'nfs' StorageClass)
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
make check           # Verify cluster connection
cp .env.example .env # Configure credentials (edit .env)

# Phase 1: Pre-GitOps Setup (run individually, verify each)
make pull-secret     # Add quay.io/rhoai credentials
                     # VERIFY: oc get secret/pull-secret -n openshift-config

make icsp            # Create ImageContentSourcePolicy
                     # WAITS: ~10-15 min for all nodes to restart
                     # VERIFY: oc get nodes (all Ready)

make gpu             # Create GPU MachineSet (g5.2xlarge, autoscale 1-3)
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
make validate        # Validate full cluster state
```

**Key principle**: After each step, STOP and verify before continuing. This allows for troubleshooting if issues occur.

### Autonomous Workflow

Use only when explicitly requested with "run autonomously" or "don't stop".

```bash
make all             # Runs: setup (pull-secret, icsp, gpu, cpu) + bootstrap (gitops, deploy)
                     # Each script waits for readiness before proceeding
```

## Common Commands

### Pre-GitOps Setup

```bash
make pull-secret     # Add quay.io/rhoai credentials to global pull secret
make icsp            # Create ImageContentSourcePolicy (triggers node restart)
make gpu             # Create GPU MachineSet (waits for node Ready)
make cpu             # Create CPU worker MachineSet (waits for node Ready)
make setup           # Run all pre-GitOps setup (pull-secret, icsp, gpu, cpu)
```

### GitOps Bootstrap

```bash
make gitops          # Install GitOps operator + ArgoCD instance
make deploy          # Deploy root app (triggers ApplicationSets)
make bootstrap       # Run gitops + deploy together
```

### Validation & Monitoring

```bash
make check           # Verify cluster connection (oc whoami, oc get nodes)
make status          # Show ArgoCD application sync status
make validate        # Full cluster validation
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
                     #   make scale NAME=gpu-g5-2xlarge REPLICAS=2
                     #   make scale NAME=gpu-g5-2xlarge REPLICAS=+1
                     #   make scale NAME=cpu-m6a-4xlarge REPLICAS=-1

make dedicate-masters # Remove worker role from master nodes
                      # Must have Ready worker nodes first
```

### Repository Configuration (for forks)

```bash
make configure-repo  # Update ApplicationSet repo URLs
                     # Set GITOPS_REPO_URL and GITOPS_BRANCH in .env
```

## Configuration (.env file)

Copy `.env.example` to `.env` and configure:

```bash
# Required: Quay.io credentials for RHOAI nightly images
QUAY_USER=your-username
QUAY_TOKEN=your-token

# Optional: GPU MachineSet configuration
GPU_INSTANCE_TYPE=g5.2xlarge    # GPU instance type
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
make pull-secret  # Uses manual mode
```

**From Manual to External Secrets:**
```bash
# Clear credentials from .env, ensure bootstrap repo access
make pull-secret  # Detects no credentials, uses External Secrets
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

- `pull-secret`: Immediate (no wait)
- `icsp`: 10-15 minutes (waits for all nodes to restart)
- `gpu`: 5-10 minutes (waits for GPU node Ready)
- `cpu`: 5-10 minutes (waits for CPU worker node Ready)
- `gitops`: 2-3 minutes (waits for GitOps operator + ArgoCD)
- `deploy`: Immediate (creates apps, sync happens async)

### Script Options

Most scripts support both CLI arguments and environment variables:

```bash
# Via CLI arguments
scripts/create-gpu-machineset.sh --instance-type g5.4xlarge --replicas 2

# Via environment variables
GPU_INSTANCE_TYPE=g5.4xlarge GPU_REPLICAS=2 scripts/create-gpu-machineset.sh

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
- **Debug**: Check AWS EC2 console for g5.2xlarge availability

**Problem**: ArgoCD apps not syncing
- **Cause**: ApplicationSet repo URL may be incorrect
- **Solution**: Run `make configure-repo` with correct `GITOPS_REPO_URL`
- **Debug**: `oc get applicationsets -n openshift-gitops -o yaml`

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
- **Resources**: Sufficient quota for GPU instances (g5.2xlarge) and CPU workers (m6a.4xlarge)

## Best Practices

### When Working with This Repository

1. **Always verify cluster connection** before running commands (`make check`)
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

## Related Repositories

- **This Repository**: [rh-aiservices-bu/rhoai-nightly](https://github.com/rh-aiservices-bu/rhoai-nightly) - GitOps deployment for RHOAI nightly builds
- **Bootstrap Repository**: [rh-aiservices-bu/rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap) - Private bootstrap repo with External Secrets configuration
- **Upstream Catalog**: [redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog) - Community GitOps catalog for OpenShift operators
- **RHOAI Documentation**: [Red Hat OpenShift AI docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)

## Notes for AI Assistants

- This repository uses **GitOps** - changes are deployed by committing to git, not by running oc commands
- Scripts in `scripts/` are **pre-GitOps only** - they run before ArgoCD is installed
- After ArgoCD is running, **all changes go through git commits**, not scripts
- The **default workflow is incremental** - stop after each phase unless user requests autonomous run
- **Never commit secrets** - this is a public repository
- All file paths should be **absolute** when referencing in responses
- When suggesting changes, show both the **file content** and the **git workflow** to apply it
