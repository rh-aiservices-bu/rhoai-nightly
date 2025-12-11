#!/usr/bin/env bash
#
# create-icsp.sh - Create ImageContentSourcePolicy for RHOAI registry mirroring
#
# Usage:
#   ./create-icsp.sh
#
# Note: This will trigger a node rollout (~5-10 min)

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "Connected to: $(oc whoami --show-server)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if oc get imagecontentsourcepolicy quay-registry &>/dev/null; then
    log_info "ICSP 'quay-registry' already exists, updating if needed"
fi

log_info "Applying ImageContentSourcePolicy..."
oc apply -f "$REPO_ROOT/bootstrap/icsp/icsp.yaml"

log_info "ICSP applied!"
log_warn "Nodes will restart to apply the new mirror configuration."
log_warn "Monitor with:"
log_warn "  oc get nodes -w"
log_warn "  oc get mcp"
