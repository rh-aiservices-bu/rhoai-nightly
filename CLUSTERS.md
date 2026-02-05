# RHOAI Clusters Branch

This document describes the `clusters` branch, which extends `main` with production-ready features for managing RHOAI deployments on specific clusters.

## Overview

The `clusters` branch provides:
- **Pinned catalog images** for reproducible deployments
- **Cluster-specific overlays** with RBAC, Gateway, and MaaS configs
- **Console notifications** for cluster identification
- **Safe upgrade procedures** for production environments

## Branch Differences

| Aspect | main | clusters |
|--------|------|----------|
| RHOAI Catalog | Floating nightly tag | Pinned SHA256 digest |
| RBAC Config | None | Admin groups + ClusterRoleBinding |
| Gateway | None | Inference gateway for LLM endpoints |
| MaaS | None | Model-as-a-Service namespace |
| Target Revision | main | clusters |
| ApplicationSets | 2 (operators, instances) | 3 (+ cluster-config) |

## Repository Structure (clusters branch additions)

```
clusters/overlays/
├── default/                          # Generic fallback overlay
└── rhoaibu-cluster-nightly/          # Production cluster overlay
    ├── kustomization.yaml            # Cluster customizations
    ├── console-notification/         # Cluster identity banner
    └── patch-cluster-config-appset.yaml

components/configs/
├── rbac/                             # Admin groups and bindings
│   ├── base/
│   └── overlays/rhoaibu-cluster-nightly/
├── gateway/                          # Inference gateway for LLMs
│   ├── base/
│   └── overlays/rhoaibu-cluster-nightly/
└── maas/                             # Model-as-a-Service billing
    ├── base/
    └── overlays/rhoaibu-cluster-nightly/

components/operators/rhoai-operator/
├── base/                             # Floating nightly catalog
└── overlays/pinned/                  # SHA256-pinned catalog
```

## Pinned vs Floating Catalog

### Floating (base/) - For Development/Testing
```yaml
image: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.3-nightly
```
- Updates every 15 minutes via registry polling
- Always uses the latest nightly build
- May introduce unexpected changes

### Pinned (overlays/pinned/) - For Production
```yaml
image: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.3@sha256:b200365c...
```
- Uses exact image digest
- Reproducible deployments
- Controlled upgrade timing

## Configuration Components

### RBAC (`components/configs/rbac/`)
Manages cluster access control:
- `cluster-admin-extra` group - Additional cluster admins
- `rhods-admins` group - RHOAI-specific admins
- ClusterRoleBinding for cluster-admin role

### Gateway (`components/configs/gateway/`)
Provides HTTPS ingress for AI inference:
- Gateway resource in `openshift-ingress` namespace
- GatewayClass for Kuadrant/Connectivity Link
- TLS certificate configuration per cluster

### MaaS (`components/configs/maas/`)
Model-as-a-Service billing infrastructure:
- Namespace for MaaS components
- GatewayClass configuration

## Upgrading RHOAI

### Pre-Upgrade Checklist

```bash
# Verify cluster health
make check
make status

# Check current RHOAI version
oc get csv -n redhat-ods-operator

# Verify all apps are healthy
oc get applications.argoproj.io -n openshift-gitops
```

### Safe Upgrade Steps

**Files to update:**

| File | What to change |
|------|----------------|
| `components/operators/rhoai-operator/overlays/pinned/kustomization.yaml` | Update image SHA256 digest and date comment |
| `clusters/overlays/<cluster>/console-notification/base/console-notification.yaml` | Update banner text with new date |

**Tip:** Get the image creation date with:
```bash
docker pull quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest>
docker inspect quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest> | jq -r '.[0].Created'
```

