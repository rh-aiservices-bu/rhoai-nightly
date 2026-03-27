# MaaS (Models as a Service) Installation Design

**Date:** 2026-03-24
**Status:** Draft

## Overview

Add MaaS support to the rhoai-nightly cluster and tooling. MaaS enables serving LLM models via a managed API with rate limiting and API key authentication, built on top of KServe and Authorino.

Three deliverables:
1. **`scripts/install-maas.sh`** — imperative script for clusters with RHOAI already installed
2. **GitOps manifests** — permanent configuration for bu-nightly cluster
3. **`install-maas` skill** — Claude Code skill that calls the script with monitoring

## Prerequisites

MaaS requires RHOAI and connectivity-link to be installed and running. The script assumes `install-rhoai` (or `make all`) has already completed successfully.

Specifically:
- RHOAI operator installed, DSC exists and healthy
- Connectivity Link / Kuadrant operator installed, Authorino running in `kuadrant-system`
- ArgoCD managing the cluster
- Base infrastructure in place (nodes, pull-secret, ICSP)

## Deliverable 1: `scripts/install-maas.sh`

### Purpose

Install MaaS on any cluster where RHOAI is already running. Handles the parts that can't be purely declarative (Authorino SSL env vars, dynamic gateway creation with cluster-specific domain).

### Phases

#### Phase 1: Preflight

- Verify `oc` connection
- Confirm RHOAI operator CSV exists in `redhat-ods-operator`
- Confirm DataScienceCluster `default-dsc` exists and has `modelsAsService.managementState: Managed`
- Confirm Authorino is running (check for Authorino CR in `kuadrant-system` namespace)
- Detect cluster domain: `oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'`
- Detect TLS cert name: `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}'`, fallback to `router-certs-default`
- Check if MaaS components already exist (postgres, gateway, maas-api) for idempotency

#### Phase 2: Deploy PostgreSQL

If postgres deployment already exists in `redhat-ods-applications`, skip this phase.

1. **Generate secrets** (imperative, not in git):
   - Generate random password: `openssl rand -base64 24 | tr -d '/+=' | head -c 24`
   - Create `postgres-secret` with `POSTGRES_USER=maas`, `POSTGRES_DB=maas`, `POSTGRES_PASSWORD=<generated>`
   - Create `maas-db-config` with `DB_CONNECTION_URL=postgresql://maas:<password>@postgres.redhat-ods-applications.svc:5432/maas?sslmode=disable`
   - Both created via `oc create secret generic` in `redhat-ods-applications`

2. **Apply postgres resources** from kustomize base:
   ```
   oc apply -k components/instances/maas-instance/base/ -n redhat-ods-applications
   ```
   This applies the Deployment, Service, and PVC (no secrets — those were created in step 1).

Wait for postgres deployment to be Ready (timeout: 120s).

#### Phase 3: Create Gateway

If gateway `maas-default-gateway` already exists in `openshift-ingress`, skip this phase.

Generate the Gateway YAML using detected `CLUSTER_DOMAIN` and `CERT_NAME` values via heredoc/envsubst and apply:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: maas.<cluster-domain>
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: maas.<cluster-domain>
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: <cert-name>
        mode: Terminate
```

Wait for Gateway to be Programmed (timeout: 120s).

#### Phase 4: Configure Authorino SSL

The Authorino service annotation and CR TLS listener config are already managed by GitOps in `connectivity-link-instance`:
- `service-annotation.yaml` sets `service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert`
- `authorino.yaml` has `listener.tls.enabled: true` with `certSecretRef.name: authorino-server-cert`

The only remaining imperative operation is setting SSL environment variables on the Authorino deployment so it trusts the OpenShift service CA when making outbound requests to maas-api:

```
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

This patches the operator-managed deployment directly. The operator may revert this on upgrade; re-running `install-maas.sh` re-applies it.

#### Phase 5: Validate

The RHOAI operator creates the `maas-api` deployment automatically when the DSC has `modelsAsService.managementState: Managed` and a valid Gateway + database exist.

- Wait for `maas-api` deployment to exist and roll out in `redhat-ods-applications` (timeout: 300s)
- Verify Gateway is Programmed
- Verify health endpoint responds (expect HTTP 401 = auth is working, not 500)
- Report MaaS API URL: `https://maas.<cluster-domain>`

### Script Conventions

- Color-coded output (matches existing scripts)
- Idempotent — safe to re-run; each phase checks if resources exist before creating
- `--dry-run` flag: all `oc apply`, `oc create`, `oc patch`, and `oc set env` commands are replaced with `echo` showing the command that would run
- Sources `.env` if present
- Exit on first error (`set -euo pipefail`)

## Deliverable 2: GitOps Manifests

### New Component: `components/instances/maas-instance/`

```
components/instances/maas-instance/
  base/
    kustomization.yaml           # Deployment, Service, PVC only (no secrets)
    postgres-deployment.yaml
    postgres-service.yaml
    postgres-pvc.yaml
  overlays/
    rhoaibu-cluster-nightly/
      kustomization.yaml         # Adds gateway + references base
      maas-gateway.yaml          # Gateway with hardcoded bu-nightly domain
```

**Why base vs overlay?**
- `base/` contains generic postgres resources (no secrets, no cluster-specific values). The script applies these directly via `oc apply -k`.
- `overlays/rhoaibu-cluster-nightly/` adds the gateway with the hardcoded bu-nightly cluster domain and cert name.

