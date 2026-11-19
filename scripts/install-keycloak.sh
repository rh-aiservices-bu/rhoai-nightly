#!/usr/bin/env bash
#
# install-keycloak.sh - Deploy Keycloak as the cluster identity provider
#
# Deploys two OCI Helm charts (ghcr.io/jharmison-redhat/helm-charts) as
# script-created ArgoCD Applications with INJECTED helm values — the realm
# users, client secrets and OAuth wiring must never live in git:
#
#   - instance-keycloak   (chart: keycloak)
#     Keycloak CR + KeycloakRealmImport (realm sso) + CNPG postgres Cluster
#     in ns keycloak. The RHBK (keycloak-operator) and CloudNativePG operators
#     must already be installed — they come from the GitOps component
#     components/operators/keycloak-stack/.
#
#   - instance-keycloak-auth (chart: keycloak-auth)
#     post-install hook Jobs upsert the OpenID identityProviders entry on the
#     platform OAuth cluster resource, create the cluster-admins Group +
#     ClusterRoleBinding, and set the console logout redirect. Sequenced
#     AFTER the Keycloak instance is Ready so the hooks hit a live issuer.
#
# Prerequisites:
#   - keycloak-operator and cloudnative-pg CSVs Succeeded in ns keycloak
#     (deployed via components/operators/keycloak-stack)
#   - .env present (generated secrets are appended to it)
#
# Chart caveats (from the chart READMEs):
#   - KeycloakRealmImport is CREATE-ONLY: re-running with changed realm
#     values does not re-import. Delete KeycloakRealmImport/sso (ns keycloak)
#     first — ArgoCD's prune recreates it and the import job re-runs.
#   - ArgoCD's handling of the chart's helm pre-delete hooks (OAuth-IdP /
#     logout-redirect removal) depends on the ArgoCD version and the deletion
#     path, so they are not guaranteed to fire when an Application is
#     deleted. This script's --uninstall mode performs that cleanup itself as
#     belt-and-braces.
#
# Usage:
#   ./install-keycloak.sh [OPTIONS]
#
# Options:
#   --dry-run     Preview without applying
#   --uninstall   Remove the Applications and the cluster identity wiring
#   -h, --help    Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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
  --dry-run     Preview without applying
  --uninstall   Remove the Applications and the cluster identity wiring
  -h, --help    Show this help message

install-keycloak.sh deploys the keycloak and keycloak-auth OCI Helm charts
as script-created ArgoCD Applications (instance-keycloak, instance-keycloak-auth)
with secret values injected from the environment — realm users, client
secrets and the OIDC IdP secret are never committed to git. Missing
KEYCLOAK_* secrets are generated and appended to .env.

Requires the keycloak-operator and cloudnative-pg CSVs (ns keycloak) from
the components/operators/keycloak-stack GitOps component.

Uninstall removes the Applications plus the Keycloak, KeycloakRealmImport
and postgres Cluster CRs, then strips the OAuth identityProviders entry and
console logout redirect itself (the chart's pre-delete hooks are not
guaranteed to run on every ArgoCD deletion path, so the uninstall does not
rely on them). The ns keycloak is kept — the
keycloak-stack operator component owns it.
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Distinct from lib/common.sh's run_cmd, which reads a shared DRY_RUN flag.
run_cmd_dry() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# =============================================================================
# Phase 0: Preflight checks
# =============================================================================
log_step "Phase 0: Preflight checks"

check_cluster_connection

if ! command -v jq &>/dev/null; then
    log_error "jq not found — required for CSV status and OAuth patch handling."
    exit 1
fi

if ! oc get crd keycloaks.k8s.keycloak.org &>/dev/null; then
    log_error "Keycloak CRD (keycloaks.k8s.keycloak.org) not found."
    log_error "The keycloak-operator is deployed by the GitOps component components/operators/keycloak-stack/"
    log_error "(instance app: keycloak-stack). Run 'make status' and sync that app first."
    exit 1
fi
log_info "Keycloak CRD found"

for CSV_PREFIX in keycloak-operator cloudnative-pg; do
    CSV_STATUS=$(oc get csv -n keycloak -o json 2>/dev/null | \
        jq -r --arg p "$CSV_PREFIX" '[.items[] | select(.metadata.name | startswith($p))][0].status.phase // "NotFound"')
    if [ "$CSV_STATUS" != "Succeeded" ]; then
        log_error "CSV ${CSV_PREFIX} in ns keycloak is '${CSV_STATUS}' (expected Succeeded)."
        log_error "Deploy the operators first: components/operators/keycloak-stack/ (GitOps app keycloak-stack)."
        exit 1
    fi
    log_info "CSV ${CSV_PREFIX} is Succeeded"
