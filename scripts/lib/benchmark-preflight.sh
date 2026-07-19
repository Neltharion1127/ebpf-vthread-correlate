#!/usr/bin/env bash
# Preflight checks for a formal benchmark batch. This file is sourced by
# run-batch.sh; it deliberately does not mutate machine state.

benchmark_preflight() {
    local repo_root="$1" java_bin="$2" prof_event="$3" skip_matrix="$4"
    local failures=0

    preflight_ok()   { printf '  [OK]   %s\n' "$*"; }
    preflight_warn() { printf '  [WARN] %s\n' "$*"; }
    preflight_fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }

    echo "== formal benchmark preflight =="

    local dirty
    # Result batches and generated paper tables are outputs, not measurement
    # inputs. Check the source/build paths that can actually change the run.
    dirty="$(git -C "$repo_root" status --porcelain --untracked-files=all -- \
        JVMTI-agent bpf src scripts pom.xml setup.sh 2>/dev/null || true)"
    if [[ -n "$dirty" ]]; then
        if [[ "${ALLOW_DIRTY:-0}" == "1" ]]; then
            preflight_warn "worktree is dirty (explicitly allowed by ALLOW_DIRTY=1)"
        else
            preflight_fail "worktree is dirty; commit/stash source changes, or deliberately set ALLOW_DIRTY=1"
        fi
        printf '%s\n' "$dirty" | sed 's/^/           /'
    else
        preflight_ok "worktree is clean"
    fi

    if [[ ! -x "$java_bin" ]]; then
        preflight_fail "configured Java is not executable: $java_bin"
    else
        local java_version
        java_version="$($java_bin -version 2>&1 || true)"
        if [[ "$java_version" == *fastdebug* ]]; then
            preflight_fail "configured JDK is fastdebug; formal measurements require a release build"
        elif [[ "$java_version" != *OpenJDK* && "$java_version" != *openjdk* ]]; then
            preflight_warn "unexpected Java version output; verify the patched release JDK manually"
        else
            preflight_ok "configured JDK is not fastdebug"
        fi
    fi

    local -a governor_files=()
    local governor_file governor_value
    shopt -s nullglob
    governor_files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    shopt -u nullglob
    if ((${#governor_files[@]} == 0)); then
        preflight_warn "CPU governor interface is unavailable; state will be recorded as N/A"
    else
        local -a bad_governors=()
        for governor_file in "${governor_files[@]}"; do
            governor_value="$(<"$governor_file")"
            [[ "$governor_value" == "performance" ]] || bad_governors+=("${governor_file%/cpufreq/scaling_governor}:$governor_value")
        done
        if ((${#bad_governors[@]})); then
            preflight_fail "not all CPUs use the performance governor: ${bad_governors[*]} (try: sudo cpupower frequency-set -g performance)"
        else
            preflight_ok "all exposed CPU governors are performance"
        fi
    fi

    local turbo_interface="" turbo_value=""
    if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        turbo_interface="intel_pstate/no_turbo"
        turbo_value="$(</sys/devices/system/cpu/intel_pstate/no_turbo)"
        if [[ "$turbo_value" == "1" ]]; then
            preflight_ok "Turbo Boost is disabled ($turbo_interface=1)"
        elif [[ "${ALLOW_TURBO:-0}" == "1" ]]; then
            preflight_warn "Turbo Boost is enabled ($turbo_interface=$turbo_value; explicitly allowed by ALLOW_TURBO=1)"
        else
            preflight_fail "Turbo Boost is enabled ($turbo_interface=$turbo_value); run: sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'"
        fi
    elif [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
        turbo_interface="cpufreq/boost"
        turbo_value="$(</sys/devices/system/cpu/cpufreq/boost)"
        if [[ "$turbo_value" == "0" ]]; then
            preflight_ok "CPU boost is disabled ($turbo_interface=0)"
        elif [[ "${ALLOW_TURBO:-0}" == "1" ]]; then
            preflight_warn "CPU boost is enabled ($turbo_interface=$turbo_value; explicitly allowed by ALLOW_TURBO=1)"
        else
            preflight_fail "CPU boost is enabled ($turbo_interface=$turbo_value); run: sudo sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'"
        fi
    else
        # Some EC2 guests do not expose P-state controls. Absence is not evidence
        # that boost is either enabled or disabled, so record it instead of guessing.
        preflight_warn "Turbo/boost control is not exposed by this kernel/instance; state is unverifiable"
    fi

    local smt_state="N/A"
    if [[ -r /sys/devices/system/cpu/smt/control ]]; then
        smt_state="$(</sys/devices/system/cpu/smt/control)"
    elif [[ -r /sys/devices/system/cpu/smt/active ]]; then
        smt_state="$(</sys/devices/system/cpu/smt/active)"
    fi
    case "$smt_state" in
        off|forceoff|notsupported|0) preflight_ok "SMT is inactive ($smt_state)" ;;
        on|1)
            if [[ "${REQUIRE_SMT_OFF:-0}" == "1" ]]; then
                preflight_fail "SMT is active and REQUIRE_SMT_OFF=1"
            else
                preflight_warn "SMT is active; accepted by default because EC2 bare-metal CPU options cannot disable it"
            fi
            ;;
        *)
            if [[ "${REQUIRE_SMT_OFF:-0}" == "1" ]]; then
                preflight_fail "SMT state is unavailable ($smt_state), so REQUIRE_SMT_OFF=1 cannot be verified"
            else
                preflight_warn "SMT state is unavailable ($smt_state); not a default hard failure on EC2 bare metal"
            fi
            ;;
    esac

    local allowed_cpus online_cpus
    allowed_cpus="$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status 2>/dev/null || true)"
    online_cpus="$(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
    if [[ -z "$allowed_cpus" ]]; then
        preflight_warn "could not determine process CPU affinity"
    elif [[ -n "$online_cpus" && "$allowed_cpus" == "$online_cpus" ]]; then
        if [[ "${REQUIRE_CPU_PINNING:-0}" == "1" ]]; then
            preflight_fail "batch is allowed on every online CPU ($allowed_cpus); launch it through taskset"
        else
            preflight_warn "batch is not CPU-pinned (allowed CPUs: $allowed_cpus); use taskset for the lowest variance"
        fi
    else
        preflight_ok "process CPU affinity is restricted to $allowed_cpus"
    fi

    if [[ "$prof_event" == "cpu" && "$skip_matrix" != "1" ]]; then
        local paranoid kptr
        paranoid="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
        kptr="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)"
        if ! [[ "$paranoid" =~ ^-?[0-9]+$ ]] || ((paranoid > 1)); then
            preflight_fail "PROF_EVENT=cpu requires kernel.perf_event_paranoid<=1 (now: $paranoid); run: sudo sysctl -w kernel.perf_event_paranoid=1"
        else
            preflight_ok "kernel.perf_event_paranoid=$paranoid"
        fi
        if [[ "$kptr" != "0" ]]; then
            preflight_fail "PROF_EVENT=cpu requires kernel.kptr_restrict=0 (now: $kptr); run: sudo sysctl -w kernel.kptr_restrict=0"
        else
            preflight_ok "kernel.kptr_restrict=0"
        fi
    fi

    local required_command
    for required_command in make mvn bpftrace sudo python3; do
        if command -v "$required_command" >/dev/null 2>&1; then
            preflight_ok "$required_command is available"
        else
            preflight_fail "$required_command is not available"
        fi
    done

    if ((failures)); then
        echo "preflight RESULT: FAIL ($failures blocking condition(s))" >&2
        return 1
    fi
    echo "preflight RESULT: OK (warnings are recorded, not silently ignored)"
}
