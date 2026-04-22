#!/usr/bin/env bash
#
# diagnose.sh - Comprehensive RHOAI cluster diagnosis
#
# Runs all diagnostic checks: connectivity, .env configuration, infrastructure,
# credentials, GitOps, operators, RHOAI, MaaS, and network health.
# Produces a structured report with actionable recommendations.
#
# Usage:
#   ./diagnose.sh [OPTIONS]
#
# Options:
#   --verbose    Show detailed output for each section
#   --quiet      Only show warnings, failures, and recommendations
#
# Exit codes:
#   0 = All healthy
#   1 = Failures detected
#   2 = Warnings only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cluster-health.sh"

VERBOSE=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose) VERBOSE=true; shift ;;
        --quiet) QUIET=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--verbose] [--quiet]"
            exit 0
            ;;
        *) shift ;;
    esac
done

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RECOMMENDATIONS=()

# Count matching lines (handles grep -c quirks with newlines)
count_matches() { grep -c "$@" 2>/dev/null | tr -d '[:space:]' || echo 0; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); [[ "$QUIET" != "true" ]] && echo -e "  ${GREEN}PASS${NC}  $1: $2"; return 0; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "  ${YELLOW}WARN${NC}  $1: $2"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $1: $2"; }
info() { [[ "$QUIET" != "true" ]] && echo -e "  ${BLUE}INFO${NC}  $1: $2"; return 0; }
recommend() { RECOMMENDATIONS+=("$1"); }

section() {
    echo ""
    echo -e "${BLUE}$1${NC}"
    printf '%.0s─' $(seq 1 ${#1})
    echo ""
}

echo ""
echo -e "${BLUE}RHOAI Cluster Diagnosis${NC}"
echo "======================="

# ═══════════════════════════════════════════════
# Section 1: Cluster Connectivity
# ═══════════════════════════════════════════════
section "1. Cluster Connectivity"

if ! oc whoami &>/dev/null; then
    fail "Connection" "Not logged into OpenShift"
    recommend "Run 'oc login --token=<token> --server=https://api.<cluster>:6443'"
    echo ""
    echo -e "${RED}Cannot proceed without cluster connection.${NC}"
    # Skip to recommendations
    section "Recommendations"
    for rec in "${RECOMMENDATIONS[@]}"; do
        echo -e "  → $rec"
    done
    exit 1
fi

CLUSTER_USER=$(oc whoami)
CLUSTER_URL=$(oc whoami --show-server)
OCP_VERSION=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo "unknown")

pass "Connection" "$CLUSTER_URL (user: $CLUSTER_USER)"
info "Platform" "$PLATFORM, OCP $OCP_VERSION"

# ═══════════════════════════════════════════════
# Section 2: Configuration (.env)
# ═══════════════════════════════════════════════
section "2. Configuration (.env)"

if [[ -f "$REPO_ROOT/.env" ]]; then
    pass ".env File" "Present"
    # Source .env for subsequent checks (don't override existing env vars)
    set -a
    source "$REPO_ROOT/.env" 2>/dev/null || true
    set +a
else
    info ".env File" "Not found (defaults will be used)"
fi

# Credentials
if [[ -n "${QUAY_USER:-}" ]] && [[ -n "${QUAY_TOKEN:-}" ]]; then
    pass "Credentials" "Manual mode (QUAY_USER set)"
else
    BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap.git}"
    BOOTSTRAP_REPO_SSH=$(echo "$BOOTSTRAP_REPO" | sed 's|https://github.com/|git@github.com:|')
    if git ls-remote "$BOOTSTRAP_REPO" HEAD &>/dev/null || git ls-remote "$BOOTSTRAP_REPO_SSH" HEAD &>/dev/null; then
        pass "Credentials" "External Secrets mode (bootstrap repo accessible)"
    else
        fail "Credentials" "No QUAY_USER/QUAY_TOKEN and no bootstrap repo access"
        recommend "Set QUAY_USER/QUAY_TOKEN in .env, or get access to $BOOTSTRAP_REPO"
    fi
fi

