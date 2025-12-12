#!/usr/bin/env bash
#
# clean.sh - Full cluster cleanup including pre-installed operators
#
# This script handles pre-installed/non-GitOps operators:
#   1. Removes ALL potentially conflicting operators (not just GitOps-managed)
#   2. Cleans up cluster-scoped resources (CatalogSources)
#
# NOTE: Run undeploy.sh first to remove ArgoCD apps and namespaces.
#       When using Makefile: `make clean` chains desync -> undeploy -> clean.
#
# Use this for:
#   - OSD/pre-provisioned clusters with pre-installed NFD/NVIDIA
#   - Full reset before fresh installation
#   - Cleaning up after failed deployments
#
# Usage:
#   ./clean.sh              # Interactive (prompts for confirmation)
#   ./clean.sh -y           # Skip confirmation
#   ./clean.sh --dry-run    # Show what would be deleted
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
parse_common_args "$@"

delete_operator_instances() {
    log_step "Deleting operator instances..."

    for op in "${OPERATOR_DEFINITIONS[@]}"; do
        IFS='|' read -r ns sub_pattern instance_kind instance_name <<< "$op"

        # Skip if namespace doesn't exist
        if ! oc get namespace "$ns" &>/dev/null; then
            continue
        fi

        # Delete instances
        if [[ "$instance_name" == "*" ]]; then
            # Delete all instances of this kind
            local instances
            instances=$(oc get "$instance_kind" -n "$ns" -o name 2>/dev/null || true)
            if [[ -n "$instances" ]]; then
                log_info "Deleting all $instance_kind in $ns"
                for inst in $instances; do
                    run_cmd "oc delete $inst -n $ns --ignore-not-found --timeout=60s 2>/dev/null || true"
                done
            fi
        else
            # Delete specific instance
            if oc get "$instance_kind" "$instance_name" -n "$ns" &>/dev/null 2>&1; then
                log_info "Deleting $instance_kind/$instance_name in $ns"
                run_cmd "oc delete $instance_kind $instance_name -n $ns --ignore-not-found --timeout=60s 2>/dev/null || true"
            fi
        fi
    done

    # Also check for cluster-scoped instances
    log_info "Checking for cluster-scoped instances..."

    # ClusterPolicy (NVIDIA)
    if oc get clusterpolicy gpu-cluster-policy &>/dev/null 2>&1; then
        log_info "Deleting ClusterPolicy/gpu-cluster-policy"
        run_cmd "oc delete clusterpolicy gpu-cluster-policy --ignore-not-found --timeout=60s 2>/dev/null || true"
    fi

    # NodeFeatureDiscovery
    if oc get nodefeaturediscovery -A -o name &>/dev/null 2>&1; then
        local nfds
        nfds=$(oc get nodefeaturediscovery -A -o name 2>/dev/null || true)
        for nfd in $nfds; do
            log_info "Deleting $nfd"
            run_cmd "oc delete $nfd -A --ignore-not-found --timeout=60s 2>/dev/null || true"
        done
    fi

    # DataScienceCluster (can be cluster-scoped)
    if oc get datasciencecluster -A -o name &>/dev/null 2>&1; then
        local dscs
        dscs=$(oc get datasciencecluster -A -o name 2>/dev/null || true)
        for dsc in $dscs; do
            log_info "Deleting $dsc"
            run_cmd "oc delete $dsc -A --ignore-not-found --timeout=120s 2>/dev/null || true"
        done
    fi

    # DSCInitialization
    if oc get dscinitializations.dscinitialization.opendatahub.io -A -o name &>/dev/null 2>&1; then
        local dscis
        dscis=$(oc get dscinitializations.dscinitialization.opendatahub.io -A -o name 2>/dev/null || true)
        for dsci in $dscis; do
            log_info "Deleting $dsci"
            run_cmd "oc delete $dsci -A --ignore-not-found --timeout=60s 2>/dev/null || true"
        done
    fi
}

