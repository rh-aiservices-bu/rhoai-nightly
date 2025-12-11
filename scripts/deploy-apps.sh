#!/usr/bin/env bash
#
# deploy-apps.sh - Deploy the root ArgoCD application
#
# This applies the cluster-config Application which triggers GitOps sync
# of all operators and instances.
#
# Usage:
#   ./deploy-apps.sh

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

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "Connected to: $(oc whoami --show-server)"

# Verify ArgoCD is ready
log_step "Verifying ArgoCD is ready..."
if ! oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
    log_error "ArgoCD not installed. Run 'make gitops' first."
    exit 1
fi

AVAILABLE=$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [[ "$AVAILABLE" != "True" ]]; then
    log_warn "ArgoCD server not fully available, waiting..."
    oc wait --for=condition=Available deployment/openshift-gitops-server \
        -n openshift-gitops --timeout=120s || {
        log_error "ArgoCD server not ready"
        exit 1
    }
fi

log_info "ArgoCD is ready"

# Apply the root application
log_step "Applying cluster-config Application..."
oc apply -f "$REPO_ROOT/bootstrap/rhoaibu-cluster-nightly/cluster-config-app.yaml"

log_info "Root application deployed!"
log_info ""
log_info "The cluster-config app will now sync and deploy all operators."
log_info "This may take 10-15 minutes for all operators to install."
log_info ""
log_info "Monitor progress with:"
log_info "  make status"
log_info "  oc get applications -n openshift-gitops"
