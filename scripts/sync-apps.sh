#!/usr/bin/env bash
#
# sync-apps.sh - Sync ArgoCD apps one-by-one in dependency order
#
# Waits for each app to be Healthy before proceeding to the next.
# This prevents overwhelming the cluster API server.
#
# Usage:
#   ./sync-apps.sh
#   SYNC_TIMEOUT=600 ./sync-apps.sh  # 10-minute timeout per app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Timeout for each app to become healthy (seconds)
HEALTH_TIMEOUT="${SYNC_TIMEOUT:-300}"

wait_for_crd() {
    local app="$1"
    local crd="${REQUIRED_CRDS[$app]:-}"

    # No CRD requirement for this app
    [[ -z "$crd" ]] && return 0

    local timeout=120
    local start_time=$(date +%s)

    while ! oc get crd "$crd" &>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for CRD: $crd (will rely on ArgoCD retry)"
            return 0  # Continue anyway, ArgoCD retry will handle it
        fi
        printf "  Waiting for CRD: %s (%ds)...\r" "$crd" "$elapsed"
        sleep 5
    done
    echo ""
    log_info "CRD ready: $crd"
    return 0
}

wait_for_dsci() {
    local app="$1"

    # Only check for instance-rhoai
    [[ "$app" != "instance-rhoai" ]] && return 0

    local timeout=120
    local start_time=$(date +%s)

    while true; do
        local phase=$(oc get dscinitialization default-dsci -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Ready" ]]; then
            log_info "DSCInitialization is Ready"
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for DSCInitialization to be Ready"
            return 0  # Continue anyway, let ArgoCD handle retries
        fi
        printf "  Waiting for DSCInitialization: phase=%s (%ds)...\r" "${phase:-NotFound}" "$elapsed"
        sleep 5
    done
}

clear_sync_failure() {
    local app="$1"
    # Check if app has a failed sync operation
    local op_phase=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
        -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")

    if [[ "$op_phase" == "Failed" ]]; then
        log_info "Clearing failed sync state for $app..."
        # Trigger a new sync operation to clear the failure
        oc patch application.argoproj.io/"$app" -n openshift-gitops --type=merge \
            -p '{"operation":{"initiatedBy":{"username":"sync-apps.sh"},"sync":{"prune":true}}}' 2>/dev/null || true
    fi
}

approve_pending_installplans() {
    # Approve any pending InstallPlans in openshift-operators namespace
    local pending
    pending=$(oc get installplan -n openshift-operators -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [[ -n "$pending" ]]; then
        for ip in $pending; do
            log_info "Auto-approving InstallPlan: $ip"
            oc patch installplan "$ip" -n openshift-operators --type=merge -p '{"spec":{"approved":true}}' 2>/dev/null || true
        done
    fi
}

sync_app() {
    local app="$1"
    local app_wait_timeout=60

    # Wait for app to exist (with retry)
    local wait_start=$(date +%s)
    while ! oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; do
        local wait_elapsed=$(($(date +%s) - wait_start))
        if [[ $wait_elapsed -ge $app_wait_timeout ]]; then
            log_warn "App '$app' not found after ${app_wait_timeout}s, skipping"
            return 1
        fi
        printf "  Waiting for app '%s' to exist (%ds)...\r" "$app" "$wait_elapsed"
        sleep 3
    done

    log_step "Syncing: $app"

    # Clear any previous sync failure (allows retry)
    clear_sync_failure "$app"

    # Wait for required CRD before syncing instance apps
    wait_for_crd "$app"

    # Wait for DSCInitialization before syncing instance-rhoai
    wait_for_dsci "$app"

    # Enable auto-sync with retry policy (handles CRD timing issues)
    oc patch application.argoproj.io/"$app" -n openshift-gitops --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"retry":{"limit":5,"backoff":{"duration":"30s","factor":2,"maxDuration":"3m"}}}}}'

    # Trigger immediate sync
    oc annotate application.argoproj.io/"$app" -n openshift-gitops \
        argocd.argoproj.io/refresh=normal --overwrite

    # Auto-approve any pending InstallPlans (OLM sometimes sets Manual regardless of subscription)
    approve_pending_installplans

    # Wait for healthy
    log_info "Waiting for $app to be Healthy (timeout: ${HEALTH_TIMEOUT}s)..."
    local start_time=$(date +%s)
    while true; do
        local health=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        local sync=$(oc get application.argoproj.io/"$app" -n openshift-gitops \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

        if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then
            log_info "$app: Synced + Healthy"
            return 0
        fi

        # Check timeout
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $HEALTH_TIMEOUT ]]; then
            log_warn "$app: Timeout after ${HEALTH_TIMEOUT}s (health=$health, sync=$sync)"
            log_warn "Continuing to next app..."
            return 0
        fi

        # Auto-approve any pending InstallPlans while waiting
        approve_pending_installplans

        # Progress indicator
        printf "  %s: sync=%s health=%s (%ds)\r" "$app" "$sync" "$health" "$elapsed"
        sleep 10
    done
}

wait_for_all_apps() {
    log_step "Verifying all apps exist before syncing..."
    local timeout=120
    local start_time=$(date +%s)

    for app in "${SYNC_ORDER[@]}"; do
        while ! oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; do
            local elapsed=$(($(date +%s) - start_time))
            if [[ $elapsed -ge $timeout ]]; then
                log_error "Timeout: App '$app' not found after ${timeout}s"
                log_error "Run 'make deploy' first to create all apps"
                exit 1
            fi
            printf "  Waiting for app: %s (%ds)...\r" "$app" "$elapsed"
            sleep 3
        done
    done
    echo ""
    log_info "All ${#SYNC_ORDER[@]} apps exist"
}

main() {
    check_cluster_connection

    # Pre-flight check: ensure all apps exist
    wait_for_all_apps

    log_info "Starting staged sync of ${#SYNC_ORDER[@]} apps..."
    log_info "Each app will wait up to ${HEALTH_TIMEOUT}s to become healthy"
    echo ""

    local success=0
    local skipped=0

    for app in "${SYNC_ORDER[@]}"; do
        if sync_app "$app"; then
            success=$((success + 1))
        else
            skipped=$((skipped + 1))
        fi
        echo ""
    done

    log_info "Sync complete: $success processed, $skipped skipped/warnings"

    # Show final status
    echo ""
    log_step "Final status:"
    oc get applications.argoproj.io -n openshift-gitops \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
    echo ""
    log_info "Auto-sync is ON. Apps will self-heal from git."
    log_info "Run 'make sync-disable' to disable auto-sync for manual changes."
}

main "$@"