done

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
elif [ "$UNINSTALL" = true ]; then
    log_warn ".env not found — uninstall proceeds with the cluster-detected domain"
else
    log_error ".env not found at ${ENV_FILE}"
    log_error "Copy .env.example to .env first (see README / 'make validate-config')."
    exit 1
fi

# Cluster domain drives every hostname (Keycloak route, console host, portal
# redirect URI). Read after .env so an explicit WILDCARD_DOMAIN/EMAIL_DOMAIN
# wins; falls back to this rig's domain when neither is set and the config
# read fails.
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)}"
if [ -z "$WILDCARD_DOMAIN" ]; then
    WILDCARD_DOMAIN="apps.cluster.nightly.rhai-tmm.dev"
    log_warn "Could not detect cluster domain — falling back to ${WILDCARD_DOMAIN}"
fi
CONSOLE_HOST="console-openshift-console.${WILDCARD_DOMAIN}"
KEYCLOAK_HOST="keycloak.${WILDCARD_DOMAIN}"
# Realm-user email defaults to the zone apex (not the wildcard subdomain):
# strip the leading "apps." from the wildcard domain.
EMAIL_DOMAIN="${EMAIL_DOMAIN:-${WILDCARD_DOMAIN#apps.}}"
log_info "Cluster domain: ${WILDCARD_DOMAIN} (email domain: ${EMAIL_DOMAIN})"

KEYCLOAK_CHART_VERSION="${KEYCLOAK_CHART_VERSION:-0.5.0}"
KEYCLOAK_AUTH_CHART_VERSION="${KEYCLOAK_AUTH_CHART_VERSION:-0.4.4}"
# ArgoCD treats `oci://`-prefixed repoURLs as raw OCI sources and ignores the
# `chart` field (upstream issues argoproj/argo-cd#25513, #28899) — the scheme
# must be omitted for Helm OCI sources.
KEYCLOAK_REPO_BASE="ghcr.io/jharmison-redhat/helm-charts"

# Uninstall short-circuits before secret generation (it needs no secrets;
# the function is defined at the bottom of the script).
if [ "$UNINSTALL" = true ]; then
    uninstall
    exit 0
fi

# =============================================================================
# Phase 1: Secrets (generate missing KEYCLOAK_* values into .env)
# =============================================================================
# .env is the secret store: values are appended here, never echoed, never
# committed. Re-runs pick the existing values back up.
log_step "Phase 1: Secrets"

ENV_HEADER="# Keycloak (make keycloak)"
ENV_UPDATED=false

ensure_env_secret() {
    local var="$1"
    if [ -n "${!var:-}" ]; then
        log_info "${var}: already set"
        return
    fi
    local value
    value=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
    grep -qxF "$ENV_HEADER" "$ENV_FILE" || printf '\n%s\n' "$ENV_HEADER" >> "$ENV_FILE"
    printf '%s=%s\n' "$var" "$value" >> "$ENV_FILE"
    export "$var=$value"
    log_info "${var}: generated and appended to .env"
    ENV_UPDATED=true
}

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping secret generation — KEYCLOAK_* values are not generated in dry-run mode and must already exist in ${ENV_FILE}"
else
    ensure_env_secret KEYCLOAK_ADMIN_PASSWORD
    ensure_env_secret KEYCLOAK_TEST_PASSWORD
    ensure_env_secret KEYCLOAK_OCP_IDP_SECRET
    ensure_env_secret KEYCLOAK_MAAS_API_SECRET
    ensure_env_secret KEYCLOAK_PORTAL_SECRET
    if [ "$ENV_UPDATED" = true ]; then
        log_info "New secrets were appended to ${ENV_FILE} (variable names only are logged)"
    fi
fi

# Injected values end up inside a YAML heredoc; reject anything that could
# corrupt it (generated values always match; hand-edited specials fail here).
for SECRET_VAR in KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_TEST_PASSWORD KEYCLOAK_OCP_IDP_SECRET KEYCLOAK_MAAS_API_SECRET KEYCLOAK_PORTAL_SECRET; do
    if ! [[ "${!SECRET_VAR:-}" =~ ^[A-Za-z0-9]+$ ]]; then
        log_error "${SECRET_VAR} is empty or contains characters outside [A-Za-z0-9]."
        log_error "Edit ${ENV_FILE} to set it to a purely alphanumeric value, or delete the line and re-run to regenerate it."
        exit 1
    fi
