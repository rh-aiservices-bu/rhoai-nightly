#!/usr/bin/env bash
#
# enable-uwm.sh - Enable OpenShift User Workload Monitoring (UWM)
#
# Applies bootstrap/cluster-monitoring-config, which sets
# enableUserWorkload: true in the cluster-monitoring-config ConfigMap. Waits
# briefly for the prometheus-user-workload-0 pod to appear.
#
# Rationale for owning this at the `make infra` stage rather than inside
# install-observability.sh: UWM is a foundational cluster capability other
# workloads may depend on. Treating it as part of infrastructure (alongside
# ICSP / CPU / GPU MachineSets) makes the dependency order clearer and keeps
# the observability install focused on MaaS-specific resources. Also, the
# UWM rollout puts measurable memory pressure on the control plane, so
# landing it while the rest of the platform is idle avoids stacking it on
# top of the observability cascade on undersized masters.
#
# Safe to re-run (idempotent) — if the ConfigMap already has
# enableUserWorkload: true, nothing changes. If the ConfigMap exists with
# other keys (retention, alertmanagerMain, etc), they are preserved via a
# YAML merge rather than replaced.
#
# Usage:
#   scripts/enable-uwm.sh            # apply and wait
#   scripts/enable-uwm.sh --dry-run  # preview only
#   scripts/enable-uwm.sh --check    # exit 0 if already enabled, 1 otherwise
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --check)     CHECK_ONLY=true; shift ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

check_cluster_connection

UWM_DIR="$REPO_ROOT/bootstrap/cluster-monitoring-config"
if [[ ! -d "$UWM_DIR" ]]; then
    log_error "Missing $UWM_DIR — cannot enable UWM"
    exit 1
fi

# Read current ConfigMap state
EXISTING_CONFIG=$(oc get cm cluster-monitoring-config -n openshift-monitoring \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)

already_enabled() {
    [[ -z "$EXISTING_CONFIG" ]] && return 1
    EXISTING_CONFIG="$EXISTING_CONFIG" python3 <<'PYEOF' 2>/dev/null
import os, sys
try:
    import yaml
except Exception:
    sys.exit(2)
try:
    doc = yaml.safe_load(os.environ.get("EXISTING_CONFIG", "")) or {}
except Exception:
    sys.exit(2)
sys.exit(0 if doc.get("enableUserWorkload") is True else 1)
PYEOF
}

if [[ "$CHECK_ONLY" == "true" ]]; then
    if already_enabled; then
        log_info "UWM enabled (enableUserWorkload: true)"
        exit 0
    else
        log_warn "UWM not enabled — run: make uwm"
        exit 1
    fi
fi

log_step "Enabling OpenShift User Workload Monitoring (UWM)"

if [[ -z "$EXISTING_CONFIG" ]]; then
    log_info "No existing cluster-monitoring-config — applying $UWM_DIR"
    run_cmd oc apply -k "$UWM_DIR"
elif already_enabled; then
    log_info "UWM already enabled — no changes"
else
    # ConfigMap exists with other keys; merge enableUserWorkload without dropping them.
    log_info "cluster-monitoring-config exists without enableUserWorkload — merging"
    NEW_YAML=$(EXISTING_CONFIG="$EXISTING_CONFIG" python3 <<'PYEOF'
import os, sys, yaml
doc = yaml.safe_load(os.environ.get("EXISTING_CONFIG", "")) or {}
doc['enableUserWorkload'] = True
sys.stdout.write(yaml.safe_dump(doc, default_flow_style=False).rstrip() + "\n")
PYEOF
)
    if [[ -z "$NEW_YAML" ]]; then
        log_error "Failed to produce merged config.yaml — aborting to avoid data loss"
        exit 1
    fi
    PATCH_JSON=$(NEW_YAML="$NEW_YAML" python3 -c 'import json, os; print(json.dumps({"data":{"config.yaml": os.environ["NEW_YAML"]}}))')
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would patch cm/cluster-monitoring-config with merged config.yaml:"
        echo "$NEW_YAML" | sed 's/^/[DRY RUN]   /'
    else
        oc patch cm cluster-monitoring-config -n openshift-monitoring \
            --type=merge -p "$PATCH_JSON"
    fi
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Skipping wait for prometheus-user-workload-0"
    exit 0
fi

log_info "Waiting up to 120s for prometheus-user-workload-0 pod to appear..."
UWM_TIMEOUT=120
UWM_ELAPSED=0
while (( UWM_ELAPSED < UWM_TIMEOUT )); do
    if oc get pod prometheus-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null; then
        log_info "prometheus-user-workload-0 present"
        log_info "UWM enabled."
        exit 0
    fi
    sleep 5
    UWM_ELAPSED=$((UWM_ELAPSED + 5))
    if (( UWM_ELAPSED % 30 == 0 )); then
        log_info "Still waiting... (${UWM_ELAPSED}s)"
    fi
done

log_warn "prometheus-user-workload-0 did not appear within ${UWM_TIMEOUT}s"
log_warn "cluster-monitoring-operator may take longer on fresh clusters. Check with:"
log_warn "  oc get pods -n openshift-user-workload-monitoring"
exit 0
