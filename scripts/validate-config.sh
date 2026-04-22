#!/usr/bin/env bash
#
# validate-config.sh - Validate .env configuration against cluster capabilities
#
# Checks credentials, branch/repo, GPU compatibility with MaaS models,
# and other .env settings against the actual cluster state.
#
# Usage:
#   ./validate-config.sh
#
# Exit codes:
#   0 = All checks passed
#   1 = Failures detected
#   2 = Warnings only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}  $1: $2"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "  ${YELLOW}WARN${NC}  $1: $2"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $1: $2"; }
info() { echo -e "  ${BLUE}INFO${NC}  $1: $2"; }

# === .env File ===
echo ""
echo -e "${BLUE}.env File${NC}"
echo "─────────"

ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    pass ".env" "File exists"
    source "$ENV_FILE" 2>/dev/null || true
else
    info ".env" "Not found — validating defaults"
fi

# === Credentials ===
echo ""
echo -e "${BLUE}Credentials${NC}"
echo "───────────"

if [[ -n "${QUAY_USER:-}" ]] && [[ -n "${QUAY_TOKEN:-}" ]]; then
    pass "Credential Mode" "Manual (QUAY_USER=$QUAY_USER)"
else
    info "Credential Mode" "External Secrets (no QUAY_USER/QUAY_TOKEN set)"

    BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap.git}"
    BOOTSTRAP_REPO_SSH=$(echo "$BOOTSTRAP_REPO" | sed 's|https://github.com/|git@github.com:|')
    if git ls-remote "$BOOTSTRAP_REPO" HEAD &>/dev/null || git ls-remote "$BOOTSTRAP_REPO_SSH" HEAD &>/dev/null; then
        pass "Bootstrap Repo" "Access confirmed"
    else
        fail "Bootstrap Repo" "Cannot access $BOOTSTRAP_REPO — set QUAY_USER/QUAY_TOKEN or get repo access"
    fi
fi

# === Branch & Repo ===
echo ""
echo -e "${BLUE}Branch & Repository${NC}"
echo "───────────────────"

# Detect configured vs actual
CONFIGURED_BRANCH="${GITOPS_BRANCH:-}"
CURRENT_BRANCH=$(cd "$REPO_ROOT" && git branch --show-current 2>/dev/null || echo "")
EFFECTIVE_BRANCH="${CONFIGURED_BRANCH:-${CURRENT_BRANCH:-main}}"

CONFIGURED_REPO="${GITOPS_REPO_URL:-}"
CURRENT_REPO=$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || echo "")
EFFECTIVE_REPO="${CONFIGURED_REPO:-${CURRENT_REPO:-https://github.com/rh-aiservices-bu/rhoai-nightly}}"

if [[ -n "$CONFIGURED_BRANCH" ]]; then
    info "Branch" "$EFFECTIVE_BRANCH (from .env GITOPS_BRANCH)"
else
    info "Branch" "$EFFECTIVE_BRANCH (auto-detected from git)"
fi

if [[ -n "$CONFIGURED_REPO" ]]; then
    info "Repo" "$EFFECTIVE_REPO (from .env GITOPS_REPO_URL)"
else
    info "Repo" "$EFFECTIVE_REPO (auto-detected from git remote)"
fi

# Check branch exists on remote
if git ls-remote "$EFFECTIVE_REPO" "$EFFECTIVE_BRANCH" 2>/dev/null | grep -q .; then
    pass "Branch Exists" "'$EFFECTIVE_BRANCH' found on remote"
else
    warn "Branch Exists" "'$EFFECTIVE_BRANCH' not found on remote — push before deploying"
fi

# Compare with what ArgoCD is currently tracking
ARGOCD_BRANCH=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{.items[0].spec.source.targetRevision}' 2>/dev/null || echo "")
if [[ -n "$ARGOCD_BRANCH" ]]; then
    if [[ "$ARGOCD_BRANCH" == "$EFFECTIVE_BRANCH" ]]; then
        pass "ArgoCD Match" "ArgoCD tracking '$ARGOCD_BRANCH' — matches config"
    else
        warn "ArgoCD Match" "ArgoCD tracking '$ARGOCD_BRANCH' but config says '$EFFECTIVE_BRANCH' — run 'GITOPS_BRANCH=$EFFECTIVE_BRANCH make deploy' to update"
    fi
fi

# === GPU & MaaS Model Compatibility ===
echo ""
echo -e "${BLUE}GPU & MaaS Model Compatibility${NC}"
echo "──────────────────────────────"

