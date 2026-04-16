#!/usr/bin/env bash
#
# install-maas.sh - Install MaaS (Models as a Service) on an RHOAI cluster
#
# This script handles the imperative parts of MaaS setup:
#   - PostgreSQL secrets (generated password)
#   - ArgoCD Application for Helm chart (Gateway, GatewayClass, PostgreSQL)
#   - Authorino SSL env vars
#
# The Helm chart (components/instances/maas-instance/chart/) manages:
#   - PostgreSQL deployment and service
#   - GatewayClass and Gateway (with cluster-specific values)
#
# Prerequisites:
#   - RHOAI operator installed and DataScienceCluster created
#   - Authorino deployed in kuadrant-system namespace
#   - ArgoCD running with at least one synced application
#
# Usage:
#   ./install-maas.sh [OPTIONS]
#
# Options:
#   --dry-run         Preview without applying
#   -h, --help        Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run         Preview without applying
  -h, --help        Show this help message
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# =============================================================================
# Phase 1: Preflight checks
# =============================================================================
log_step "Phase 1: Preflight checks"

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# Check RHOAI CSV
if ! oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods >/dev/null; then
    log_error "RHOAI operator not found"
    exit 1
fi
log_info "RHOAI operator found"

# Check DSC exists
oc get datasciencecluster default-dsc &>/dev/null || { log_error "DataScienceCluster not found"; exit 1; }
log_info "DataScienceCluster found"

# Check DSC modelsAsService
MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)
if [ "$MAAS_STATE" != "Managed" ]; then
    log_warn "modelsAsService managementState is '${MAAS_STATE:-not set}' (expected 'Managed')"
    log_warn "The DSC change should be synced via ArgoCD before running this script"
else
    log_info "modelsAsService managementState: Managed"
fi

# Check Authorino
oc get authorino authorino -n kuadrant-system &>/dev/null || { log_error "Authorino not found in kuadrant-system"; exit 1; }
log_info "Authorino found in kuadrant-system"

# Detect cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
log_info "Cluster domain: ${CLUSTER_DOMAIN}"

