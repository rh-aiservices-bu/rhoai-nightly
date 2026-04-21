#!/usr/bin/env bash
#
# preflight-check.sh - Check if cluster is ready for RHOAI installation
#
# Validates prerequisites that must be true BEFORE installing.
# Does NOT check things the install itself creates (ICSP, pull-secret,
# GitOps, RHOAI, MaaS) — those are reported as install status context.
#
# Use `make diagnose` for a full health check of all components.
#
# Usage:
#   ./preflight-check.sh [OPTIONS]
#
# Options:
#   --quiet      Only show warnings and failures
#
# Exit codes:
#   0 = Ready for install
#   1 = Not ready (failures)
#   2 = Ready with warnings

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cluster-health.sh"

QUIET=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet) QUIET=true; shift ;;
        --skip-sizing-check) export SKIP_SIZING_CHECK=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--quiet] [--skip-sizing-check]"
            echo "Checks if the cluster is ready for RHOAI installation."
            echo "Use 'make diagnose' for a full health check."
            echo ""
            echo "Options:"
            echo "  --skip-sizing-check   Downgrade master-sizing FAIL to WARN"
            echo "  --quiet               Only show warnings and failures"
            echo ""
            echo "Env vars:"
            echo "  PREFLIGHT_SKIP_SIZING=1        Same as --skip-sizing-check"
            echo "  PREFLIGHT_SIM_INSTANCE_TYPE=…  Simulate a master instance type"
            exit 0
            ;;
        *) shift ;;
    esac
done

# Count matching lines (handles grep -c quirks with newlines)
count_matches() { grep -c "$@" 2>/dev/null | tr -d '[:space:]' || echo 0; }

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); [[ "$QUIET" != "true" ]] && echo -e "  ${GREEN}PASS${NC}  $1: $2"; return 0; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "  ${YELLOW}WARN${NC}  $1: $2"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $1: $2"; }
info() { [[ "$QUIET" != "true" ]] && echo -e "  ${BLUE}INFO${NC}  $1: $2"; return 0; }

echo ""
echo -e "${BLUE}Preflight Check — Can we install RHOAI?${NC}"
echo "════════════════════════════════════════"

# ─────────────────────────────────────────
# 1. Cluster Connectivity (REQUIRED)
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Cluster Connection${NC}"
echo "──────────────────"

if ! oc whoami &>/dev/null; then
    fail "Connection" "Not logged into OpenShift. Run 'oc login' first."
    echo ""
    echo -e "${RED}Cannot proceed without cluster connection.${NC}"
    exit 1
fi

CLUSTER_URL=$(oc whoami --show-server 2>/dev/null)
OCP_VERSION=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo "unknown")
CLUSTER_AVAILABLE=$(oc get clusterversion -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")

pass "Connection" "$CLUSTER_URL"
info "Platform" "$PLATFORM, OCP $OCP_VERSION"

if [[ "$CLUSTER_AVAILABLE" != "True" ]]; then
    fail "Cluster Health" "ClusterVersion Available=$CLUSTER_AVAILABLE — cluster is not healthy"
else
    pass "Cluster Health" "Available"
fi

# ─────────────────────────────────────────
# 2. Control Plane Health (REQUIRED)
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Control Plane Health${NC}"
echo "────────────────────"

check_master_sizing --fail-hard
check_master_pressure --fail-hard
check_cluster_operators --fail-hard

# ─────────────────────────────────────────
# 3. Node Health (REQUIRED)
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Node Health${NC}"
echo "───────────"

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_NODES=$(oc get nodes --no-headers 2>/dev/null | count_matches " Ready")
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker,\!node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
GPU_SELECTOR="nvidia.com/gpu.present=true"
if [[ "$GPU_NODES" -eq 0 ]]; then
    GPU_NODES=$(oc get nodes -l $GPU_SELECTOR --no-headers 2>/dev/null | wc -l | tr -d ' ')
    GPU_SELECTOR="node-role.kubernetes.io/gpu"
fi

if [[ "$TOTAL_NODES" -eq 0 ]]; then
    fail "Nodes" "No nodes found"
elif [[ "$READY_NODES" -ne "$TOTAL_NODES" ]]; then
    NOTREADY=$((TOTAL_NODES - READY_NODES))
    fail "Nodes" "$NOTREADY of $TOTAL_NODES node(s) not Ready — wait for nodes before installing"
else
    pass "Nodes" "$TOTAL_NODES total ($MASTER_NODES master, $WORKER_NODES worker, $GPU_NODES gpu) — all Ready"
fi

# MCP — degraded MCP blocks installation
MCP_DEGRADED=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | count_matches "True")
MCP_UPDATING=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updated")].status}{"\n"}{end}' 2>/dev/null | count_matches "False")

if [[ "$MCP_DEGRADED" -gt 0 ]]; then
    fail "MachineConfigPool" "Degraded — must resolve before installing"
elif [[ "$MCP_UPDATING" -gt 0 ]]; then
    warn "MachineConfigPool" "Still updating — install will wait but may be slow"
else
    pass "MachineConfigPool" "All updated"
fi

