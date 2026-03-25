#!/usr/bin/env bash
#
# install-maas.sh - Install MaaS (Models as a Service) on an RHOAI cluster
#
# This script handles the imperative parts of MaaS setup that can't be purely
# declarative in GitOps: PostgreSQL secrets, Gateway creation, and Authorino
# SSL configuration.
#
# Based on upstream MaaS documentation and deploy scripts:
#   - MaaS Setup:     https://opendatahub-io.github.io/models-as-a-service/dev/install/maas-setup/
#   - TLS Config:     https://opendatahub-io.github.io/models-as-a-service/dev/configuration-and-management/tls-configuration/
#   - Deploy script:  https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/deploy.sh
#
# Prerequisites:
#   - RHOAI operator installed and DataScienceCluster created
#   - Authorino deployed in kuadrant-system namespace
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

NAMESPACE=redhat-ods-applications
log_info "Target namespace: ${NAMESPACE}"

# =============================================================================
# Phase 2: Deploy PostgreSQL
# Ref: https://opendatahub-io.github.io/models-as-a-service/dev/install/maas-setup/#database-setup
# Upstream: https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-database.sh
# =============================================================================
log_step "Phase 2: Deploy PostgreSQL"

if oc get deployment postgres -n "$NAMESPACE" &>/dev/null; then
    log_info "PostgreSQL already deployed, skipping"
else
    # Generate password
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

    # Create secrets if they don't already exist (idempotent)
    if ! oc get secret postgres-secret -n "$NAMESPACE" &>/dev/null; then
        run_cmd oc create secret generic postgres-secret \
          -n "$NAMESPACE" \
          --from-literal=POSTGRES_USER=maas \
          --from-literal=POSTGRES_DB=maas \
          --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
        log_info "Created postgres-secret"
    else
        log_info "postgres-secret already exists, skipping"
    fi

    if ! oc get secret maas-db-config -n "$NAMESPACE" &>/dev/null; then
        run_cmd oc create secret generic maas-db-config \
          -n "$NAMESPACE" \
          --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
        log_info "Created maas-db-config"
    else
        log_info "maas-db-config already exists, skipping"
    fi

    # Apply PostgreSQL manifests
    run_cmd oc apply -k "$REPO_ROOT/components/instances/maas-instance/base/" -n "$NAMESPACE"

    # Wait for rollout
    run_cmd oc rollout status deployment/postgres -n "$NAMESPACE" --timeout=120s

    log_info "PostgreSQL deployed successfully"
fi

# =============================================================================
# Phase 3: Create MaaS Gateway
# Ref: https://opendatahub-io.github.io/models-as-a-service/dev/install/maas-setup/#create-gateway
# GatewayClass: https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/data/gatewayclass.yaml
# Gateway:      https://github.com/opendatahub-io/models-as-a-service/blob/main/deployment/base/networking/maas/maas-gateway-api.yaml
# =============================================================================
log_step "Phase 3: Create MaaS Gateway"

# Ensure GatewayClass exists (required before creating Gateway)
if oc get gatewayclass openshift-default &>/dev/null; then
    log_info "GatewayClass openshift-default already exists, skipping"
else
    log_info "Creating GatewayClass openshift-default..."
    run_cmd oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: "openshift.io/gateway-controller/v1"
EOF
    log_info "GatewayClass created"
fi

if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null; then
    log_info "Gateway already exists, skipping"
else
    run_cmd oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/component: gateway
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: "maas.${CLUSTER_DOMAIN}"
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: "maas.${CLUSTER_DOMAIN}"
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${CERT_NAME}
        mode: Terminate
EOF

    run_cmd oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=120s

    log_info "Gateway created successfully"
fi

# =============================================================================
# Phase 4: Configure Authorino SSL env vars
# Ref: https://opendatahub-io.github.io/models-as-a-service/dev/configuration-and-management/tls-configuration/#authorino-maas-api-outbound-tls
# Upstream: https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-authorino-tls.sh
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
# Ref: https://opendatahub-io.github.io/models-as-a-service/dev/install/validation/
# =============================================================================
log_step "Phase 5: Validate MaaS deployment"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping validation (no resources were created)"
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
while [ $ELAPSED -lt $TIMEOUT ]; do
    if oc get deployment maas-api -n "$NAMESPACE" &>/dev/null; then
        log_info "maas-api deployment found"
        MAAS_API_FOUND=true
        break
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

# Test health endpoint
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
fi
log_info "========================================="
