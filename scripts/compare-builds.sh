#!/usr/bin/env bash
#
# compare-builds.sh - Answer "which RHOAI build is where, and what changed"
#
# On-demand only. Keeps NO state between runs: every invocation resolves its
# reference points fresh and compares them against each other. There is nothing
# to schedule and nothing to diff against a previous run.
#
# A "reference point" is anything that resolves to a catalog image digest. Each
# is optional and independently skippable; a run with two of them is valid. A
# point that cannot be resolved (branch missing, cluster unreachable, tag gone)
# is REPORTED as unresolved, never silently dropped -- "the cluster is gone" is
# itself a finding.
#
#   1. --branch NAME   catalogsource pin on a git branch (default: main, clusters)
#   2. --cluster CTX   a live cluster: the catalog POD's imageID, not .spec.image.
#                      Under a floating tag those two disagree and the pod wins.
#   3. --image REF     a tag or digest you name explicitly
#   4. --stream        newest build in main's version family. Both the -nightly
#                      and the released rhoai-<ver> track are probed: they move
#                      independently and the released track has led before.
#
# With a cluster available it also compares the COMPONENT layer -- what the
# catalog offers (packagemanifest relatedImages) against what is deployed (the
# installed CSV's RELATED_IMAGE env). Drift there means the cluster runs an
# older nightly than its own catalog serves, which is the static-CSV-name issue
# (docs/issues/nightly-csv-name-static.md) and what `make restart-catalog` fixes.
#
# Usage:
#   scripts/compare-builds.sh                        # main + clusters + current cluster + stream
#   scripts/compare-builds.sh --no-cluster           # offline: git pins + quay only
#   scripts/compare-builds.sh --cluster CTX          # a specific oc context (repeatable)
#   scripts/compare-builds.sh --image :rhoai-3.6-ea.1-nightly
#   scripts/compare-builds.sh --repos                # also report upstream commits since the build
#   scripts/compare-builds.sh --list-tags            # authoritative milestone discovery (SLOW, ~216k tags)
#   scripts/compare-builds.sh --json                 # machine-readable
#
# Options:
#   --branch NAME     add a git branch pin           --no-branches
#   --cluster CTX     add a cluster ("current" ok)   --no-cluster
#   --image REF       add an explicit image ref      (a bare ":tag" means the FBC repo)
#   --stream/--no-stream
#   --components/--no-components   component-layer diff (default: on when a cluster resolves)
#   --repos           check the upstream org clones for commits since the build
#   --list-tags       discover milestone tags from the registry instead of probing
#   --json            emit JSON instead of the table
#   -q, --quiet       suppress progress chatter
#
# Exit codes:
#   0 = every resolved reference point agrees (same digest)
#   1 = usage error, or nothing could be resolved at all
#   2 = drift: resolved points disagree, or the cluster lags its own catalog

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FBC_REPO="quay.io/rhoai/rhoai-fbc-fragment"
CATALOG_NAME="rhoai-catalog-nightly"
CATALOG_NS="openshift-marketplace"
OPERATOR_NS="redhat-ods-operator"
CHANNEL="stable-3.x"
CATALOG_PATH="components/operators/rhoai-operator/base/catalogsource.yaml"
CHANNEL_PATH="components/operators/rhoai-operator/base/patch-channel.yaml"
OC_TIMEOUT="--request-timeout=20s"

BRANCHES=()
CLUSTERS=()
IMAGES=()
USE_BRANCHES=true
USE_CLUSTER=true
USE_STREAM=true
USE_COMPONENTS=""      # empty = auto (on when a cluster resolves)
USE_REPOS=false
LIST_TAGS=false
JSON=false
QUIET=false

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compare-builds.XXXXXX")" || { echo "cannot create temp dir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

say() { $QUIET || log_info "$*"; }
note() { $QUIET || log_step "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)    [[ $# -ge 2 ]] || { log_error "--branch needs a name"; exit 1; }; BRANCHES+=("$2"); shift 2 ;;
        --cluster)   [[ $# -ge 2 ]] || { log_error "--cluster needs a context"; exit 1; }; CLUSTERS+=("$2"); shift 2 ;;
        --image)     [[ $# -ge 2 ]] || { log_error "--image needs a reference"; exit 1; }; IMAGES+=("$2"); shift 2 ;;
        --no-branches)   USE_BRANCHES=false; shift ;;
        --no-cluster)    USE_CLUSTER=false; shift ;;
        --stream)        USE_STREAM=true; shift ;;
        --no-stream)     USE_STREAM=false; shift ;;
        --components)    USE_COMPONENTS=true; shift ;;
        --no-components) USE_COMPONENTS=false; shift ;;
        --repos)         USE_REPOS=true; shift ;;
        --list-tags)     LIST_TAGS=true; shift ;;
        --json)          JSON=true; QUIET=true; shift ;;
        -q|--quiet)      QUIET=true; shift ;;
        -h|--help)   sed -n '3,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

