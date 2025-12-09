#!/usr/bin/env bash
#
# add-pull-secret.sh - Add quay.io/rhoai credentials to global pull-secret
#
# Usage:
#   ./add-pull-secret.sh

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

TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

log_info "Extracting current pull-secret..."
oc get secret/pull-secret -n openshift-config \
    --template='{{index .data ".dockerconfigjson" | base64decode}}' > "$TMPFILE"

if grep -q "quay.io/rhoai" "$TMPFILE" 2>/dev/null; then
    log_info "quay.io/rhoai credentials already present"
    exit 0
fi

# Credentials should be passed via environment variables
if [[ -z "${QUAY_USER:-}" ]] || [[ -z "${QUAY_TOKEN:-}" ]]; then
    log_error "QUAY_USER and QUAY_TOKEN environment variables must be set"
    log_error "Example: QUAY_USER=myuser QUAY_TOKEN=mytoken ./add-pull-secret.sh"
    exit 1
fi

log_info "Adding quay.io/rhoai credentials..."
oc registry login --registry=quay.io/rhoai \
    --auth-basic="${QUAY_USER}:${QUAY_TOKEN}" \
    --to="$TMPFILE"

log_info "Updating cluster pull-secret..."
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$TMPFILE"

log_info "Pull secret updated!"
log_info "Verify with: oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'"