# Branch
CURRENT_BRANCH=$(cd "$REPO_ROOT" && git branch --show-current 2>/dev/null || echo "main")
EFFECTIVE_BRANCH="${GITOPS_BRANCH:-$CURRENT_BRANCH}"
EFFECTIVE_REPO=$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || echo "https://github.com/rh-aiservices-bu/rhoai-nightly")
EFFECTIVE_REPO="${GITOPS_REPO_URL:-$EFFECTIVE_REPO}"

info "Branch" "$EFFECTIVE_BRANCH"
info "Repo" "$EFFECTIVE_REPO"

if git ls-remote "$EFFECTIVE_REPO" "$EFFECTIVE_BRANCH" 2>/dev/null | grep -q .; then
    pass "Branch Remote" "'$EFFECTIVE_BRANCH' exists on remote"
else
    warn "Branch Remote" "'$EFFECTIVE_BRANCH' not found on remote"
    recommend "Push branch: git push -u origin $EFFECTIVE_BRANCH"
fi

# ═══════════════════════════════════════════════
# Section 3: Nodes & Infrastructure
# ═══════════════════════════════════════════════
section "3. Nodes & Infrastructure"

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_NODES=$(oc get nodes --no-headers 2>/dev/null | count_matches " Ready")
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker,\!node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
# Check for GPU nodes using nvidia label (works on all clusters) with role label as fallback
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
GPU_SELECTOR="nvidia.com/gpu.present=true"
if [[ "$GPU_NODES" -eq 0 ]]; then
    GPU_NODES=$(oc get nodes -l $GPU_SELECTOR --no-headers 2>/dev/null | wc -l | tr -d ' ')
    GPU_SELECTOR="node-role.kubernetes.io/gpu"
fi

READY_NODES=${READY_NODES:-0}
TOTAL_NODES=${TOTAL_NODES:-0}
if [[ "$TOTAL_NODES" -eq 0 ]]; then
    fail "Nodes" "No nodes found"
elif [[ "$READY_NODES" -eq "$TOTAL_NODES" ]]; then
    pass "Nodes" "$TOTAL_NODES total ($MASTER_NODES master, $WORKER_NODES worker, $GPU_NODES gpu) — all Ready"
else
    NOTREADY=$((TOTAL_NODES - READY_NODES))
    if [[ "$NOTREADY" -gt 0 ]]; then
        warn "Nodes" "$NOTREADY of $TOTAL_NODES node(s) not Ready"
    else
        pass "Nodes" "$TOTAL_NODES total ($MASTER_NODES master, $WORKER_NODES worker, $GPU_NODES gpu) — all Ready"
    fi
fi

# ICSP
ICSP_COUNT=$(oc get imagecontentsourcepolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ICSP_COUNT" -gt 0 ]]; then
    pass "ICSP" "Present"
else
    info "ICSP" "Not configured (will be created during install)"
fi

# GPU details
if [[ "$GPU_NODES" -gt 0 ]]; then
    GPU_INSTANCE=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    GPU_MEM=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || echo "unknown")
    pass "GPU" "$GPU_NODES node(s) — $GPU_INSTANCE ($GPU_MEM allocatable)"

    # Check for cordoned GPU nodes (Issue 10)
    GPU_CORDONED=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{range .items[*]}{.spec.unschedulable}{"\n"}{end}' 2>/dev/null | count_matches "true")
    if [[ "$GPU_CORDONED" -gt 0 ]]; then
        warn "GPU Cordoned" "$GPU_CORDONED GPU node(s) are cordoned (unschedulable) — pods can't schedule"
        recommend "Uncordon GPU node: oc adm uncordon \$(oc get node -l node-role.kubernetes.io/gpu -o name)"
    fi
else
    info "GPU" "No GPU nodes"
fi

# MCP
MCP_DEGRADED=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | count_matches "True")
if [[ "$MCP_DEGRADED" -gt 0 ]]; then
    fail "MCP" "$MCP_DEGRADED MachineConfigPool(s) degraded"
else
    pass "MCP" "All healthy"
fi

if [[ "$VERBOSE" == "true" ]]; then
    echo ""
    oc get nodes -o wide --no-headers 2>/dev/null | head -10
fi

# ═══════════════════════════════════════════════
# Section 4: Control Plane Health
# ═══════════════════════════════════════════════
section "4. Control Plane Health"

