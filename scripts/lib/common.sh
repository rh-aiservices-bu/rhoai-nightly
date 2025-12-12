#!/usr/bin/env bash
#
# common.sh - Shared functions and constants for rhoai-nightly scripts
#
# Source this file in other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#

# Colors
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export NC='\033[0m'

# Logging functions
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Application sync order (operators first, then instances)
# Used by sync-apps.sh
SYNC_ORDER=(
    # Phase 1: Foundation
    "nfd"
    "instance-nfd"
    "nvidia-operator"
    "instance-nvidia"

    # Phase 2: Dependent Operators
    "openshift-service-mesh"
    "kueue-operator"
    "leader-worker-set"
    "instance-lws"
    "jobset-operator"
    "instance-jobset"
    "connectivity-link"
    "instance-kuadrant"

    # Phase 3: RHOAI
    "rhoai-operator"
    "instance-rhoai"
)

# Cleanup order: reverse of SYNC_ORDER + cluster-config
# Used by desync.sh, undeploy.sh
CLEANUP_ORDER=()
for ((i=${#SYNC_ORDER[@]}-1; i>=0; i--)); do
    CLEANUP_ORDER+=("${SYNC_ORDER[i]}")
done
CLEANUP_ORDER+=("cluster-config")

# Namespaces created by our GitOps deployment
MANAGED_NAMESPACES=(
    "redhat-ods-operator"
    "redhat-ods-applications"
    "redhat-ods-monitoring"
    "rhods-notebooks"
    "rhoai-model-registries"
    "kuadrant-system"
    "nvidia-gpu-operator"
    "openshift-nfd"
    "openshift-kueue-operator"
    "openshift-lws-operator"
    "openshift-jobset-operator"
)

# CRDs that must exist before syncing instance apps
declare -A REQUIRED_CRDS=(
    ["instance-nfd"]="nodefeaturediscoveries.nfd.openshift.io"
    ["instance-nvidia"]="clusterpolicies.nvidia.com"
    ["instance-lws"]="leaderworkersetoperators.operator.openshift.io"
    ["instance-jobset"]="jobsetoperators.operator.openshift.io"
    ["instance-kuadrant"]="kuadrants.kuadrant.io"
    ["instance-rhoai"]="datascienceclusters.datasciencecluster.opendatahub.io"
)

# Operators we deploy (and their potential conflicts)
# Format: "namespace|subscription_pattern|instance_kind|instance_name"
# Used by clean.sh for removing pre-installed operators
OPERATOR_DEFINITIONS=(
    # RHOAI
    "redhat-ods-operator|rhods-operator|DataScienceCluster|default-dsc"
    "redhat-ods-operator|rhods-operator|DSCInitialization|default-dsci"

    # Connectivity Link / Kuadrant
    "kuadrant-system|rhcl-operator|Kuadrant|kuadrant"
    "kuadrant-system|authorino-operator|Authorino|authorino"
    "kuadrant-system|limitador-operator|Limitador|limitador"
    "kuadrant-system|dns-operator|DNSPolicy|*"

    # Service Mesh 3
    "openshift-operators|servicemeshoperator3|ServiceMeshControlPlane|*"

    # Kueue
    "openshift-kueue-operator|kueue-operator|ClusterQueue|*"
    "openshift-kueue-operator|kueue-operator|LocalQueue|*"

    # Leader Worker Set
    "openshift-lws-operator|lws-operator|LeaderWorkerSetOperator|leaderworkersetoperator"

    # JobSet
    "openshift-jobset-operator|jobset-operator|JobSetOperator|jobsetoperator"

    # NVIDIA GPU Operator
    "nvidia-gpu-operator|gpu-operator-certified|ClusterPolicy|gpu-cluster-policy"

    # NFD
    "openshift-nfd|nfd|NodeFeatureDiscovery|nfd-instance"
)

# Namespaces where operators might be installed
OPERATOR_NAMESPACES=(
    "redhat-ods-operator"
    "kuadrant-system"
    "openshift-operators"
    "openshift-kueue-operator"
    "openshift-lws-operator"
    "openshift-jobset-operator"
    "nvidia-gpu-operator"
    "openshift-nfd"
)

# Check cluster connection
check_cluster_connection() {
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster"
        exit 1
    fi
    log_info "Connected to: $(oc whoami --show-server)"
}

# Run command or print dry-run message
# Usage: run_cmd "command" (requires DRY_RUN variable to be set)
run_cmd() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Parse common arguments (-y/--yes, --dry-run)
# Sets SKIP_CONFIRM and DRY_RUN variables
parse_common_args() {
    DRY_RUN=false
    SKIP_CONFIRM=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            -y|--yes) SKIP_CONFIRM=true; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    export DRY_RUN SKIP_CONFIRM
}

# Prompt for confirmation (respects SKIP_CONFIRM and DRY_RUN)
confirm_action() {
    local message="${1:-Are you sure?}"
    if [[ "$SKIP_CONFIRM" != "true" && "$DRY_RUN" != "true" ]]; then
        read -p "$message [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi
}