done

# =============================================================================
# Phase 2: Create instance-keycloak ArgoCD Application (Keycloak + realm sso)
# =============================================================================
log_step "Phase 2: Apply instance-keycloak Application (chart keycloak@${KEYCLOAK_CHART_VERSION})"

run_cmd_dry oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: instance-keycloak
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${KEYCLOAK_REPO_BASE}
    chart: keycloak
    targetRevision: ${KEYCLOAK_CHART_VERSION}
    helm:
      valuesObject:
        global:
          wildcardDomain: ${WILDCARD_DOMAIN}
          oidc:
            realm: sso
            clientId: ocp-idp
            secret: "${KEYCLOAK_OCP_IDP_SECRET}"
            consoleHost: ${CONSOLE_HOST}
        emailDomain: ${EMAIL_DOMAIN}
        replicas: 1
        realms:
          sso:
            registrationAllowed: false
            admin:
              username: keycloak-admin
              password: "${KEYCLOAK_ADMIN_PASSWORD}"
            users:
              alice:
                password: "${KEYCLOAK_TEST_PASSWORD}"
                realmRoles:
                  - user
              bob:
                password: "${KEYCLOAK_TEST_PASSWORD}"
                realmRoles:
                  - user
            groupsFromRoles: true
            clients:
              ocp-idp:
                secret: '{{ .Values.global.oidc.secret }}'
                redirectUris:
                  - "*"
                defaultClientScopes:
                  - acr
                  - basic
                  - email
                  - groups
                  - profile
                  - roles
                  - service_account
                  - web-origins
              maas-api:
                secret: "${KEYCLOAK_MAAS_API_SECRET}"
                redirectUris:
                  - "*"
                defaultClientScopes:
                  - basic
                  - email
                  - groups
                  - profile
                  - roles
                  - web-origins
              maas-consumer-portal:
                secret: "${KEYCLOAK_PORTAL_SECRET}"
                redirectUris:
                  - https://maas.${WILDCARD_DOMAIN}/oauth2/callback
                defaultClientScopes:
                  - basic
                  - email
                  - groups
                  - profile
                  - roles
                  - web-origins
            clientScopes:
              - name: basic
                description: OpenID Connect scope for add all basic claims to the token
                protocol: openid-connect
                attributes:
                  display.on.consent.screen: 'false'
                  include.in.token.scope: 'false'
                protocolMappers:
                  - name: auth_time
                    protocol: openid-connect
                    protocolMapper: oidc-usersessionmodel-note-mapper
                    consentRequired: false
                    config:
                      access.token.claim: 'true'
                      claim.name: auth_time
                      id.token.claim: 'true'
                      introspection.token.claim: 'true'
                      jsonType.label: long
                      user.session.note: AUTH_TIME
              - name: groups
                description: ""
                protocol: openid-connect
                attributes:
                  display.on.consent.screen: 'true'
                  include.in.token.scope: 'true'
                protocolMappers:
                  - name: groups
                    protocol: openid-connect
                    protocolMapper: oidc-usermodel-realm-role-mapper
                    consentRequired: false
                    config:
                      access.token.claim: 'true'
                      claim.name: groups
                      id.token.claim: 'true'
                      introspection.token.claim: 'true'
                      jsonType.label: String
                      multivalued: 'true'
                      user.attribute: foo
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 3m
EOF