check_master_sizing
check_master_pressure
check_cluster_operators

# ═══════════════════════════════════════════════
# Section 5: Credentials on Cluster
# ═══════════════════════════════════════════════
section "5. Pull Secret (Cluster)"

PULL_SECRET_KEYS=$(oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.auths | keys[]' 2>/dev/null || echo "")
HAS_QUAY_RHOAI=$(echo "$PULL_SECRET_KEYS" | count_matches "quay.io/rhoai")

if [[ "$HAS_QUAY_RHOAI" -gt 0 ]]; then
    pass "Pull Secret" "quay.io/rhoai credentials present"
else
    info "Pull Secret" "quay.io/rhoai not yet configured (will be created during install)"
fi

ES_STATUS=$(oc get externalsecret pull-secret -n openshift-config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$ES_STATUS" == "True" ]]; then
    pass "External Secret" "Synced"
elif [[ -n "$ES_STATUS" ]]; then
    warn "External Secret" "Status: $ES_STATUS"
fi

# ═══════════════════════════════════════════════
# Section 6: GitOps & ArgoCD
# ═══════════════════════════════════════════════
section "6. GitOps & ArgoCD"

GITOPS_CSV=$(oc get csv -n openshift-gitops-operator --no-headers 2>/dev/null | grep gitops || echo "")
if [[ -n "$GITOPS_CSV" ]]; then
    GITOPS_PHASE=$(echo "$GITOPS_CSV" | awk '{print $NF}')
    if [[ "$GITOPS_PHASE" == "Succeeded" ]]; then
        pass "GitOps Operator" "$(echo "$GITOPS_CSV" | awk '{print $1}') (Succeeded)"
    else
        warn "GitOps Operator" "$GITOPS_PHASE"
    fi
else
    info "GitOps Operator" "Not installed"
fi

APP_COUNT=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$APP_COUNT" -gt 0 ]]; then
    APP_SYNCED=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null | count_matches "Synced")
    APP_HEALTHY=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.health.status}{"\n"}{end}' 2>/dev/null | count_matches "Healthy")
    APP_DEGRADED=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.health.status}{"\n"}{end}' 2>/dev/null | count_matches "Degraded")

    if [[ "$APP_SYNCED" -eq "$APP_COUNT" ]] && [[ "$APP_HEALTHY" -eq "$APP_COUNT" ]]; then
        pass "ArgoCD Apps" "$APP_COUNT apps — all Synced+Healthy"
    elif [[ "$APP_DEGRADED" -gt 0 ]]; then
        warn "ArgoCD Apps" "$APP_DEGRADED degraded out of $APP_COUNT"
        recommend "Check degraded apps: make status"
    else
        info "ArgoCD Apps" "$APP_COUNT total: $APP_SYNCED synced, $APP_HEALTHY healthy"
    fi

    ARGOCD_BRANCH=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{.items[0].spec.source.targetRevision}' 2>/dev/null || echo "")
    info "ArgoCD Branch" "$ARGOCD_BRANCH"

    if [[ -n "$ARGOCD_BRANCH" ]] && [[ "$ARGOCD_BRANCH" != "$EFFECTIVE_BRANCH" ]]; then
        warn "Branch Mismatch" "ArgoCD='$ARGOCD_BRANCH' vs config='$EFFECTIVE_BRANCH'"
        recommend "Update ArgoCD: GITOPS_BRANCH=$EFFECTIVE_BRANCH make deploy"
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        oc get applications.argoproj.io -n openshift-gitops -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null
    fi
else
    info "ArgoCD Apps" "None deployed"
fi

# ═══════════════════════════════════════════════
# Section 7: Operators & Install Plans
# ═══════════════════════════════════════════════
section "7. Operators"

BAD_CSVS=$(oc get csv -A --no-headers 2>/dev/null | grep -v "Succeeded" | grep -v "^$" || echo "")
if [[ -n "$BAD_CSVS" ]]; then
    BAD_COUNT=$(echo "$BAD_CSVS" | wc -l | tr -d ' ')
    warn "CSVs" "$BAD_COUNT not Succeeded"
    echo "$BAD_CSVS" | head -5 | while read -r line; do
        echo "         $(echo "$line" | awk '{print $2, $NF}')"
    done
