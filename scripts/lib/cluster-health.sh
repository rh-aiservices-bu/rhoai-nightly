#!/usr/bin/env bash
#
# cluster-health.sh - Shared control-plane health checks for preflight + diagnose
#
# Source this file AFTER common.sh and AFTER defining pass/warn/fail/info
# callback functions in the caller. The functions here emit via those callbacks.
#
# Functions:
#   check_master_sizing      — master node memory vs. OOM thresholds
#   check_master_pressure    — live memory/CPU pressure on masters
#   check_cluster_operators  — Degraded / Available=False ClusterOperators
#
# Rationale for thresholds: 2026-04-20 on cluster-hm2fl, 3× m6a.xlarge (16 GiB)
# masters OOMed during the RHOAI 3.4 observability cascade (Perses + Tempo +
# OTel + MonitoringStack + NodeMetrics all reconciling at once). 32 GiB was
# the empirical floor; 64 GiB gave comfortable margin.
#

# Map a common AWS instance type to approximate RAM GiB. Empty for unknown.
# Used only by PREFLIGHT_SIM_INSTANCE_TYPE so Pass C can exercise the FAIL
# path from a large-master cluster without provisioning a small one.
_instance_type_to_gib() {
    case "$1" in
        *.large)      echo 8  ;;
        *.xlarge)     echo 16 ;;
        *.2xlarge)    echo 32 ;;
        *.4xlarge)    echo 64 ;;
        *.8xlarge)    echo 128 ;;
        *.12xlarge)   echo 192 ;;
        *.16xlarge)   echo 256 ;;
        *)            echo "" ;;
    esac
}

# Convert Kubernetes memory quantity (e.g. "16002800Ki", "32Gi") to GiB (integer).
# Prints "0" on parse failure.
_kube_mem_to_gib() {
    local raw="$1"
    [[ -z "$raw" ]] && { echo 0; return; }
    local num unit
    if [[ "$raw" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo 0; return
    fi
    case "$unit" in
        "")   echo $(( num / 1073741824 )) ;;
        Ki)   echo $(( num / 1048576 )) ;;
        Mi)   echo $(( num / 1024 )) ;;
        Gi)   echo "$num" ;;
        Ti)   echo $(( num * 1024 )) ;;
        K|k)  echo $(( num / 1048576 )) ;;
        M|m)  echo $(( num / 1024 )) ;;
        G|g)  echo "$num" ;;
        *)    echo 0 ;;
    esac
}