# =============================================================================
# Phase 3: Wait for Keycloak instance + realm import
# =============================================================================
# CNPG postgres boots first; the Keycloak CR only turns Ready once the
# database is up and the realm import can run against it.
log_step "Phase 3: Wait for Keycloak instance and realm import"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping readiness waits"
else
    log_info "Waiting for Keycloak/keycloak to be created (timeout 5m) and Ready (timeout 10m; postgres boots first)..."
    if ! oc wait --for=create keycloak/keycloak -n keycloak --timeout=5m; then
        log_error "Keycloak/keycloak was not created within 5m."
        log_error "Debug: oc get applications.argoproj.io/instance-keycloak -n openshift-gitops; oc get pods -n keycloak"
        exit 1
    fi
    if ! oc wait keycloak/keycloak -n keycloak --for=condition=Ready --timeout=10m 2>/dev/null; then
        log_error "Keycloak/keycloak was created but did not reach Ready within 10m."
        log_error "Debug: oc describe keycloak/keycloak -n keycloak; oc get pods -n keycloak"
        exit 1
    fi
    log_info "Keycloak instance Ready"

    # KeycloakRealmImport CR name = the realms map key (chart renders one CR
    # per entry, named after the realm).
    log_info "Waiting for KeycloakRealmImport/sso to be created (timeout 5m) and report Done (timeout 5m)..."
    if ! oc wait --for=create keycloakrealmimport/sso -n keycloak --timeout=5m; then
        log_error "KeycloakRealmImport/sso was not created within 5m."
        log_error "Debug: oc get applications.argoproj.io/instance-keycloak -n openshift-gitops; oc get keycloakrealmimport -n keycloak"
        exit 1
    fi
    if ! oc wait keycloakrealmimport/sso -n keycloak --for=condition=Done --timeout=5m 2>/dev/null; then
        log_error "KeycloakRealmImport/sso was created but did not reach Done within 5m."
        log_error "NOTE: realm imports are create-only — if the realm previously existed with"
        log_error "different values, delete the CR (oc delete keycloakrealmimport/sso -n keycloak);"
        log_error "ArgoCD prune recreates it and the import re-runs."
        log_error "Debug: oc describe keycloakrealmimport/sso -n keycloak"
        exit 1
    fi
    log_info "Realm sso imported"
fi

# =============================================================================
# Phase 4: Create instance-keycloak-auth ArgoCD Application (OAuth wiring)
# =============================================================================
# Deliberately after Phase 3: the post-install hook Jobs upsert the OAuth
# identityProviders entry and console logout redirect, and need a live
# Keycloak issuer behind the route to validate against.
log_step "Phase 4: Apply instance-keycloak-auth Application (chart keycloak-auth@${KEYCLOAK_AUTH_CHART_VERSION})"

run_cmd_dry oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: instance-keycloak-auth
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${KEYCLOAK_REPO_BASE}
    chart: keycloak-auth
    targetRevision: ${KEYCLOAK_AUTH_CHART_VERSION}
    helm:
      valuesObject:
        global:
          wildcardDomain: ${WILDCARD_DOMAIN}
          oidc:
            realm: sso
            clientId: ocp-idp
            secret: "${KEYCLOAK_OCP_IDP_SECRET}"
            consoleHost: ${CONSOLE_HOST}
        keycloak:
          name: keycloak
        oauth:
          idpName: keycloak
        logoutRedirect:
          enabled: true
        clusterAdmins:
          users:
            - keycloak-admin
        removeKubeAdmin: false
        # The rig's router cert is the Let's Encrypt wildcard (publicly
        # trusted), so the OAuth server needs no extra CA bundle.
        ingressCA: ""
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 3m
EOF

if [ "$DRY_RUN" = true ]; then
    log_info "========================================="
    log_info "Keycloak Installation Summary (DRY RUN)"
    log_info "========================================="
    log_info "Keycloak host:   https://${KEYCLOAK_HOST}"
    log_info "Console host:    https://${CONSOLE_HOST}"
    log_info "Realm:           sso (clients: ocp-idp, maas-api, maas-consumer-portal)"
    log_info "Admin user:      keycloak-admin (password in .env: KEYCLOAK_ADMIN_PASSWORD)"
    log_info "Test users:      alice, bob (password in .env: KEYCLOAK_TEST_PASSWORD)"
    log_info "Secrets:         NOT generated in dry-run — KEYCLOAK_* must already exist in .env"
    log_info "========================================="
    exit 0
fi

# =============================================================================
# Phase 5: Verify identity wiring
# =============================================================================
log_step "Phase 5: Verify identity wiring"

# Wait for a specific keycloak-auth hook Job (created by the ArgoCD sync of
# the chart's post-install/post-upgrade hooks) to complete.
wait_hook_job() {
    local job_name="$1" timeout="${2:-300}"
    if ! oc wait --for=create "job/${job_name}" -n keycloak --timeout="${timeout}s" 2>/dev/null; then
        log_warn "Hook job ${job_name} was not created within ${timeout}s"
        return 1
    fi
    if oc wait "job/${job_name}" -n keycloak --for=condition=Complete --timeout="${timeout}s" 2>/dev/null; then
        log_info "Hook job ${job_name} complete"
        return 0
    fi
    log_warn "Hook job ${job_name} not Complete after ${timeout}s — check its pod logs in ns keycloak"
    return 1
}

