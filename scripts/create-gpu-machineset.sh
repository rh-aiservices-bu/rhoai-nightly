#!/usr/bin/env bash
#
# create-gpu-machineset.sh - Create GPU MachineSet with auto-discovery
#
# Usage:
#   ./create-gpu-machineset.sh [--instance-type TYPE] [--wait]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
WAIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --wait) WAIT=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--instance-type TYPE] [--wait]"
            echo "  --instance-type  GPU instance type (default: g5.2xlarge)"
            echo "  --wait           Wait for GPU node to be Ready"
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
AZ=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
AMI=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}')
SUBNET=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.filters[0].values[0]}')
IAM_PROFILE=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.iamInstanceProfile.id}')
SG=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.securityGroups[0].filters[0].values[0]}')

log_info "  Region: $REGION"
log_info "  Availability Zone: $AZ"
log_info "  AMI: $AMI"
log_info "  Instance Type: $INSTANCE_TYPE"

MS_NAME="${INFRA_ID}-gpu-${AZ##*-}"

# Create MachineSet
cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${MS_NAME}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
      machine.openshift.io/cluster-api-machineset: ${MS_NAME}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
        machine.openshift.io/cluster-api-machine-role: gpu
        machine.openshift.io/cluster-api-machine-type: gpu
        machine.openshift.io/cluster-api-machineset: ${MS_NAME}
    spec:
      metadata:
        labels:
          node-role.kubernetes.io/gpu: ""
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          ami:
            id: ${AMI}
          instanceType: ${INSTANCE_TYPE}
          placement:
            availabilityZone: ${AZ}
            region: ${REGION}
          subnet:
            filters:
              - name: tag:Name
                values:
                  - ${SUBNET}
          iamInstanceProfile:
            id: ${IAM_PROFILE}
          securityGroups:
            - filters:
                - name: tag:Name
                  values:
                    - ${SG}
          tags:
            - name: kubernetes.io/cluster/${INFRA_ID}
              value: owned
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: aws-cloud-credentials
          blockDevices:
            - ebs:
                volumeSize: 120
                volumeType: gp3
EOF

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
