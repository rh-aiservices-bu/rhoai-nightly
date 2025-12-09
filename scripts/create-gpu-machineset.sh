#!/usr/bin/env bash
#
# create-gpu-machineset.sh - Create GPU MachineSet with auto-discovery
#
# Usage:
#   ./create-gpu-machineset.sh [OPTIONS]
#
# Options:
#   --instance-type TYPE   GPU instance type (default: g5.2xlarge)
#   --replicas N           Number of replicas (default: 1)
#   --az ZONE              Availability zone (default: auto-detected)
#   --access-type TYPE     SHARED or PRIVATE (default: SHARED)
#   --dry-run              Preview without applying
#   --wait                 Wait for node to become Ready
#
# Environment variables (can also be set in .env):
#   GPU_INSTANCE_TYPE, GPU_REPLICAS, GPU_ACCESS_TYPE, GPU_AZ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Defaults (can be overridden by env vars or CLI args)
INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-${INSTANCE_TYPE:-g5.2xlarge}}"
REPLICAS="${GPU_REPLICAS:-${REPLICAS:-1}}"
ACCESS_TYPE="${GPU_ACCESS_TYPE:-${ACCESS_TYPE:-SHARED}}"
AZ="${GPU_AZ:-}"
WAIT=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --access-type) ACCESS_TYPE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --wait) WAIT=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --instance-type TYPE   GPU instance type (default: g5.2xlarge)
  --replicas N           Number of replicas (default: 1)
  --az ZONE              Availability zone (default: auto-detected)
  --access-type TYPE     SHARED or PRIVATE (default: SHARED)
  --dry-run              Preview without applying
  --wait                 Wait for GPU node to be Ready

Supported instance types:
  g4dn.*           NVIDIA T4 (16GB) - Budget option
  g5.*             NVIDIA A10G (24GB) - Recommended for inference
  p4d.24xlarge     NVIDIA A100 x8 (80GB) - Training
  p5.48xlarge      NVIDIA H100 x8 (80GB) - High-end training

Environment variables (can also be set in .env):
  GPU_INSTANCE_TYPE, GPU_REPLICAS, GPU_ACCESS_TYPE, GPU_AZ
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "Connected to: $(oc whoami --show-server)"

# Check if GPU MachineSet already exists
if oc get machineset -n openshift-machine-api -o name 2>/dev/null | grep -q gpu; then
    log_warn "GPU MachineSet already exists"
    oc get machineset -n openshift-machine-api | grep gpu
    exit 0
fi

# Verify AWS platform
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo "unknown")
if [[ "$PLATFORM" != "AWS" ]]; then
    log_error "This script only supports AWS. Detected platform: $PLATFORM"
    exit 1
fi

# Auto-discover cluster values
log_info "Auto-discovering cluster values..."

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
log_info "  Infrastructure ID: $INFRA_ID"

# Get reference worker MachineSet
REF_MS=$(oc get machineset -n openshift-machine-api -o name | head -1 | cut -d/ -f2)
if [[ -z "$REF_MS" ]]; then
    log_error "No existing MachineSet found to use as reference"
    exit 1
fi
log_info "  Reference MachineSet: $REF_MS"

# Extract values
REGION=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.placement.region}')
DISCOVERED_AZ=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
AMI=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}')
SUBNET=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.filters[0].values[0]}')
IAM_PROFILE=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.iamInstanceProfile.id}')
SG=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.securityGroups[0].filters[0].values[0]}')

# Use discovered AZ if not specified
if [[ -z "$AZ" ]]; then
    AZ="$DISCOVERED_AZ"
fi

log_info "  Region: $REGION"
log_info "  Availability Zone: $AZ"
log_info "  AMI: $AMI"
log_info "  Instance Type: $INSTANCE_TYPE"
log_info "  Replicas: $REPLICAS"
log_info "  Access Type: $ACCESS_TYPE"

MS_NAME="${INFRA_ID}-gpu-${AZ##*-}"

# Generate MachineSet YAML from template
TEMPLATE_FILE="$REPO_ROOT/bootstrap/gpu-machineset/gpu-machineset-template.yaml"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log_error "Template file not found: $TEMPLATE_FILE"
    exit 1
fi

export MS_NAME INFRA_ID REPLICAS AMI INSTANCE_TYPE AZ REGION SUBNET IAM_PROFILE SG
MACHINESET_YAML=$(envsubst < "$TEMPLATE_FILE")

# Dry-run or apply
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would apply:"
    echo "$MACHINESET_YAML"
    echo "$MACHINESET_YAML" | oc apply --dry-run=client -f -
    log_info "[DRY-RUN] Complete - no changes made"
    exit 0
fi

echo "$MACHINESET_YAML" | oc apply -f -
log_info "GPU MachineSet created: $MS_NAME"

if [[ "$WAIT" == "true" ]]; then
    log_info "Waiting for GPU node to be Ready (5-10 minutes)..."

    for i in {1..60}; do
        NODE=$(oc get nodes -l node-role.kubernetes.io/gpu -o name 2>/dev/null | head -1)
        if [[ -n "$NODE" ]]; then
            READY=$(oc get "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
            if [[ "$READY" == "True" ]]; then
                log_info "GPU Node is Ready: $NODE"
                exit 0
            fi
        fi
        echo -n "."
        sleep 10
    done
    echo
    log_warn "Timeout waiting for GPU node"
fi

log_info "Monitor with: oc get machines -n openshift-machine-api -w | grep gpu"
