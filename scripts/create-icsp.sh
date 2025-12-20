#!/usr/bin/env bash
#
# create-icsp.sh - Create ImageContentSourcePolicy for RHOAI registry mirroring
#
# Usage:
#   ./create-icsp.sh
#
# TODO: Consider migrating to IDMS (ImageDigestMirrorSet) for OpenShift 4.14+

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
log_info "Waiting for MachineConfigPools to update..."

# Wait for MCPs to start updating
sleep 10

# Wait for both master and worker MCPs to be Updated
# Use a loop with timeout since MCP updates can take a while
TIMEOUT=1200  # 20 minutes
INTERVAL=30
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    MASTER_UPDATED=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "Unknown")
    WORKER_UPDATED=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "Unknown")
    MASTER_UPDATING=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
    WORKER_UPDATING=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")

    log_info "MCP Status - master: Updated=$MASTER_UPDATED Updating=$MASTER_UPDATING | worker: Updated=$WORKER_UPDATED Updating=$WORKER_UPDATING"

    if [[ "$MASTER_UPDATED" == "True" && "$WORKER_UPDATED" == "True" ]]; then
        log_info "All MachineConfigPools updated successfully!"
        oc get mcp
        oc get nodes
        exit 0
    fi

    # If no worker MCP exists yet (SNO), just wait for master
    if [[ "$WORKER_UPDATED" == "Unknown" && "$MASTER_UPDATED" == "True" ]]; then
        log_info "Master MCP updated (no worker MCP exists)"
        oc get mcp
        oc get nodes
        exit 0
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

log_warn "Timeout waiting for MCP updates after $TIMEOUT seconds"
log_warn "Current MCP status:"
oc get mcp
log_warn "You may need to wait longer or check for issues with: oc describe mcp"
exit 1