wait_hook_job "oauth-idp-upsert" 300 || log_warn "Continuing despite oauth-idp-upsert result — verified below"
wait_hook_job "logout-redirect-set" 300 || log_warn "Continuing despite logout-redirect-set result — verified below"

# The two checks below are the deliverable: without the IdP entry and a
# reachable issuer, console login via Keycloak does not work.
fatal_unverified() {
    log_error "========================================="
    log_error "IDENTITY WIRING NOT VERIFIED"
    log_error "$1"
    log_error "Debug: oc get oauth cluster -o yaml; curl -sS https://${KEYCLOAK_HOST}/realms/sso/.well-known/openid-configuration"
    log_error "Debug: oc get jobs -n keycloak; oc logs job/oauth-idp-upsert -n keycloak"
    log_error "========================================="
    exit 1
}

# OAuth identityProviders entry present (FATAL on failure)
IDP_PRESENT=false
for _ in $(seq 1 24); do
    if oc get oauth cluster -o json 2>/dev/null | jq -e --arg idp "keycloak" \
        '.spec.identityProviders[]? | select(.name == $idp)' >/dev/null 2>&1; then
        IDP_PRESENT=true
        break
    fi
    sleep 5
done
if [ "$IDP_PRESENT" = true ]; then
    log_info "OAuth cluster identityProviders contains 'keycloak'"
else
    fatal_unverified "OAuth cluster identityProviders does not contain 'keycloak'."
fi

# Keycloak issuer reachable over the publicly-trusted LE wildcard (no -k)
# (FATAL on failure)
ISSUER_OK=false
for _ in $(seq 1 24); do
    HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
        "https://${KEYCLOAK_HOST}/realms/sso/.well-known/openid-configuration" 2>/dev/null || echo 000)
    [ "$HTTP_CODE" = "200" ] && { ISSUER_OK=true; break; }
    sleep 5
done
if [ "$ISSUER_OK" = true ]; then
    log_info "Issuer endpoint https://${KEYCLOAK_HOST}/realms/sso/.well-known/openid-configuration -> HTTP 200"
else
    fatal_unverified "Issuer endpoint returned HTTP ${HTTP_CODE:-000} (DNS/route may still be propagating)."
fi

log_info "========================================="
log_info "Keycloak Installation Summary"
log_info "========================================="
log_info "Keycloak host:   https://${KEYCLOAK_HOST}"
log_info "Console login:   now via Keycloak (https://${CONSOLE_HOST})"
log_info "Realm:           sso (clients: ocp-idp, maas-api, maas-consumer-portal)"
log_info "Admin user:      keycloak-admin (password in .env: KEYCLOAK_ADMIN_PASSWORD)"
log_info "Test users:      alice, bob (password in .env: KEYCLOAK_TEST_PASSWORD)"
log_info "Cluster admins:  keycloak-admin (via the cluster-admins group)"
log_info "========================================="
log_info "Change realm values later? KeycloakRealmImport is create-only — delete"
log_info "KeycloakRealmImport/sso in ns keycloak so ArgoCD re-runs the import."
log_info "========================================="

