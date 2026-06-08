#!/usr/bin/env bash
#
# restart-catalog.sh - Force OLM to re-resolve RHOAI after a catalog image change
#
# Bouncing the catalog pod alone is not enough after a catalog-image flip:
# OLM caches the Subscription's resolved InstallPlanRef and sticks with the
# previously-resolved CSV until the Subscription itself is re-resolved. This
# script restarts the catalog pod, bounces the operator pod, then (by default)
# deletes the Subscription so ArgoCD recreates it and OLM generates a fresh
# InstallPlan against the new catalog content.
#
# Same-version guard: if the installed CSV already matches the catalog channel
# head (i.e. the catalog image flipped but the resolved version did NOT change —
# common when re-pulling a *moving* nightly tag that still points at the same
# build), the Subscription delete is SKIPPED. Deleting it in that case orphans
# the running CSV and deadlocks OLM with ConstraintsNotSatisfiable ("two
# providers of the same API"), which then needs a manual CSV delete to recover.
# The pod bounce alone is sufficient when the version is unchanged. Override
# with --force-resub.
#
# See .tmp/plans/install-gotchas.md §1 for the empirical failure this guards
# against (cluster-hm2fl 2026-04-20).
#
# Usage:
#   scripts/restart-catalog.sh                # full behaviour (recommended)
#   scripts/restart-catalog.sh --no-resub     # just bounce pods, skip Subscription delete
#   scripts/restart-catalog.sh --force-resub  # delete Subscription even if version unchanged
#
# Exit codes:
#   0 = success
#   1 = cluster unreachable or RHOAI not installed
#   2 = catalog channel head could not be confirmed; Subscription left intact.
#       A real version bump may NOT have been applied (operator still on the old
#       CSV). Verify the catalog is serving, then re-run with --force-resub.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RESUB=true
FORCE_RESUB=false
HEAD_UNRESOLVED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-resub) RESUB=false; shift ;;
        --force-resub) FORCE_RESUB=true; shift ;;
        -h|--help)
            sed -n '3,34p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

check_cluster_connection

# Abort if RHOAI not installed — nothing to restart
if ! oc get subscription rhods-operator -n redhat-ods-operator &>/dev/null; then
    log_warn "rhods-operator subscription not found in redhat-ods-operator — nothing to restart"
    exit 0
fi

# Capture Subscription fields up front in a single API read (they live on the
# Subscription object and are independent of catalog pod state — read them before
# the bounce, since the guard below may delete the Subscription).
SUB_FIELDS=$(oc get subscription rhods-operator -n redhat-ods-operator \
    -o jsonpath='{.status.installedCSV}|{.spec.channel}|{.spec.source}' 2>/dev/null || echo "||")
OLD_CSV="${SUB_FIELDS%%|*}"
SUB_REST="${SUB_FIELDS#*|}"
CHANNEL="${SUB_REST%%|*}"
SOURCE="${SUB_REST##*|}"

log_step "Restarting catalog pod"
oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly 2>/dev/null || true
log_info "Waiting up to 120s for catalog pod Ready"
if ! oc wait --for=condition=Ready pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly --timeout=120s 2>/dev/null; then
    log_warn "Catalog pod didn't reach Ready within 120s — continuing anyway"
fi

log_step "Restarting rhods-operator pod"
oc delete pod -n redhat-ods-operator -l name=rhods-operator 2>/dev/null || true

