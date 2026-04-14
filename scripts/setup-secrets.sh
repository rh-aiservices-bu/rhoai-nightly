#!/usr/bin/env bash
#
# setup-secrets.sh - Setup pull-secret (auto-detects mode)
#
# Modes (in priority order):
#   1. QUAY_USER/QUAY_TOKEN set → use manual mode (deletes ExternalSecret if exists)
#   2. ExternalSecret already exists → update config (re-applies AWS creds + template)
#   3. Pull-secret already has rhoai creds → skip
#   4. Has access to bootstrap repo → install External Secrets
#   5. None of above → error
#
# Usage:
#   ./setup-secrets.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Bootstrap repo configuration (for AWS credentials only)
# Override via .env: BOOTSTRAP_REPO, BOOTSTRAP_BRANCH
BOOTSTRAP_REPO_DEFAULT="https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap.git"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-$BOOTSTRAP_REPO_DEFAULT}"
BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-dev}"
BOOTSTRAP_SECRETS_PATH="external-secrets/rhoaibu-cluster-nightly"

# Local ExternalSecret template (not managed by ArgoCD to avoid conflict with manual mode)
LOCAL_EXTERNAL_SECRET="$REPO_ROOT/bootstrap/external-secrets"

# Auto-detect git protocol from origin remote and convert bootstrap URL to match
# Only applies when using the default bootstrap URL (not user-overridden)
auto_detect_git_protocol() {
    if [[ "$BOOTSTRAP_REPO" != "$BOOTSTRAP_REPO_DEFAULT" ]]; then
        return  # User set a custom URL, don't override
    fi

    local origin_url
    origin_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")

    if [[ "$origin_url" == git@* ]]; then
        # Origin uses SSH — convert bootstrap URL to SSH
        BOOTSTRAP_REPO="git@github.com:rh-aiservices-bu/rh-aiservices-bu-bootstrap.git"
        log_info "Detected SSH git protocol, using SSH for bootstrap repo"
    fi
}

# Test git access to bootstrap repo (non-blocking)
# Returns 0 if accessible, 1 if not
test_bootstrap_access() {
    local url="$1"

    if [[ "$url" == git@* ]]; then
        # SSH: use ConnectTimeout to fail fast
        GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
            git ls-remote "$url" &>/dev/null 2>&1
    else
        # HTTPS: disable terminal prompt to prevent hanging
        GIT_TERMINAL_PROMPT=0 git ls-remote "$url" &>/dev/null 2>&1
    fi
}

check_cluster_connection

# Mode 1: Manual credentials provided (takes precedence)
if [[ -n "${QUAY_USER:-}" ]] && [[ -n "${QUAY_TOKEN:-}" ]]; then
    # Delete ExternalSecret if exists (to avoid conflict - it would overwrite manual creds)
    if oc get externalsecret pull-secret -n openshift-config &>/dev/null; then
        log_warn "Switching from External Secrets to manual mode"
        log_info "Deleting ExternalSecret pull-secret..."
        oc delete externalsecret pull-secret -n openshift-config
    fi
    log_info "Using manual pull-secret (QUAY credentials set)"
    exec "$SCRIPT_DIR/add-pull-secret.sh"
fi

# Mode 2: Already managed by ExternalSecret - update config if changed
if oc get externalsecret pull-secret -n openshift-config &>/dev/null; then
    log_info "ExternalSecret exists, updating configuration..."

    auto_detect_git_protocol

    # Re-apply AWS credentials (in case BOOTSTRAP_REPO changed)
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    if git clone --depth 1 --branch "$BOOTSTRAP_BRANCH" "$BOOTSTRAP_REPO" "$TMPDIR/bootstrap" 2>/dev/null; then
        oc apply -k "$TMPDIR/bootstrap/$BOOTSTRAP_SECRETS_PATH" 2>/dev/null || true
    fi

    # Re-apply ExternalSecret template (in case template changed)
    oc apply -k "$LOCAL_EXTERNAL_SECRET"
    log_info "Configuration updated"
    exit 0
fi

# Mode 3: Pull-secret already has rhoai creds (check before bootstrap repo)
if oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | \
   base64 -d 2>/dev/null | grep -q "quay.io/rhoai"; then
    log_info "Pull-secret already has quay.io/rhoai credentials"
    exit 0
fi

# Mode 4: External Secrets via bootstrap repo
auto_detect_git_protocol

