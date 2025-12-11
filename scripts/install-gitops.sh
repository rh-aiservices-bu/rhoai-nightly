#!/usr/bin/env bash
#
# install-gitops.sh - Install OpenShift GitOps operator and ArgoCD
#
# Usage:
#   ./install-gitops.sh

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

# Step 1: Apply GitOps operator subscription
log_step "Installing OpenShift GitOps operator..."
oc apply -k "$REPO_ROOT/bootstrap/gitops-operator/"

# Step 2: Wait for Operator CSV to succeed
log_step "Waiting for GitOps operator to install (this may take 2-3 minutes)..."
TIMEOUT=300
INTERVAL=10
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    CSV=$(oc get csv -n openshift-gitops-operator -o name 2>/dev/null | grep gitops || true)
    if [[ -n "$CSV" ]]; then
        PHASE=$(oc get "$CSV" -n openshift-gitops-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$PHASE" == "Succeeded" ]]; then
            log_info "GitOps operator installed successfully"
            break
        fi
        log_info "Operator CSV phase: $PHASE"
    else
        log_info "Waiting for operator CSV..."
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    log_error "Timeout waiting for GitOps operator"
    exit 1
fi

# Step 3: Wait for openshift-gitops namespace
log_step "Waiting for openshift-gitops namespace..."
for i in {1..30}; do
    if oc get namespace openshift-gitops &>/dev/null; then
        log_info "Namespace openshift-gitops exists"
        break
    fi
    sleep 2
done

# Step 4: Apply ArgoCD instance configuration
log_step "Configuring ArgoCD instance..."
until oc apply -k "$REPO_ROOT/bootstrap/argocd-instance/" 2>/dev/null; do
    log_info "Waiting for ArgoCD CRDs... retrying in 5s"
    sleep 5
done

# Step 5: Wait for ArgoCD Server to be available
log_step "Waiting for ArgoCD server to be ready..."

# First wait for the deployment to exist
for i in {1..60}; do
    if oc get deployment/openshift-gitops-server -n openshift-gitops &>/dev/null; then
        break
    fi
    log_info "Waiting for ArgoCD server deployment to be created..."
    sleep 5
done

# Then wait for it to be ready
oc wait --for=condition=Available deployment/openshift-gitops-server \
    -n openshift-gitops --timeout=300s || {
    log_error "ArgoCD server not ready after 5 minutes"
    exit 1
}

log_info "ArgoCD server is ready!"
ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
log_info "ArgoCD Console: https://$ROUTE"
