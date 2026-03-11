#!/usr/bin/env bash
#
# configure-repo.sh - Update repo URLs for forks
#
# Usage:
#   ./configure-repo.sh
#
# Environment variables (can also be set in .env):
#   GITOPS_REPO_URL  - Git repository URL (default: https://github.com/rh-aiservices-bu/rhoai-nightly)
#   GITOPS_BRANCH    - Git branch (default: main)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
GITOPS_REPO_URL="${GITOPS_REPO_URL:-https://github.com/rh-aiservices-bu/rhoai-nightly}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

log_info "Updating repo URLs to: $GITOPS_REPO_URL"
log_info "Updating branch to: $GITOPS_BRANCH"

# Update ApplicationSets in components/argocd/apps/
for file in "$REPO_ROOT"/components/argocd/apps/*.yaml; do
    if [[ -f "$file" && "$file" != *"kustomization.yaml" ]]; then
        sed -i '' "s|repoURL: https://github.com/[^/]*/rhoai-nightly|repoURL: $GITOPS_REPO_URL|g" "$file"
        sed -i '' "s|revision: main|revision: $GITOPS_BRANCH|g" "$file"
        sed -i '' "s|targetRevision: main|targetRevision: $GITOPS_BRANCH|g" "$file"
        log_info "Updated: $file"
    fi
done

# Update cluster overlay patches
for file in "$REPO_ROOT"/clusters/overlays/rhoaibu-cluster-nightly/patch-*.yaml; do
    if [[ -f "$file" ]]; then
        sed -i '' "s|value: https://github.com/[^/]*/rhoai-nightly|value: $GITOPS_REPO_URL|g" "$file"
        sed -i '' "s|value: main|value: $GITOPS_BRANCH|g" "$file"
        log_info "Updated: $file"
    fi
done

# Update bootstrap cluster-config-app
CLUSTER_CONFIG="$REPO_ROOT/bootstrap/rhoaibu-cluster-nightly/cluster-config-app.yaml"
if [[ -f "$CLUSTER_CONFIG" ]]; then
    sed -i '' "s|repoURL: https://github.com/[^/]*/rhoai-nightly|repoURL: $GITOPS_REPO_URL|g" "$CLUSTER_CONFIG"
    sed -i '' "s|targetRevision: main|targetRevision: $GITOPS_BRANCH|g" "$CLUSTER_CONFIG"
    log_info "Updated: $CLUSTER_CONFIG"
fi

echo ""
log_info "Review changes with: git diff"
log_info "Commit with: git add -A && git commit -m 'Configure for fork'"