else
    pass "CSVs" "All Succeeded"
fi

PENDING_PLANS=$(oc get installplan -A --no-headers 2>/dev/null | grep -v "Complete" | grep -v "^$" || echo "")
if [[ -n "$PENDING_PLANS" ]]; then
    PENDING_COUNT=$(echo "$PENDING_PLANS" | wc -l | tr -d ' ')
    warn "Install Plans" "$PENDING_COUNT pending — may need manual approval"
    echo "$PENDING_PLANS" | head -3 | while read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        NAME=$(echo "$line" | awk '{print $2}')
        echo "         $NS/$NAME"
        recommend "Approve: oc patch installplan $NAME -n $NS --type merge -p '{\"spec\":{\"approved\":true}}'"
    done
else
    pass "Install Plans" "All Complete"
fi

# Check for duplicate OperatorGroups (Issue 9a — OLM silently fails with duplicates)
DUP_OG_FOUND=false
for ns in nvidia-gpu-operator openshift-nfd cert-manager-operator openshift-operators; do
    OG_COUNT=$(oc get operatorgroup -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$OG_COUNT" -gt 1 ]]; then
        warn "OperatorGroup" "Duplicate in $ns ($OG_COUNT found) — OLM won't resolve subscriptions"
        recommend "Delete extra OperatorGroup in $ns: oc get operatorgroup -n $ns"
        DUP_OG_FOUND=true
    fi
done
if [[ "$DUP_OG_FOUND" == "false" ]] && [[ "$APP_COUNT" -gt 0 ]]; then
    pass "OperatorGroups" "No duplicates"
fi

# Verify key operator CSVs are actually installed (Issue 9b — Synced+Healthy ≠ operator working)
if [[ "$APP_COUNT" -gt 0 ]]; then
    MISSING_CSVS=""
    for op_check in "nvidia-gpu-operator:gpu-operator" "openshift-nfd:nfd" "redhat-ods-operator:rhods"; do
        NS="${op_check%%:*}"
        PATTERN="${op_check##*:}"
        HAS_SUB=$({ oc get subscription -n "$NS" --no-headers 2>/dev/null || true; } | grep -c . || echo 0)
        HAS_CSV=$({ oc get csv -n "$NS" --no-headers 2>/dev/null || true; } | grep -c "$PATTERN" || echo 0)
        HAS_SUB=$(echo "$HAS_SUB" | tr -d '[:space:]')
        HAS_CSV=$(echo "$HAS_CSV" | tr -d '[:space:]')
        if [[ "$HAS_SUB" -gt 0 ]] && [[ "$HAS_CSV" -eq 0 ]]; then
            MISSING_CSVS="$MISSING_CSVS $NS"
        fi
    done
    if [[ -n "$MISSING_CSVS" ]]; then
        warn "Operator CSVs" "Subscriptions exist but CSVs missing in:$MISSING_CSVS — check OperatorGroups and install plans"
    else
        pass "Operator CSVs" "All key operators have CSVs installed"
    fi
fi

# ═══════════════════════════════════════════════
# Section 8: RHOAI
# ═══════════════════════════════════════════════
section "8. RHOAI"

CATALOG_IMAGE=$(oc get catalogsource rhoai-catalog-nightly -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || echo "")
if [[ -n "$CATALOG_IMAGE" ]]; then
    # Extract just the tag
    CATALOG_TAG="${CATALOG_IMAGE##*:}"
    pass "Catalog" "$CATALOG_TAG"
else
    info "Catalog" "Not configured"
fi

CATALOG_POD=$(oc get pods -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly --no-headers 2>/dev/null | head -1 || echo "")
if [[ -n "$CATALOG_POD" ]]; then
    POD_STATUS=$(echo "$CATALOG_POD" | awk '{print $3}')
    if [[ "$POD_STATUS" == "Running" ]]; then
        pass "Catalog Pod" "Running"
    else
        warn "Catalog Pod" "$POD_STATUS"
        recommend "Run: make restart-catalog"
    fi
fi

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods || echo "")
if [[ -n "$RHOAI_CSV" ]]; then
    RHOAI_NAME=$(echo "$RHOAI_CSV" | awk '{print $1}')
    RHOAI_PHASE=$(echo "$RHOAI_CSV" | awk '{print $NF}')
    if [[ "$RHOAI_PHASE" == "Succeeded" ]]; then
        pass "RHOAI CSV" "$RHOAI_NAME ($RHOAI_PHASE)"
    else
        warn "RHOAI CSV" "$RHOAI_NAME ($RHOAI_PHASE)"
    fi
