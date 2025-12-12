#!/usr/bin/env bash
#
# scale-machineset.sh - Scale a MachineSet by name
#
# Usage:
#   ./scale-machineset.sh --name <machineset-name> --replicas <N|+N|-N> [--wait]
#
# Examples:
#   ./scale-machineset.sh --name cluster-abc-gpu-worker-us-east-2a --replicas 2
#   ./scale-machineset.sh --name cluster-abc-cpu-worker-us-east-2b --replicas +1
#   ./scale-machineset.sh --name cluster-abc-gpu-worker-us-east-2a --replicas -1 --wait

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

NAME=""
REPLICAS=""
WAIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) NAME="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --wait) WAIT=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 --name <machineset-name> --replicas <N|+N|-N> [--wait]

Scale a MachineSet by exact name.

Options:
  --name NAME        Exact MachineSet name
  --replicas N       Target replica count (absolute: 2, relative: +1 or -1)
  --wait             Wait for nodes to reach Ready state

Examples:
  $0 --name cluster-abc-gpu-worker-us-east-2a --replicas 2
  $0 --name cluster-abc-cpu-worker-us-east-2b --replicas +1
  $0 --name cluster-abc-gpu-worker-us-east-2a --replicas 0 --wait
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required parameters
if [[ -z "$NAME" ]]; then
    log_error "Missing required parameter: --name"
    exit 1
fi

if [[ -z "$REPLICAS" ]]; then
    log_error "Missing required parameter: --replicas"
    exit 1
fi

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "Connected to: $(oc whoami --show-server)"

# Verify MachineSet exists
if ! oc get machineset "$NAME" -n openshift-machine-api &>/dev/null; then
    log_error "MachineSet not found: $NAME"
    log_info "Available MachineSets:"
    oc get machineset -n openshift-machine-api -o name | sed 's/machineset.machine.openshift.io\//  /'
    exit 1
fi

# Get current replica count
CURRENT=$(oc get machineset "$NAME" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
log_info "Current replicas: $CURRENT"

# Calculate target replicas
if [[ "$REPLICAS" =~ ^[+-] ]]; then
    # Relative: +N or -N
    TARGET=$((CURRENT + REPLICAS))
else
    # Absolute
    TARGET=$REPLICAS
fi

# Validate target
if [[ $TARGET -lt 0 ]]; then
    log_error "Target replicas cannot be negative: $TARGET"
    exit 1
fi

if [[ $TARGET -eq $CURRENT ]]; then
    log_info "Already at $CURRENT replicas, nothing to do"
    exit 0
fi

log_info "Scaling $NAME: $CURRENT → $TARGET replicas"

# Scale the MachineSet
oc scale machineset "$NAME" -n openshift-machine-api --replicas="$TARGET"

log_info "Scale command issued"

# Wait for nodes if requested
if [[ "$WAIT" == "true" ]]; then
    log_info "Waiting for nodes to be Ready..."

    # Wait up to 10 minutes
    for i in {1..60}; do
        READY=$(oc get machineset "$NAME" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        READY=${READY:-0}

        if [[ "$READY" -ge "$TARGET" ]]; then
            log_info "All $TARGET nodes are Ready"
            oc get machineset "$NAME" -n openshift-machine-api
            exit 0
        fi

        echo -n "."
        sleep 10
    done

    echo
    log_warn "Timeout waiting for nodes ($READY/$TARGET ready)"
    oc get machineset "$NAME" -n openshift-machine-api
    exit 1
fi

log_info "Monitor with: oc get machines -n openshift-machine-api -w | grep $NAME"
