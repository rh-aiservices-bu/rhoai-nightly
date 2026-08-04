#!/usr/bin/env bash
#
# install-evalhub.sh - Enable eval-hub by creating a dedicated ArgoCD Application
#
# Eval-hub is a TrustyAI evaluation harness layered on top of RHOAI. The
# manifests (EvalHub CR, MLflow CR, DataSciencePipelinesApplication, the
# evalhub-tenant namespace, RBAC, and a hook Job that wires DSPA's MinIO
# secret) live under components/instances/evalhub/ and are deployed via
# their own ArgoCD Application. This makes eval-hub orthogonal to MaaS
# and observability — the three features compose freely without a
# combinatorial overlay tree on instance-rhoai.
#
# This script:
#   - Runs a lightweight settle-gate (rhods-operator Succeeded, DSC/DSCI
#     Ready, default StorageClass present)
#   - Creates the instance-evalhub ArgoCD Application pointed at
#     components/instances/evalhub on the same repo+branch as
#     instance-rhoai (matches the install-maas.sh pattern)
#   - Waits for resources to reconcile and pods to come up (warn-only
#     post-flip)
#
# --uninstall:
#   - Deletes the instance-evalhub Application with cascade. The
#     resources-finalizer.argocd.argoproj.io finalizer prunes EvalHub,
#     MLflow, DSPA, evalhub-tenant ns + RBAC + Job before the Application
#     finishes deleting.
#
# Eval-hub is opt-in (not part of make all) because it requires a
# default StorageClass (MLflow PVC + DSPA-managed MinIO PVC). See
# CLAUDE.md "Eval Hub" for the full rationale.
#
# Prerequisites:
#   - OpenShift cluster connection (oc whoami works)
#   - instance-rhoai ArgoCD Application present (used to detect repoURL/branch)
#
# Usage:
#   ./install-evalhub.sh [OPTIONS]
#
# Options:
#   --dry-run         Preview without applying
#   --uninstall       Delete the instance-evalhub Application (cascade-prunes resources)
#   -h, --help        Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  --uninstall       Delete the instance-evalhub Application (prunes resources)
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

EVALHUB_APP_NAME="instance-evalhub"
EVALHUB_PATH="components/instances/evalhub"

abort_settle_gate() {
    log_error "Settle-gate refused: $1"
    log_error "Re-run 'make evalhub' once the underlying issue clears."
    exit 1
}

# Lightweight settle-gate. Eval-hub doesn't pressure the control plane the
# way the observability cascade does, so we skip the master-memory and
# pod-CrashLoop checks and only verify the cluster has the prerequisites
# eval-hub actually needs:
#   1. rhods-operator CSV Succeeded (operator owns EvalHub/MLflow/DSPA CRs)
#   2. DSC Ready + DSCI Available + DSCI not Degraded
#   3. At least one default StorageClass (MLflow + DSPA MinIO need RWO PVCs)
run_settle_gate() {
    log_step "Phase S: Settle-gate — verifying cluster is ready for eval-hub"

    # 1. rhods-operator CSV Succeeded.
    local csv_phase
    csv_phase=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null \
        | awk '$1 ~ /^rhods-operator/ {print $NF; exit}')
    if [[ -z "$csv_phase" ]]; then
        abort_settle_gate "rhods-operator CSV not found in redhat-ods-operator namespace"
    fi
    if [[ "$csv_phase" != "Succeeded" ]]; then
        abort_settle_gate "rhods-operator CSV phase=$csv_phase (must be Succeeded)"
    fi
    log_info "  ✓ rhods-operator CSV Succeeded"

    # 2. DSC Ready + DSCI Available + DSCI not Degraded.
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

    # 3. Default StorageClass exists. Eval-hub creates two RWO PVCs (MLflow
    # backend + DSPA-managed MinIO); without a default SC they'd both sit
    # Pending and the patch-secret Job would race-loop on the missing
    # ds-pipeline-s3-dspa secret until backoffLimit:3 exhausts.
    local default_sc
    default_sc=$(oc get storageclass -o json 2>/dev/null \
        | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in data.get("items", []):
    annot = it.get("metadata", {}).get("annotations", {}) or {}
    if annot.get("storageclass.kubernetes.io/is-default-class") == "true":
        print(it.get("metadata", {}).get("name", ""))
        break
' 2>/dev/null || echo "")
    if [[ -z "$default_sc" ]]; then
        abort_settle_gate "No default StorageClass found. MLflow needs a 10Gi RWO PVC and DSPA spins up its own MinIO PVC; both will sit Pending without one. Set a default with: oc patch storageclass <name> -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
    fi
    log_info "  ✓ Default StorageClass: $default_sc"

    log_info "Settle-gate passed. Proceeding with Application creation."
}

