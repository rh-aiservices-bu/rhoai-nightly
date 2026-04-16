#!/usr/bin/env bash
#
# uninstall-maas.sh - Remove MaaS resources
#
# This script removes:
#   - Authorino SSL env vars
#   - instance-maas ArgoCD Application (cascade-deletes Gateway, GatewayClass, PostgreSQL)
#   - PostgreSQL secrets (not managed by Helm)
#   - Stale DNS records from LoadBalancer
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
# Phase 2: Delete instance-maas ArgoCD Application
# =============================================================================
log_step "Phase 2: Delete instance-maas ArgoCD Application"

if oc get application.argoproj.io/instance-maas -n openshift-gitops &>/dev/null; then
    run_cmd oc delete application.argoproj.io/instance-maas -n openshift-gitops
    log_info "instance-maas Application deleted (cascade removes Gateway, GatewayClass, PostgreSQL)"
else
    log_info "instance-maas Application not found, skipping"
fi

# =============================================================================
# Phase 3: Delete PostgreSQL secrets
# =============================================================================
log_step "Phase 3: Delete PostgreSQL secrets"

if oc get secret postgres-creds -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete secret postgres-creds -n "$NAMESPACE"
    log_info "postgres-creds deleted"
else
    log_info "postgres-creds not found, skipping"
fi

if oc get secret maas-db-config -n "$NAMESPACE" &>/dev/null; then
    run_cmd oc delete secret maas-db-config -n "$NAMESPACE"
    log_info "maas-db-config deleted"
else
    log_info "maas-db-config not found, skipping"
fi

# =============================================================================
# Phase 4: Clean up stale DNS records
# =============================================================================
log_step "Phase 4: Clean up stale DNS records"

if oc get dnsrecord -n openshift-ingress 2>/dev/null | grep -q maas-default-gateway; then
    log_info "Cleaning up stale DNS record from LoadBalancer..."
    STALE_DNS=$(oc get dnsrecord -n openshift-ingress --no-headers 2>/dev/null | grep maas-default-gateway | awk '{print $1}')
    for record in $STALE_DNS; do
        run_cmd oc delete dnsrecord "$record" -n openshift-ingress
    done
    log_info "Stale DNS records removed"
else
    log_info "No stale DNS records found"
fi

# =============================================================================
# Phase 5: Summary
# =============================================================================
log_step "Phase 5: Summary"

log_info "========================================="
log_info "MaaS Uninstall Summary"
log_info "========================================="
log_info "Removed: Authorino SSL env vars"
log_info "Removed: instance-maas ArgoCD Application"
log_info "  (cascade-deleted: Gateway, GatewayClass, PostgreSQL deployment/service)"
log_info "Removed: postgres-creds, maas-db-config secrets"
log_info "Removed: stale DNS records (if any)"
log_info ""
log_info "NOT removed (operator-managed):"
log_info "  - maas-api, maas-controller deployments"
log_info "  - HTTPRoutes, AuthPolicies"
log_info "  - DataScienceCluster modelsAsService config"
log_info ""
log_info "The operator will clean up its managed resources"
log_info "when it detects the Gateway is gone."
log_info "========================================="