if [[ "$RESUB" == "true" ]]; then
    # Resolve the catalog channel head to compare against the installed CSV.
    # Bouncing the catalog pod above removed its PackageManifests until the new
    # grpc pod is serving, so poll until the head reappears (up to ~180s) rather
    # than reading once (a single read right after the bounce comes back empty).
    # Scope by the Subscription's OWN catalog source: multiple PackageManifests
    # named "rhods-operator" can exist (e.g. the default redhat-operators catalog
    # ships one on a different version), so an unscoped lookup reads the wrong head.
    # PackageManifests carry a catalog=<source> label.
    HEAD_CSV=""
    if [[ "$FORCE_RESUB" != "true" && -n "$CHANNEL" && -n "$SOURCE" ]]; then
        log_info "Resolving catalog '$SOURCE' channel '$CHANNEL' head (waiting for packagemanifest)..."
        for _ in $(seq 1 36); do
            HEAD_CSV=$(oc get packagemanifest -n openshift-marketplace -l "catalog=$SOURCE" \
                -o jsonpath="{.items[?(@.metadata.name=='rhods-operator')].status.channels[?(@.name=='$CHANNEL')].currentCSV}" 2>/dev/null || echo "")
            [[ -n "$HEAD_CSV" ]] && break
            sleep 5
        done
    fi

    # Decide whether to delete the Subscription (single delete path below avoids
    # duplicating the delete + monitor-hint logging across branches).
    DO_DELETE=false
    DELETE_REASON=""
    if [[ "$FORCE_RESUB" == "true" ]]; then
        DO_DELETE=true
        DELETE_REASON="--force-resub"
    elif [[ -z "$HEAD_CSV" ]]; then
        # FAIL SAFE: could not confirm the catalog head (catalog pod not serving
        # PackageManifests in time). Do NOT delete — deleting on an unconfirmed
        # head risks orphaning the running CSV and deadlocking OLM with
        # ConstraintsNotSatisfiable, which needs a manual `oc delete csv` to clear.
        # But this is ALSO the shape of a real version bump whose new catalog is
        # just slow to serve, so exit non-zero (code 2) rather than silently
        # reporting success — a masked upgrade must be loud.
        log_warn "Could not determine catalog '$SOURCE' channel '$CHANNEL' head (packagemanifest not available within ~180s)."
        log_warn "Skipping Subscription deletion to avoid orphaning the CSV (ConstraintsNotSatisfiable deadlock)."
        log_warn "If this was a real version bump, the operator may NOT have upgraded (still on ${OLD_CSV:-its current CSV})."
        log_warn "Verify 'oc get packagemanifest -l catalog=$SOURCE' is serving, then re-run with: make restart-catalog FORCE_RESUB=true"
        HEAD_UNRESOLVED=true
    elif [[ -n "$OLD_CSV" && "$OLD_CSV" == "$HEAD_CSV" ]]; then
        # Same-version guard. The catalog image changed but the resolved version
        # did not (e.g. re-pulling a moving nightly tag still pointing at the same
        # build). Deleting the Subscription here would orphan the running CSV and
        # deadlock OLM: the catalog's identical CSV and the orphaned one both
        # provide the same API GVK -> ConstraintsNotSatisfiable. Pod bounce is enough.
        log_step "Skipping Subscription deletion — catalog channel head unchanged"
        log_info "Installed CSV ($OLD_CSV) already matches catalog '$CHANNEL' head ($HEAD_CSV)."
        log_info "Pod bounce above is sufficient; deleting the Subscription would orphan the CSV and deadlock OLM."
        log_info "To force a re-resolve anyway, re-run with: make restart-catalog FORCE_RESUB=true"
    else
        DO_DELETE=true
        DELETE_REASON="catalog '$CHANNEL' head ${HEAD_CSV} differs from installed ${OLD_CSV:-<none>} — version change"
    fi

    if [[ "$DO_DELETE" == "true" ]]; then
        log_step "Deleting rhods-operator Subscription so OLM re-resolves ($DELETE_REASON)"
        [[ -n "$OLD_CSV" ]] && log_info "Previous installedCSV: $OLD_CSV"
        oc delete subscription rhods-operator -n redhat-ods-operator
        log_info "Subscription deleted. ArgoCD will recreate it from components/operators/rhoai-operator/; OLM will generate a fresh InstallPlan against the new catalog."
        log_info "Monitor progress: oc get subscription,installplan,csv -n redhat-ods-operator -w"
    fi
else
    log_info "--no-resub set; Subscription left in place."
    log_info "If OLM doesn't re-resolve (symptom: Subscription stuck at old installedCSV), re-run without --no-resub."
fi

if [[ "$HEAD_UNRESOLVED" == "true" ]]; then
    log_warn "Done with warnings — catalog head unconfirmed, Subscription left intact (exit 2)."
    exit 2
fi

log_info "Done."
