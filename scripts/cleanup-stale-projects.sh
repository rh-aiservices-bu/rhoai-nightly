#!/usr/bin/env bash
#
# cleanup-stale-projects.sh - Audit and delete stale AI dashboard projects
#
# Scans namespaces labelled opendatahub.io/dashboard=true (RHOAI dashboard
# projects) and classifies each as:
#
#   EMPTY    - no workloads, no PVCs, no pods (namespace + RBAC only).
#              Age = namespace creation time. Zero data loss to delete.
#   STOPPED  - has workloads but ALL notebooks are stopped and ALL models
#              carry serving.kserve.io/stop=true, zero running pods.
#              Age = last human touch (newest kubeflow-resource-stopped
#              annotation / workload creation). Deleting loses PVC contents.
#   ACTIVE   - anything with a running pod, an un-stopped notebook, or an
#              un-stopped model. NEVER deleted by this script.
#
# Usage:
#   ./cleanup-stale-projects.sh                          # audit only (default)
#   ./cleanup-stale-projects.sh --delete-empty 30        # delete EMPTY older than 30d
#   ./cleanup-stale-projects.sh --delete-stopped 30      # delete STOPPED idle >30d
#   ./cleanup-stale-projects.sh --delete-empty 30 --delete-stopped 45 --dry-run
#   ./cleanup-stale-projects.sh --exclude foo,bar --delete-empty 30
#
# Safety:
#   - Only dashboard-labelled namespaces are ever candidates.
#   - Hard exclusions (infra that carries the label): llm, evalhub-tenant,
#     models-as-a-service — plus anything passed via --exclude.
#   - Every namespace is re-verified (running pods, classification) immediately
#     before its delete is issued; a namespace that changed state is skipped.
#   - Deletes are async (--wait=false); the script reports terminating
#     namespaces at the end so callers can poll.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

DELETE_EMPTY_DAYS=""
DELETE_STOPPED_DAYS=""
DRY_RUN=false
EXTRA_EXCLUDES=""
HARD_EXCLUDES="llm evalhub-tenant models-as-a-service"

while [[ $# -gt 0 ]]; do
    case $1 in
        --delete-empty)   DELETE_EMPTY_DAYS="$2"; shift 2 ;;
        --delete-stopped) DELETE_STOPPED_DAYS="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --exclude)        EXTRA_EXCLUDES="${2//,/ }"; shift 2 ;;
        -h|--help)
            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

for d in "$DELETE_EMPTY_DAYS" "$DELETE_STOPPED_DAYS"; do
    if [[ -n "$d" && ! "$d" =~ ^[0-9]+$ ]]; then
        log_error "Day thresholds must be positive integers (got: $d)"
        exit 1
    fi
done

command -v jq >/dev/null || { log_error "jq is required"; exit 1; }
oc whoami >/dev/null 2>&1 || { log_error "Not logged in to a cluster"; exit 1; }
log_info "Cluster: $(oc whoami --show-server)"

NOW_EPOCH=$(date +%s)

# ISO8601 -> epoch, portable across macOS (BSD date) and Linux (GNU date)
epoch_of() {
    local ts="$1"
    if date -j >/dev/null 2>&1; then
        date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0
    else
        date -u -d "$ts" +%s 2>/dev/null || echo 0
    fi
}

days_ago() {
    local ts="$1" e
    e=$(epoch_of "$ts")
    [[ "$e" == "0" ]] && { echo "?"; return; }
    echo $(( (NOW_EPOCH - e) / 86400 ))
}

is_excluded() {
    local ns="$1" e
    for e in $HARD_EXCLUDES $EXTRA_EXCLUDES; do
        [[ "$ns" == "$e" ]] && return 0
    done
    return 1
}

