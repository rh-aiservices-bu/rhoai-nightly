#!/usr/bin/env bash
#
# setup-maas-model.sh - Deploy a sample model with MaaS access and rate limits
#
# Each model includes:
#   - LLMInferenceService (the model workload)
#   - MaaSModelRef (registers model in MaaS catalog)
#   - MaaSAuthPolicy (grants access to specified groups)
#   - MaaSSubscription (free + premium tiers with token rate limits)
#
# Prerequisites:
#   - MaaS installed (run make maas first)
#   - oc logged into cluster
#
# Usage:
#   ./setup-maas-model.sh [OPTIONS] [MODEL]
#
# Models:
#   simulator       CPU-only mock (default, ~256Mi RAM, no real LLM)
#   granite-gpu     IBM Granite 3.1 2B on vLLM GPU (requires nvidia.com/gpu)
#   all             Deploy all models
#
# Options:
#   --delete        Delete the model instead of deploying
#   --status        Show status of deployed models
#   -h, --help      Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$REPO_ROOT/components/instances/maas-models"

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

# Default to MAAS_MODELS env var, then all models
MODEL="${1:-${MAAS_MODELS:-all}}"
DELETE=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --delete) DELETE=true; shift ;;
        --status) STATUS_ONLY=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: setup-maas-model.sh [OPTIONS] [MODEL...]

Deploy sample models with MaaS access and rate limits.
Each model gets free tier (100 tokens/min) and premium tier (10000 tokens/min).

Models:
  simulator         CPU-only mock (default, ~256Mi RAM)
  gpt-oss-20b       OpenAI gpt-oss-20b on vLLM GPU (requires nvidia.com/gpu)
  granite-tiny-gpu  RedHatAI Granite 4.0-h-tiny FP8 on vLLM GPU
  all               Deploy all models

Config:
  Set MAAS_MODELS in .env to deploy multiple models by default:
    MAAS_MODELS=simulator gpt-oss-20b

Options:
  --delete        Delete the model(s) instead of deploying
  --status        Show status of deployed models
  -h, --help      Show this help message

Examples:
  ./setup-maas-model.sh                            # Deploy simulator (or MAAS_MODELS)
  ./setup-maas-model.sh simulator gpt-oss-20b      # Deploy specific models
  ./setup-maas-model.sh all                        # Deploy all models
  ./setup-maas-model.sh --delete gpt-oss-20b       # Remove one model
  ./setup-maas-model.sh --delete all               # Remove all models
  ./setup-maas-model.sh --status                   # Show deployed model status
EOF
            exit 0
            ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *)
            # Collect all positional args as models (supports: simulator gpt-oss-20b)
            if [ "$MODEL" = "${MAAS_MODELS:-simulator}" ] && [ -z "${POSITIONAL_SET:-}" ]; then
                MODEL="$1"
                POSITIONAL_SET=true
            else
                MODEL="$MODEL $1"
            fi
            shift
            ;;
    esac
done