```bash
# 1. Disable auto-sync to prevent race conditions
make sync-disable

# 2. Update files in git (see table above)
#    - Pinned catalog image: components/operators/rhoai-operator/overlays/pinned/kustomization.yaml
#    - Console notification: clusters/overlays/<cluster>/console-notification/base/console-notification.yaml

# 3. Commit and push
git add components/operators/rhoai-operator/ clusters/overlays/
git commit -m "Upgrade RHOAI to <date> nightly build"
git push

# 4. Sync all apps (applies new CatalogSource from git)
make sync
# This syncs rhoai-operator first, which updates the CatalogSource spec

# 5. Restart catalog pod (forces immediate image pull)
make restart-catalog
# Restarts catalog pod to pull new image, then restarts operator

# 6. Monitor the operator upgrade
oc get csv -n redhat-ods-operator -w
# Wait for new CSV to reach "Succeeded" phase

# 7. Verify RHOAI deployment
oc get datascienceclusters
oc get pods -n redhat-ods-applications

# 8. Re-enable auto-sync
make sync-enable
```

**Important:** Sync must happen BEFORE restart-catalog. The sync applies the new CatalogSource
image from git, then restart-catalog restarts the pod to pull it.

### Rollback Procedure

```bash
# Revert the catalog change
git revert HEAD
git push

# Sync to apply reverted CatalogSource, then restart catalog
make sync
make restart-catalog

# Verify rollback
oc get csv -n redhat-ods-operator
```

## Troubleshooting

### DSCInitialization Not Ready
**Symptom:** `instance-rhoai` app stuck waiting for DSCInitialization

**Cause:** Operator restart resets the initialization state

**Fix:**
```bash
# Wait for operator to stabilize
oc get pods -n redhat-ods-operator -w

# Re-sync the instance
make sync-app APP=instance-rhoai
```

### CRD Not Found Errors
**Symptom:** ArgoCD reports "CRD not found" during sync

**Cause:** New operator version introduces new CRDs that aren't available yet

**Fix:**
```bash
# Sync operator first to install CRDs
make sync-app APP=rhoai-operator

# Then sync instance
make sync-app APP=instance-rhoai
```

### Pods Stuck Terminating
**Symptom:** Old pods won't terminate during upgrade

**Cause:** Finalizers or PodDisruptionBudgets blocking deletion

**Fix:**
```bash
# Check PDBs
oc get pdb -n redhat-ods-applications

# Check pod finalizers
oc get pod <pod-name> -n redhat-ods-applications -o jsonpath='{.metadata.finalizers}'

# Force delete if needed (use with caution)
oc delete pod <pod-name> -n redhat-ods-applications --force --grace-period=0
```

### instance-nvidia OutOfSync
**Symptom:** `instance-nvidia` app shows OutOfSync but Healthy

**Cause:** ClusterPolicy drift - NVIDIA operator adds default fields not in git

**Fix:** This is expected behavior. The app is Healthy, and the OutOfSync is cosmetic. ArgoCD will continue attempting to sync (see `autoHealAttemptsCount` in app status).

### Catalog Pod Not Pulling New Image
**Symptom:** `make restart-catalog` ran but operator version didn't change

**Cause:** Image pull policy or caching

**Fix:**
```bash
# Delete the catalog pod to force re-pull
oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly

# Verify new pod has correct image
oc get pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Creating a New Cluster Overlay

1. **Copy existing overlay as template:**
   ```bash
   cp -r clusters/overlays/rhoaibu-cluster-nightly clusters/overlays/my-cluster
   ```

2. **Update console notification:**
   Edit `clusters/overlays/my-cluster/console-notification/console-notification.yaml`:
   ```yaml
   spec:
     text: "My Cluster - RHOAI 3.3"
   ```

3. **Patch RBAC groups:**
   Create `components/configs/rbac/overlays/my-cluster/` with patches for your admin users.

4. **Patch Gateway:**
   Create `components/configs/gateway/overlays/my-cluster/` with:
   - Your cluster's domain name
   - TLS certificate secret reference

5. **Update ApplicationSet patch:**
   Edit `clusters/overlays/my-cluster/patch-cluster-config-appset.yaml` to point to your overlays.

6. **Apply:**
   ```bash
   oc apply -k clusters/overlays/my-cluster
   make sync-configs
   ```

## Related Documentation

- `README.md` - General repository documentation
- `CLAUDE.md` - AI assistant guidance
- [RHOAI Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)