# GPU instance type reference table
# Maps instance type to VRAM (GB) and system RAM (GB)
get_gpu_specs() {
    case "$1" in
        g5.xlarge)    echo "24|16"  ;;
        g5.2xlarge)   echo "24|32"  ;;
        g5.4xlarge)   echo "24|64"  ;;
        g5.8xlarge)   echo "24|128" ;;
        g5.12xlarge)  echo "96|192" ;;
        g5.16xlarge)  echo "24|256" ;;
        g5.24xlarge)  echo "96|384" ;;
        g5.48xlarge)  echo "192|768" ;;
        g6e.xlarge)   echo "48|32"  ;;
        g6e.2xlarge)  echo "48|64"  ;;
        g6e.4xlarge)  echo "48|128" ;;
        g6e.8xlarge)  echo "48|256" ;;
        g6e.12xlarge) echo "96|384" ;;
        g6e.16xlarge) echo "48|512" ;;
        g6e.24xlarge) echo "96|768" ;;
        g6e.48xlarge) echo "192|1536" ;;
        p4d.24xlarge) echo "320|1152" ;;
        p5.48xlarge)  echo "640|2048" ;;
        *)            echo "0|0" ;;
    esac
}

# Model resource requirements
# Format: gpu_required|mem_request_gi|mem_limit_gi|description
get_model_requirements() {
    case "$1" in
        simulator)        echo "0|0|1|CPU-only mock model" ;;
        gpt-oss-20b)      echo "1|16|60|OpenAI gpt-oss-20b on vLLM CUDA" ;;
        granite-tiny-gpu)  echo "1|8|24|Granite 4.0-h-tiny FP8 on vLLM CUDA" ;;
        *)                echo "0|0|0|Unknown model" ;;
    esac
}

# Determine GPU type — from cluster first, then .env, then default
# Check nvidia label first (works on all clusters), fall back to role label
GPU_SELECTOR="nvidia.com/gpu.present=true"
if ! oc get nodes -l "$GPU_SELECTOR" --no-headers 2>/dev/null | grep -q .; then
    GPU_SELECTOR="node-role.kubernetes.io/gpu"
fi
GPU_INSTANCE_ON_CLUSTER=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")
GPU_INSTANCE_IN_ENV="${GPU_INSTANCE_TYPE:-}"
GPU_INSTANCE_DEFAULT="g6e.2xlarge"

if [[ -n "$GPU_INSTANCE_ON_CLUSTER" ]]; then
    GPU_TYPE="$GPU_INSTANCE_ON_CLUSTER"
    GPU_SOURCE="cluster"
elif [[ -n "$GPU_INSTANCE_IN_ENV" ]]; then
    GPU_TYPE="$GPU_INSTANCE_IN_ENV"
    GPU_SOURCE=".env"
else
    GPU_TYPE="$GPU_INSTANCE_DEFAULT"
    GPU_SOURCE="default"
fi

GPU_SPECS=$(get_gpu_specs "$GPU_TYPE")
GPU_VRAM="${GPU_SPECS%%|*}"
GPU_RAM="${GPU_SPECS##*|}"
GPU_NODE_COUNT=$(oc get nodes -l $GPU_SELECTOR --no-headers 2>/dev/null | wc -l | tr -d ' ')

info "GPU Type" "$GPU_TYPE — from $GPU_SOURCE"
info "GPU Nodes" "$GPU_NODE_COUNT on cluster"

# Get actual specs from the GPU node (more accurate than instance type table)
NODE_ALLOC_KI=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null | sed 's/Ki//' || echo "0")
GPU_VRAM_MIB=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null || echo "0")
GPU_PRODUCT=$(oc get nodes -l $GPU_SELECTOR -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || echo "unknown")

if [[ "$NODE_ALLOC_KI" -gt 0 ]]; then
    NODE_ALLOC_GI=$((NODE_ALLOC_KI / 1024 / 1024))
    info "System RAM" "${NODE_ALLOC_GI}Gi allocatable (after OS/kubelet reserves)"
else
    NODE_ALLOC_GI="$GPU_RAM"
fi

if [[ "$GPU_VRAM_MIB" -gt 0 ]]; then
    GPU_VRAM_GI=$((GPU_VRAM_MIB / 1024))
    info "GPU VRAM" "${GPU_VRAM_GI}GB $GPU_PRODUCT (from node label nvidia.com/gpu.memory)"
else
    GPU_VRAM_GI="$GPU_VRAM"
    info "GPU VRAM" "${GPU_VRAM_GI}GB (estimated from instance type)"
fi

# Get configured models
MAAS_MODELS_CONFIGURED="${MAAS_MODELS:-}"
if [[ -z "$MAAS_MODELS_CONFIGURED" ]]; then
    ALL_MODELS="gpt-oss-20b"
    info "MAAS_MODELS" "Not set — default: $ALL_MODELS"
    MAAS_MODELS_CONFIGURED="$ALL_MODELS"