# owner_of <ns> — best-effort attribution: dashboard requester annotation,
# else first User-kind rolebinding subject, else "admin-created"
owner_of() {
    local ns="$1" owner
    owner=$(oc get ns "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/requester}' 2>/dev/null)
    if [[ -z "$owner" ]]; then
        owner=$(oc get rolebindings -n "$ns" -o json 2>/dev/null \
            | jq -r '[.items[].subjects[]? | select(.kind=="User") | .name] | unique | first // empty')
    fi
    echo "${owner:-admin-created}"
}

# classify <ns>
# Prints: "<CLASS> <age-days> <detail>"
#   EMPTY   <ns-age>       "-"
#   STOPPED <idle-days>    "wb=N models=N pvcGi=N"
#   ACTIVE  -              "<reason>"
classify() {
    local ns="$1"

    local ns_json
    ns_json=$(oc get ns "$ns" -o json 2>/dev/null) || { echo "GONE - -"; return; }

    local running_pods
    running_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null \
        | grep -cv "Completed" || true)
    if [[ "$running_pods" -gt 0 ]]; then
        echo "ACTIVE - running-pods=$running_pods"
        return
    fi

    local wl_json nb_json model_json pvc_json
    wl_json=$(oc get deploy,sts -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
    nb_json=$(oc get notebooks.kubeflow.org -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
    model_json=$(oc get inferenceservice,llminferenceservice -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
    pvc_json=$(oc get pvc -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')

    local n_wl n_nb n_model n_pvc
    n_wl=$(jq '.items | length' <<<"$wl_json")
    n_nb=$(jq '.items | length' <<<"$nb_json")
    n_model=$(jq '.items | length' <<<"$model_json")
    n_pvc=$(jq '.items | length' <<<"$pvc_json")

    if [[ "$n_wl" == "0" && "$n_nb" == "0" && "$n_model" == "0" && "$n_pvc" == "0" ]]; then
        local created
        created=$(jq -r '.metadata.creationTimestamp' <<<"$ns_json")
        echo "EMPTY $(days_ago "$created") -"
        return
    fi

    # Any notebook without a stopped annotation that has ready replicas -> active.
    # A notebook with neither annotation nor replicas was created but never run.
    local unstopped_nb
    unstopped_nb=$(jq -r '[.items[] | select(
        (.metadata.annotations["kubeflow-resource-stopped"] == null)
        and ((.status.readyReplicas // 0) > 0)
    )] | length' <<<"$nb_json")
    if [[ "$unstopped_nb" -gt 0 ]]; then
        echo "ACTIVE - unstopped-notebooks=$unstopped_nb"
        return
    fi

    # Any model not explicitly stopped -> active
    local unstopped_model
    unstopped_model=$(jq -r '[.items[] | select(
        .metadata.annotations["serving.kserve.io/stop"] != "true"
    )] | length' <<<"$model_json")
    if [[ "$unstopped_model" -gt 0 ]]; then
        echo "ACTIVE - unstopped-models=$unstopped_model"
        return
    fi

    # STOPPED. Last human touch = newest of: notebook stop annotations,
    # notebook/workload/model/PVC creation timestamps. (Model
    # status.lastTransitionTime is unreliable — operator upgrades bump it.)
    local last_touch
    last_touch=$( (
        jq -r '.items[].metadata.annotations["kubeflow-resource-stopped"] // empty' <<<"$nb_json"
        jq -r '.items[].metadata.creationTimestamp' <<<"$nb_json"
        jq -r '.items[].metadata.creationTimestamp' <<<"$wl_json"
        jq -r '.items[].metadata.creationTimestamp' <<<"$model_json"
        jq -r '.items[].metadata.creationTimestamp' <<<"$pvc_json"
    ) | sort | tail -1 )

    local pvc_gi
    pvc_gi=$(jq -r '[.items[].spec.resources.requests.storage // "0"
        | sub("Gi$";"") | tonumber? // 0] | add' <<<"$pvc_json")

    echo "STOPPED $(days_ago "$last_touch") wb=$n_nb models=$n_model pvcGi=$pvc_gi"
}

# ---------------------------------------------------------------------------
# Audit pass
# ---------------------------------------------------------------------------
log_info "Scanning dashboard projects (label opendatahub.io/dashboard=true)..."
CANDIDATES=$(oc get ns -l opendatahub.io/dashboard=true \
    -o jsonpath='{range .items[?(@.status.phase=="Active")]}{.metadata.name}{"\n"}{end}')

EMPTY_ROWS=""
STOPPED_ROWS=""
ACTIVE_ROWS=""
EXCLUDED_ROWS=""

while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    if is_excluded "$ns"; then
        EXCLUDED_ROWS+="$ns"$'\n'
        continue
    fi
    read -r class age detail <<<"$(classify "$ns")"
    owner=$(owner_of "$ns")
    case "$class" in
        EMPTY)   EMPTY_ROWS+="$age $ns owner=$owner"$'\n' ;;
        STOPPED) STOPPED_ROWS+="$age $ns $detail owner=$owner"$'\n' ;;
        ACTIVE)  ACTIVE_ROWS+="$ns $detail owner=$owner"$'\n' ;;
    esac
done <<<"$CANDIDATES"

echo ""
echo "=== EMPTY (no workloads/PVCs/pods — age = namespace age) ==="
[[ -n "$EMPTY_ROWS" ]] && sort -rn <<<"$EMPTY_ROWS" | sed '/^$/d' \
    | awk '{printf "  %4sd  %-40s %s\n", $1, $2, $3}' || echo "  (none)"
echo ""
echo "=== STOPPED (all workbenches stopped + all models stopped — age = last touch) ==="
[[ -n "$STOPPED_ROWS" ]] && sort -rn <<<"$STOPPED_ROWS" | sed '/^$/d' \
    | awk '{printf "  %4sd  %-40s %s %s %s %s\n", $1, $2, $3, $4, $5, $6}' || echo "  (none)"
echo ""
echo "=== ACTIVE (never touched by this script) ==="
[[ -n "$ACTIVE_ROWS" ]] && sed '/^$/d' <<<"$ACTIVE_ROWS" | sort \
    | awk '{printf "  %-40s %s %s\n", $1, $2, $3}' || echo "  (none)"
echo ""
echo "=== EXCLUDED ==="
[[ -n "$EXCLUDED_ROWS" ]] && sed '/^$/d; s/^/  /' <<<"$EXCLUDED_ROWS" || echo "  (none)"
echo ""

# ---------------------------------------------------------------------------
# Delete pass
# ---------------------------------------------------------------------------
if [[ -z "$DELETE_EMPTY_DAYS" && -z "$DELETE_STOPPED_DAYS" ]]; then
    log_info "Audit only. Use --delete-empty <days> / --delete-stopped <days> to delete."
    exit 0
fi

TO_DELETE=""
if [[ -n "$DELETE_EMPTY_DAYS" && -n "$EMPTY_ROWS" ]]; then
    while read -r age ns _; do
        [[ -z "$ns" ]] && continue
        [[ "$age" != "?" && "$age" -gt "$DELETE_EMPTY_DAYS" ]] && TO_DELETE+="$ns "
    done <<<"$EMPTY_ROWS"
fi
if [[ -n "$DELETE_STOPPED_DAYS" && -n "$STOPPED_ROWS" ]]; then
    while read -r age ns _; do
        [[ -z "$ns" ]] && continue
        [[ "$age" != "?" && "$age" -gt "$DELETE_STOPPED_DAYS" ]] && TO_DELETE+="$ns "
    done <<<"$STOPPED_ROWS"
fi

if [[ -z "$TO_DELETE" ]]; then
    log_info "Nothing crosses the thresholds. No deletions."
    exit 0
fi

echo "Will delete: $TO_DELETE"
if $DRY_RUN; then
    log_warn "--dry-run: stopping before deletion."
    exit 0
fi

DELETED=0
SKIPPED=0
for ns in $TO_DELETE; do
    # Re-verify immediately before deleting — state may have changed mid-run
    read -r class _ detail <<<"$(classify "$ns")"
    if [[ "$class" != "EMPTY" && "$class" != "STOPPED" ]]; then
        log_warn "SKIP $ns — reclassified as $class ($detail)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    if oc delete project "$ns" --wait=false >/dev/null 2>&1; then
        log_info "Deleted: $ns"
        DELETED=$((DELETED+1))
    else
        log_error "Failed to delete: $ns"
        SKIPPED=$((SKIPPED+1))
    fi
done

log_info "Deleted $DELETED namespace(s), skipped $SKIPPED."
if [[ "$DELETED" -gt 0 ]]; then
    log_info "Deletions are async. Check progress with:"
    echo "    oc get ns -l opendatahub.io/dashboard=true | grep Terminating"
fi
