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
GPU_NODES=$(oc get nodes -l node-role.kubernetes.io/gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$READY_NODES" -eq "$TOTAL_NODES" ]] && [[ "$TOTAL_NODES" -gt 0 ]]; then
    pass "Nodes" "$TOTAL_NODES total ($MASTER_NODES master, $WORKER_NODES worker, $GPU_NODES gpu) — all Ready"
else
    NOTREADY=$((TOTAL_NODES - READY_NODES))
    warn "Nodes" "$NOTREADY node(s) not Ready"
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
    GPU_INSTANCE=$(oc get nodes -l node-role.kubernetes.io/gpu -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    GPU_MEM=$(oc get nodes -l node-role.kubernetes.io/gpu -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || echo "unknown")
    pass "GPU" "$GPU_NODES node(s) — $GPU_INSTANCE ($GPU_MEM allocatable)"
else
    info "GPU" "No GPU nodes"
    recommend "Run: make gpu"
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
# Section 4: Credentials on Cluster
# ═══════════════════════════════════════════════
section "4. Pull Secret (Cluster)"

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
# Section 5: GitOps & ArgoCD
# ═══════════════════════════════════════════════
section "5. GitOps & ArgoCD"

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
# Section 6: Operators & Install Plans
# ═══════════════════════════════════════════════
section "6. Operators"

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

# ═══════════════════════════════════════════════
# Section 7: RHOAI
# ═══════════════════════════════════════════════
section "7. RHOAI"

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
        warn "DSC" "$DSC_PHASE"
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        oc get datascienceclusters -o jsonpath='{.items[0].status.conditions}' 2>/dev/null | jq -r '.[] | "  \(.type): \(.status)"' 2>/dev/null || true
    fi
else
    info "DSC" "Not created"
fi

# ═══════════════════════════════════════════════
# Section 8: MaaS (Models as a Service)
# ═══════════════════════════════════════════════
section "8. MaaS"

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
# Section 9: Network
# ═══════════════════════════════════════════════
section "9. Network"

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