# =============================================================================
# Uninstall
# =============================================================================
# The chart's helm pre-delete hooks (OAuth-IdP removal, logout-redirect unset)
# are not guaranteed to run on every ArgoCD Application-deletion path, so this
# uninstall performs that cleanup itself as belt-and-braces — and does it
# BEFORE deleting the Applications (the chart's own invariant: remove the IdP
# before the client secret can vanish).
uninstall() {
log_step "Uninstall: removing Keycloak Applications and identity wiring"

# Strip OUR identityProviders entry only — every other entry is preserved.
# Merge patch carries the live resourceVersion (same scheme as the chart's
# pre-delete hook) so a concurrent OAuth write fails loudly instead of
# clobbering.
if oc get oauth cluster -o json 2>/dev/null | jq -e --arg idp "keycloak" \
    '.spec.identityProviders[]? | select(.name == $idp)' >/dev/null 2>&1; then
    PATCH=$(oc get oauth cluster -o json | jq -c --arg idp "keycloak" \
        '{metadata:{resourceVersion:.metadata.resourceVersion},
          spec:{identityProviders:[.spec.identityProviders[] | select(.name != $idp)]}}')
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would patch OAuth cluster to drop identityProviders entry 'keycloak'"
    elif oc patch oauth cluster --type=merge -p "$PATCH" 2>/dev/null; then
        log_info "Removed OAuth identityProviders entry 'keycloak'"
    else
        # resourceVersion conflict — re-read and retry once
        log_warn "OAuth patch hit a conflict, retrying once with fresh resourceVersion"
        PATCH=$(oc get oauth cluster -o json | jq -c --arg idp "keycloak" \
            '{metadata:{resourceVersion:.metadata.resourceVersion},
              spec:{identityProviders:[.spec.identityProviders[] | select(.name != $idp)]}}')
        oc patch oauth cluster --type=merge -p "$PATCH" || log_error "Could not remove OAuth identityProviders entry 'keycloak' — remove it manually"
    fi
else
    log_info "OAuth cluster has no 'keycloak' identityProviders entry — nothing to strip"
fi

# Unset the console logoutRedirect ONLY if it still points at this
# deployment's Keycloak logout URL (a foreign value is left untouched).
LOGOUT_URL="https://${KEYCLOAK_HOST}/realms/sso/protocol/openid-connect/logout?client_id=ocp-idp&post_logout_redirect_uri=$(printf 'https://%s' "$CONSOLE_HOST" | jq -sRr @uri)"
CURRENT_REDIRECT=$(oc get console cluster -o jsonpath='{.spec.authentication.logoutRedirect.redirectURL}' 2>/dev/null || true)
if [ "$CURRENT_REDIRECT" = "$LOGOUT_URL" ]; then
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would unset Console spec.authentication.logoutRedirect"
    else
        oc patch console cluster --type=merge -p '{"spec":{"authentication":{"logoutRedirect":null}}}' \
            && log_info "Unset Console logoutRedirect" \
            || log_error "Could not unset Console logoutRedirect — remove spec.authentication.logoutRedirect manually"
    fi
elif [ -n "$CURRENT_REDIRECT" ]; then
    log_warn "Console logoutRedirect holds a foreign value — leaving it untouched"
else
    log_info "Console logoutRedirect is not set — nothing to unset"
fi

# Identity wiring is clean — now remove the Applications. ArgoCD's
# resources-finalizer cascades the chart resources (Keycloak,
# KeycloakRealmImport, CNPG Cluster); the chart's pre-delete hooks may or may
# not fire depending on the ArgoCD version and deletion path, which is why
# the strip above ran first.
run_cmd_dry oc delete application.argoproj.io/instance-keycloak-auth -n openshift-gitops --ignore-not-found
run_cmd_dry oc delete application.argoproj.io/instance-keycloak -n openshift-gitops --ignore-not-found

# Orphan guard: if an Application was created without the ArgoCD finalizer,
# its chart resources survive the app deletion. Delete the CRs and the
# chart-created cluster-scoped objects (group, binding, client secret)
# explicitly — each is a no-op when the finalizer already removed them.
# The ns is kept — the keycloak-stack operator component owns it.
run_cmd_dry oc delete keycloakrealmimport/sso -n keycloak --ignore-not-found
run_cmd_dry oc delete keycloak/keycloak -n keycloak --ignore-not-found
run_cmd_dry oc delete clusters.postgresql.cnpg.io/keycloak-postgres -n keycloak --ignore-not-found
run_cmd_dry oc delete secret/openid-client-secret -n openshift-config --ignore-not-found
run_cmd_dry oc delete group.user.openshift.io/cluster-admins --ignore-not-found
run_cmd_dry oc delete clusterrolebinding.rbac.authorization.k8s.io/keycloak-auth-cluster-admins --ignore-not-found

log_info "========================================="
log_info "Keycloak Uninstall Summary"
log_info "========================================="
log_info "Removed: instance-keycloak + instance-keycloak-auth Applications,"
log_info "         Keycloak/KeycloakRealmImport/postgres CRs, OAuth IdP entry,"
log_info "         console logoutRedirect (when ours), openid-client-secret,"
log_info "         cluster-admins Group + keycloak-auth-cluster-admins binding"
log_info "Kept:    ns keycloak (owned by the keycloak-stack operator component),"
log_info "         .env KEYCLOAK_* secrets, kubeadmin"
log_info "========================================="
}

