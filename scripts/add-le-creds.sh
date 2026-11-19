#!/usr/bin/env bash
#
# add-le-creds.sh - Add Route53 credentials for Let's Encrypt DNS-01
#
# Creates/updates the Secret consumed by the letsencrypt-prod ClusterIssuer
# (components/instances/letsencrypt/cluster-issuer.yaml) in ns cert-manager.
#
# Usage:
#   ./add-le-creds.sh   (LE_AWS_ACCESS_KEY_ID + LE_AWS_SECRET_ACCESS_KEY required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

SECRET_NAME="letsencrypt-route53-credentials"
SECRET_NS="cert-manager"

check_cluster_connection

if [[ -z "${LE_AWS_ACCESS_KEY_ID:-}" ]] || [[ -z "${LE_AWS_SECRET_ACCESS_KEY:-}" ]]; then
    log_error "LE_AWS_ACCESS_KEY_ID and LE_AWS_SECRET_ACCESS_KEY environment variables must be set"
    log_error "Add them to .env (see .env.example) and run: make le-creds"
    exit 1
fi

if [[ "${LE_AWS_ACCESS_KEY_ID}" == *$'\n'* ]] || [[ "${LE_AWS_SECRET_ACCESS_KEY}" == *$'\n'* ]]; then
    log_error "Credential values must not contain newlines"
    exit 1
fi

if oc get secret "$SECRET_NAME" -n "$SECRET_NS" &>/dev/null; then
    log_info "Secret $SECRET_NAME exists in $SECRET_NS, updating..."
else
    log_info "Creating Secret $SECRET_NAME in $SECRET_NS..."
fi

oc create secret generic "$SECRET_NAME" -n "$SECRET_NS" \
    --from-literal=aws-access-key-id="$LE_AWS_ACCESS_KEY_ID" \
    --from-literal=aws-secret-access-key="$LE_AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | oc apply -f -

log_info "Route53 credentials for Let's Encrypt DNS-01 updated!"
log_info "Verify with: oc get secret/$SECRET_NAME -n $SECRET_NS -o jsonpath='{.data}' | jq 'keys'"
