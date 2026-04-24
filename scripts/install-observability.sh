#!/usr/bin/env bash
#
# install-observability.sh - Install MaaS observability stack
#
# Enables the RHOAI 3.x Observability dashboard for MaaS by:
#   - Enabling OpenShift user-workload monitoring (UWM)
#   - Verifying the Kuadrant CR has spec.observability.enable=true (set via GitOps)
#   - Conditionally applying Limitador/Authorino ServiceMonitors (avoid duplicates)
#   - Conditionally applying Istio Gateway metrics Service + ServiceMonitor (requires MaaS gateway)
#   - Conditionally applying KServe LLM models ServiceMonitor (requires `llm` namespace)
#
# The GitOps-managed TelemetryPolicy (adds model/user/subscription labels) and
# Istio Telemetry (per-subscription latency) are deployed via the
# `instance-maas-observability` ArgoCD Application from
# `components/instances/maas-observability/base/`.
#
# Prerequisites:
#   - OpenShift cluster connection (oc whoami works)
#   - Kuadrant CRD present (kuadrants.kuadrant.io)
#   - Istio/Sail Telemetry CRD present (telemetries.telemetry.istio.io)
#
# Usage:
#   ./install-observability.sh [OPTIONS]
#
# Options:
#   --dry-run         Preview without applying
#   --uninstall       Revert observability (remove conditional monitors, disable Kuadrant observability)
#   -h, --help        Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/lib/observability-manifests"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; }

DRY_RUN=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run         Preview without applying
  --uninstall       Revert observability changes
  -h, --help        Show this help message
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# Track actions for final summary
APPLIED_ITEMS=()
SKIPPED_ITEMS=()

applied() { APPLIED_ITEMS+=("$1"); }
skipped() { SKIPPED_ITEMS+=("$1"); }

# Path constants for the overlay flip
OVERLAY_MAAS="components/instances/rhoai-instance/overlays/maas"
OVERLAY_MAAS_OBS="components/instances/rhoai-instance/overlays/maas-observability"

# Settle-gate master-memory threshold (percent). Overridable via env var.
# Raised from 75 -> 80 after observing the RHOAI 3.4 cascade on a constrained
# control plane (3x m5.2xlarge, 76% steady-state on the hottest master) land
# with ~0% master-memory delta. The operator ships OTel as a 2-replica
# StatefulSet on workers (not a per-master DaemonSet), and Tempo + NodeMetrics
# are absent on this release, so masters only absorb modest apiserver
# watch-cache growth. 80% leaves ~10% headroom above the observed worst case
# while still protecting older releases that had heavier master-side cascades.
SETTLE_GATE_MASTER_MEM_MAX="${SETTLE_GATE_MASTER_MEM_MAX:-80}"

# Abort the install with a clear message. Used by the settle-gate.
abort_settle_gate() {
    log_error "Settle-gate refused: $1"
    log_error "Re-run 'make observability' once the underlying issue clears."
    exit 1
}

# Check all CSVs named in the argument list (format: csv-prefix:namespace) are
# Succeeded. Returns 0 if all good, non-zero with a message otherwise.
settle_check_csvs() {
    local failed=""
    for entry in "$@"; do
        local prefix="${entry%%:*}"
        local ns="${entry##*:}"
        local line
        line=$(oc get csv -n "$ns" --no-headers 2>/dev/null | awk -v p="$prefix" '$1 ~ "^"p {print; exit}')
        if [[ -z "$line" ]]; then
            failed+=" ${prefix}@${ns}(missing)"
            continue
        fi
        local phase
        phase=$(awk '{print $NF}' <<< "$line")
        if [[ "$phase" != "Succeeded" ]]; then
            failed+=" ${prefix}@${ns}($phase)"
        fi
    done
    if [[ -n "$failed" ]]; then
        echo "CSVs not Succeeded:$failed"
        return 1
    fi
    return 0
}