# check_master_sizing [--fail-hard]
#
# Emits via caller's pass/warn/fail/info. With --fail-hard, threshold violations
# use fail(). Without it (diagnose mode), they use warn() so the script keeps
# going. Honours $PREFLIGHT_SKIP_SIZING=1 / $SKIP_SIZING_CHECK=1 — downgrades
# fail→warn. Honours $PREFLIGHT_SIM_INSTANCE_TYPE for Pass C testing.
check_master_sizing() {
    local fail_hard=false
    if [[ "${1:-}" == "--fail-hard" ]]; then
        fail_hard=true
    fi

    local skip_override=false
    if [[ "${PREFLIGHT_SKIP_SIZING:-0}" == "1" ]] || [[ "${SKIP_SIZING_CHECK:-0}" == "1" ]]; then
        skip_override=true
    fi

    # Gather per-master instance-type + capacity.memory
    local master_json
    master_json=$(oc get nodes -l node-role.kubernetes.io/master \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.node\.kubernetes\.io/instance-type}{"|"}{.status.capacity.memory}{"\n"}{end}' 2>/dev/null || echo "")

    if [[ -z "$master_json" ]]; then
        info "Master Sizing" "No master nodes found — skipping sizing check"
        return 0
    fi

    local min_gib=999999
    local worst_name="" worst_type="" worst_mem=""
    local sim_type="${PREFLIGHT_SIM_INSTANCE_TYPE:-}"
    local types=""

    while IFS='|' read -r name itype mem; do
        [[ -z "$name" ]] && continue
        # Simulation hook: force every master to appear as $sim_type.
        [[ -n "$sim_type" ]] && itype="$sim_type"
        # Prefer instance-type nameplate (e.g. m6a.2xlarge = 32 GiB) over
        # capacity.memory, because the kubelet reserves 1-2 GiB of each
        # node's RAM for system daemons — a 32 GiB instance reports
        # ~30 GiB capacity, which would spuriously FAIL a <32 GiB rule.
        local gib
        gib=$(_instance_type_to_gib "$itype")
        if [[ -z "$gib" ]]; then
            # Unknown instance type — fall back to capacity
            gib=$(_kube_mem_to_gib "$mem")
        fi
        types+="${itype:-unknown},"
        if (( gib < min_gib )); then
            min_gib=$gib
            worst_name="$name"
            worst_type="${itype:-unknown}"
            worst_mem="${gib} GiB"
        fi
    done <<< "$master_json"

    # Dedupe the types string for the summary message.
    local dedup_types
    dedup_types=$(echo "$types" | tr ',' '\n' | sort -u | grep -v '^$' | paste -sd, -)

    if (( min_gib == 999999 )); then
        info "Master Sizing" "Could not parse master memory — skipping"
        return 0
    fi

    local sim_note=""
    [[ -n "$sim_type" ]] && sim_note=" [PREFLIGHT_SIM_INSTANCE_TYPE=$sim_type]"

    if (( min_gib < 32 )); then
        local msg="Masters $dedup_types (smallest $worst_name: $worst_type, ${min_gib} GiB). Branch's observability load OOM'd an m6a.xlarge control plane on 2026-04-20. Resize the ControlPlaneMachineSet to at least m5.2xlarge / m6a.2xlarge before proceeding.${sim_note}"
        if [[ "$skip_override" == "true" ]]; then
            warn "Master Sizing" "$msg (override: PREFLIGHT_SKIP_SIZING=1 set)"
        elif [[ "$fail_hard" == "true" ]]; then
            fail "Master Sizing" "$msg"
            _recommend_if_available "Resize masters to 32 GiB+ (m5.2xlarge/m6a.2xlarge) or set PREFLIGHT_SKIP_SIZING=1 to override (not recommended)."
        else
            warn "Master Sizing" "$msg"
            _recommend_if_available "Resize masters to 32 GiB+ before enabling the observability cascade."
        fi
    elif (( min_gib < 64 )); then
        warn "Master Sizing" "Masters $dedup_types (smallest $worst_name: $worst_type, ${min_gib} GiB). Install should complete but margin is thin — monitor 'oc adm top nodes' during install and abort if any master exceeds 80%.${sim_note}"
    else
        pass "Master Sizing" "Masters $dedup_types (smallest ${min_gib} GiB) — comfortable headroom"
    fi
}