elif [[ "$MAAS_MODELS_CONFIGURED" == "all" ]]; then
    ALL_MODELS="gpt-oss-20b granite-tiny-gpu"
    info "MAAS_MODELS" "all ($ALL_MODELS)"
    MAAS_MODELS_CONFIGURED="$ALL_MODELS"
else
    info "MAAS_MODELS" "$MAAS_MODELS_CONFIGURED"
fi

# Check each model against actual node allocatable memory
GPU_MODELS_COUNT=0
for MODEL in $MAAS_MODELS_CONFIGURED; do
    REQ=$(get_model_requirements "$MODEL")
    REQ_GPU="${REQ%%|*}"
    REST="${REQ#*|}"
    REQ_REQUEST="${REST%%|*}"
    REST2="${REST#*|}"
    REQ_LIMIT="${REST2%%|*}"
    REQ_DESC="${REST2#*|}"

    if [[ "$REQ_GPU" -eq 0 ]]; then
        pass "$MODEL" "CPU-only ($REQ_DESC) — runs anywhere"
    else
        GPU_MODELS_COUNT=$((GPU_MODELS_COUNT + 1))
        if [[ "$GPU_NODE_COUNT" -eq 0 ]]; then
            # No GPU nodes yet on cluster. `make gpu` creates the MachineSet as
            # part of the install flow, so treat as INFO, not FAIL. We can't
            # validate node-specific RAM/VRAM until the node exists.
            info "$MODEL" "Requires GPU; no GPU nodes yet — 'make gpu' will create $GPU_TYPE MachineSet"
        elif [[ "$NODE_ALLOC_GI" -gt 0 ]] && [[ "$REQ_REQUEST" -gt "$NODE_ALLOC_GI" ]]; then
            fail "$MODEL" "Requests ${REQ_REQUEST}Gi RAM but node only has ${NODE_ALLOC_GI}Gi allocatable — won't schedule"
        elif [[ "$NODE_ALLOC_GI" -gt 0 ]] && [[ "$REQ_LIMIT" -gt "$NODE_ALLOC_GI" ]]; then
            warn "$MODEL" "Limit ${REQ_LIMIT}Gi > node allocatable ${NODE_ALLOC_GI}Gi — may OOMKill if usage spikes"
        else
            pass "$MODEL" "${REQ_DESC} (requests ${REQ_REQUEST}Gi, limit ${REQ_LIMIT}Gi, node has ${NODE_ALLOC_GI}Gi)"
        fi
    fi
done

if [[ "$GPU_MODELS_COUNT" -gt 1 ]] && [[ "$GPU_NODE_COUNT" -eq 1 ]]; then
    warn "GPU Contention" "$GPU_MODELS_COUNT GPU models but only 1 GPU node — only one runs at a time"
elif [[ "$GPU_MODELS_COUNT" -gt 1 ]] && [[ "$GPU_NODE_COUNT" -gt 0 ]] && [[ "$GPU_MODELS_COUNT" -gt "$GPU_NODE_COUNT" ]]; then
    warn "GPU Contention" "$GPU_MODELS_COUNT GPU models but only $GPU_NODE_COUNT GPU node(s)"
fi

# === Other .env Settings ===
echo ""
echo -e "${BLUE}Other Settings${NC}"
echo "──────────────"

CPU_TYPE="${CPU_INSTANCE_TYPE:-m6a.4xlarge}"
info "CPU Instance" "$CPU_TYPE"

if [[ -n "${GPU_AZ:-}" ]]; then
    # Verify AZ exists in cluster
    CLUSTER_AZS=$(oc get machines -n openshift-machine-api -o jsonpath='{range .items[*]}{.spec.providerSpec.value.placement.availabilityZone}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ', ' | sed 's/,$//')
    if echo "$CLUSTER_AZS" | grep -q "$GPU_AZ"; then
        pass "GPU AZ" "$GPU_AZ (matches cluster AZs: $CLUSTER_AZS)"
    else
        warn "GPU AZ" "$GPU_AZ not found in cluster AZs: $CLUSTER_AZS"
    fi
fi

# === Summary ===
echo ""
echo "──────────────"
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
echo -e "Results: ${GREEN}$PASS_COUNT passed${NC}, ${YELLOW}$WARN_COUNT warnings${NC}, ${RED}$FAIL_COUNT failures${NC} ($TOTAL checks)"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "${RED}Configuration has issues. Fix .env before proceeding.${NC}"
    exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Configuration has warnings — review before proceeding.${NC}"
    exit 2
else
    echo ""
    echo -e "${GREEN}Configuration looks good.${NC}"
    exit 0
fi
