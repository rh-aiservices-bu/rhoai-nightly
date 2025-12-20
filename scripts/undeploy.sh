#!/usr/bin/env bash
#
# undeploy.sh - Remove all ArgoCD applications with cascade deletion
#
# This script performs GitOps cleanup by deleting ArgoCD apps in reverse
# dependency order, letting ArgoCD cascade delete the managed resources.
#
# Order: instances first (so operators can clean up), then operators
#
# Usage:
#   ./undeploy.sh              # Interactive (prompts for confirmation)
#   ./undeploy.sh -y           # Skip confirmation
#   ./undeploy.sh --dry-run    # Show what would be deleted
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
parse_common_args "$@"

# Wait for an application to be fully deleted (cascade complete)
wait_for_app_deletion() {
    local app="$1"
    local timeout=300  # 5 minutes for cascade deletion
    local start_time=$(date +%s)

    log_info "Waiting for $app to be deleted (cascade)..."

    while oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "$app: Timeout waiting for deletion, forcing removal..."
            # Force remove finalizer and delete
            oc patch application.argoproj.io/"$app" -n openshift-gitops \
                --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
            oc delete application.argoproj.io/"$app" -n openshift-gitops \
                --ignore-not-found --timeout=30s 2>/dev/null || true
            return 0
        fi

        # Show what ArgoCD is doing
        local health sync
        health=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        sync=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

        printf "  $app: sync=%s health=%s (%ds)...\r" "$sync" "$health" "$elapsed"
        sleep 5
    done
    echo ""
    log_info "$app: Deleted"
}

delete_app_with_cascade() {
    local app="$1"

    # Check if app exists
    if ! oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; then
        log_info "App '$app' not found, skipping"
        return 0
    fi

    log_step "Deleting application: $app"

    # Ensure the app has the cascade finalizer (it should by default)
    # This makes ArgoCD delete managed resources before removing the app
    local has_finalizer
    has_finalizer=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
        -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "")

    if [[ "$has_finalizer" != *"resources-finalizer"* ]]; then
        log_info "Adding cascade finalizer to $app"
        run_cmd "oc patch application.argoproj.io/$app -n openshift-gitops --type=merge \
            -p '{\"metadata\":{\"finalizers\":[\"resources-finalizer.argocd.argoproj.io\"]}}'"
    fi

    # Delete the application - ArgoCD will cascade delete resources
    run_cmd "oc delete application.argoproj.io/$app -n openshift-gitops --wait=false"

    # Wait for cascade deletion to complete
    if [[ "$DRY_RUN" != "true" ]]; then
        wait_for_app_deletion "$app"
    fi
}

disable_applicationsets() {
    log_step "Disabling ApplicationSets (prevents app recreation)..."
    local appsets
    appsets=$(oc get applicationsets.argoproj.io -n openshift-gitops -o name 2>/dev/null || true)

    for appset in $appsets; do
        local name="${appset#applicationset.argoproj.io/}"
        log_info "Disabling: $name"
        run_cmd "oc patch $appset -n openshift-gitops --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/generators\",\"value\":[]}]' 2>/dev/null || true"
    done
}

delete_applicationsets() {
    log_step "Deleting ArgoCD applicationsets..."
    run_cmd "oc delete applicationsets.argoproj.io --all -n openshift-gitops --ignore-not-found 2>/dev/null || true"
}

cleanup_namespaces() {
    log_step "Cleaning up any remaining namespaces..."

    for ns in "${MANAGED_NAMESPACES[@]}"; do
        if oc get namespace "$ns" &>/dev/null; then
            log_info "Deleting namespace: $ns"

            # Remove finalizers on any stuck resources in the namespace
            run_cmd "oc get all -n $ns -o name 2>/dev/null | xargs -I {} oc patch {} -n $ns --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]' 2>/dev/null || true"

            # Delete the namespace
            run_cmd "oc delete namespace $ns --ignore-not-found --timeout=120s 2>/dev/null || true"
        fi
    done
}

main() {
    check_cluster_connection

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Check if any apps exist
    local app_count
    app_count=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l || echo 0)
    app_count="${app_count// /}"  # trim whitespace

    echo ""
    log_warn "This will remove all ArgoCD-managed RHOAI resources!"
    log_warn "GitOps operator will be retained for easy redeployment."

    if [[ "$app_count" -gt 0 ]]; then
        log_warn "Found $app_count ArgoCD applications to delete."
    fi

    confirm_action "Are you sure?"

    echo ""

    # Step 1: Disable ApplicationSets (prevents app recreation during deletion)
    disable_applicationsets

    # Step 2: Delete applications in reverse dependency order
    # ArgoCD cascade deletion handles resource cleanup
    log_step "Deleting applications in dependency order..."
    for app in "${CLEANUP_ORDER[@]}"; do
        delete_app_with_cascade "$app"
        echo ""
    done

    # Step 3: Delete any remaining applications not in our list
    local remaining
    remaining=$(oc get applications.argoproj.io -n openshift-gitops -o name 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        log_step "Deleting remaining applications..."
        for app in $remaining; do
            local app_name="${app#application.argoproj.io/}"
            delete_app_with_cascade "$app_name"
        done
    fi

    # Step 4: Delete applicationsets
    delete_applicationsets

    # Step 5: Clean up any remaining namespaces
    cleanup_namespaces

    echo ""
    log_info "Undeploy complete!"
    log_info "GitOps operator retained. Run 'make deploy && make sync' to redeploy."
}

main