log_info "Testing access to bootstrap repo: $BOOTSTRAP_REPO"
if test_bootstrap_access "$BOOTSTRAP_REPO"; then
    log_info "No credentials set, using External Secrets from bootstrap repo"

    # Install External Secrets Operator (ArgoCD will adopt later)
    log_step "Installing External Secrets Operator..."
    oc apply -k "$REPO_ROOT/components/operators/external-secrets-operator/"

    # Wait for CSV
    log_info "Waiting for External Secrets Operator CSV..."
    timeout=300
    start_time=$(date +%s)
    while true; do
        # Get CSV name and phase
        csv_info=$(oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep "external-secrets" | head -1 || echo "")
        csv_name=$(echo "$csv_info" | awk '{print $1}')
        csv_phase=$(echo "$csv_info" | awk '{print $2}')

        if [[ "$csv_phase" == "Succeeded" ]]; then
            log_info "External Secrets Operator CSV Succeeded: $csv_name"
            break
        fi
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for CSV, continuing..."
            break
        fi
        printf "  CSV: %s phase=%s (%ds)...\r" "${csv_name:-pending}" "${csv_phase:-Pending}" "$elapsed"
        sleep 10
    done
    echo ""

    # Wait for External Secrets CRDs to be available
    log_info "Waiting for External Secrets CRDs..."
    oc wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=60s 2>/dev/null || true
    oc wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=60s 2>/dev/null || true
    oc wait --for=condition=Established crd/operatorconfigs.operator.external-secrets.io --timeout=60s 2>/dev/null || true

    # Install External Secrets Instance (creates OperatorConfig which deploys controller + webhook)
    log_step "Installing External Secrets Instance..."
    oc apply -k "$REPO_ROOT/components/instances/external-secrets-instance/"

    # Wait for webhook to be ready
    log_info "Waiting for External Secrets webhook..."
    oc wait --for=condition=Available deployment/cluster-external-secrets-webhook -n external-secrets --timeout=120s 2>/dev/null || true

    # Wait for ClusterSecretStore to be ready
    log_info "Waiting for ClusterSecretStore to be ready..."
    timeout=60
    start_time=$(date +%s)
    while true; do
        if oc get clustersecretstore rhoai-nightly-external-store &>/dev/null; then
            log_info "ClusterSecretStore ready"
            break
        fi
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for ClusterSecretStore, continuing..."
            break
        fi
        sleep 2
    done

    # Clone and apply AWS credentials from bootstrap repo
    log_step "Applying AWS credentials from private repo..."
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    log_info "Cloning $BOOTSTRAP_REPO (branch: $BOOTSTRAP_BRANCH)..."
    git clone --depth 1 --branch "$BOOTSTRAP_BRANCH" "$BOOTSTRAP_REPO" "$TMPDIR/bootstrap" 2>/dev/null

    # Create namespace for AWS credentials (idempotent)
    oc create namespace external-secrets --dry-run=client -o yaml | oc apply -f -

    log_info "Applying AWS credentials from $BOOTSTRAP_SECRETS_PATH..."
    oc apply -k "$TMPDIR/bootstrap/$BOOTSTRAP_SECRETS_PATH"

    # Apply ExternalSecret from local template (not ArgoCD-managed to avoid conflict with manual mode)
    log_step "Applying ExternalSecret from local template..."
    oc apply -k "$LOCAL_EXTERNAL_SECRET"

    # Wait for ExternalSecret to sync
    log_step "Waiting for pull-secret to sync from AWS..."
    timeout=180
    start_time=$(date +%s)
    while true; do
        status=$(oc get externalsecret pull-secret -n openshift-config \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        reason=$(oc get externalsecret pull-secret -n openshift-config \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")

        if [[ "$status" == "True" ]]; then
            echo ""
            log_info "Pull-secret synced from AWS Secrets Manager!"
            log_info "Registry credentials:"
            oc get secret pull-secret -n openshift-config \
                -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]' 2>/dev/null | sed 's/^/  - /'
            exit 0
        fi
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            echo ""
            log_error "Timeout waiting for ExternalSecret to sync"
            log_error "ExternalSecret status:"
            oc get externalsecret pull-secret -n openshift-config -o yaml 2>/dev/null | tail -20
            exit 1
        fi
        printf "  ExternalSecret: status=%s reason=%s (%ds)...\r" "${status:-Unknown}" "${reason:-Pending}" "$elapsed"
        sleep 5
    done
fi

# Mode 5: No option available
log_error "No pull-secret configuration available!"
log_error ""
log_error "Could not access bootstrap repo: $BOOTSTRAP_REPO"
log_error ""
log_error "Options:"
log_error "  1. Set QUAY_USER and QUAY_TOKEN in .env (manual mode)"
log_error "  2. Configure git access to the bootstrap repo:"
if [[ "$BOOTSTRAP_REPO" == https://* ]]; then
    log_error "     Your repo URL uses HTTPS. To authenticate:"
    log_error "       gh auth login                    # GitHub CLI (recommended)"
    log_error "       gh auth setup-git                # Configure git to use gh credentials"
    log_error "     Or switch to SSH in .env:"
    log_error "       BOOTSTRAP_REPO=git@github.com:rh-aiservices-bu/rh-aiservices-bu-bootstrap.git"
else
    log_error "     Ensure your SSH key has access to the repo:"
    log_error "       ssh -T git@github.com"
fi
log_error ""
log_error "For manual mode:"
log_error "  cp .env.example .env"
log_error "  # Edit .env with your quay.io credentials"
log_error "  make secrets"
exit 1