# Verify the cluster can absorb the monitoring cascade. See plan §3 #4
# settle-gate checklist.
run_settle_gate() {
    log_step "Phase S: Settle-gate — verifying cluster is ready for observability cascade"

    # 1. Required operator CSVs all Succeeded.
    # Contract: settle_check_csvs prints failures to stdout AND returns non-zero
    # on failure, prints nothing AND returns zero on success. We rely on the
    # stdout signal, not the exit code (the `|| true` is here so set -e doesn't
    # abort before we can read $csv_report; an empty $csv_report = pass).
    local csv_report
    csv_report=$(settle_check_csvs \
        "rhods-operator:redhat-ods-operator" \
        "cluster-observability-operator:openshift-cluster-observability-operator" \
        "opentelemetry-operator:openshift-operators" \
        "servicemeshoperator3:openshift-operators" \
        "authorino-operator:kuadrant-system" \
        "limitador-operator:kuadrant-system" 2>&1) || true
    if [[ -n "$csv_report" ]]; then
        abort_settle_gate "$csv_report"
    fi
    log_info "  ✓ Required operator CSVs Succeeded"

    # 2. DSC + DSCI healthy. DSC uses Ready=True; DSCI uses Available=True +
    # Degraded=False (it does NOT have a Ready condition — checked the operator
    # source, the conditions emitted are ReconcileComplete/Available/Progressing/
    # Degraded/Upgradeable). Treat DSC.Ready=False as ok ONLY if the only failing
    # subcomponent is modelsasservice (expected before make maas runs); but at
    # this point in the flow MaaS is already installed, so any DSC.Ready != True
    # is a real block.
    local dsc_ready dsci_avail dsci_degraded
    dsc_ready=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    dsci_avail=$(oc get dscinitialization default-dsci -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
    dsci_degraded=$(oc get dscinitialization default-dsci -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
    if [[ "$dsc_ready" != "True" ]]; then
        abort_settle_gate "DataScienceCluster/default-dsc Ready=$dsc_ready (must be True)"
    fi
    if [[ "$dsci_avail" != "True" ]]; then
        abort_settle_gate "DSCInitialization/default-dsci Available=$dsci_avail (must be True)"
    fi
    if [[ "$dsci_degraded" == "True" ]]; then
        abort_settle_gate "DSCInitialization/default-dsci Degraded=True (must be False)"
    fi
    log_info "  ✓ DSC Ready=True, DSCI Available=True / Degraded=False"

    # 3. No CrashLoopBackOff / non-terminal pods in the core namespaces.
    # NOTE: oc/kubectl ignore all but the LAST -n flag, so we must loop.
    local bad_pods=0
    for ns in redhat-ods-applications kuadrant-system openshift-monitoring; do
        local n
        n=$(oc get pods -n "$ns" --field-selector=status.phase!=Running,status.phase!=Succeeded \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        bad_pods=$(( bad_pods + ${n:-0} ))
    done
    if (( bad_pods > 0 )); then
        abort_settle_gate "$bad_pods non-Running/non-Succeeded pod(s) across redhat-ods-applications/kuadrant-system/openshift-monitoring. Inspect: for ns in redhat-ods-applications kuadrant-system openshift-monitoring; do oc get pods -n \$ns --field-selector=status.phase!=Running,status.phase!=Succeeded; done"
    fi
    log_info "  ✓ No non-terminal pods in core namespaces"

    # 4. etcd CO Degraded=False
    local etcd_degraded
    etcd_degraded=$(oc get co etcd -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
    if [[ "$etcd_degraded" == "True" ]]; then
        abort_settle_gate "ClusterOperator/etcd is Degraded=True. Do not fire an observability cascade against a degraded control plane."
    fi
    log_info "  ✓ etcd Available + Degraded=False"

    # 5. Masters <75% memory. Skip silently if metrics-server unavailable (OCP dep).
    # `|| true` is required because under `set -euo pipefail` a non-zero from the
    # command substitution would abort the script before we can check $top_out.
    local top_out
    top_out=$(oc adm top nodes -l node-role.kubernetes.io/master --no-headers 2>&1) || true
    if [[ -n "$top_out" ]] && ! [[ "$top_out" =~ "metrics not available" ]] && ! [[ "$top_out" =~ "Metrics API not available" ]] && ! [[ "$top_out" =~ "error:" ]]; then
        local worst_pct=0 worst_name=""
        while read -r line; do
            [[ -z "$line" ]] && continue
            local name pct
            name=$(awk '{print $1}' <<< "$line")
            pct=$(awk '{print $5}' <<< "$line" | tr -d '%')
            [[ ! "$pct" =~ ^[0-9]+$ ]] && continue
            if (( pct > worst_pct )); then
                worst_pct=$pct; worst_name="$name"
            fi
        done <<< "$top_out"
        if (( worst_pct >= SETTLE_GATE_MASTER_MEM_MAX )); then
            abort_settle_gate "Master $worst_name at ${worst_pct}% memory (threshold <${SETTLE_GATE_MASTER_MEM_MAX}%). On RHOAI 3.4 the cascade typically adds 0-5% to master memory (OTel deploys as a StatefulSet on workers); older releases with DaemonSet OTel could add 10-15%. Resize the control plane, wait for recovery, or set SETTLE_GATE_MASTER_MEM_MAX=<n> to override before proceeding."
        fi
        log_info "  ✓ Masters <${SETTLE_GATE_MASTER_MEM_MAX}% memory (worst: $worst_name at ${worst_pct}%)"
    else
        log_info "  ~ metrics-server unavailable — master pressure check skipped"
    fi

    log_info "Settle-gate passed. Proceeding with overlay flip."
}

# Get current source.path for the instance-rhoai Application.
get_rhoai_app_path() {
    oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.path}' 2>/dev/null || echo ""
}

# Flip the instance-rhoai Application source.path to a given overlay.
# Patches ArgoCD; ArgoCD reconciles the DSCI change into the cluster.
set_rhoai_app_path() {
    local target_path="$1"
    local label="$2"  # human-readable for logging

    local current
    current=$(get_rhoai_app_path)
    if [[ -z "$current" ]]; then
        log_error "Application instance-rhoai not found in openshift-gitops — cannot flip overlay"
        log_error "Has 'make deploy' run? This flip requires an existing ArgoCD Application."
        exit 1
    fi
    if [[ "$current" == "$target_path" ]]; then
        log_info "instance-rhoai already at $label ($target_path) — no flip needed"
        return 0
    fi
    # Warn if the current path is neither known overlay — someone hand-patched
    # it. Don't refuse (the flip may be the correct unstuck), but make sure
    # the user sees what they're overwriting.
    if [[ "$current" != "$OVERLAY_MAAS" && "$current" != "$OVERLAY_MAAS_OBS" ]]; then
        log_warn "instance-rhoai source.path is at an UNKNOWN location: $current"
        log_warn "Expected $OVERLAY_MAAS or $OVERLAY_MAAS_OBS."
        log_warn "Overlay flip will overwrite it with $target_path."
        log_warn "If you intentionally pointed it elsewhere, abort now (Ctrl-C); otherwise it auto-proceeds in 5s."
        sleep 5
    fi
    log_info "Flipping instance-rhoai source.path: $current -> $target_path ($label)"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would: oc patch application.argoproj.io/instance-rhoai -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"path\":\"$target_path\"}}}'"
        return 0
    fi
    oc patch application.argoproj.io/instance-rhoai -n openshift-gitops \
        --type=merge -p "{\"spec\":{\"source\":{\"path\":\"$target_path\"}}}"
    # Nudge ArgoCD to reconcile immediately instead of waiting for the next sync.
    oc annotate application.argoproj.io/instance-rhoai -n openshift-gitops \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
    log_info "Patch applied."
}

# Wait up to timeout seconds for DSCI to reflect the monitoring.metrics field
# AND the RHOAI operator to have created the Perses CR. Returns 0 on success,
# non-zero on timeout (which is warn-level — cascade may still complete later).
wait_for_monitoring_cascade() {
    local timeout="${1:-600}"
    local deadline=$(( $(date +%s) + timeout ))

    log_info "Waiting up to ${timeout}s for ArgoCD reconcile + Perses CR creation..."
    while (( $(date +%s) < deadline )); do
        local metrics_set
        metrics_set=$(oc get dscinitialization default-dsci -o jsonpath='{.spec.monitoring.metrics.storage}' 2>/dev/null || echo "")
        local perses_exists=""
        if oc get crd perses.perses.dev &>/dev/null; then
            perses_exists=$(oc get perses -n redhat-ods-monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
        fi
        if [[ -n "$metrics_set" ]] && (( ${perses_exists:-0} > 0 )); then
            log_info "DSCI metrics applied; Perses CR present in redhat-ods-monitoring."
            return 0
        fi
        sleep 10
    done
    log_warn "Did not observe DSCI metrics + Perses within ${timeout}s. Monitoring cascade may still complete later; monitor with:"
    log_warn "  oc get dscinitialization default-dsci -o jsonpath='{.spec.monitoring.metrics}'"
    log_warn "  oc get perses -n redhat-ods-monitoring"
    return 1
}

# =============================================================================
# Phase 1: Preflight checks
# =============================================================================
log_step "Phase 1: Preflight checks"

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# Check Kuadrant CRD
KUADRANT_CRD_OK=true
if ! oc get crd kuadrants.kuadrant.io &>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
        log_warn "Kuadrant CRD (kuadrants.kuadrant.io) not found — continuing (dry-run)"
        KUADRANT_CRD_OK=false
    else
        log_warn "Kuadrant CRD (kuadrants.kuadrant.io) not found — some steps will be skipped"
        KUADRANT_CRD_OK=false
    fi
else
    log_info "Kuadrant CRD found"
fi

# Check Istio Telemetry CRD
ISTIO_TELEMETRY_CRD_OK=true
if ! oc get crd telemetries.telemetry.istio.io &>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
        log_warn "Istio Telemetry CRD (telemetries.telemetry.istio.io) not found — continuing (dry-run)"
        ISTIO_TELEMETRY_CRD_OK=false
    else
        log_warn "Istio Telemetry CRD (telemetries.telemetry.istio.io) not found — GitOps resources may not sync"
        ISTIO_TELEMETRY_CRD_OK=false
    fi
else
    log_info "Istio Telemetry CRD found"
fi

# =============================================================================
# UNINSTALL PATH
# =============================================================================
if [ "$UNINSTALL" = true ]; then
    log_step "Uninstall: reverting MaaS observability"

    # Reverse-flip: instance-rhoai back to overlays/maas so DSCI monitoring.metrics
    # is removed and ArgoCD reconciles the monitoring cascade down. The RHOAI
    # operator will tear down MonitoringStack/Perses/Tempo/OTel as part of
    # that reconcile.
    set_rhoai_app_path "$OVERLAY_MAAS" "maas (observability off)"
    applied "instance-rhoai source -> $OVERLAY_MAAS (monitoring cascade will tear down)"

    # Kuadrant observability.enable is GitOps-managed in
    # components/instances/connectivity-link-instance/base/kuadrant.yaml.
    # To disable it, edit that file and let ArgoCD reconcile, OR run:
    #   oc patch kuadrant kuadrant -n kuadrant-system --type=merge \
    #     -p '{"spec":{"observability":{"enable":false}}}'
    # (ArgoCD will flip it back to true on next sync unless the git manifest is changed first)
    log_info "NOTE: Kuadrant observability is GitOps-managed — uninstall does not disable it."
    log_info "      To disable: edit components/instances/connectivity-link-instance/base/kuadrant.yaml"

    # Delete conditional ServiceMonitors labelled by this script
    log_info "Deleting conditional MaaS observability monitors (label app.kubernetes.io/part-of=maas-observability)"
    run_cmd oc delete servicemonitor,service -n kuadrant-system \
        -l app.kubernetes.io/part-of=maas-observability --ignore-not-found
    run_cmd oc delete servicemonitor,service -n openshift-ingress \
        -l app.kubernetes.io/managed-by=maas-observability --ignore-not-found
    # Also clean up the KServe LLM ServiceMonitor in the model namespace if present.
    if oc get ns llm &>/dev/null; then
        run_cmd oc delete servicemonitor -n llm \
            -l app.kubernetes.io/managed-by=maas-observability --ignore-not-found
    fi
    applied "Deleted label-matched ServiceMonitors/Services"

    echo ""
    log_info "========================================="
    log_info "MaaS Observability Uninstall Summary"
    log_info "========================================="
    for item in "${APPLIED_ITEMS[@]}"; do
        log_info "  - $item"
    done
    log_info ""
    log_info "Note: cluster-monitoring-config (enableUserWorkload) was NOT removed."
    log_info "Other workloads / admins may depend on user-workload monitoring and/or"
    log_info "other keys (prometheusK8s.retention, alertmanagerMain, etc)."
    # Inspect the live ConfigMap and tailor the guidance
    UNINSTALL_EXISTING=$(oc get cm cluster-monitoring-config -n openshift-monitoring \
        -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
    if [ -n "$UNINSTALL_EXISTING" ]; then
        ONLY_UWM=$(EXISTING_CONFIG="$UNINSTALL_EXISTING" python3 <<'PYEOF' 2>/dev/null || echo "unknown"
import os, sys
try:
    import yaml
except Exception:
    print("unknown"); sys.exit(0)
try:
    doc = yaml.safe_load(os.environ.get("EXISTING_CONFIG", "")) or {}
except Exception:
    print("unknown"); sys.exit(0)
print("true" if list(doc.keys()) == ["enableUserWorkload"] and doc.get("enableUserWorkload") is True else "false")
PYEOF
)
        if [ "$ONLY_UWM" = "true" ]; then
            log_info "The ConfigMap currently has ONLY enableUserWorkload: true — safe to delete:"
            log_info "  oc delete cm cluster-monitoring-config -n openshift-monitoring"
        else
            log_info "The ConfigMap contains other keys besides enableUserWorkload — DO NOT blanket-delete it."
            log_info "To disable UWM only, edit the ConfigMap and set enableUserWorkload: false (or remove it):"
            log_info "  oc edit cm cluster-monitoring-config -n openshift-monitoring"
        fi
    else
        log_info "No cluster-monitoring-config present — nothing to remove."
    fi
    log_info "========================================="
    log_info ""
    log_info "Note: GitOps-managed TelemetryPolicy / Istio Telemetry are not removed here."
    log_info "They are managed by the instance-maas-observability ArgoCD Application."
    log_info "========================================="
    log_info ""
    log_info "Note: The openshift.io/cluster-monitoring label (if previously removed from"
    log_info "kuadrant-system, openshift-ingress, llm, or redhat-ods-applications by"
    log_info "install) is NOT restored automatically — the install removed it because it"
    log_info "conflicts with user-workload-monitoring scraping. If you need it back:"
    log_info "  oc label namespace <ns> openshift.io/cluster-monitoring=true --overwrite"
    log_info "========================================="
    exit 0
fi

# =============================================================================
# Phase A: Verify OpenShift User Workload Monitoring (UWM) is enabled
# =============================================================================
# UWM is now owned by `make infra` (scripts/enable-uwm.sh), not this script.
# We only verify the ConfigMap flag here so any MaaS observability work that
# depends on UWM fails fast with a clear pointer if it's missing.
log_step "Phase A: Verify UWM is enabled"

if ! "$SCRIPT_DIR/enable-uwm.sh" --check 2>/dev/null; then
    log_error "User Workload Monitoring is not enabled."
    log_error "UWM is now part of infrastructure setup. Run one of:"
    log_error "  make uwm     (enable UWM only)"
    log_error "  make infra   (ICSP + CPU + GPU + UWM)"
    exit 1
fi
log_info "UWM enabled (cluster-monitoring-config has enableUserWorkload: true)"
applied "UWM verified (owned by make infra / scripts/enable-uwm.sh)"

# =============================================================================
# Phase A2: Scrub openshift.io/cluster-monitoring label from MaaS namespaces
# =============================================================================
# The cluster-monitoring-operator scrapes any namespace labelled
# openshift.io/cluster-monitoring=true via the platform Prometheus. For MaaS
# namespaces we want user-workload-monitoring (UWM) to own scraping — if both
# are active we get duplicate scrapes and UWM coverage can silently drop from
# dashboards. Mirrors upstream install-observability.sh (kuadrant-system, llm,
# MaaS API ns). Our cluster is greenfield, so this is typically a no-op.
log_step "Phase A2: Scrub openshift.io/cluster-monitoring label from MaaS namespaces"

SCRUBBED_NS=()
for ns in kuadrant-system llm redhat-ods-applications; do
    if oc get ns "$ns" >/dev/null 2>&1; then
        label=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null || true)
        if [ -n "$label" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would remove openshift.io/cluster-monitoring label from namespace $ns"
            else
                log_info "Removing openshift.io/cluster-monitoring label from namespace $ns (conflicts with UWM scraping)"
                oc label namespace "$ns" openshift.io/cluster-monitoring- >/dev/null 2>&1 || true
            fi
            SCRUBBED_NS+=("$ns")
        fi
    fi
done

if [ ${#SCRUBBED_NS[@]} -eq 0 ]; then
    log_info "No MaaS namespaces carry the openshift.io/cluster-monitoring label — nothing to scrub"
    skipped "openshift.io/cluster-monitoring label scrub (no labels found)"
else
    applied "Scrubbed openshift.io/cluster-monitoring label from: ${SCRUBBED_NS[*]}"
fi

# =============================================================================
# Phase S: Settle-gate (refuses if cluster can't absorb the observability cascade)
# =============================================================================
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping settle-gate"
else
    run_settle_gate
    applied "Settle-gate passed (operators Succeeded, DSC/DSCI Ready, pods Running, etcd healthy, masters <75% mem)"
fi

# =============================================================================
# Phase O: Flip instance-rhoai Application source -> overlays/maas-observability
# =============================================================================
log_step "Phase O: Flip instance-rhoai overlay -> maas-observability"

set_rhoai_app_path "$OVERLAY_MAAS_OBS" "maas-observability"
if [ "$DRY_RUN" = false ]; then
    wait_for_monitoring_cascade 600 || true

    # Post-flip sanity: verify cascade pods reach Running. wait_for_monitoring_cascade
    # only confirms the Perses CR and DSCI.metrics.storage are set; it does not
    # verify any pod is actually Running. If a future release brings back
    # DaemonSet OTel and a master is pressured, pods could sit Pending and we
    # would silently succeed. Warn-level (not abort) because we've already
    # flipped the overlay — this is a "cascade still landing" signal, not a
    # gate error.
    log_step "Phase V: Verify cascade pods reach Running (timeout 120s)"
    pod_deadline=$(( $(date +%s) + 120 ))
    pod_bad=0
    pod_total=0
    while (( $(date +%s) < pod_deadline )); do
        pod_bad=$(oc get pods -n redhat-ods-monitoring \
            --field-selector=status.phase!=Running,status.phase!=Succeeded \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pod_total=$(oc get pods -n redhat-ods-monitoring --no-headers 2>/dev/null \
            | wc -l | tr -d ' ')
        if (( pod_total > 0 && pod_bad == 0 )); then
            log_info "  ✓ All $pod_total cascade pods Running in redhat-ods-monitoring"
            break
        fi
        sleep 5
    done
    if (( pod_bad > 0 )); then
        log_warn "$pod_bad pod(s) in redhat-ods-monitoring not Running after 120s:"
        oc get pods -n redhat-ods-monitoring \
            --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
        log_warn "Cascade may still be landing, or a pod is stuck. Check with 'oc get pods -n redhat-ods-monitoring'."
    fi

    applied "instance-rhoai source -> $OVERLAY_MAAS_OBS (monitoring cascade triggered)"
else
    applied "[DRY RUN] instance-rhoai source -> $OVERLAY_MAAS_OBS"
fi

# =============================================================================
# Phase B: Verify Kuadrant observability
# =============================================================================
# `spec.observability.enable: true` is set declaratively in
# components/instances/connectivity-link-instance/base/kuadrant.yaml and
# reconciled by ArgoCD. This phase only verifies the CR has the flag, to
# surface drift early. Previously this was an imperative `oc patch` which
# raced with GitOps self-heal.
log_step "Phase B: Verify Kuadrant observability"

if [ "$KUADRANT_CRD_OK" = false ]; then
    log_skip "Kuadrant CRD not installed — skipping Phase B"
    skipped "Kuadrant observability verification (CRD missing)"
else
    KUADRANT_CR=$(oc get kuadrant -n kuadrant-system -o name 2>/dev/null | head -1 || true)
    if [ -z "$KUADRANT_CR" ]; then
        log_warn "No Kuadrant CR found in kuadrant-system — GitOps may not have synced instance-kuadrant yet"
        skipped "Kuadrant observability verification (no CR)"
    else
        OBS_ENABLED=$(oc get "$KUADRANT_CR" -n kuadrant-system -o jsonpath='{.spec.observability.enable}' 2>/dev/null || echo "")
        if [ "$OBS_ENABLED" = "true" ]; then
            log_info "$KUADRANT_CR has observability.enable=true (GitOps-managed)"
            applied "Kuadrant observability verified on $KUADRANT_CR"
        else
            log_warn "$KUADRANT_CR does NOT have observability.enable=true"
            log_warn "Expected GitOps to reconcile it from components/instances/connectivity-link-instance/base/kuadrant.yaml"
            log_warn "Check: oc get application.argoproj.io instance-kuadrant -n openshift-gitops"
            skipped "Kuadrant observability verification (flag not yet reconciled)"
        fi
    fi
fi

# =============================================================================
# Phase C: Conditionally apply Limitador ServiceMonitor
# =============================================================================
log_step "Phase C: Limitador ServiceMonitor (conditional)"

# Wait briefly for the Kuadrant operator to reconcile observability and create
# its own limitador monitor. This reduces the race where our standalone
# ServiceMonitor gets applied on top, causing duplicate scrapes. If the
# operator hasn't created one after 60s, we fall through to the previous
# conditional-apply behavior.
if [ "$KUADRANT_CRD_OK" = true ] && [ "$DRY_RUN" = false ]; then
    log_info "Waiting up to 60s for Kuadrant operator to reconcile observability monitors..."
    for _ in $(seq 1 12); do
        if oc get podmonitors.monitoring.coreos.com,servicemonitors.monitoring.coreos.com \
                -n kuadrant-system -o name 2>/dev/null | grep -qi limitador; then
            log_info "Kuadrant limitador monitor found — Phase C will skip duplicate"
            break
        fi
        sleep 5
    done
elif [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would wait up to 60s for Kuadrant operator to create its limitador monitor"
fi

EXISTING_LIMITADOR_MONS=$(oc get podmonitors,servicemonitors -n kuadrant-system -o name 2>/dev/null | grep -i limitador || true)
if [ -n "$EXISTING_LIMITADOR_MONS" ]; then
    log_skip "Existing Limitador monitor(s) detected:"
    echo "$EXISTING_LIMITADOR_MONS" | while read -r line; do
        [ -n "$line" ] && log_skip "   $line"
    done
    log_skip "Skipping limitador-servicemonitor to avoid duplicate metrics"
    skipped "limitador-servicemonitor (existing monitor present)"
else
    log_info "No existing Limitador monitor found — applying $MANIFEST_DIR/limitador-servicemonitor.yaml"
    run_cmd oc apply -f "$MANIFEST_DIR/limitador-servicemonitor.yaml"
    applied "limitador-servicemonitor (kuadrant-system)"
fi

# =============================================================================
# Phase D: Conditionally apply Authorino ServiceMonitor
# =============================================================================
log_step "Phase D: Authorino server-metrics ServiceMonitor (conditional)"

# Check if any existing monitor in kuadrant-system already references authorino
# with port=server-metrics (either via JSON output or by name heuristic).
EXISTING_AUTHORINO_MONS=""
if oc get podmonitors,servicemonitors -n kuadrant-system -o json &>/dev/null; then
    # Search for any endpoint/port that looks like server-metrics on an authorino monitor
    EXISTING_AUTHORINO_MONS=$(oc get podmonitors,servicemonitors -n kuadrant-system -o json 2>/dev/null \
        | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data.get("items", [])
hits = []
for it in items:
    name = it.get("metadata", {}).get("name", "")
    kind = it.get("kind", "")
    spec = it.get("spec", {})
    # Iterate endpoints/podMetricsEndpoints looking for server-metrics port
    endpoints = spec.get("endpoints", []) or spec.get("podMetricsEndpoints", []) or []
    for ep in endpoints:
        port = ep.get("port", "") or ep.get("targetPort", "")
        path = ep.get("path", "")
        port_str = str(port)
        if "authorino" in name.lower() and (port_str == "server-metrics" or "server-metrics" in path):
            hits.append(f"{kind}/{name}")
            break
for h in hits:
    print(h)
' 2>/dev/null || true)
fi

if [ -n "$EXISTING_AUTHORINO_MONS" ]; then
    log_skip "Existing Authorino server-metrics monitor(s) detected:"
    echo "$EXISTING_AUTHORINO_MONS" | while read -r line; do
        [ -n "$line" ] && log_skip "   $line"
    done
    log_skip "Skipping authorino-server-metrics-servicemonitor"
    skipped "authorino-server-metrics-servicemonitor (existing monitor present)"
else
    log_info "No existing Authorino server-metrics monitor found — applying"
    run_cmd oc apply -f "$MANIFEST_DIR/authorino-server-metrics-servicemonitor.yaml"
    applied "authorino-server-metrics-servicemonitor (kuadrant-system)"
fi

# =============================================================================
# Phase E: Conditionally apply Istio Gateway Service + ServiceMonitor
# =============================================================================
log_step "Phase E: Istio Gateway metrics Service + ServiceMonitor (conditional)"

GW_DEPLOY_COUNT=$(oc get deploy -n openshift-ingress \
    -l 'gateway.networking.k8s.io/gateway-name=maas-default-gateway' \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "${GW_DEPLOY_COUNT:-0}" -gt 0 ]; then
    log_info "Found $GW_DEPLOY_COUNT gateway deployment(s) for maas-default-gateway"
    run_cmd oc apply -f "$MANIFEST_DIR/istio-gateway-service.yaml"
    applied "istio-gateway-metrics Service (openshift-ingress)"
    run_cmd oc apply -f "$MANIFEST_DIR/istio-gateway-servicemonitor.yaml"
    applied "istio-gateway-metrics ServiceMonitor (openshift-ingress)"
else
    log_skip "No maas-default-gateway deployment in openshift-ingress yet"
    log_skip "Re-run 'make observability' after 'make maas' provisions the gateway"
    skipped "istio-gateway-metrics Service+ServiceMonitor (gateway not present)"
fi

# =============================================================================
# Phase F: Conditionally apply KServe LLM models ServiceMonitor
# =============================================================================
log_step "Phase F: KServe LLM models ServiceMonitor (conditional)"

# Only applies when a `llm` namespace exists (our LLMInferenceService convention).
# This ServiceMonitor scrapes vllm:* metrics from pods labelled
# app.kubernetes.io/part-of=llminferenceservice on port 8000 and feeds the Perses
# dashboard vLLM panels.
if oc get ns llm &>/dev/null; then
    log_info "Namespace 'llm' found — applying $MANIFEST_DIR/kserve-llm-models-servicemonitor.yaml"
    run_cmd oc apply -f "$MANIFEST_DIR/kserve-llm-models-servicemonitor.yaml"
    applied "kserve-llm-models ServiceMonitor (llm)"
else
    log_skip "Namespace 'llm' not found — skipping KServe vLLM ServiceMonitor."
    log_skip "Run this script again after deploying a model (e.g. 'make maas-model')."
    skipped "kserve-llm-models ServiceMonitor (llm namespace not present)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_info "========================================="
log_info "MaaS Observability Install Summary"
log_info "========================================="
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] No changes applied"
fi
log_info "Applied:"
if [ ${#APPLIED_ITEMS[@]} -eq 0 ]; then
    log_info "  (none)"
else
    for item in "${APPLIED_ITEMS[@]}"; do
        log_info "  + $item"
    done
fi
log_info ""
log_info "Skipped:"
if [ ${#SKIPPED_ITEMS[@]} -eq 0 ]; then
    log_info "  (none)"
else
    for item in "${SKIPPED_ITEMS[@]}"; do
        log_info "  - $item"
    done
fi
log_info "========================================="
log_info ""
log_info "Next steps:"
log_info "  1. GitOps syncs instance-maas-observability (TelemetryPolicy + Istio Telemetry)"
log_info "  2. Fire inference against a MaaS model, wait ~2 min for scrapes"
log_info "  3. Open RHOAI console -> Observability dashboard"
log_info "  4. Run 'make diagnose' and look at section 9 (Observability)"
log_info "========================================="