# check_master_pressure [--fail-hard]
#
# Uses `oc adm top nodes -l node-role.kubernetes.io/master`. Memory >85% FAIL,
# 70-85% WARN, <70% PASS. CPU reported WARN-only (recoverable). Without
# --fail-hard, memory >85% is WARN (diagnose mode stays read-only but still
# reports).
check_master_pressure() {
    local fail_hard=false
    if [[ "${1:-}" == "--fail-hard" ]]; then
        fail_hard=true
    fi

    local top_out
    top_out=$(oc adm top nodes -l node-role.kubernetes.io/master --no-headers 2>&1)
    local rc=$?
    if (( rc != 0 )) || [[ "$top_out" =~ "metrics not available" ]] || [[ "$top_out" =~ "Metrics API not available" ]]; then
        info "Master Pressure" "metrics-server unavailable — pressure check skipped"
        return 0
    fi

    local worst_mem_name="" worst_mem_pct=0
    local worst_cpu_name="" worst_cpu_pct=0
    local reported=0

    # Format: NAME  CPU(cores)  CPU%  MEMORY(bytes)  MEMORY%
    while read -r line; do
        [[ -z "$line" ]] && continue
        local name cpu_pct mem_pct
        name=$(awk '{print $1}' <<< "$line")
        cpu_pct=$(awk '{print $3}' <<< "$line" | tr -d '%')
        mem_pct=$(awk '{print $5}' <<< "$line" | tr -d '%')
        [[ -z "$name" || -z "$mem_pct" ]] && continue
        # Skip unparseable rows (metric gap).
        [[ ! "$mem_pct" =~ ^[0-9]+$ ]] && continue
        reported=$((reported + 1))
        if (( mem_pct > worst_mem_pct )); then
            worst_mem_pct=$mem_pct; worst_mem_name="$name"
        fi
        if [[ "$cpu_pct" =~ ^[0-9]+$ ]] && (( cpu_pct > worst_cpu_pct )); then
            worst_cpu_pct=$cpu_pct; worst_cpu_name="$name"
        fi
    done <<< "$top_out"

    if (( reported == 0 )); then
        info "Master Pressure" "No master metrics parsed — skipping"
        return 0
    fi

    # Memory verdict
    if (( worst_mem_pct > 85 )); then
        local msg="$worst_mem_name at ${worst_mem_pct}% memory — within OOM range observed on cluster-hm2fl 2026-04-20. Abort any in-progress observability install and resize the control plane."
        if [[ "$fail_hard" == "true" ]]; then
            fail "Master Memory" "$msg"
        else
            warn "Master Memory" "$msg"
        fi
        _recommend_if_available "Resize control plane before retrying observability install: oc adm top nodes -l node-role.kubernetes.io/master"
    elif (( worst_mem_pct >= 70 )); then
        warn "Master Memory" "$worst_mem_name at ${worst_mem_pct}% — approaching OOM range; do not trigger new operator installs until this recovers"
    else
        pass "Master Memory" "All masters <70% (worst: $worst_mem_name at ${worst_mem_pct}%)"
    fi

    # CPU verdict (warn-only; saturation is recoverable)
    if (( worst_cpu_pct > 85 )); then
        warn "Master CPU" "$worst_cpu_name at ${worst_cpu_pct}% — apiserver may be slow; watch for leader-election timeouts"
    elif (( worst_cpu_pct >= 70 )); then
        info "Master CPU" "$worst_cpu_name at ${worst_cpu_pct}% — elevated but recoverable"
    else
        pass "Master CPU" "All masters <70% (worst: $worst_cpu_name at ${worst_cpu_pct}%)"
    fi
}

# check_cluster_operators [--fail-hard]
#
# Reports Degraded=True / Available=False / persistent Progressing=True
# ClusterOperators. With --fail-hard, Degraded or !Available → fail(); without
# it → warn(). Progressing is always INFO (transient on fresh cluster).
check_cluster_operators() {
    local fail_hard=false
    if [[ "${1:-}" == "--fail-hard" ]]; then
        fail_hard=true
    fi

    local co_json
    co_json=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Available")].status}{"|"}{.status.conditions[?(@.type=="Progressing")].status}{"|"}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null || echo "")

    if [[ -z "$co_json" ]]; then
        info "ClusterOperators" "No ClusterOperators returned — skipping"
        return 0
    fi

    local degraded_list="" unavail_list="" progressing_list=""
    local total=0
    while IFS='|' read -r name avail prog degr; do
        [[ -z "$name" ]] && continue
        total=$((total + 1))
        [[ "$degr"  == "True"  ]] && degraded_list+="$name "
        [[ "$avail" == "False" ]] && unavail_list+="$name "
        [[ "$prog"  == "True"  ]] && progressing_list+="$name "
    done <<< "$co_json"

    if [[ -n "$unavail_list" ]]; then
        local msg="$unavail_list(Available=False) — cluster not healthy"
        if [[ "$fail_hard" == "true" ]]; then
            fail "ClusterOperators" "$msg"
        else
            warn "ClusterOperators" "$msg"
        fi
        _recommend_if_available "Investigate: oc get co; oc describe co <name>"
    fi

    if [[ -n "$degraded_list" ]]; then
        local msg="$degraded_list(Degraded=True)"
        if [[ "$fail_hard" == "true" ]]; then
            fail "ClusterOperators" "$msg — resolve before installing"
        else
            warn "ClusterOperators" "$msg"
        fi
        _recommend_if_available "Investigate degraded operators: oc describe co <name>"
    fi

    if [[ -z "$unavail_list" && -z "$degraded_list" ]]; then
        if [[ -n "$progressing_list" ]]; then
            info "ClusterOperators" "$total total; Progressing: $progressing_list(usually transient on fresh cluster)"
        else
            pass "ClusterOperators" "$total operators — all Available, none Degraded, none Progressing"
        fi
    fi
}

# Call the caller's recommend() if it exists (diagnose has it; preflight doesn't).
_recommend_if_available() {
    if declare -F recommend >/dev/null 2>&1; then
        recommend "$@"
    fi
}
