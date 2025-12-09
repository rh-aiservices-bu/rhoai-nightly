#!/usr/bin/env bash
#
# validate.sh - Full cluster validation
#
# Usage:
#   ./validate.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

section() { echo -e "${BLUE}=== $* ===${NC}"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }

section "Cluster Info"
oc whoami --show-server
echo ""

section "Nodes"
oc get nodes
echo ""

section "GPU Nodes"
oc get nodes -l node-role.kubernetes.io/gpu 2>/dev/null || echo "No GPU nodes"
echo ""

section "GitOps Operator"
oc get csv -n openshift-gitops-operator 2>/dev/null | grep gitops || echo "Not installed"
echo ""

section "ArgoCD Applications"
oc get applications -n openshift-gitops 2>/dev/null || echo "ArgoCD not ready"
echo ""

section "RHOAI Operator"
oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "Not installed"
echo ""

section "DataScienceCluster"
oc get datasciencecluster 2>/dev/null || echo "Not created"