for tool in skopeo jq git; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required but not installed"; exit 1; }
done

# Default reference points when none were named explicitly.
$USE_BRANCHES && [[ ${#BRANCHES[@]} -eq 0 ]] && BRANCHES=(main clusters)
$USE_BRANCHES || BRANCHES=()
$USE_CLUSTER && [[ ${#CLUSTERS[@]} -eq 0 ]] && CLUSTERS=(current)
$USE_CLUSTER || CLUSTERS=()

# --- resolution helpers -------------------------------------------------------

# Rows accumulate as TSV: point <TAB> ref <TAB> digest <TAB> build-date <TAB> version <TAB> release
ROWS="$WORK/rows.tsv"
: > "$ROWS"
UNRESOLVED="$WORK/unresolved.tsv"
: > "$UNRESOLVED"

add_row()        { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$ROWS"; }
add_unresolved() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$UNRESOLVED"; }

# Normalise "":tag"", "tag", "repo:tag", or "repo@sha256:..." to a full pull spec.
full_ref() {
    local r="$1"
    case "$r" in
        *"@sha256:"*|*"/"*) echo "$r" ;;
        :*)                 echo "${FBC_REPO}${r}" ;;
        *)                  echo "${FBC_REPO}:${r}" ;;
    esac
}

# skopeo inspect, memoised per reference. Emits "digest<TAB>build-date<TAB>version<TAB>release".
# --override-os/--override-arch are mandatory on Apple Silicon: without them
# skopeo refuses with "no image found in image index for architecture arm64".
inspect_ref() {
    local ref cache
    ref="$(full_ref "$1")"
    cache="$WORK/insp.$(printf '%s' "$ref" | tr -c 'A-Za-z0-9' '_')"
    if [[ ! -f "$cache" ]]; then
        skopeo inspect --no-tags --override-os linux --override-arch amd64 \
            "docker://$ref" 2>"$cache.err" \
            | jq -r '[.Digest, .Labels["build-date"], .Labels.version, .Labels.release]
                     | map(. // "?") | @tsv' > "$cache" 2>/dev/null
    fi
    [[ -s "$cache" ]] || return 1
    cat "$cache"
}

short() { local d="${1#sha256:}"; echo "${d:0:8}"; }

# 1 + 3: catalogsource pin on a git branch.
resolve_branch() {
    local br="$1" ref rest
    # Braces before the colon are load-bearing under zsh, where "$br:c" would
    # parse as the :c modifier. Harmless in bash; kept so the line is portable.
    ref="$(git -C "$REPO_ROOT" show "origin/${br}:${CATALOG_PATH}" 2>/dev/null \
           | sed -nE 's/^[[:space:]]*image:[[:space:]]*//p')"
    if [[ -z "$ref" ]]; then
        # fall back to a local branch when there is no remote-tracking copy
        ref="$(git -C "$REPO_ROOT" show "${br}:${CATALOG_PATH}" 2>/dev/null \
               | sed -nE 's/^[[:space:]]*image:[[:space:]]*//p')"
    fi
    [[ -n "$ref" ]] || { add_unresolved "branch:$br" "-" "branch or catalogsource not found"; return 1; }
    if ! rest="$(inspect_ref "$ref")"; then
        add_unresolved "branch:$br" "$ref" "tag not resolvable on the registry"; return 1
    fi
    IFS=$'\t' read -r dg bd ver rel <<< "$rest"
    add_row "branch:$br" "$ref" "$dg" "$bd" "$ver" "$rel"
    echo "$ref"
}

branch_channel() {
    git -C "$REPO_ROOT" show "origin/${1}:${CHANNEL_PATH}" 2>/dev/null \
        | grep -A1 '/spec/channel' | sed -nE 's/^[[:space:]]*value:[[:space:]]*//p'
}

# 2: a live cluster. The catalog POD's imageID is the running build; .spec.image
# is only what GitOps asked for.
resolve_cluster() {
    local ctx="$1" ctxargs=() label spec pod_img csv sub
    if [[ "$ctx" == "current" ]]; then
        ctx="$(oc config current-context 2>/dev/null)"
        [[ -n "$ctx" ]] || { add_unresolved "cluster:current" "-" "no current oc context"; return 1; }
    fi
    ctxargs=(--context="$ctx")

    # One call proves reachability AND yields a clean short name: context names
    # mangle dots to dashes, but the server URL keeps them, so api.<name>.<...>
    # gives the cluster name directly. Without a --request-timeout an
    # unreachable API hangs for minutes instead of failing.
    local server
    server="$(oc "${ctxargs[@]}" $OC_TIMEOUT whoami --show-server 2>/dev/null)"
    if [[ -z "$server" ]]; then
        label="cluster:$(printf '%s' "$ctx" | sed -E 's#^default/api-##; s#:6443/.*$##' | cut -c1-20)"
        add_unresolved "$label" "-" "unreachable (context exists, API did not answer)"
        return 1
    fi
    label="cluster:$(printf '%s' "$server" | sed -E 's#^https?://api[.-]##; s#[:.].*$##' | cut -c1-20)"

    # Two different context names can point at one cluster ("current" plus its
    # own name is the common case). Resolve it once.
    if [[ -f "$WORK/ctx.$label" ]]; then
        say "  $label already resolved via another context — skipping duplicate"
        return 1
    fi
    spec="$(oc "${ctxargs[@]}" $OC_TIMEOUT get catalogsource "$CATALOG_NAME" -n "$CATALOG_NS" \
            -o jsonpath='{.spec.image}' 2>/dev/null)"
    pod_img="$(oc "${ctxargs[@]}" $OC_TIMEOUT get pod -n "$CATALOG_NS" -l "olm.catalogSource=$CATALOG_NAME" \
            -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null \
            | grep -v '^$' | sort -u | head -1)"
    if [[ -z "$pod_img" && -z "$spec" ]]; then
        add_unresolved "$label" "-" "no $CATALOG_NAME CatalogSource (RHOAI not installed?)"
        return 1
    fi
    csv="$(oc "${ctxargs[@]}" $OC_TIMEOUT get subscription rhods-operator -n "$OPERATOR_NS" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null)"
    sub="$(oc "${ctxargs[@]}" $OC_TIMEOUT get subscription rhods-operator -n "$OPERATOR_NS" \
            -o jsonpath='{.status.state}' 2>/dev/null)"
    echo "$ctx"   > "$WORK/ctx.$label"
    echo "$csv"   > "$WORK/csv.$label"
    echo "$sub"   > "$WORK/sub.$label"
    echo "$spec"  > "$WORK/spec.$label"

    if [[ -n "$pod_img" ]] && rest="$(inspect_ref "$pod_img")"; then
        IFS=$'\t' read -r dg bd ver rel <<< "$rest"
        add_row "$label" "${spec:-$pod_img}" "$dg" "$bd" "$ver" "$rel"
    elif [[ -n "$pod_img" ]]; then
        # digest is authoritative even when the registry lookup fails
        add_row "$label" "${spec:-?}" "${pod_img##*@}" "?" "?" "?"
    else
        add_unresolved "$label" "$spec" "catalog pod not running; only .spec.image known"
        return 1
    fi
    echo "$label"
}

# 4: newest build in a version family. Probing a short candidate list beats
# `skopeo list-tags`, which returns ~216k tags and takes minutes.
resolve_stream() {
    local ver="$1" candidates=() t rest
    candidates=("rhoai-${ver}" "rhoai-${ver}-nightly")
    if $LIST_TAGS; then
        note "listing registry tags (slow)..."
        skopeo list-tags --override-os linux --override-arch amd64 "docker://$FBC_REPO" 2>/dev/null \
            | jq -r '.Tags[]' > "$WORK/tags.txt"
        while IFS= read -r t; do candidates+=("$t"); done < <(
            grep -E "^rhoai-${ver//./\\.}(-ea\.[0-9]+)?(-nightly)?$" "$WORK/tags.txt" | sort -u)
    else
        for n in 1 2 3 4; do
            candidates+=("rhoai-${ver}-ea.${n}" "rhoai-${ver}-ea.${n}-nightly")
        done
    fi
    # dedupe, preserving order
    local seen=() c
    for c in "${candidates[@]}"; do
        [[ " ${seen[*]-} " == *" $c "* ]] && continue
        seen+=("$c")
        if rest="$(inspect_ref ":$c")"; then
            IFS=$'\t' read -r dg bd ver2 rel <<< "$rest"
            add_row "stream:$c" "${FBC_REPO}:$c" "$dg" "$bd" "$ver2" "$rel"
        fi
    done
}

# --- resolve ------------------------------------------------------------------

MAIN_REF=""
for br in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
    note "resolving branch pin: $br"
    out="$(resolve_branch "$br")" && [[ "$br" == "main" ]] && MAIN_REF="$out"
done

CLUSTER_LABELS=()
for ctx in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    note "resolving cluster: $ctx"
    if lbl="$(resolve_cluster "$ctx")"; then CLUSTER_LABELS+=("$lbl"); fi
done

for img in ${IMAGES[@]+"${IMAGES[@]}"}; do
    note "resolving image: $img"
    if rest="$(inspect_ref "$img")"; then
        IFS=$'\t' read -r dg bd ver rel <<< "$rest"
        add_row "image" "$(full_ref "$img")" "$dg" "$bd" "$ver" "$rel"
    else
        add_unresolved "image" "$(full_ref "$img")" "not resolvable on the registry"
    fi
done

if $USE_STREAM; then
    # Version family comes from main's pin when available, else any resolved row.
    src="${MAIN_REF:-$(cut -f2 "$ROWS" 2>/dev/null | head -1)}"
    VER="$(echo "$src" | sed -nE 's/.*:rhoai-([0-9]+\.[0-9]+).*/\1/p')"
    if [[ -n "$VER" ]]; then
        note "probing the rhoai-$VER family"
        resolve_stream "$VER"
    else
        add_unresolved "stream" "-" "could not derive a version family (no rhoai-X.Y pin resolved)"
    fi
fi

if [[ ! -s "$ROWS" ]]; then
    log_error "No reference point could be resolved."
    [[ -s "$UNRESOLVED" ]] && while IFS=$'\t' read -r p r w; do log_error "  $p ($r): $w"; done < "$UNRESOLVED"
    exit 1
fi

# --- component layer ----------------------------------------------------------

COMPONENT_DRIFT=false
COMPONENT_REPORT="$WORK/components.txt"
: > "$COMPONENT_REPORT"

norm_images() { grep -oE '[a-z0-9.:/-]+@sha256:[0-9a-f]{64}' | sed 's/@/ /' | sort -u; }

component_diff() {
    local label="$1" ctx csv
    ctx="$(cat "$WORK/ctx.$label" 2>/dev/null)"
    csv="$(cat "$WORK/csv.$label" 2>/dev/null)"
    [[ -n "$ctx" && -n "$csv" ]] || return 1

    oc --context="$ctx" --request-timeout=30s get packagemanifest -l "catalog=$CATALOG_NAME" -n "$CATALOG_NS" -o json 2>/dev/null \
      | jq -r --arg ch "$CHANNEL" '.items[]|select(.metadata.name=="rhods-operator").status.channels[]
               |select(.name==$ch)|.currentCSVDesc.relatedImages[]' 2>/dev/null \
      | norm_images > "$WORK/offered.$label"

    oc --context="$ctx" --request-timeout=30s get csv "$csv" -n "$OPERATOR_NS" \
        -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].env[*]}{.value}{"\n"}{end}' 2>/dev/null \
      | norm_images > "$WORK/deployed.$label"

    [[ -s "$WORK/offered.$label" && -s "$WORK/deployed.$label" ]] || return 1

    local n_off n_dep drift=0
    n_off=$(wc -l < "$WORK/offered.$label" | tr -d ' ')
    n_dep=$(wc -l < "$WORK/deployed.$label" | tr -d ' ')
    {
        echo "  $label  (catalog offers $n_off images, CSV deploys $n_dep)"
        # Joining on the repo name is required: the two lists are not the same
        # universe (the env list holds version strings and duplicates; the
        # packagemanifest holds the bundle and operator images the env list has
        # no reason to carry). Diffing them raw manufactures ~30 false rows.
        while read -r repo off dep; do
            if [[ "$off" != "$dep" ]]; then
                drift=1
                printf '    DRIFT %s\n      offers   %s\n      deploys  %s\n' \
                    "$repo" "$(short "$off")" "$(short "$dep")"
            fi
        done < <(join "$WORK/offered.$label" "$WORK/deployed.$label")
        [[ $drift -eq 0 ]] && echo "    no component drift — cluster is current with its own catalog"
    } >> "$COMPONENT_REPORT"
    [[ $drift -eq 1 ]] && COMPONENT_DRIFT=true
    return 0
}

if [[ -z "$USE_COMPONENTS" ]]; then
    [[ ${#CLUSTER_LABELS[@]} -gt 0 ]] && USE_COMPONENTS=true || USE_COMPONENTS=false
fi
if [[ "$USE_COMPONENTS" == true && ${#CLUSTER_LABELS[@]} -gt 0 ]]; then
    for lbl in "${CLUSTER_LABELS[@]}"; do
        note "component diff: $lbl"
        component_diff "$lbl" || echo "  $lbl  component diff unavailable" >> "$COMPONENT_REPORT"
    done
elif [[ "$USE_COMPONENTS" == true ]]; then
    echo "  skipped — component digests require a reachable cluster (no opm/crane locally)" >> "$COMPONENT_REPORT"
fi

# --- verdict ------------------------------------------------------------------

# Only branch/cluster/image points are ACTIONABLE -- they say where a build is
# actually pinned or running, so a disagreement among them is real drift. The
# stream rows are deliberately historical (ea.1, ea.2 ...) and always differ;
# counting them as drift would make every run report a problem.
grep -v $'^stream:' "$ROWS" > "$WORK/actionable.tsv" || true
grep    $'^stream:' "$ROWS" > "$WORK/streamrows.tsv" || true

DISTINCT=$(cut -f3 "$WORK/actionable.tsv" 2>/dev/null | sort -u | grep -c . || echo 0)
NEWEST_DATE=$(cut -f4 "$WORK/actionable.tsv" 2>/dev/null | grep -v '^?$' | sort | tail -1)
OLDEST_DATE=$(cut -f4 "$WORK/actionable.tsv" 2>/dev/null | grep -v '^?$' | sort | head -1)

# Newest build anywhere in the family, and whether our pins already have it.
STREAM_BEST=$(sort -t$'\t' -k4,4 "$WORK/streamrows.tsv" 2>/dev/null | tail -1)
STREAM_NEWER=false
if [[ -n "$STREAM_BEST" && -n "$NEWEST_DATE" ]]; then
    sb_date=$(printf '%s' "$STREAM_BEST" | cut -f4)
    [[ "$sb_date" > "$NEWEST_DATE" ]] && STREAM_NEWER=true
fi

RC=0
[[ "$DISTINCT" -gt 1 ]] && RC=2
$COMPONENT_DRIFT && RC=2

if $JSON; then
    {
        echo '{'
        echo '  "points": ['
        first=1
        while IFS=$'\t' read -r p r d b v rel; do
            [[ $first -eq 1 ]] || echo ','
            first=0
            printf '    {"point":%s,"ref":%s,"digest":%s,"buildDate":%s,"version":%s,"release":%s}' \
                "$(jq -Rn --arg x "$p" '$x')" "$(jq -Rn --arg x "$r" '$x')" \
                "$(jq -Rn --arg x "$d" '$x')" "$(jq -Rn --arg x "$b" '$x')" \
                "$(jq -Rn --arg x "$v" '$x')" "$(jq -Rn --arg x "$rel" '$x')"
        done < "$ROWS"
        echo; echo '  ],'
        echo '  "unresolved": ['
        first=1
        while IFS=$'\t' read -r p r w; do
            [[ $first -eq 1 ]] || echo ','
            first=0
            printf '    {"point":%s,"ref":%s,"why":%s}' \
                "$(jq -Rn --arg x "$p" '$x')" "$(jq -Rn --arg x "$r" '$x')" "$(jq -Rn --arg x "$w" '$x')"
        done < "$UNRESOLVED"
        echo; echo '  ],'
        printf '  "distinctDigests": %s,\n' "$DISTINCT"
        printf '  "componentDrift": %s,\n' "$($COMPONENT_DRIFT && echo true || echo false)"
        printf '  "exitCode": %s\n' "$RC"
        echo '}'
    }
    exit $RC
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
echo " RHOAI build comparison"
echo "════════════════════════════════════════════════════════════════════════════"
echo
print_rows() {
    while IFS=$'\t' read -r p r d b v rel; do
        printf '%-30s %-28s %-10s %-21s %s\n' \
            "$p" "$(echo "$r" | sed "s#^${FBC_REPO}##; s/^://")" "$(short "$d")" "$b" "$v"
    done < <(sort -t$'\t' -k4,4 "$1")
}

printf '%-30s %-28s %-10s %-21s %s\n' "REFERENCE POINT" "TAG / REF" "DIGEST" "BUILT" "VERSION"
printf '%-30s %-28s %-10s %-21s %s\n' "------------------------------" "----------------------------" "----------" "---------------------" "-------"
print_rows "$WORK/actionable.tsv"
if [[ -s "$WORK/streamrows.tsv" ]]; then
    echo "-- available in the family (context, not drift) ----------------------------"
    print_rows "$WORK/streamrows.tsv"
fi

if [[ -s "$UNRESOLVED" ]]; then
    echo
    log_warn "Unresolved reference points (reported, not skipped):"
    while IFS=$'\t' read -r p r w; do printf '    %-28s %s\n' "$p" "$w"; done < "$UNRESOLVED"
fi

if [[ ${#BRANCHES[@]} -gt 1 ]]; then
    echo
    echo "Subscription channel per branch:"
    for br in "${BRANCHES[@]}"; do
        printf '    %-12s %s\n' "$br" "$(branch_channel "$br" || echo '?')"
    done
fi

for lbl in ${CLUSTER_LABELS[@]+"${CLUSTER_LABELS[@]}"}; do
    echo
    printf 'Cluster %s: CSV %s (%s)\n' "$lbl" \
        "$(cat "$WORK/csv.$lbl" 2>/dev/null)" "$(cat "$WORK/sub.$lbl" 2>/dev/null)"
done

if [[ -s "$COMPONENT_REPORT" ]]; then
    echo
    echo "Component layer:"
    cat "$COMPONENT_REPORT"
fi

if $USE_REPOS; then
    echo
    echo "Upstream repos (commits after $OLDEST_DATE, unmerged into the local clones):"
    GH_ROOT="${GH_ROOT:-$HOME/git/github}"
    since="${OLDEST_DATE%%T*}"
    found=false
    for org in opendatahub-io red-hat-data-services; do
        [[ -d "$GH_ROOT/$org" ]] || continue
        for d in "$GH_ROOT/$org"/*/; do
            [[ -d "$d/.git" ]] || continue
            out="$(git -C "$d" log --oneline --no-decorate "HEAD..@{u}" --since="$since" 2>/dev/null)"
            if [[ -n "$out" ]]; then
                found=true
                printf '  %s/%s\n' "$org" "$(basename "$d")"
                echo "$out" | sed 's/^/      /'
            fi
        done
    done
    $found || echo "  none (or clones are already up to date — run each org's pull-all.sh -n)"
fi

echo
case $RC in
    0) log_info "All $(grep -c . "$WORK/actionable.tsv") actionable reference points agree on one build." ;;
    2) log_warn "Drift: $DISTINCT distinct builds across the actionable reference points."
       [[ -n "$NEWEST_DATE" && -n "$OLDEST_DATE" && "$NEWEST_DATE" != "$OLDEST_DATE" ]] && \
           echo "         oldest $OLDEST_DATE   newest $NEWEST_DATE"
       $COMPONENT_DRIFT && echo "         a cluster lags its own catalog — see docs/issues/nightly-csv-name-static.md"
       ;;
esac

if $STREAM_NEWER && [[ -n "$STREAM_BEST" ]]; then
    sb_tag=$(printf '%s' "$STREAM_BEST" | cut -f1 | sed 's/^stream://')
    sb_dig=$(printf '%s' "$STREAM_BEST" | cut -f3)
    sb_dat=$(printf '%s' "$STREAM_BEST" | cut -f4)
    echo
    log_warn "A newer build exists in this family than anything pinned or running:"
    printf '         %s  %s  %s\n' "$sb_tag" "$(short "$sb_dig")" "$sb_dat"
    case "$sb_tag" in
        *-nightly) ;;
        *) echo "         NOTE: that is the released z-stream track, a different track"
           echo "               from -nightly. Moving to it is a track change, not just"
           echo "               a fresher build." ;;
    esac
fi
echo
echo "This script reports only. Acting on drift is a separate decision:"
echo "  same version, newer build   -> scripts/restart-catalog.sh on the target cluster"
echo "  a real version bump         -> the upgrade-rhoai-nightly workflow"
echo "  a moved component digest    -> re-run that ledger entry's Detection command"
echo "                                 (docs/workarounds.md, docs/issues/) before"
echo "                                 concluding anything is fixed."
exit $RC