# Wait up to timeout seconds for eval-hub resources to reconcile. Returns
# 0 on success, non-zero on timeout (warn-level — resources may still
# converge later).
wait_for_evalhub_cascade() {
    local timeout="${1:-600}"
    local deadline=$(( $(date +%s) + timeout ))

    log_info "Waiting up to ${timeout}s for EvalHub Ready + MLflow + DSPA + evalhub-tenant ns..."
    while (( $(date +%s) < deadline )); do
        local evalhub_phase mlflow_present dspa_present ns_present
        evalhub_phase=$(oc get evalhub evalhub -n redhat-ods-applications \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        # MLflow CR has no .status.phase to wait on; existence is enough.
        mlflow_present=$(oc get mlflow mlflow -n redhat-ods-applications --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        dspa_present=$(oc get dspa dspa -n evalhub-tenant --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        ns_present=$(oc get ns evalhub-tenant --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)

        if [[ "$evalhub_phase" == "Ready" ]] \
                && (( ${mlflow_present:-0} > 0 )) \
                && (( ${dspa_present:-0} > 0 )) \
                && (( ${ns_present:-0} > 0 )); then
            log_info "EvalHub Ready, MLflow + DSPA reconciled, evalhub-tenant ns present."
            return 0
        fi
        sleep 10
    done
    log_warn "Did not observe EvalHub Ready + MLflow + DSPA + evalhub-tenant ns within ${timeout}s. Resources may still converge later; monitor with:"
    log_warn "  oc get evalhub -n redhat-ods-applications"
    log_warn "  oc get mlflow -n redhat-ods-applications"
    log_warn "  oc get dspa -n evalhub-tenant"
    log_warn "  oc get application.argoproj.io/$EVALHUB_APP_NAME -n openshift-gitops"
    return 1
}

# Phase V-style post-create pod-readiness check. Polls both
# redhat-ods-applications (eval-hub + mlflow pods) and evalhub-tenant
# (DSPA + MinIO pods) for up to 120s. Warn-level only — by this point
# the Application is created. Reuses the `|| echo 0` defenses from PR #10
# so missing namespaces don't crash under set -euo pipefail.
phase_v_pod_check() {
    log_step "Phase V: Verify eval-hub pods reach Running (timeout 120s)"
    local pod_deadline=$(( $(date +%s) + 120 ))
    local rhods_bad=0 rhods_total=0 tenant_bad=0 tenant_total=0
    while (( $(date +%s) < pod_deadline )); do
        # eval-hub + mlflow pods live in redhat-ods-applications. Filter by
        # name prefix to ignore unrelated RHOAI pods.
        rhods_total=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null \
            | grep -E '^(evalhub|mlflow)' | wc -l | tr -d ' ' || echo 0)
        rhods_bad=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null \
            | grep -E '^(evalhub|mlflow)' \
            | awk '$3 != "Running" && $3 != "Completed" {c++} END {print c+0}' || echo 0)

        tenant_bad=$(oc get pods -n evalhub-tenant \
            --field-selector=status.phase!=Running,status.phase!=Succeeded \
            --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        tenant_total=$(oc get pods -n evalhub-tenant --no-headers 2>/dev/null \
            | wc -l | tr -d ' ' || echo 0)

        if (( ${rhods_total:-0} > 0 && ${rhods_bad:-0} == 0 \
              && ${tenant_total:-0} > 0 && ${tenant_bad:-0} == 0 )); then
            log_info "  ✓ All ${rhods_total} eval-hub/mlflow pods + ${tenant_total} evalhub-tenant pods Running"
            return 0
        fi
        sleep 5
    done

    if (( ${rhods_bad:-0} > 0 )); then
        log_warn "${rhods_bad} eval-hub/mlflow pod(s) in redhat-ods-applications not Running after 120s:"
        oc get pods -n redhat-ods-applications --no-headers 2>/dev/null \
            | grep -E '^(evalhub|mlflow)' | awk '$3 != "Running" && $3 != "Completed"' || true
    elif (( ${rhods_total:-0} == 0 )); then
        log_warn "No eval-hub/mlflow pods appeared in redhat-ods-applications within 120s — operator may not have reconciled the CRs. Check 'oc get evalhub,mlflow -A'."
    fi

    if (( ${tenant_bad:-0} > 0 )); then
        log_warn "${tenant_bad} pod(s) in evalhub-tenant not Running after 120s:"
        oc get pods -n evalhub-tenant \
            --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    elif (( ${tenant_total:-0} == 0 )); then
        log_warn "No pods appeared in evalhub-tenant within 120s — DSPA may not have reconciled. Check 'oc get dspa -n evalhub-tenant' and 'oc get ns evalhub-tenant'."
    fi
    return 1
}

# =============================================================================
# Phase 1: Preflight
# =============================================================================
log_step "Phase 1: Preflight checks"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# =============================================================================
# UNINSTALL PATH
# =============================================================================
if [ "$UNINSTALL" = true ]; then
    log_step "Uninstall: deleting $EVALHUB_APP_NAME Application (cascade-prunes resources)"

    if ! oc get application.argoproj.io/"$EVALHUB_APP_NAME" -n openshift-gitops &>/dev/null; then
        log_info "$EVALHUB_APP_NAME Application not found — nothing to uninstall"
        skipped "$EVALHUB_APP_NAME deletion (already absent)"
    else
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would: oc delete application.argoproj.io/$EVALHUB_APP_NAME -n openshift-gitops"
        else
            # The resources-finalizer.argocd.argoproj.io on the Application
            # makes ArgoCD prune its managed resources before allowing the
            # Application to finish deleting. EvalHub, MLflow, DSPA, the
            # evalhub-tenant ns + RBAC + Job all get cleaned up.
            log_info "Deleting Application (ArgoCD will prune managed resources)..."
            oc delete application.argoproj.io/"$EVALHUB_APP_NAME" -n openshift-gitops
            log_info "Application deleted; ArgoCD pruning eval-hub resources asynchronously."
            log_info "Watch with: oc get evalhub,mlflow,dspa -A; oc get ns evalhub-tenant"
        fi
        applied "$EVALHUB_APP_NAME Application deleted (resources pruning)"
    fi

    echo ""
    log_info "========================================="
    log_info "Eval-hub Uninstall Summary"
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
    exit 0
fi

# =============================================================================
# Phase D: Detect repo URL + branch from existing instance-rhoai Application
# =============================================================================
log_step "Phase D: Detect GitOps repo + branch"

REPO_URL="${GITOPS_REPO_URL:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || echo "")}"
BRANCH="${GITOPS_BRANCH:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "")}"

if [[ -z "$REPO_URL" ]] || [[ -z "$BRANCH" ]]; then
    log_error "Could not detect GitOps repo URL or branch from instance-rhoai Application."
    log_error "Has 'make deploy' run? Otherwise set GITOPS_REPO_URL and GITOPS_BRANCH explicitly."
    exit 1
fi
log_info "GitOps source: ${REPO_URL} @ ${BRANCH}"
log_info "Application path: ${EVALHUB_PATH}"

# =============================================================================
# Phase S: Settle-gate
# =============================================================================
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping settle-gate"
else
    run_settle_gate
    applied "Settle-gate passed (rhods-operator Succeeded, DSC/DSCI Ready, default StorageClass present)"
fi

# =============================================================================
# Phase A: Create/update instance-evalhub Application
# =============================================================================
log_step "Phase A: Create/update $EVALHUB_APP_NAME ArgoCD Application"

# Idempotent — oc apply re-applies an already-present Application without
# changing Synced/Healthy state. The resources-finalizer enables cascade
# deletion at uninstall time.
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would apply Application $EVALHUB_APP_NAME -> ${REPO_URL}@${BRANCH} ${EVALHUB_PATH}"
else
    cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${EVALHUB_APP_NAME}
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${EVALHUB_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 3m
EOF
    # Nudge ArgoCD to reconcile immediately
    oc annotate application.argoproj.io/"$EVALHUB_APP_NAME" -n openshift-gitops \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
fi
applied "$EVALHUB_APP_NAME Application -> ${REPO_URL}@${BRANCH} ${EVALHUB_PATH}"

# =============================================================================
# Phase W: Wait for cascade
# =============================================================================
if [ "$DRY_RUN" = false ]; then
    wait_for_evalhub_cascade 600 || true
    phase_v_pod_check || true
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_info "========================================="
log_info "Eval-hub Install Summary"
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
log_info "  1. ArgoCD reconciles -> EvalHub, MLflow, DSPA, evalhub-tenant ns + RBAC + Job"
log_info "  2. Verify with: oc get evalhub,mlflow,dspa -A"
log_info "  3. evalhub-tenant DSPA pods take ~3-5 min on first install"
log_info "  4. Application status: oc get application.argoproj.io/$EVALHUB_APP_NAME -n openshift-gitops"
log_info "========================================="
