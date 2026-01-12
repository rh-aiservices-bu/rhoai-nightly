# RHOAI 3.2 Nightly GitOps

Deploy RHOAI 3.2 nightly builds using GitOps on OpenShift.

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
- `gpu` - Create GPU MachineSet g5.2xlarge (waits for node Ready)

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
```

## Validation

```bash
make check    # Verify cluster connection
make status   # Show ArgoCD app status
make validate # Full validation
```

## Other Commands

```bash
make refresh                             # Force pull latest nightly images
make scale NAME=<machineset> REPLICAS=N  # Scale a MachineSet
make dedicate-masters                    # Remove worker role from masters
```

## Sync Control

After `make sync`, apps have auto-sync **ON** and will self-heal from git.

```bash
make sync-disable                        # Disable auto-sync (for manual changes)
make sync-enable                         # Re-enable auto-sync
make sync-app APP=<name>                 # Sync single app + enable auto-sync on it
make refresh-apps                        # Refresh and sync all apps (one-time, keeps current sync setting)
```

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