**Secrets are NOT in the kustomization.** The `postgres-secret` and `maas-db-config` secrets are created manually (or by the script) before the ArgoCD app syncs. ArgoCD manages the Deployment/Service/PVC but not the secrets. The Deployment references `postgres-secret` via `envFrom`; if the secret doesn't exist, the pod will be in `CreateContainerConfigError` until the secret is created. This is acceptable — the secret is a documented prerequisite.

### DSC Changes (in `rhoai-instance`)

Modify `components/instances/rhoai-instance/base/datasciencecluster.yaml`:

```yaml
kserve:
  managementState: Managed
  nim:
    managementState: Managed
  rawDeploymentServiceConfig: Headed    # Changed from Headless
  modelsAsService:                      # Added
    managementState: Managed
```

These changes are safe without MaaS infrastructure — KServe just creates Services for raw deployments (Headed), and the modelsAsService controller starts but has no Gateway to route through.

### ApplicationSet Update

Add entry to `components/argocd/apps/cluster-oper-instances-appset.yaml`:

```yaml
- cluster: local
  values:
    name: instance-maas
    path: components/instances/maas-instance/overlays/rhoaibu-cluster-nightly
    namespace: openshift-gitops
```

Note: The ApplicationSet uses `applicationsSync: create-only`. Adding a new list element creates a new Application automatically. After committing this change, the root application may need a sync to pick up the ApplicationSet change: `make sync-app APP=cluster-config` or `oc apply -f components/argocd/apps/cluster-oper-instances-appset.yaml`.

### Authorino TLS

The service annotation and CR TLS config are already in `connectivity-link-instance` GitOps manifests. No changes needed there.

The SSL env var patching (Phase 4 of the script) is not in GitOps because it patches an operator-managed deployment. For bu-nightly, this is applied by running `scripts/install-maas.sh` once after the GitOps resources are synced, or re-applied after operator upgrades.

### Makefile Target

Add to `Makefile`:

```makefile
maas:
	@scripts/install-maas.sh
```

### ArgoCD Permissions

The Gateway is created in `openshift-ingress`. The ArgoCD instance on bu-nightly has cluster-admin, so no additional RBAC is needed.

## Deliverable 3: `install-maas` Skill

### Metadata

```yaml
name: install-maas
description: >
  Install MaaS on a connected OpenShift cluster with RHOAI already running.
  Deploys PostgreSQL, creates the Gateway, configures Authorino TLS,
  and validates MaaS API is healthy.
argument-hint: "[--dry-run]"
allowed-tools: >
  Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *),
  Bash(echo *), Bash(ls *), Bash(date *), Bash(LOGDIR=*),
  Bash(for *), AskUserQuestion
```

### Execution Flow

1. **Preflight** — run cluster checks in parallel:
   - `oc whoami --show-server`
   - `oc get csv -n redhat-ods-operator | grep rhods`
   - `oc get datascienceclusters`
   - `oc get authorino -n kuadrant-system`
   - `oc get deployment maas-api -n redhat-ods-applications` (check if already installed)

2. **Run script** — `make maas` in background with log capture:
   ```
   LOGDIR=.tmp/logs/install-maas-$(date +%Y%m%d-%H%M%S)
   mkdir -p $LOGDIR
   make maas 2>&1 | tee $LOGDIR/install-maas.log
   ```

3. **Monitor** — while script runs, check:
   - `oc get deployment postgres -n redhat-ods-applications`
   - `oc get gateway maas-default-gateway -n openshift-ingress`
   - `oc get deployment maas-api -n redhat-ods-applications`

4. **Final report** — summarize:
   - MaaS API URL
   - PostgreSQL status
   - Gateway status
   - maas-api deployment status
   - Any warnings or errors
   - Log file location

## Files Changed/Created

### New Files
- `scripts/install-maas.sh`
- `components/instances/maas-instance/base/kustomization.yaml`
- `components/instances/maas-instance/base/postgres-deployment.yaml`
- `components/instances/maas-instance/base/postgres-service.yaml`
- `components/instances/maas-instance/base/postgres-pvc.yaml`
- `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/kustomization.yaml`
- `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/maas-gateway.yaml`
- `.claude/skills/install-maas/SKILL.md`

### Modified Files
- `components/instances/rhoai-instance/base/datasciencecluster.yaml` — add Headed + modelsAsService
- `components/argocd/apps/cluster-oper-instances-appset.yaml` — add maas-instance entry
- `Makefile` — add `maas` target
- `.claude/settings.local.json` — add `Skill(install-maas)` to allow list

## Open Items

1. **Postgres credentials for bu-nightly** — manual secret creation documented as prerequisite. Can switch to ExternalSecrets later if desired.
2. **Authorino SSL env var persistence** — operator may revert the env var patch on upgrade. Re-running `scripts/install-maas.sh` re-applies it. Could add a post-upgrade hook later.

## References

- [MaaS Setup Guide](https://opendatahub-io.github.io/models-as-a-service/dev/install/maas-setup/)
- [MaaS TLS Configuration](https://opendatahub-io.github.io/models-as-a-service/dev/configuration-and-management/tls-configuration/)
- [Upstream MaaS Repository](https://github.com/opendatahub-io/models-as-a-service)
