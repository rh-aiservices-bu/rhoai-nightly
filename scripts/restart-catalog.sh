#!/usr/bin/env bash
#
# restart-catalog.sh - Force OLM to re-resolve RHOAI after a catalog image change
#
# Bouncing the catalog pod alone is not enough after a catalog-image flip:
# OLM caches the Subscription's resolved InstallPlanRef and sticks with the
# previously-resolved CSV until the Subscription itself is re-resolved. This
# script restarts the catalog pod, bounces the operator pod, then (by default)
# deletes the Subscription so ArgoCD recreates it and OLM generates a fresh
# InstallPlan against the new catalog content.
#
# See .tmp/plans/install-gotchas.md §1 for the empirical failure this guards
# against (cluster-hm2fl 2026-04-20).
#
# Usage:
#   scripts/restart-catalog.sh              # full behaviour (recommended)
#   scripts/restart-catalog.sh --no-resub   # just bounce pods, skip Subscription delete
#
# Exit codes:
#   0 = success
#   1 = cluster unreachable or RHOAI not installed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RESUB=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-resub) RESUB=false; shift ;;
        -h|--help)
            sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

check_cluster_connection

# Abort if RHOAI not installed — nothing to restart
if ! oc get subscription rhods-operator -n redhat-ods-operator &>/dev/null; then
    log_warn "rhods-operator subscription not found in redhat-ods-operator — nothing to restart"
    exit 0
fi

log_step "Restarting catalog pod"
oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly 2>/dev/null || true
log_info "Waiting up to 120s for catalog pod Ready"
if ! oc wait --for=condition=Ready pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly --timeout=120s 2>/dev/null; then
    log_warn "Catalog pod didn't reach Ready within 120s — continuing anyway"
fi

log_step "Restarting rhods-operator pod"
oc delete pod -n redhat-ods-operator -l name=rhods-operator 2>/dev/null || true

if [[ "$RESUB" == "true" ]]; then
    log_step "Deleting rhods-operator Subscription so OLM re-resolves"
    # Capture current installedCSV for the log (so the user can correlate the
    # new InstallPlan with the old one).
    OLD_CSV=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    [[ -n "$OLD_CSV" ]] && log_info "Previous installedCSV: $OLD_CSV"

    oc delete subscription rhods-operator -n redhat-ods-operator
    log_info "Subscription deleted. ArgoCD will recreate it from components/operators/rhoai-operator/; OLM will generate a fresh InstallPlan against the new catalog."
    log_info "Monitor progress: oc get subscription,installplan,csv -n redhat-ods-operator -w"
else
    log_info "--no-resub set; Subscription left in place."
    log_info "If OLM doesn't re-resolve (symptom: Subscription stuck at old installedCSV), re-run without --no-resub."
fi

log_info "Done."
