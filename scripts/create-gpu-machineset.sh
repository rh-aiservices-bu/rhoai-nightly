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
#   --min N                Minimum replicas for autoscaling (default: 1)
#   --max N                Maximum replicas for autoscaling (default: 3)
#   --dry-run              Preview without applying
#
# The script always waits for the GPU node to be Ready before exiting.
#
# Environment variables (can also be set in .env):
#   GPU_INSTANCE_TYPE, GPU_REPLICAS, GPU_ACCESS_TYPE, GPU_AZ, GPU_MIN, GPU_MAX

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Defaults (can be overridden by env vars or CLI args)
INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-${INSTANCE_TYPE:-g5.2xlarge}}"
REPLICAS="${GPU_REPLICAS:-${REPLICAS:-1}}"
ACCESS_TYPE="${GPU_ACCESS_TYPE:-${ACCESS_TYPE:-SHARED}}"
AZ="${GPU_AZ:-}"
AUTOSCALE_MIN="${GPU_MIN:-1}"
AUTOSCALE_MAX="${GPU_MAX:-3}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --access-type) ACCESS_TYPE="$2"; shift 2 ;;
        --min) AUTOSCALE_MIN="$2"; shift 2 ;;
        --max) AUTOSCALE_MAX="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --instance-type TYPE   GPU instance type (default: g5.2xlarge)
  --replicas N           Number of replicas (default: 1)
  --az ZONE              Availability zone (default: auto-detected)
  --access-type TYPE     SHARED or PRIVATE (default: SHARED)
  --min N                Minimum replicas for autoscaling (default: 1)
  --max N                Maximum replicas for autoscaling (default: 3)
  --dry-run              Preview without applying

The script always waits for GPU node(s) to be Ready before exiting.

Autoscaling:
  Autoscaling is enabled by default. The script will:
  1. Create a ClusterAutoscaler (if not exists)
  2. Create a MachineAutoscaler for the GPU MachineSet
  3. Set initial replicas to --min value

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

# Check if GPU MachineSet already exists with Ready node
EXISTING_GPU_MS=$(oc get machineset -n openshift-machine-api -o name 2>/dev/null | grep gpu || true)
if [[ -n "$EXISTING_GPU_MS" ]]; then
    EXISTING_READY=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1 || echo "0")
    # Get readyReplicas specifically from the GPU machineset
    GPU_MS_NAME=$(echo "$EXISTING_GPU_MS" | head -1 | cut -d/ -f2)
    EXISTING_READY=$(oc get machineset "$GPU_MS_NAME" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${EXISTING_READY:-0}" -ge 1 ]]; then
        log_info "GPU MachineSet '$GPU_MS_NAME' already has $EXISTING_READY Ready replica(s), skipping"
        oc get machineset -n openshift-machine-api | grep gpu
        oc get nodes -l node-role.kubernetes.io/gpu
        exit 0
    fi
    log_info "GPU MachineSet already exists, will update if needed"
    oc get machineset -n openshift-machine-api | grep gpu
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

# Handle autoscaling configuration (enabled by default with min=1, max=3)
AUTOSCALING_ENABLED=true
REPLICAS="$AUTOSCALE_MIN"
log_info "  Autoscaling: enabled (min=$AUTOSCALE_MIN, max=$AUTOSCALE_MAX)"

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

echo "$MACHINESET_YAML" | retry 3 oc apply -f -
log_info "GPU MachineSet created: $MS_NAME"

# Create autoscaling resources if enabled
if [[ "$AUTOSCALING_ENABLED" == "true" ]]; then
    log_info "Creating autoscaling resources..."

    # Create ClusterAutoscaler if it doesn't exist
    if ! oc get clusterautoscaler default &>/dev/null; then
        log_info "Creating ClusterAutoscaler..."
        cat <<EOF | oc apply -f -
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  podPriorityThreshold: -10
  scaleDown:
    delayAfterAdd: 20m
    delayAfterDelete: 5m
    delayAfterFailure: 30s
    enabled: true
    unneededTime: 5m
EOF
        log_info "ClusterAutoscaler created"
    else
        log_info "ClusterAutoscaler already exists"
    fi

    # Create MachineAutoscaler for this MachineSet
    log_info "Creating MachineAutoscaler for $MS_NAME..."
    cat <<EOF | oc apply -f -
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: $MS_NAME
  namespace: openshift-machine-api
spec:
  minReplicas: $AUTOSCALE_MIN
  maxReplicas: $AUTOSCALE_MAX
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: $MS_NAME
EOF
    log_info "MachineAutoscaler created: $MS_NAME (min=$AUTOSCALE_MIN, max=$AUTOSCALE_MAX)"
fi

# Always wait for GPU node to be Ready
log_info "Waiting for GPU node to be Ready (this may take 5-15 minutes)..."

TIMEOUT=1200  # 20 minutes
INTERVAL=15
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    # Check Machine status first
    MACHINE_STATUS=$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=$MS_NAME -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")

    NODE=$(oc get nodes -l node-role.kubernetes.io/gpu -o name 2>/dev/null | head -1)
    if [[ -n "$NODE" ]]; then
        READY=$(oc get "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$READY" == "True" ]]; then
            log_info "GPU node is Ready!"
            oc get nodes -l node-role.kubernetes.io/gpu
            exit 0
        fi
        log_info "GPU node exists but not Ready yet (Machine: $MACHINE_STATUS, Node Ready: $READY)"
    else
        log_info "Waiting for GPU node... (Machine phase: $MACHINE_STATUS)"
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

log_warn "Timeout waiting for GPU node after $TIMEOUT seconds"
log_warn "Check machine status: oc get machines -n openshift-machine-api | grep gpu"
log_warn "Check events: oc get events -n openshift-machine-api --sort-by='.lastTimestamp' | tail -20"
exit 1
