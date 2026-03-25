#!/usr/bin/env bash
#
# uninstall-maas.sh - Remove MaaS resources created by install-maas.sh
#
# This script removes the imperative resources that install-maas.sh creates:
#   - PostgreSQL deployment, service, PVC, and secrets
#   - MaaS Gateway and GatewayClass
#   - Authorino SSL env vars
#
# It does NOT modify:
#   - DataScienceCluster (modelsAsService config stays in GitOps)
#   - Operator-managed resources (maas-api, maas-controller, HTTPRoutes, AuthPolicies)
#     These will be cleaned up by the operator when the Gateway is removed.
#
# Usage:
#   ./uninstall-maas.sh [OPTIONS]
#
# Options:
#   --dry-run         Preview without applying
#   -h, --help        Show this help message
#

set -euo pipefail

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

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

NAMESPACE=redhat-ods-applications

# =============================================================================
# Phase 1: Remove Authorino SSL env vars
# =============================================================================
log_step "Phase 1: Remove Authorino SSL env vars"

EXISTING_ENVS=$(oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")

if echo "$EXISTING_ENVS" | grep -q "SSL_CERT_FILE"; then
    run_cmd oc -n kuadrant-system set env deployment/authorino SSL_CERT_FILE- REQUESTS_CA_BUNDLE-
    log_info "Authorino SSL env vars removed"
else
    log_info "Authorino SSL env vars not set, skipping"
fi

# =============================================================================
# Phase 2: Remove MaaS Gateway
# =============================================================================
log_step "Phase 2: Remove MaaS Gateway"

if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null; then
    run_cmd oc delete gateway maas-default-gateway -n openshift-ingress
    log_info "Gateway deleted"
else
    log_info "Gateway not found, skipping"
fi

if oc get gatewayclass openshift-default &>/dev/null; then
    run_cmd oc delete gatewayclass openshift-default
    log_info "GatewayClass deleted"
else
    log_info "GatewayClass not found, skipping"
fi

# =============================================================================
# Phase 3: Remove PostgreSQL
# =============================================================================
log_step "Phase 3: Remove PostgreSQL"

if oc get deployment postgres -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete deployment postgres -n "$NAMESPACE"
    log_info "PostgreSQL deployment deleted"
else
    log_info "PostgreSQL deployment not found, skipping"
fi

if oc get service postgres -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete service postgres -n "$NAMESPACE"
    log_info "PostgreSQL service deleted"
else
    log_info "PostgreSQL service not found, skipping"
fi

if oc get pvc postgres-pvc -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete pvc postgres-pvc -n "$NAMESPACE"
    log_info "PostgreSQL PVC deleted"
else
    log_info "PostgreSQL PVC not found, skipping"
fi

if oc get secret postgres-secret -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete secret postgres-secret -n "$NAMESPACE"
    log_info "postgres-secret deleted"
else
    log_info "postgres-secret not found, skipping"
fi

if oc get secret maas-db-config -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete secret maas-db-config -n "$NAMESPACE"
    log_info "maas-db-config deleted"
else
    log_info "maas-db-config not found, skipping"
fi

# =============================================================================
# Phase 4: Summary
# =============================================================================
log_step "Phase 4: Summary"

log_info "========================================="
log_info "MaaS Uninstall Summary"
log_info "========================================="
log_info "Removed: Authorino SSL env vars"
log_info "Removed: maas-default-gateway (openshift-ingress)"
log_info "Removed: openshift-default GatewayClass"
log_info "Removed: PostgreSQL deployment, service, PVC"
log_info "Removed: postgres-secret, maas-db-config"
log_info ""
log_info "NOT removed (operator-managed):"
log_info "  - maas-api, maas-controller deployments"
log_info "  - HTTPRoutes, AuthPolicies"
log_info "  - DataScienceCluster modelsAsService config"
log_info ""
log_info "The operator will clean up its managed resources"
log_info "when it detects the Gateway is gone."
log_info "========================================="
