#!/usr/bin/env bash
#
# configure-rhoai.sh - Configure RHOAI operator channel and catalog image
#
# Usage:
#   ./configure-rhoai.sh
#
# Environment variables (can also be set in .env):
#   RHOAI_CHANNEL        - Subscription channel (default: fast-3.x)
#   RHOAI_CATALOG_IMAGE  - CatalogSource image (default: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.3-nightly)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
RHOAI_CHANNEL="${RHOAI_CHANNEL:-fast-3.x}"
RHOAI_CATALOG_IMAGE="${RHOAI_CATALOG_IMAGE:-quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.3-nightly}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

log_step "Configuring RHOAI operator..."
log_info "  Channel: $RHOAI_CHANNEL"
log_info "  Catalog Image: $RHOAI_CATALOG_IMAGE"
echo ""

# Update patch-channel.yaml
PATCH_CHANNEL="$REPO_ROOT/components/operators/rhoai-operator/base/patch-channel.yaml"
if [[ -f "$PATCH_CHANNEL" ]]; then
    # Replace any existing channel value (handles fast-3.x, beta, alpha, stable, etc.)
    sed -i '' "s|value: [a-z0-9.-]*$|value: $RHOAI_CHANNEL|g" "$PATCH_CHANNEL"
    log_info "Updated: $PATCH_CHANNEL"
fi

# Update catalogsource.yaml
CATALOG_SOURCE="$REPO_ROOT/components/operators/rhoai-operator/base/catalogsource.yaml"
if [[ -f "$CATALOG_SOURCE" ]]; then
    # Update image
    sed -i '' "s|image: quay.io/rhoai/rhoai-fbc-fragment:.*|image: $RHOAI_CATALOG_IMAGE|g" "$CATALOG_SOURCE"

    # Extract version from image tag for display name
    # e.g., "rhoai-3.4-ea.2-nightly" -> "3.4 Ea.2"
    IMAGE_TAG="${RHOAI_CATALOG_IMAGE##*:}"
    # Remove "rhoai-" prefix and "-nightly" suffix, replace "-" with " "
    DISPLAY_VERSION=$(echo "$IMAGE_TAG" | sed 's/^rhoai-//; s/-nightly$//; s/-/ /g' | sed 's/\bea\b/EA/g')
    sed -i '' "s|displayName: RHOAI.*|displayName: RHOAI $DISPLAY_VERSION Nightly|g" "$CATALOG_SOURCE"

    log_info "Updated: $CATALOG_SOURCE"
fi

echo ""
log_info "Configuration complete!"
echo ""
log_info "Review changes with: git diff"
log_info "Commit with: git add -A && git commit -m 'Configure RHOAI: $RHOAI_CHANNEL'"
echo ""
log_warn "If ArgoCD is already running, also run:"
log_warn "  make refresh-apps      # Refresh from git"
log_warn "  make restart-catalog   # Restart catalog pod to pull new image"
