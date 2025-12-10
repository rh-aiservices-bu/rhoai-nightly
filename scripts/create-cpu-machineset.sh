#!/usr/bin/env bash
#
# create-cpu-machineset.sh - Create CPU worker MachineSet with auto-discovery
#
# Creates dedicated CPU worker nodes separate from master/infra nodes.
# Useful for RHOAI workloads that need dedicated compute resources.
#
# Usage:
#   ./create-cpu-machineset.sh [OPTIONS]
#
# Options:
#   --instance-type TYPE   Instance type (default: m5.2xlarge)
#   --replicas N           Number of replicas (default: 2)
#   --az ZONE              Availability zone (default: auto-detected)
#   --volume-size GB       Root volume size in GB (default: 120)
#   --dry-run              Preview without applying
#   --wait                 Wait for nodes to become Ready
#
# Environment variables (can also be set in .env):
#   CPU_INSTANCE_TYPE, CPU_REPLICAS, CPU_AZ, CPU_VOLUME_SIZE

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
INSTANCE_TYPE="${CPU_INSTANCE_TYPE:-${INSTANCE_TYPE:-m5.4xlarge}}"
REPLICAS="${CPU_REPLICAS:-${REPLICAS:-1}}"
AZ="${CPU_AZ:-}"
VOLUME_SIZE="${CPU_VOLUME_SIZE:-${VOLUME_SIZE:-120}}"
WAIT=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --volume-size) VOLUME_SIZE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --wait) WAIT=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Creates dedicated CPU worker nodes separate from master/infra nodes.

Options:
  --instance-type TYPE   Instance type (default: m5.4xlarge)
  --replicas N           Number of replicas (default: 1)
  --az ZONE              Availability zone (default: auto-detected)
  --volume-size GB       Root volume size in GB (default: 120)
  --dry-run              Preview without applying
  --wait                 Wait for nodes to be Ready

Common instance types:
  m5.xlarge      4 vCPU,  16GB RAM  - Light workloads
  m5.2xlarge     8 vCPU,  32GB RAM  - Default, general purpose
  m5.4xlarge    16 vCPU,  64GB RAM  - Medium workloads
  m5.8xlarge    32 vCPU, 128GB RAM  - Heavy workloads
  m6i.xlarge     4 vCPU,  16GB RAM  - Latest gen, general purpose
  c5.2xlarge     8 vCPU,  16GB RAM  - Compute optimized
  r5.2xlarge     8 vCPU,  64GB RAM  - Memory optimized

Environment variables (can also be set in .env):
  CPU_INSTANCE_TYPE, CPU_REPLICAS, CPU_AZ, CPU_VOLUME_SIZE
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

# Check if CPU worker MachineSet already exists
if oc get machineset -n openshift-machine-api -o name 2>/dev/null | grep -q "cpu-worker"; then
    log_warn "CPU worker MachineSet already exists"
    oc get machineset -n openshift-machine-api | grep cpu-worker
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

# Get reference worker MachineSet (not gpu, not infra)
REF_MS=$(oc get machineset -n openshift-machine-api -o name | grep -v gpu | grep -v infra | head -1 | cut -d/ -f2)
if [[ -z "$REF_MS" ]]; then
    log_error "No existing worker MachineSet found to use as reference"
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
log_info "  Volume Size: ${VOLUME_SIZE}GB"

MS_NAME="${INFRA_ID}-cpu-worker-${AZ##*-}"

# Generate MachineSet YAML from template
TEMPLATE_FILE="$REPO_ROOT/bootstrap/cpu-machineset/cpu-machineset-template.yaml"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log_error "Template file not found: $TEMPLATE_FILE"
    exit 1
fi

export MS_NAME INFRA_ID REPLICAS AMI INSTANCE_TYPE AZ REGION SUBNET IAM_PROFILE SG VOLUME_SIZE
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
log_info "CPU worker MachineSet created: $MS_NAME"

if [[ "$WAIT" == "true" ]]; then
    log_info "Waiting for CPU worker nodes to be Ready (5-10 minutes)..."

    EXPECTED_READY=$REPLICAS
    for i in {1..60}; do
        READY_COUNT=$(oc get nodes -l node-role.kubernetes.io/cpu-worker --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
        if [[ "$READY_COUNT" -ge "$EXPECTED_READY" ]]; then
            log_info "CPU worker nodes are Ready: $READY_COUNT/$EXPECTED_READY"
            oc get nodes -l node-role.kubernetes.io/cpu-worker
            exit 0
        fi
        echo -n "."
        sleep 10
    done
    echo
    log_warn "Timeout waiting for CPU worker nodes ($READY_COUNT/$EXPECTED_READY ready)"
fi

log_info "Monitor with: oc get machines -n openshift-machine-api -w | grep cpu-worker"