# Detect TLS certificate name
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
[ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
log_info "TLS certificate: ${CERT_NAME}"

# Detect repo URL and branch from existing ArgoCD apps
REPO_URL="${GITOPS_REPO_URL:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || echo "")}"
BRANCH="${GITOPS_BRANCH:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "")}"

if [ -z "$REPO_URL" ] || [ -z "$BRANCH" ]; then
    log_error "Could not detect repo URL or branch from ArgoCD. Set GITOPS_REPO_URL and GITOPS_BRANCH env vars."
    exit 1
fi
log_info "GitOps repo: ${REPO_URL} @ ${BRANCH}"

NAMESPACE=redhat-ods-applications
log_info "Target namespace: ${NAMESPACE}"

# =============================================================================
# Phase 2: Create PostgreSQL secrets
# =============================================================================
log_step "Phase 2: Create PostgreSQL secrets"

if ! oc get secret postgres-creds -n "$NAMESPACE" &>/dev/null; then
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

    run_cmd oc create secret generic postgres-creds \
      -n "$NAMESPACE" \
      --from-literal=POSTGRES_USER=maas \
      --from-literal=POSTGRES_DB=maas \
      --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
    log_info "Created postgres-creds"

    # Create DB connection URL secret (used by maas-api)
    run_cmd oc create secret generic maas-db-config \
      -n "$NAMESPACE" \
      --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
    log_info "Created maas-db-config"
else
    log_info "postgres-creds already exists, skipping secret creation"
fi

# =============================================================================
# Phase 3: Create/update instance-maas ArgoCD Application
# =============================================================================
log_step "Phase 3: Create/update instance-maas ArgoCD Application"

log_info "Applying instance-maas Application (Helm source)..."
run_cmd oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: instance-maas
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: components/instances/maas-instance/chart
    helm:
      values: |
        clusterDomain: ${CLUSTER_DOMAIN}
        certName: ${CERT_NAME}
        namespace: ${NAMESPACE}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 3m
EOF

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping ArgoCD sync wait"
else
    log_info "Waiting for ArgoCD to sync..."
    TIMEOUT=180
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        SYNC_STATUS=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        HEALTH=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        if [ "$SYNC_STATUS" = "Synced" ]; then
            log_info "ArgoCD sync complete (health: ${HEALTH})"
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            log_info "Waiting for sync... (${ELAPSED}s, status: ${SYNC_STATUS}, health: ${HEALTH})"
        fi
    done

    if [ "$SYNC_STATUS" != "Synced" ]; then
        log_warn "ArgoCD sync did not complete within ${TIMEOUT}s (status: ${SYNC_STATUS})"
    fi

    # Wait for Gateway to be programmed
    log_info "Waiting for Gateway to be programmed..."
    oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=180s 2>/dev/null || \
        log_warn "Gateway did not reach Programmed state within 180s"
    log_info "Gateway programmed"
fi

# =============================================================================
# Phase 4: Configure Authorino SSL env vars
# =============================================================================
log_step "Phase 4: Configure Authorino SSL env vars"

EXISTING_ENVS=$(oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null)

if echo "$EXISTING_ENVS" | grep -q "SSL_CERT_FILE"; then
    log_info "Authorino SSL already configured, skipping"
else
    run_cmd oc -n kuadrant-system set env deployment/authorino \
      SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
      REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

    log_info "Authorino SSL configured"
fi

# =============================================================================
# Phase 5: Validate MaaS deployment
# =============================================================================
log_step "Phase 5: Validate MaaS deployment"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping validation"
    log_info "========================================="
    log_info "MaaS Installation Summary (DRY RUN)"
    log_info "========================================="
    log_info "MaaS API URL: https://maas.${CLUSTER_DOMAIN}"
    log_info "All phases completed in dry-run mode"
    log_info "========================================="
    exit 0
fi

log_info "Waiting for maas-api deployment (this may take several minutes)..."
TIMEOUT=300
ELAPSED=0
MAAS_API_FOUND=false
RETRIGGER_DONE=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    if oc get deployment maas-api -n "$NAMESPACE" &>/dev/null; then
        log_info "maas-api deployment found"
        MAAS_API_FOUND=true
        break
    fi

    # Check for Gateway/ModelsAsService race condition:
    # The operator may have checked for the Gateway before ArgoCD created it,
    # cached the error, and stopped reconciling. Trigger re-reconciliation once.
    if [ "$RETRIGGER_DONE" = false ] && [ $ELAPSED -ge 60 ]; then
        MAAS_STATUS=$(oc get modelsasservice default-modelsasservice -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        MAAS_MSG=$(oc get modelsasservice default-modelsasservice -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [ "$MAAS_STATUS" = "False" ] && echo "$MAAS_MSG" | grep -q "gateway.*not found"; then
            log_warn "ModelsAsService has stale 'gateway not found' error — triggering re-reconciliation"
            oc annotate modelsasservice default-modelsasservice reconcile-trigger="$(date +%s)" --overwrite 2>/dev/null || true
            RETRIGGER_DONE=true
        fi
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        log_info "Still waiting for maas-api... (${ELAPSED}s elapsed)"
    fi
done

if [ "$MAAS_API_FOUND" = true ]; then
    oc rollout status deployment/maas-api -n "$NAMESPACE" --timeout=180s || log_warn "maas-api rollout did not complete within 180s"
else
    log_warn "maas-api deployment not found after ${TIMEOUT}s. The operator may still be reconciling."
fi

# Check Gateway status
GATEWAY_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")

# Test health endpoint (may need DNS propagation time for LoadBalancer)
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://maas.${CLUSTER_DOMAIN}/maas-api/health" 2>/dev/null || echo "000")

log_info "========================================="
log_info "MaaS Installation Summary"
log_info "========================================="
log_info "MaaS API URL: https://maas.${CLUSTER_DOMAIN}"
log_info "PostgreSQL:   deployed in ${NAMESPACE}"
log_info "Gateway:      Programmed=${GATEWAY_STATUS}"
log_info "Health check: HTTP ${HTTP_CODE}"
if [ "$HTTP_CODE" = "401" ]; then
    log_info "Auth is working (401 = unauthenticated request rejected)"
elif [ "$HTTP_CODE" = "000" ]; then
    log_info "Health check failed (DNS may still be propagating for LoadBalancer)"
    log_info "ELB DNS typically takes 2-5 minutes to propagate"
fi
log_info "========================================="
