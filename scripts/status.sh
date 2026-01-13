#!/usr/bin/env bash
#
# status.sh - Show ArgoCD application status
#
# Usage:
#   ./status.sh

set -euo pipefail

echo "ArgoCD Applications:"
# Use full resource name to avoid conflict with app.k8s.io/v1beta1 Application CRD
oc get applications.argoproj.io -n openshift-gitops 2>/dev/null || echo "ArgoCD not installed"
echo ""

echo "ApplicationSets:"
oc get applicationsets.argoproj.io -n openshift-gitops 2>/dev/null || echo "No ApplicationSets"