delete_subscriptions_and_csvs() {
    log_step "Deleting operator subscriptions and CSVs..."

    for ns in "${OPERATOR_NAMESPACES[@]}"; do
        if ! oc get namespace "$ns" &>/dev/null; then
            continue
        fi

        # Delete all subscriptions in the namespace
        local subs
        subs=$(oc get subscriptions.operators.coreos.com -n "$ns" -o name 2>/dev/null || true)
        if [[ -n "$subs" ]]; then
            log_info "Deleting subscriptions in $ns"
            for sub in $subs; do
                run_cmd "oc delete $sub -n $ns --ignore-not-found 2>/dev/null || true"
            done
        fi

        # Delete all CSVs in the namespace
        local csvs
        csvs=$(oc get clusterserviceversions.operators.coreos.com -n "$ns" -o name 2>/dev/null || true)
        if [[ -n "$csvs" ]]; then
            log_info "Deleting CSVs in $ns"
            for csv in $csvs; do
                run_cmd "oc delete $csv -n $ns --ignore-not-found 2>/dev/null || true"
            done
        fi

        # Delete OperatorGroups (skip openshift-operators which has system global-operators)
        if [[ "$ns" != "openshift-operators" ]]; then
            local ogs
            ogs=$(oc get operatorgroups.operators.coreos.com -n "$ns" -o name 2>/dev/null || true)
            if [[ -n "$ogs" ]]; then
                log_info "Deleting OperatorGroups in $ns"
                for og in $ogs; do
                    run_cmd "oc delete $og -n $ns --ignore-not-found 2>/dev/null || true"
                done
            fi
        fi
    done

    # Also check openshift-operators for Service Mesh
    if oc get namespace openshift-operators &>/dev/null; then
        local sm_subs
        sm_subs=$(oc get subscriptions.operators.coreos.com -n openshift-operators -o name 2>/dev/null | grep -E "servicemesh|istio" || true)
        if [[ -n "$sm_subs" ]]; then
            log_info "Deleting Service Mesh subscriptions"
            for sub in $sm_subs; do
                run_cmd "oc delete $sub -n openshift-operators --ignore-not-found 2>/dev/null || true"
            done
        fi

        local sm_csvs
        sm_csvs=$(oc get clusterserviceversions.operators.coreos.com -n openshift-operators -o name 2>/dev/null | grep -E "servicemesh|istio" || true)
        if [[ -n "$sm_csvs" ]]; then
            log_info "Deleting Service Mesh CSVs"
            for csv in $sm_csvs; do
                run_cmd "oc delete $csv -n openshift-operators --ignore-not-found 2>/dev/null || true"
            done
        fi
    fi
}

cleanup_cluster_resources() {
    log_step "Cleaning up cluster-scoped resources..."

    # Delete RHOAI CatalogSource
    if oc get catalogsource rhoai-catalog-nightly -n openshift-marketplace &>/dev/null 2>&1; then
        log_info "Deleting CatalogSource/rhoai-catalog-nightly"
        run_cmd "oc delete catalogsource rhoai-catalog-nightly -n openshift-marketplace --ignore-not-found 2>/dev/null || true"
    fi

    # Delete any custom CatalogSources we created
    local catalogs
    catalogs=$(oc get catalogsource -n openshift-marketplace -o name 2>/dev/null | grep -E "rhoai|rhods" || true)
    if [[ -n "$catalogs" ]]; then
        for cat in $catalogs; do
            log_info "Deleting $cat"
            run_cmd "oc delete $cat -n openshift-marketplace --ignore-not-found 2>/dev/null || true"
        done
    fi
}

main() {
    check_cluster_connection

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    echo ""
    log_warn "=========================================="
    log_warn "  FULL CLUSTER CLEANUP"
    log_warn "=========================================="
    log_warn ""
    log_warn "This will remove:"
    log_warn "  - All ArgoCD applications and synced resources"
    log_warn "  - ALL potentially conflicting operators (NFD, NVIDIA, SM3, Kueue, etc.)"
    log_warn "  - All related namespaces and instances"
    log_warn ""
    log_warn "GitOps operator will be retained."

    confirm_action "Are you sure you want to proceed?"

    echo ""

    # Step 1: Delete any remaining operator instances (pre-installed, not ArgoCD-managed)
    delete_operator_instances

    # Step 2: Delete any remaining subscriptions and CSVs (pre-installed operators)
    delete_subscriptions_and_csvs

    # Step 3: Clean up cluster-scoped resources (CatalogSources)
    cleanup_cluster_resources

    echo ""
    log_info "=========================================="
    log_info "  CLEANUP COMPLETE"
    log_info "=========================================="
    log_info ""
    log_info "Cluster is now clean. To redeploy:"
    log_info "  make setup      # Pre-GitOps setup"
    log_info "  make bootstrap  # Install GitOps + deploy apps"
    log_info "  make sync       # Sync all apps"
}

main
