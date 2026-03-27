#!/usr/bin/env bash
#
# sync-configs.sh - Sync cluster config ArgoCD apps
#
# Enables auto-sync and waits for each config app to be Healthy.
#
# Usage:
#   ./sync-configs.sh
#   SYNC_TIMEOUT=300 ./sync-configs.sh  # 5-minute timeout per app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Timeout for each app to become healthy (seconds)
HEALTH_TIMEOUT="${SYNC_TIMEOUT:-120}"

# Config apps to sync (order matters for dependencies)
CONFIG_APPS=(
    "config-rbac"      # No dependencies
    "config-gateway"   # Needs GatewayClass CRD (from connectivity-link)
    "config-maas"      # Needs GatewayClass CRD (from connectivity-link)
)

sync_config_app() {
    local app="$1"

    # Check if app exists
    if ! oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; then
        log_warn "App '$app' not found, skipping"
        return 1
    fi

    log_step "Syncing: $app"

    # Enable auto-sync with retry policy
    oc patch application.argoproj.io/"$app" -n openshift-gitops --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"retry":{"limit":5,"backoff":{"duration":"30s","factor":2,"maxDuration":"3m"}}}}}'

    # Trigger immediate sync
    oc annotate application.argoproj.io/"$app" -n openshift-gitops \
        argocd.argoproj.io/refresh=normal --overwrite

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
            return 0
        fi

        # Progress indicator
        printf "  %s: sync=%s health=%s (%ds)\r" "$app" "$sync" "$health" "$elapsed"
        sleep 5
    done
}

main() {
    check_cluster_connection

    log_info "Syncing ${#CONFIG_APPS[@]} cluster config apps..."
    echo ""

    local success=0
    local skipped=0

    for app in "${CONFIG_APPS[@]}"; do
        if sync_config_app "$app"; then
            success=$((success + 1))
        else
            skipped=$((skipped + 1))
        fi
        echo ""
    done

    log_info "Config sync complete: $success synced, $skipped skipped"

    # Show final status
    echo ""
    log_step "Config apps status:"
    oc get applications.argoproj.io -n openshift-gitops | grep -E "^NAME|config-"
}

main "$@"
