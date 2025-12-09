#!/usr/bin/env bash
#
# bootstrap-gitops.sh - Install OpenShift GitOps and configure ArgoCD
#
# Usage:
#   ./bootstrap-gitops.sh
#
# Environment variables (can also be set in .env):
#   GITOPS_REPO_URL  - Git repository URL (default: https://github.com/cfchase/rhoai-nightly)
#   GITOPS_BRANCH    - Git branch (default: main)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults (can be overridden by env vars)
GITOPS_REPO_URL="${GITOPS_REPO_URL:-https://github.com/cfchase/rhoai-nightly}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"

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
log_info "GitOps Repo: $GITOPS_REPO_URL"
log_info "GitOps Branch: $GITOPS_BRANCH"

# Step 1: Install GitOps Operator
log_step "Installing OpenShift GitOps operator..."
until oc apply -k "$REPO_ROOT/bootstrap/gitops-operator/" 2>/dev/null; do
    log_info "Waiting for CRDs... retrying in 2s"
    sleep 2
done

# Step 2: Wait for Operator
log_step "Waiting for GitOps operator..."
for i in {1..60}; do
    CSV=$(oc get csv -n openshift-gitops-operator -o name 2>/dev/null | grep gitops || true)
    if [[ -n "$CSV" ]]; then
        PHASE=$(oc get "$CSV" -n openshift-gitops-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$PHASE" == "Succeeded" ]]; then
            log_info "GitOps operator ready"
            break
        fi
    fi
    echo -n "."
    sleep 5
done
echo

# Step 3: Wait for namespace
log_step "Waiting for openshift-gitops namespace..."
for i in {1..30}; do
    if oc get namespace openshift-gitops &>/dev/null; then
        break
    fi
    sleep 2
done

# Step 4: Apply ArgoCD Instance
log_step "Applying ArgoCD instance..."
until oc apply -k "$REPO_ROOT/bootstrap/argocd-instance/" 2>/dev/null; do
    sleep 2
done

# Step 5: Wait for ArgoCD Server
log_step "Waiting for ArgoCD server..."
oc wait --for=condition=Available deployment/openshift-gitops-server \
    -n openshift-gitops --timeout=300s 2>/dev/null || log_warn "Timeout, continuing..."

# Step 6: Apply Root Application (with repo URL substitution)
log_step "Applying root Application..."
export GITOPS_REPO_URL GITOPS_BRANCH
envsubst < "$REPO_ROOT/bootstrap/root-app/root-app-template.yaml" | oc apply -f -

log_info "Bootstrap complete!"
ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
log_info "ArgoCD Console: https://$ROUTE"
