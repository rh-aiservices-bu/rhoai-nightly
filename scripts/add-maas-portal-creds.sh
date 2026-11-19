#!/usr/bin/env bash
#
# add-maas-portal-creds.sh - Provision the MaaS consumer portal auth-proxy credentials
#
# Creates/updates the administrator-path credentials Secret
# `maas-consumer-portal-auth-proxy-creds` in ns redhat-ai-gateway-infra,
# consumed by the ai-gateway-controller's portal oauth2-proxy. (The
# tenant-managed alternative — AITenant.spec.oidc.clientSecretRef — is not
# used on this rig.)
#
# KEYCLOAK_PORTAL_SECRET is the `maas-consumer-portal` Keycloak client secret
# (from `make keycloak`). MAAS_PORTAL_COOKIE_SECRET is generated into .env on
# first run.
#
# Usage:
#   make maas-portal-creds   (KEYCLOAK_PORTAL_SECRET comes from .env via the
#                             Makefile export)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

SECRET_NAME="maas-consumer-portal-auth-proxy-creds"
SECRET_NS="redhat-ai-gateway-infra"
ENV_FILE="${REPO_ROOT}/.env"
ENV_HEADER="# MaaS portal (make maas-portal-creds)"

check_cluster_connection

if ! oc get namespace "$SECRET_NS" &>/dev/null; then
    log_error "Namespace $SECRET_NS does not exist"
    log_error "It is created by the MaaS-on-Praxis stack (DSC aigateway.modelsAsAService: Managed) — check 'oc get datasciencecluster' and 'make status' first."
    exit 1
fi

if [[ -z "${KEYCLOAK_PORTAL_SECRET:-}" ]]; then
    log_error "KEYCLOAK_PORTAL_SECRET environment variable must be set"
    log_error "It is the maas-consumer-portal Keycloak client secret — generated into .env by 'make keycloak', then run: make maas-portal-creds"
    exit 1
fi

# Base64url-tolerant for rotated secrets; still YAML-heredoc-safe.
if ! [[ "${KEYCLOAK_PORTAL_SECRET}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "KEYCLOAK_PORTAL_SECRET must match ^[A-Za-z0-9_-]+\$ (got an unexpected character or format)"
    exit 1
fi

if [[ -n "${MAAS_PORTAL_COOKIE_SECRET:-}" ]]; then
    log_info "MAAS_PORTAL_COOKIE_SECRET: already set"
else
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env not found at ${ENV_FILE} — copy .env.example to .env first"
        exit 1
    fi
    # Skip the append when a value line already exists, not just the section
    # header — avoids a duplicate MAAS_PORTAL_COOKIE_SECRET key when
    # .env.example-shaped entries are present.
    if ! grep -qxF "$ENV_HEADER" "$ENV_FILE" && ! grep -q '^MAAS_PORTAL_COOKIE_SECRET=' "$ENV_FILE"; then
        printf '\n%s\n' "$ENV_HEADER" >> "$ENV_FILE"
    fi
    MAAS_PORTAL_COOKIE_SECRET="$(openssl rand -hex 16)"
    printf 'MAAS_PORTAL_COOKIE_SECRET=%s\n' "$MAAS_PORTAL_COOKIE_SECRET" >> "$ENV_FILE"
    export MAAS_PORTAL_COOKIE_SECRET
    log_info "MAAS_PORTAL_COOKIE_SECRET: generated and appended to .env"
fi

if oc get secret "$SECRET_NAME" -n "$SECRET_NS" &>/dev/null; then
    log_info "Secret $SECRET_NAME exists in $SECRET_NS, updating..."
else
    log_info "Creating Secret $SECRET_NAME in $SECRET_NS..."
fi

render_secret() {
    oc create secret generic "$SECRET_NAME" -n "$SECRET_NS" \
        --from-literal=OAUTH2_PROXY_CLIENT_ID=maas-consumer-portal \
        --from-literal=OAUTH2_PROXY_CLIENT_SECRET="$KEYCLOAK_PORTAL_SECRET" \
        --from-literal=OAUTH2_PROXY_COOKIE_SECRET="$MAAS_PORTAL_COOKIE_SECRET" \
        --dry-run=client -o yaml
}

# Server-side dry run validates the manifest against the API without
# persisting or echoing any secret value; the apply pass re-renders the same
# manifest.
render_secret | oc apply --dry-run=server -f - >/dev/null

render_secret | oc apply -f -

log_info "MaaS portal auth-proxy credentials updated!"
log_info "Verify with: oc get secret/$SECRET_NAME -n $SECRET_NS -o jsonpath='{.data}' | jq 'keys'"