else
    info "RHOAI CSV" "Not installed"
fi

DSC_PHASE=$(oc get datascienceclusters -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
if [[ -n "$DSC_PHASE" ]]; then
    if [[ "$DSC_PHASE" == "Ready" ]]; then
        pass "DSC" "Ready"
    else
        # Check if Not Ready is just due to missing MaaS prereqs (expected before make maas)
        MAAS_MSG=$(oc get datascienceclusters -o jsonpath='{.items[0].status.conditions[?(@.type=="ModelsAsServiceReady")].message}' 2>/dev/null || echo "")
        if echo "$MAAS_MSG" | grep -q "maas-db-config.*not found\|database Secret"; then
            info "DSC" "$DSC_PHASE (MaaS prereqs missing — run 'make maas' to fix)"
        else
            warn "DSC" "$DSC_PHASE"
        fi
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        oc get datascienceclusters -o jsonpath='{.items[0].status.conditions}' 2>/dev/null | jq -r '.[] | "  \(.type): \(.status)"' 2>/dev/null || true
    fi
else
    info "DSC" "Not created"
fi

# ═══════════════════════════════════════════════
# Section 9: MaaS (Models as a Service)
# ═══════════════════════════════════════════════
section "9. MaaS"

MAAS_APP=$(oc get application.argoproj.io/instance-maas -n openshift-gitops --no-headers 2>/dev/null || echo "")
if [[ -n "$MAAS_APP" ]]; then
    MAAS_SYNC=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "unknown")
    MAAS_HEALTH=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo "unknown")

    if [[ "$MAAS_SYNC" == "Synced" ]] && [[ "$MAAS_HEALTH" == "Healthy" ]]; then
        pass "MaaS App" "Synced+Healthy"
    else
        warn "MaaS App" "Sync=$MAAS_SYNC Health=$MAAS_HEALTH"
    fi

    # Check maas-api
    MAAS_API=$(oc get deployment maas-api -n redhat-ods-applications -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$MAAS_API" -gt 0 ]]; then
        pass "maas-api" "Running ($MAAS_API replicas)"
    else
        warn "maas-api" "Not ready"
    fi

    # Gateway
    GW_PROGRAMMED=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
    if [[ "$GW_PROGRAMMED" == "True" ]]; then
        pass "Gateway" "Programmed"
    elif [[ -n "$GW_PROGRAMMED" ]]; then
        warn "Gateway" "Programmed=$GW_PROGRAMMED"
    else
        warn "Gateway" "Not found"
    fi

    # ModelsAsService
    MAAS_READY=$(oc get modelsasservice -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    MAAS_MSG=$(oc get modelsasservice -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
    if [[ "$MAAS_READY" == "True" ]]; then
        pass "ModelsAsService" "Ready"
    elif [[ -n "$MAAS_READY" ]]; then
        if echo "$MAAS_MSG" | grep -q "gateway.*not found"; then
            warn "ModelsAsService" "Gateway not found (known race condition — usually self-resolves)"
            recommend "If stuck, run: make maas"
        else
            warn "ModelsAsService" "$MAAS_MSG"
        fi
    fi

    # Authorino SSL
    SSL_VARS=$(oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | jq -r '[.[] | select(.name | startswith("SSL"))] | length' 2>/dev/null || echo "0")
    if [[ "$SSL_VARS" -gt 0 ]]; then
        pass "Authorino SSL" "Configured ($SSL_VARS env vars)"
    else
        warn "Authorino SSL" "Not configured"
        recommend "Run: make maas (configures Authorino SSL)"
    fi

    # Models
    MODEL_COUNT=$(oc get llminferenceservice -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$MODEL_COUNT" -gt 0 ]]; then
        MODEL_READY=$(oc get llminferenceservice -n llm -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | count_matches "True")
        if [[ "$MODEL_READY" -eq "$MODEL_COUNT" ]]; then
            pass "Models" "$MODEL_COUNT deployed, all Ready"
        else
            info "Models" "$MODEL_COUNT deployed, $MODEL_READY Ready"
        fi

        if [[ "$VERBOSE" == "true" ]]; then
            echo ""
            oc get llminferenceservice -n llm -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null
        fi

        SUB_COUNT=$(oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | wc -l | tr -d ' ')
        info "Subscriptions" "$SUB_COUNT"
    else
        info "Models" "None deployed"
    fi
else
    info "MaaS" "Not installed"
fi

# ═══════════════════════════════════════════════
# Section 10: Observability (MaaS)
# ═══════════════════════════════════════════════
section "10. Observability"

if [[ -z "$MAAS_APP" ]]; then
    info "Observability" "MaaS not installed — skipping observability checks"
else
    # UWM ConfigMap
    UWM_CM=$(oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if [[ -z "$UWM_CM" ]]; then
        info "UWM ConfigMap" "cluster-monitoring-config not found in openshift-monitoring"
    elif echo "$UWM_CM" | grep -q "enableUserWorkload:[[:space:]]*true"; then
        pass "UWM ConfigMap" "enableUserWorkload: true"
    else
        warn "UWM ConfigMap" "cluster-monitoring-config present but enableUserWorkload not true"
        recommend "Run: make observability"
    fi

    # prometheus-user-workload-0 pod
    UWM_POD_STATUS=$(oc get pod prometheus-user-workload-0 -n openshift-user-workload-monitoring -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$UWM_POD_STATUS" == "Running" ]]; then
        pass "UWM Prometheus" "prometheus-user-workload-0 Running"
    elif [[ -n "$UWM_POD_STATUS" ]]; then
        info "UWM Prometheus" "prometheus-user-workload-0 phase=$UWM_POD_STATUS"
    else
        info "UWM Prometheus" "prometheus-user-workload-0 not present"
    fi

    # Kuadrant observability enabled
    KUADRANT_OBS=$(oc get kuadrant -n kuadrant-system -o jsonpath='{.items[0].spec.observability.enable}' 2>/dev/null || echo "")
    if [[ "$KUADRANT_OBS" == "true" ]]; then
        pass "Kuadrant Observability" "enabled"
    else
        info "Kuadrant Observability" "not enabled (spec.observability.enable != true)"
        recommend "Run: make observability"
    fi

    # TelemetryPolicy present
    TP_EXISTS=$(oc get telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress --ignore-not-found -o name 2>/dev/null || echo "")
    if [[ -n "$TP_EXISTS" ]]; then
        pass "TelemetryPolicy" "maas-telemetry present in openshift-ingress"
    else
        info "TelemetryPolicy" "maas-telemetry not found (GitOps instance-maas-observability may still be syncing)"
    fi

    # Istio Telemetry present
    IT_EXISTS=$(oc get telemetry.telemetry.istio.io latency-per-subscription -n openshift-ingress --ignore-not-found -o name 2>/dev/null || echo "")
    if [[ -n "$IT_EXISTS" ]]; then
        pass "Istio Telemetry" "latency-per-subscription present in openshift-ingress"
    else
        info "Istio Telemetry" "latency-per-subscription not found (GitOps instance-maas-observability may still be syncing)"
    fi

    # KServe vLLM ServiceMonitor (scrapes vllm:* metrics for Perses dashboards)
    if oc get ns llm &>/dev/null; then
        if oc get servicemonitor kserve-llm-models -n llm --ignore-not-found -o name &>/dev/null && \
                [[ -n "$(oc get servicemonitor kserve-llm-models -n llm --ignore-not-found -o name 2>/dev/null)" ]]; then
            pass "KServe vLLM ServiceMonitor" "kserve-llm-models present in llm"
        else
            warn "KServe vLLM ServiceMonitor" "kserve-llm-models missing in llm namespace"
            recommend "Run: make observability"
        fi
    else
        info "KServe vLLM ServiceMonitor" "llm namespace not present — skipping"
    fi
fi

# Perses backend for the RHOAI Observability dashboard tab (independent of MaaS).
# COO provides the Perses CRDs; the RHOAI operator's Monitoring controller owns
# the Perses CR + datasources + dashboards end-to-end — we don't create them.
if oc get crd perses.perses.dev &>/dev/null; then
    PERSES_CR=$(oc get perses -n redhat-ods-monitoring --ignore-not-found -o name 2>/dev/null | head -1 || echo "")
    if [[ -n "$PERSES_CR" ]]; then
        PERSES_NAME="${PERSES_CR##*/}"
        PERSES_SVC=$(oc get svc "$PERSES_NAME" -n redhat-ods-monitoring --ignore-not-found -o name 2>/dev/null || echo "")
        if [[ -n "$PERSES_SVC" ]]; then
            PERSES_PORT=$(oc get svc "$PERSES_NAME" -n redhat-ods-monitoring -o jsonpath='{.spec.ports[?(@.port==8080)].port}' 2>/dev/null || echo "")
            if [[ "$PERSES_PORT" == "8080" ]]; then
                pass "Perses Dashboard Backend" "$PERSES_NAME (operator-managed) Service reachable on port 8080 in redhat-ods-monitoring"
            else
                warn "Perses Dashboard Backend" "$PERSES_NAME Service exists but port 8080 not found"
            fi
        else
            info "Perses Dashboard Backend" "$PERSES_NAME CR present but Service not yet created (operator may still be reconciling)"
        fi
    else
        info "Perses Dashboard Backend" "No Perses CR in redhat-ods-monitoring yet (RHOAI operator may still be reconciling)"
    fi
else
    info "Perses Dashboard Backend" "COO not installed — Perses CRDs not registered (cluster-observability-operator subscription pending)"
fi

# ═══════════════════════════════════════════════
# Section 11: Network
# ═══════════════════════════════════════════════
section "11. Network"

INGRESS_AVAILABLE=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
if [[ "$INGRESS_AVAILABLE" == "True" ]]; then
    pass "Ingress" "Available"
else
    warn "Ingress" "Available=$INGRESS_AVAILABLE"
fi

# ═══════════════════════════════════════════════
# Summary & Next Steps
# ═══════════════════════════════════════════════
echo ""
echo "═══════════════════════"
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
echo -e "Results: ${GREEN}$PASS_COUNT passed${NC}, ${YELLOW}$WARN_COUNT warnings${NC}, ${RED}$FAIL_COUNT failures${NC} ($TOTAL checks)"

# Show recommendations for actual problems (WARN/FAIL items)
if [[ ${#RECOMMENDATIONS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BLUE}Fix:${NC}"
    for rec in "${RECOMMENDATIONS[@]}"; do
        echo -e "  → $rec"
    done
fi

# Smart next-step based on install state
echo ""
echo -e "${BLUE}Next Step:${NC}"
RHOAI_INSTALLED="false"
MAAS_INSTALLED="false"
[[ -n "$RHOAI_CSV" ]] && RHOAI_INSTALLED="true"
[[ -n "$MAAS_APP" ]] && MAAS_INSTALLED="true"

if [[ -z "$GITOPS_CSV" ]]; then
    echo -e "  → Run: make all (full install: ICSP, secrets, GitOps, RHOAI, MaaS)"
elif [[ -z "$RHOAI_CSV" ]]; then
    echo -e "  → Run: make deploy && make sync (GitOps installed, deploy RHOAI)"
elif [[ "$RHOAI_INSTALLED" == "true" ]] && [[ "$MAAS_INSTALLED" != "true" ]]; then
    echo -e "  → Run: make maas && make maas-model (RHOAI installed, add MaaS)"
elif [[ "$MAAS_INSTALLED" == "true" ]] && [[ "$MODEL_COUNT" -eq 0 ]]; then
    echo -e "  → Run: make maas-model (MaaS installed, deploy models)"
else
    echo -e "  → Cluster is fully operational"
fi

echo ""
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo -e "${RED}Cluster has issues that need attention.${NC}"
    exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    echo -e "${YELLOW}Cluster is healthy (with warnings).${NC}"
    exit 2
else
    echo -e "${GREEN}Cluster is healthy.${NC}"
    exit 0
fi