# =============================================================================
# Resolve model paths
# =============================================================================
resolve_single_model() {
    local model="$1"
    case "$model" in
        simulator)
            echo "$MODELS_DIR/simulator"
            ;;
        gpt-oss-20b|gpt-oss)
            echo "$MODELS_DIR/gpt-oss-20b"
            ;;
        granite-tiny-gpu|granite-tiny|granite)
            echo "$MODELS_DIR/granite-tiny-gpu"
            ;;
        all)
            for d in "$MODELS_DIR"/*/; do
                [ -f "$d/kustomization.yaml" ] && echo "$d"
            done
            ;;
        *)
            if [ -d "$MODELS_DIR/$model" ]; then
                echo "$MODELS_DIR/$model"
            else
                log_error "Unknown model: $model"
                log_error "Available: $(ls "$MODELS_DIR" | tr '\n' ', ' | sed 's/,$//')"
                return 1
            fi
            ;;
    esac
}

resolve_model_paths() {
    local models="$1"
    for m in $models; do
        resolve_single_model "$m" || return 1
    done
}

# =============================================================================
# Status
# =============================================================================
if [ "$STATUS_ONLY" = true ]; then
    log_step "MaaS Model Status"

    echo ""
    echo "LLMInferenceServices:"
    oc get llminferenceservice -A 2>/dev/null || echo "  (none)"

    echo ""
    echo "MaaSModelRefs:"
    oc get maasmodelref -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,ENDPOINT:.status.endpoint' 2>/dev/null || echo "  (none)"

    echo ""
    echo "MaaSSubscriptions:"
    oc get maassubscription -A 2>/dev/null || echo "  (none)"

    echo ""
    echo "MaaSAuthPolicies:"
    oc get maasauthpolicy -A 2>/dev/null || echo "  (none)"

    echo ""
    echo "Model Pods:"
    oc get pods -n llm 2>/dev/null || echo "  (none in llm namespace)"

    exit 0
fi

# =============================================================================
# Preflight
# =============================================================================
log_step "Preflight checks"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

MODEL_PATHS=$(resolve_model_paths "$MODEL") || exit 1

# Check for GPU requirement
for path in $MODEL_PATHS; do
    model_name=$(basename "$path")
    if [[ "$model_name" == *gpu* ]]; then
        GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$GPU_NODES" = "0" ]; then
            log_warn "$model_name requires GPU nodes but none found with nvidia.com/gpu.present=true"
            log_warn "The model may get stuck in Pending state"
        else
            log_info "Found $GPU_NODES GPU node(s) for $model_name"
        fi
    fi
done

# =============================================================================
# Delete mode
# =============================================================================
if [ "$DELETE" = true ]; then
    for path in $MODEL_PATHS; do
        model_name=$(basename "$path")
        log_step "Deleting model: $model_name"
        oc kustomize "$path" | oc delete -f - 2>/dev/null || true
        log_info "Deleted $model_name resources"
    done

    # Clean up empty namespaces
    for ns in llm models-as-a-service; do
        if oc get namespace "$ns" &>/dev/null; then
            REMAINING=$(oc get all,maasmodelref,maasauthpolicy,maassubscription,llminferenceservice -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "$REMAINING" = "0" ]; then
                oc delete namespace "$ns" 2>/dev/null || true
                log_info "Deleted empty namespace $ns"
            fi
        fi
    done
    exit 0
fi

# =============================================================================
# Deploy
# =============================================================================

# Ensure namespaces exist
oc create namespace llm --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f - 2>/dev/null

for path in $MODEL_PATHS; do
    model_name=$(basename "$path")
    log_step "Deploying model: $model_name"

    log_info "Applying kustomize manifests..."
    oc kustomize "$path" | oc apply --server-side=true -f -
done

# =============================================================================
# Wait for readiness
# =============================================================================
log_step "Waiting for models to be ready"

# Wait for pods
log_info "Waiting for model pods..."
TIMEOUT=300
# GPU models need more time to download weights
for path in $MODEL_PATHS; do
    if [[ "$(basename "$path")" == *gpu* ]]; then
        TIMEOUT=600
        log_info "GPU model detected, extending timeout to ${TIMEOUT}s"
        break
    fi
done

ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    TOTAL_PODS=$(oc get pods -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
    NOT_RUNNING=$(oc get pods -n llm --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" | wc -l | tr -d ' ')
    READY_PODS=$((TOTAL_PODS - NOT_RUNNING))

    if [ "$TOTAL_PODS" -ge 1 ] && [ "$NOT_RUNNING" = "0" ]; then
        log_info "All model pods running ($READY_PODS/$TOTAL_PODS)"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Waiting for model pods... (${ELAPSED}s, running: $READY_PODS/$TOTAL_PODS)"
    fi
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log_warn "Some model pods may not be ready after ${TIMEOUT}s"
    oc get pods -n llm
fi

# Wait for MaaSModelRef
log_info "Waiting for MaaSModelRef(s) to be Ready..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    TOTAL_REFS=$(oc get maasmodelref -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_REFS=$(oc get maasmodelref -n llm --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    READY_REFS=$(echo "$READY_REFS" | tr -d '[:space:]')

    if [ "$TOTAL_REFS" -ge 1 ] && [ "$READY_REFS" = "$TOTAL_REFS" ]; then
        log_info "All MaaSModelRefs ready ($READY_REFS/$TOTAL_REFS)"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log_warn "Some MaaSModelRefs may not be Ready after ${TIMEOUT}s"
fi

# =============================================================================
# Summary
# =============================================================================
log_step "Model deployment summary"

echo ""
echo "LLMInferenceServices:"
oc get llminferenceservice -n llm 2>/dev/null || echo "  (none)"

echo ""
echo "MaaSModelRefs:"
oc get maasmodelref -n llm -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,ENDPOINT:.status.endpoint' 2>/dev/null || echo "  (none)"

echo ""
echo "MaaSSubscriptions:"
oc get maassubscription -n models-as-a-service 2>/dev/null || echo "  (none)"

echo ""
echo "Model Pods:"
oc get pods -n llm 2>/dev/null || echo "  (none)"

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -n "$CLUSTER_DOMAIN" ]; then
    echo ""
    log_info "MaaS API: https://maas.${CLUSTER_DOMAIN}/maas-api/v1/models"
    log_info "Run 'make maas-verify' to test end-to-end"
fi
