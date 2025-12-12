#!/usr/bin/env bash
#
# status.sh - Show ArgoCD application status
#
# Usage:
#   ./status.sh

set -euo pipefail

echo "ArgoCD Applications:"
oc get applications -n openshift-gitops 2>/dev/null || echo "ArgoCD not installed"
echo ""

echo "ApplicationSets:"
oc get applicationsets -n openshift-gitops 2>/dev/null || echo "No ApplicationSets"