# GPU — warn only (not required for basic install, just for GPU models)
if [[ "$GPU_NODES" -gt 0 ]]; then
    GPU_INSTANCE=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    pass "GPU Nodes" "$GPU_NODES node(s) ($GPU_INSTANCE)"
else
    info "GPU Nodes" "None — 'make gpu' will create during install"
fi

# ─────────────────────────────────────────
# 3. Configuration (.env)
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Configuration${NC}"
echo "─────────────"

if [[ -f "$REPO_ROOT/.env" ]]; then
    pass ".env File" "Present"
    source "$REPO_ROOT/.env" 2>/dev/null || true
else
    info ".env File" "Not present — using defaults (override by copying .env.example to .env if needed)"
fi

# Check credentials availability — one of these must work
if [[ -n "${QUAY_USER:-}" ]] && [[ -n "${QUAY_TOKEN:-}" ]]; then
    pass "Credentials" "Manual mode (QUAY_USER set)"
else
    BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap.git}"
    # Try HTTPS first, then convert to SSH if HTTPS fails (handles SSH-only auth setups)
    BOOTSTRAP_REPO_SSH=$(echo "$BOOTSTRAP_REPO" | sed 's|https://github.com/|git@github.com:|')
    if git ls-remote "$BOOTSTRAP_REPO" HEAD &>/dev/null || git ls-remote "$BOOTSTRAP_REPO_SSH" HEAD &>/dev/null; then
        pass "Credentials" "External Secrets mode (bootstrap repo accessible)"
    else
        fail "Credentials" "No QUAY_USER/QUAY_TOKEN and no access to bootstrap repo"
    fi
fi

# Check branch exists on remote (warn only — can push before install)
CURRENT_BRANCH=$(cd "$REPO_ROOT" && git branch --show-current 2>/dev/null || echo "main")
EFFECTIVE_BRANCH="${GITOPS_BRANCH:-$CURRENT_BRANCH}"
EFFECTIVE_REPO=$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || echo "")

info "GitOps Branch" "$EFFECTIVE_BRANCH"

if [[ -n "$EFFECTIVE_REPO" ]] && ! git ls-remote "$EFFECTIVE_REPO" "$EFFECTIVE_BRANCH" 2>/dev/null | grep -q .; then
    warn "Branch" "'$EFFECTIVE_BRANCH' not found on remote — push before deploying"
else
    pass "Branch" "'$EFFECTIVE_BRANCH' exists on remote"
fi

# ─────────────────────────────────────────
# 4. Install Status (INFO only — not pass/fail)
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Current Install Status${NC}"
echo "──────────────────────"

# These are informational — things the install will create/manage
ICSP_COUNT=$(oc get imagecontentsourcepolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ICSP_COUNT" -gt 0 ]]; then
    info "ICSP" "Present"
else
    info "ICSP" "Not configured (will be created by 'make icsp')"
fi

PULL_SECRET_KEYS=$(oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.auths | keys[]' 2>/dev/null || echo "")
HAS_QUAY_RHOAI=$(echo "$PULL_SECRET_KEYS" | count_matches "quay.io/rhoai")
if [[ "$HAS_QUAY_RHOAI" -gt 0 ]]; then
    info "Pull Secret" "quay.io/rhoai present"
else
    info "Pull Secret" "Not yet configured (will be created by 'make secrets')"
fi

GITOPS_CSV=$(oc get csv -n openshift-gitops-operator --no-headers 2>/dev/null | grep gitops || echo "")
if [[ -n "$GITOPS_CSV" ]]; then
    info "GitOps" "Installed ($(echo "$GITOPS_CSV" | awk '{print $NF}'))"
else
    info "GitOps" "Not installed"
fi

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods || echo "")
if [[ -n "$RHOAI_CSV" ]]; then
    info "RHOAI" "Installed ($(echo "$RHOAI_CSV" | awk '{print $NF}'))"
else
    info "RHOAI" "Not installed"
fi

MAAS_APP=$(oc get application.argoproj.io/instance-maas -n openshift-gitops --no-headers 2>/dev/null || echo "")
if [[ -n "$MAAS_APP" ]]; then
    info "MaaS" "Installed"
else
    info "MaaS" "Not installed"
fi

# Warn about pending install plans (can block operator installs)
PENDING_PLANS=$(oc get installplan -A --no-headers 2>/dev/null | grep -v "Complete" | grep -v "^$" || echo "")
if [[ -n "$PENDING_PLANS" ]]; then
    PENDING_COUNT=$(echo "$PENDING_PLANS" | wc -l | tr -d ' ')
    warn "Install Plans" "$PENDING_COUNT pending — may block operator installs (check manual approval)"
fi

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
echo -e "Preflight: ${GREEN}$PASS_COUNT passed${NC}, ${YELLOW}$WARN_COUNT warnings${NC}, ${RED}$FAIL_COUNT failures${NC}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "${RED}Not ready for install. Fix the failures above first.${NC}"
    exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Ready to install (with warnings).${NC}"
    exit 2
else
    echo ""
    echo -e "${GREEN}Ready to install! Run '/install-rhoai' or 'make all'.${NC}"
    exit 0
fi
