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
# Section 5: Workload Health
# ═══════════════════════════════════════════════
# Added 2026-07-29 after a full install reported "35 passed, 0 failures —
# Cluster is fully operational" while the RHOAI dashboard was returning 503
# and its gateway pod sat in CrashLoopBackOff with 13 OOMKilled restarts.
# Nothing in this script looked at pod state, so any crash-looping workload
# outside the handful of hard-coded deployments was invisible.
section "5. Workload Health"

# Namespaces this repo installs into. Problems HERE are our failures; problems
# elsewhere in the cluster are surfaced as a single summary line so platform
# breakage is still visible without burying our own signal in it.
RHOAI_NS_RE='^(redhat-ods-|redhat-ai-gateway-infra|openshift-ods|kuadrant-system|llm$|models-as-a-service|nvidia-gpu-operator|openshift-nfd|openshift-gitops|external-secrets|nfs-provisioner|evalhub-tenant|openshift-jobset-operator|openshift-lws-operator|openshift-kueue-operator|openshift-cluster-observability-operator|openshift-operators$|openshift-ingress$)'

# Crash-looping / unpullable / erroring pods.
BAD_PODS_ALL=$(oc get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError|InvalidImageName/ {print $1" "$2" "$4}' || echo "")
BAD_PODS=$(echo "$BAD_PODS_ALL" | grep -E "$RHOAI_NS_RE" || echo "")
BAD_PODS_OTHER=$(echo "$BAD_PODS_ALL" | grep -vE "$RHOAI_NS_RE" | grep -v "^$" || echo "")

if [[ -n "$BAD_PODS" ]]; then
    BAD_POD_COUNT=$(echo "$BAD_PODS" | wc -l | tr -d ' ')
    fail "Pod Health" "$BAD_POD_COUNT RHOAI/MaaS pod(s) crash-looping or unable to pull images"
    echo "$BAD_PODS" | head -6 | while read -r line; do
        echo "         $(echo "$line" | awk '{print $1"/"$2" "$3}')"
    done
    FIRST_BAD_NS=$(echo "$BAD_PODS" | head -1 | awk '{print $1}')
    FIRST_BAD_POD=$(echo "$BAD_PODS" | head -1 | awk '{print $2}')
    recommend "Investigate: oc logs -n $FIRST_BAD_NS $FIRST_BAD_POD --previous --tail=30"
else
    pass "Pod Health" "No crash-looping or image-pull-failing pods in RHOAI/MaaS namespaces"
fi

if [[ -n "$BAD_PODS_OTHER" ]]; then
    OTHER_COUNT=$(echo "$BAD_PODS_OTHER" | wc -l | tr -d ' ')
    warn "Pod Health (other ns)" "$OTHER_COUNT pod(s) unhealthy outside RHOAI namespaces — not installed by this repo"
    echo "$BAD_PODS_OTHER" | head -3 | while read -r line; do
        echo "         $(echo "$line" | awk '{print $1"/"$2" "$3}')"
    done
fi

# OOMKilled is called out separately: it is the single most common failure mode
# in this stack (docs/workarounds.md A2 raises the MaaS gateway to 2Gi for
# exactly this reason) and it is invisible in the pod STATUS column once the
# container restarts successfully.
OOM_PODS=$(oc get pods -A -o json 2>/dev/null | jq -r '
    .items[]
    | . as $p
    | (.status.containerStatuses // [])[]
    | select(.lastState.terminated.reason == "OOMKilled")
    | "\($p.metadata.namespace) \($p.metadata.name) \(.name) restarts=\(.restartCount)"' 2>/dev/null \
    | grep -E "$RHOAI_NS_RE" || echo "")
if [[ -n "$OOM_PODS" ]]; then
    OOM_COUNT=$(echo "$OOM_PODS" | wc -l | tr -d ' ')
    fail "OOMKilled" "$OOM_COUNT container(s) OOMKilled — raise limits or find the leak"
    echo "$OOM_PODS" | head -5 | while read -r line; do
        echo "         $(echo "$line" | awk '{print $1"/"$2" container="$3" "$4}')"
    done
    recommend "OOMKilled containers found — check limits (see docs/workarounds.md A1/A2 for the gateway cases)"
else
    pass "OOMKilled" "No containers OOMKilled"
fi

# Pods that restarted RECENTLY (last 30 min) — catches active flapping, e.g. a
# gateway that recovers just long enough to look Running between OOMKills.
# Deliberately recency-based, not count-based: on a long-lived cluster dozens of
# platform pods carry double-digit lifetime restarts that are entirely normal,
# and warning on those trains people to ignore this check.
RECENT_RESTART_CUTOFF=$(( $(date +%s) - 1800 ))
FLAPPING=$(oc get pods -A -o json 2>/dev/null | jq -r --argjson cutoff "$RECENT_RESTART_CUTOFF" '
    .items[]
    | . as $p
    | (.status.containerStatuses // [])[]
    | select(.lastState.terminated.finishedAt != null)
    | select((.lastState.terminated.finishedAt | fromdateiso8601) > $cutoff)
    | "\($p.metadata.namespace) \($p.metadata.name) container=\(.name) reason=\(.lastState.terminated.reason) restarts=\(.restartCount)"' 2>/dev/null \
    | grep -E "$RHOAI_NS_RE" || echo "")
if [[ -n "$FLAPPING" ]]; then
    FLAP_COUNT=$(echo "$FLAPPING" | wc -l | tr -d ' ')
    warn "Recent Restarts" "$FLAP_COUNT container(s) restarted in the last 30 min"
    echo "$FLAPPING" | head -5 | while read -r line; do
        echo "         $(echo "$line" | awk '{print $1"/"$2" "$3" "$4" "$5}')"
    done
    recommend "Recent restarts — check whether a workload is flapping: oc get pods -A --sort-by=.status.startTime | tail -20"
else
    pass "Recent Restarts" "No container restarted in the last 30 min"
fi

# ═══════════════════════════════════════════════
# Section 6: Credentials on Cluster
# ═══════════════════════════════════════════════
section "6. Pull Secret (Cluster)"

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
section "7. GitOps & ArgoCD"

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
section "8. Operators"

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

# Only UNAPPROVED plans actually need action. The previous `grep -v Complete`
# also matched approved plans still installing, so a healthy cluster reported
# "15 pending — may need manual approval" when all 15 were approved+Complete.
PENDING_PLANS=$(oc get installplan -A -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.clusterServiceVersionNames[0]}{"\n"}{end}' 2>/dev/null | grep -v "^$" || echo "")
if [[ -n "$PENDING_PLANS" ]]; then
    PENDING_COUNT=$(echo "$PENDING_PLANS" | wc -l | tr -d ' ')
    warn "Install Plans" "$PENDING_COUNT awaiting approval"
    echo "$PENDING_PLANS" | head -3 | while read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        NAME=$(echo "$line" | awk '{print $2}')
        CSV=$(echo "$line" | awk '{print $3}')
        echo "         $NS/$NAME ($CSV)"
        # Service Mesh plans are deliberately NOT auto-approved: on clusters where
        # the ingress operator owns the SM subscription, approving them can disrupt
        # the ingress data plane (docs/workarounds.md C2).
        if [[ "$CSV" == servicemeshoperator* ]]; then
            recommend "REVIEW (do NOT blind-approve): $NS/$NAME is $CSV — see docs/workarounds.md C2"
        else
            recommend "Approve: oc patch installplan $NAME -n $NS --type merge -p '{\"spec\":{\"approved\":true}}'"
        fi
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
section "9. RHOAI"

CATALOG_IMAGE=$(oc get catalogsource rhoai-catalog-nightly -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || echo "")
if [[ -n "$CATALOG_IMAGE" ]]; then
    # Extract the tag, or for a digest-pinned image the repo + short digest —
    # "${CATALOG_IMAGE##*:}" alone turns an @sha256: pin into 64 hex characters
    # and loses the version identification this line exists to give.
    if [[ "$CATALOG_IMAGE" == *"@sha256:"* ]]; then
        CATALOG_REPO="${CATALOG_IMAGE%@sha256:*}"      # quay.io/rhoai/rhoai-fbc-fragment
        CATALOG_DIGEST="${CATALOG_IMAGE##*@sha256:}"
        CATALOG_TAG="${CATALOG_REPO##*/}@sha256:${CATALOG_DIGEST:0:12} (digest-pinned)"
    else
        CATALOG_TAG="${CATALOG_IMAGE##*:}"
    fi
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
        # Check if Not Ready is just due to missing MaaS prereqs (expected before
        # make maas). 3.5 renamed the condition ModelsAsServiceReady ->
        # AIGatewayReady; check both so this keeps working across the ea.2/3.5.0
        # split until every cluster is upgraded.
        MAAS_MSG=""
        for c in AIGatewayReady ModelsAsServiceReady; do
            MAAS_MSG=$(oc get datascienceclusters -o jsonpath="{.items[0].status.conditions[?(@.type=='$c')].message}" 2>/dev/null || echo "")
            [[ -n "$MAAS_MSG" ]] && break
        done
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
section "10. MaaS"

MAAS_APP=$(oc get application.argoproj.io/instance-maas -n openshift-gitops --no-headers 2>/dev/null || echo "")
if [[ -n "$MAAS_APP" ]]; then
    MAAS_SYNC=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "unknown")
    MAAS_HEALTH=$(oc get application.argoproj.io/instance-maas -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo "unknown")

    if [[ "$MAAS_SYNC" == "Synced" ]] && [[ "$MAAS_HEALTH" == "Healthy" ]]; then
        pass "MaaS App" "Synced+Healthy"
    else
        warn "MaaS App" "Sync=$MAAS_SYNC Health=$MAAS_HEALTH"
    fi

    # Check maas-api — RHOAI 3.5+ deploys it in redhat-ai-gateway-infra; older in redhat-ods-applications
    MAAS_API=$(oc get deployment maas-api -n redhat-ai-gateway-infra -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${MAAS_API:-0}" -lt 1 ]]; then
        MAAS_API=$(oc get deployment maas-api -n redhat-ods-applications -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    fi
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

    # Kuadrant policy enforcement.
    # Added 2026-07-29: every structural MaaS check passed (gateway Programmed,
    # maas-api Running, Authorino Running, health 200) while API-key creation
    # returned 500, because the Kuadrant operator had cached "no Gateway API
    # provider" at startup, left AuthPolicy Accepted=False, and generated ZERO
    # AuthConfigs — so Authorino enforced nothing. Pods being Running says
    # nothing about whether policy is actually attached.
    AP_TOTAL=$(oc get authpolicy -A --no-headers 2>/dev/null | grep -cv "^$" || echo 0)
    if [[ "$AP_TOTAL" -gt 0 ]]; then
        AP_BAD=$(oc get authpolicy -A -o json 2>/dev/null | jq -r '
            .items[]
            | select(((.status.conditions // [])[] | select(.type=="Accepted") | .status) != "True")
            | "\(.metadata.namespace)/\(.metadata.name): \((.status.conditions // [])[] | select(.type=="Accepted") | .message // "no Accepted condition")"' 2>/dev/null || echo "")
        if [[ -n "$AP_BAD" ]]; then
            fail "AuthPolicy" "$(echo "$AP_BAD" | wc -l | tr -d ' ') policy(ies) not Accepted — auth is NOT being enforced"
            echo "$AP_BAD" | head -3 | while read -r line; do echo "         $line"; done
            if echo "$AP_BAD" | grep -qi "provider.*not installed\|restart Kuadrant"; then
                recommend "Kuadrant cached a stale provider probe — delete its pod: oc delete pod -n openshift-operators -l control-plane=controller-manager (see docs/workarounds.md E1)"
            else
                recommend "AuthPolicy not Accepted — inspect: oc get authpolicy -A -o yaml | grep -A5 conditions"
            fi
        else
            pass "AuthPolicy" "$AP_TOTAL policy(ies) Accepted"
        fi

        # AuthConfigs are the concrete artifact Authorino enforces. Accepted
        # policies with zero AuthConfigs means enforcement silently does nothing.
        AC_COUNT=$(oc get authconfig -A --no-headers 2>/dev/null | grep -cv "^$" || echo 0)
        if [[ "$AC_COUNT" -eq 0 ]]; then
            fail "AuthConfigs" "0 AuthConfigs exist despite $AP_TOTAL AuthPolicy — Authorino has nothing to enforce"
            recommend "No AuthConfigs generated — restart the Kuadrant operator pod (docs/workarounds.md E1)"
        else
            pass "AuthConfigs" "$AC_COUNT generated"
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
section "11. Observability"

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
                # A Service on :8080 is NOT proof the dashboard can use it. On
                # 2026-08-04 (tm9xb) every server-side signal was green while the
                # Observability page was 100% broken, two ways:
                # Root cause is a SINGLE unset field: Dashboard.spec.observability.enabled
                # defaults false and no rhods-operator path sets it, so the dashboard
                # operator skips the whole manifests/observability/rhoai/ bundle. The
                # missing dashboard-perses-access NetworkPolicy and the missing RHOAI
                # PersesDashboards are consequences of that, not separate blockers, so
                # the .enabled test must come first and the reachability test is only
                # meaningful once it is true.
                # See docs/issues/observability-dashboard-unreachable.md
                #
                # Test .enabled explicitly, not mere presence of the object: it is
                # +kubebuilder:default=false, so once anything causes the object to
                # materialize as {"enabled":false} a presence check reads non-empty and
                # would blame the network path while the flag is still off.
                DASH_OBS=$(oc get dashboard default-dashboard -o jsonpath='{.spec.observability.enabled}' 2>/dev/null || echo "")
                DASH_POD=$(oc get pods -n redhat-ods-applications -l app=rhods-dashboard \
                    --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's|pod/||')
                PERSES_REACH=""
                if [[ -n "$DASH_POD" ]]; then
                    # Capture curl's code and the exec status separately: on failure
                    # curl -w already prints '000' with no newline, so a `|| echo 000`
                    # fallback would concatenate into '000000'.
                    PERSES_REACH=$(oc exec -n redhat-ods-applications "$DASH_POD" -c rhods-dashboard -- \
                        curl -s -m 5 -o /dev/null -w '%{http_code}' \
                        "http://${PERSES_NAME}.redhat-ods-monitoring.svc.cluster.local:8080/api/v1/dashboards" 2>/dev/null)
                    PERSES_EXEC_RC=$?
                    [[ -z "$PERSES_REACH" ]] && PERSES_REACH="000"
                else
                    PERSES_EXEC_RC=0
                fi

                if [[ "$DASH_OBS" != "true" ]]; then
                    warn "Observability Dashboard" "Dashboard CR spec.observability.enabled is not true — the whole observability bundle (Perses proxy config, dashboard-perses-access NetworkPolicy, RHOAI PersesDashboards) is skipped; UI shows 'Unable to reach observability dashboards' (RHOAIENG-80354)"
                elif [[ -z "$DASH_POD" ]]; then
                    warn "Observability Dashboard" "No Running rhods-dashboard pod — cannot test the path to $PERSES_NAME"
                elif [[ "$PERSES_REACH" != "200" ]]; then
                    # Distinguish a real drop from an inability to run the probe:
                    # diagnose.sh is otherwise read-only, so a non-admin run lands
                    # here on missing pods/exec rather than on a network problem.
                    if [[ "$PERSES_EXEC_RC" -ne 0 && "$PERSES_REACH" == "000" ]]; then
                        info "Observability Dashboard" "Could not probe $PERSES_NAME from the dashboard pod (oc exec rc=$PERSES_EXEC_RC — needs pods/exec; not evidence of a network problem)"
                    else
                        warn "Observability Dashboard" "Dashboard pod cannot reach $PERSES_NAME:8080 (HTTP '$PERSES_REACH') — check for a NetworkPolicy in redhat-ods-monitoring denying ingress from redhat-ods-applications"
                    fi
                else
                    pass "Observability Dashboard" "$PERSES_NAME reachable from the dashboard pod (HTTP 200) and proxy configured"
                fi
                pass "Perses Dashboard Backend" "$PERSES_NAME (operator-managed) Service present on port 8080 in redhat-ods-monitoring"
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
section "12. Network"

INGRESS_AVAILABLE=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
if [[ "$INGRESS_AVAILABLE" == "True" ]]; then
    pass "Ingress" "Available"
else
    warn "Ingress" "Available=$INGRESS_AVAILABLE"
fi

# ── Gateways ─────────────────────────────────────────────────────────────────
# Previously only `maas-default-gateway` was checked, and only its Programmed
# condition. That missed the dashboard gateway entirely: on 2026-07-29
# `data-science-gateway` was Programmed=True while its backing envoy pod was
# OOMKilled in CrashLoopBackOff and the dashboard served 503. Programmed
# describes the CONFIG, not the data plane — always check the pods too.
GATEWAYS=$(oc get gateway -A --no-headers 2>/dev/null | awk '{print $1" "$2}' || echo "")
if [[ -n "$GATEWAYS" ]]; then
    echo "$GATEWAYS" | while read -r GW_NS GW_NAME; do
        [[ -z "$GW_NAME" ]] && continue
        GW_PROG=$(oc get gateway "$GW_NAME" -n "$GW_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
        GW_PODS=$(oc get pods -n "$GW_NS" -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" --no-headers 2>/dev/null || echo "")
        GW_POD_TOTAL=$(echo "$GW_PODS" | grep -cv "^$" || echo 0)
        GW_POD_READY=$(echo "$GW_PODS" | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") c++} END {print c+0}')
        if [[ "$GW_PROG" != "True" ]]; then
            echo "  GWFAIL $GW_NS/$GW_NAME Programmed=$GW_PROG"
        elif [[ "$GW_POD_TOTAL" -eq 0 ]]; then
            echo "  GWWARN $GW_NS/$GW_NAME Programmed but no backing pods found"
        elif [[ "$GW_POD_READY" -lt "$GW_POD_TOTAL" ]]; then
            echo "  GWFAIL $GW_NS/$GW_NAME Programmed=True but only $GW_POD_READY/$GW_POD_TOTAL pod(s) Ready"
        else
            echo "  GWPASS $GW_NS/$GW_NAME Programmed, $GW_POD_READY/$GW_POD_TOTAL pod(s) Ready"
        fi
    done > /tmp/.diag-gw-$$ 2>/dev/null
    while read -r STATUS REST; do
        case "$STATUS" in
            GWPASS) pass "Gateway" "$REST" ;;
            GWWARN) warn "Gateway" "$REST" ;;
            GWFAIL) fail "Gateway" "$REST"
                    recommend "Gateway data plane down: oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=<name>; check for OOMKilled (docs/workarounds.md A1/A2)" ;;
        esac
    done < /tmp/.diag-gw-$$
    rm -f /tmp/.diag-gw-$$
else
    info "Gateways" "None found"
fi

# ── User-facing endpoint reachability ────────────────────────────────────────
# The check that would have caught the 2026-07-29 dashboard outage directly.
# Unauthenticated probes only — 200/302/303 all mean "the data plane answered";
# 503/502/000 mean the gateway or backend is down.
CLUSTER_DOMAIN=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null || echo "")
if [[ -n "$CLUSTER_DOMAIN" ]]; then
    DASH_HOST=$(oc get route -A -o jsonpath='{range .items[?(@.spec.to.name=="data-science-gateway-data-science-gateway-class")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)
    [[ -z "$DASH_HOST" ]] && DASH_HOST=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "$DASH_HOST" ]]; then
        DASH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 "https://${DASH_HOST}/" 2>/dev/null || echo "000")
        case "$DASH_CODE" in
            200|302|303)
                pass "Dashboard Reachable" "https://${DASH_HOST}/ -> HTTP $DASH_CODE" ;;
            000)
                fail "Dashboard Reachable" "https://${DASH_HOST}/ -> no response (timeout/DNS)"
                recommend "Dashboard unreachable — check the gateway pod: oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=data-science-gateway" ;;
            *)
                fail "Dashboard Reachable" "https://${DASH_HOST}/ -> HTTP $DASH_CODE (expected 200/302)"
                recommend "Dashboard returning $DASH_CODE — check gateway pod for OOMKilled/CrashLoopBackOff (docs/workarounds.md A1)" ;;
        esac
    else
        info "Dashboard Reachable" "No dashboard route found"
    fi
fi

MAAS_HOST=$(oc get route -A --no-headers 2>/dev/null | awk '$3 ~ /^maas\./ {print $3; exit}')
if [[ -z "$MAAS_HOST" ]] && [[ -n "$CLUSTER_DOMAIN" ]]; then
    oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null && MAAS_HOST="maas.${CLUSTER_DOMAIN}"
fi
if [[ -n "$MAAS_HOST" ]]; then
    MAAS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 "https://${MAAS_HOST}/maas-api/health" 2>/dev/null || echo "000")
    if [[ "$MAAS_CODE" == "200" ]] || [[ "$MAAS_CODE" == "401" ]]; then
        pass "MaaS Endpoint Reachable" "https://${MAAS_HOST}/maas-api/health -> HTTP $MAAS_CODE"
    else
        fail "MaaS Endpoint Reachable" "https://${MAAS_HOST}/maas-api/health -> HTTP $MAAS_CODE (expected 200/401)"
        recommend "MaaS endpoint not answering — check maas-api and the MaaS gateway pod"
    fi
fi

# ── Known-workaround effectiveness (docs/workarounds.md A1) ──────────────────
# The Kuadrant wasm leak being PRESENT is normal; what matters is whether our
# strip EnvoyFilter actually neutralises it. istio orders EnvoyFilters by
# (priority, creationTimestamp, name) — if the strip sorts BEFORE Kuadrant's
# filter, the REMOVE runs before the INSERT and the wasm survives.
if oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress &>/dev/null; then
    LEAK_SELECTOR=$(oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.workloadSelector}' 2>/dev/null || echo "")
    if [[ -z "$LEAK_SELECTOR" ]]; then
        STRIP_PRIO=$(oc get envoyfilter strip-kuadrant-wasm-dashboard-gateway -n openshift-ingress -o jsonpath='{.spec.priority}' 2>/dev/null || echo "")
        if [[ -z "$STRIP_PRIO" ]]; then
            fail "Wasm Leak Strip" "Kuadrant EnvoyFilter has empty workloadSelector (leaking) and no strip filter found"
            recommend "Dashboard gateway will crash-loop — see docs/workarounds.md A1"
        elif [[ "$STRIP_PRIO" -le 0 ]] 2>/dev/null; then
            warn "Wasm Leak Strip" "strip filter priority=$STRIP_PRIO — ordering not guaranteed vs Kuadrant's filter"
            recommend "Set spec.priority > 0 on strip-kuadrant-wasm-dashboard-gateway (docs/workarounds.md A1)"
        else
            pass "Wasm Leak Strip" "Leak present but strip filter has priority=$STRIP_PRIO (applies after Kuadrant)"
        fi
    else
        pass "Wasm Leak Strip" "Kuadrant EnvoyFilter is scoped (no leak) — strip no longer needed"
    fi
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
