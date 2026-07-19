#!/usr/bin/env bash
# runinfo.sh — provenance metadata writer (closes PROVENANCE GAP-1/2/4 from the
# v2 batch analysis: no RUNINFO file, unrecorded JDK placement path, unrecorded
# consumer checkout on the run host).
#
# Sourced by measure-oslevel.sh and profile-matrix.sh. Each run calls
# write_runinfo once at startup; it writes RUNINFO-<timestamp>.txt into the
# given output directory and prints the file path on stdout.
#
# JDK-side provenance is BEST-EFFORT by design: if $java_bin lives inside a git
# checkout we record that repo's HEAD (+ dirty count); otherwise we look for a
# tarball next to the install root and record its path + sha256; otherwise we
# say so explicitly rather than guess.
#
# Usage: write_runinfo <outdir> <script-name> <java-bin> [KNOB=value ...]

write_runinfo() {
    local outdir="$1" script_name="$2" java_bin="$3"
    shift 3

    local lib_dir consumer_root stamp file
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    consumer_root="$(cd "$lib_dir/../.." && pwd)"
    stamp="$(date +%Y%m%d-%H%M%S)"
    file="$outdir/RUNINFO-$stamp.txt"
    mkdir -p "$outdir"

    {
        echo "script    : $script_name"
        echo "date      : $(date -Is)"
        echo "hostname  : $(hostname)"
        echo "uname     : $(uname -a)"
        echo "nproc     : $(nproc)"
        echo "meminfo   : $(head -1 /proc/meminfo)"
        echo "bpftrace  : $( (bpftrace --version 2>&1 || echo 'not found') | head -1)"

        # Environment pinning evidence (bare-metal GAP-3): best-effort, N/A when
        # a source is unavailable (non-EC2 host, no cpufreq, numactl missing).
        echo "cpu governor  : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
        echo "cpu affinity  : $(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status 2>/dev/null || echo N/A)"
        local turbo="N/A"
        if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
            turbo="intel_pstate/no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
        elif [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
            turbo="cpufreq/boost=$(cat /sys/devices/system/cpu/cpufreq/boost)"
        fi
        echo "turbo         : $turbo"
        local smt="N/A"
        if [[ -r /sys/devices/system/cpu/smt/control ]]; then
            smt="$(cat /sys/devices/system/cpu/smt/control)"
        elif [[ -r /sys/devices/system/cpu/smt/active ]]; then
            smt="active=$(cat /sys/devices/system/cpu/smt/active)"
        fi
        echo "smt           : $smt"
        local numa
        numa="$(numactl --hardware 2>/dev/null | head -2 | paste -sd'; ' - || true)"
        echo "numa          : ${numa:-N/A}"
        # EC2 instance type via IMDS (v1, then v2 token fallback); 2s cap so a
        # non-EC2 host just records N/A instead of hanging.
        local itype imds_tok
        itype="$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || true)"
        if [[ -z "$itype" || "$itype" == *"401"* || "$itype" == *"<?xml"* ]]; then
            imds_tok="$(curl -s --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
                -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
            [[ -n "$imds_tok" ]] && itype="$(curl -s --max-time 2 \
                -H "X-aws-ec2-metadata-token: $imds_tok" \
                http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || true)"
        fi
        echo "instance-type : ${itype:-N/A}"

        echo "java bin  : $java_bin"
        echo "java -version:"
        if [[ -x "$java_bin" ]]; then
            "$java_bin" -version 2>&1 | sed 's/^/    /'
        else
            echo "    (not executable)"
        fi

        echo "consumer  : $consumer_root"
        echo "consumer HEAD   : $(git -C "$consumer_root" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "consumer branch : $(git -C "$consumer_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        local dirty
        dirty="$(git -C "$consumer_root" status --porcelain 2>/dev/null || true)"
        if [[ -n "$dirty" ]]; then
            echo "consumer status --porcelain ($(printf '%s\n' "$dirty" | wc -l) entries):"
            printf '%s\n' "$dirty" | sed 's/^/    /'
        else
            echo "consumer status --porcelain : clean"
        fi

        # JDK-side provenance, best-effort (see header).
        #
        # Up-walk guard (bare-metal batch PROVENANCE GAP-2): `git -C` searches
        # UPWARD, so a non-git jdk_home nested inside the consumer repo (the
        # setup.sh .vthread-jdk layout) used to resolve to the CONSUMER's HEAD
        # and get recorded as the JDK's — and the tarball branch below became
        # unreachable. Only trust git provenance when the resolved toplevel is
        # a repo other than the consumer's own.
        local jdk_home jdk_top consumer_top
        jdk_home="$(cd "$(dirname "$java_bin")/.." 2>/dev/null && pwd || true)"
        echo "jdk home  : ${jdk_home:-unresolvable}"
        jdk_top="$(git -C "${jdk_home:-/nonexistent}" rev-parse --show-toplevel 2>/dev/null || true)"
        consumer_top="$(git -C "$consumer_root" rev-parse --show-toplevel 2>/dev/null || echo "$consumer_root")"
        if [[ -n "$jdk_top" && "$jdk_top" != "$consumer_top" ]]; then
            echo "jdk git HEAD    : $(git -C "$jdk_home" rev-parse HEAD 2>/dev/null || echo unknown)"
            echo "jdk git branch  : $(git -C "$jdk_home" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
            echo "jdk git dirty   : $(git -C "$jdk_home" status --porcelain 2>/dev/null | wc -l) entries"
        else
            # setup.sh install: PROVENANCE.txt is written next to the unpack
            # root at download+verify time (release tag, asset, sha256).
            local prov="" prov_cand
            for prov_cand in "$jdk_home/../PROVENANCE.txt" "$jdk_home/PROVENANCE.txt"; do
                [[ -f "$prov_cand" ]] && { prov="$prov_cand"; break; }
            done
            if [[ -n "$prov" ]]; then
                echo "jdk provenance  : $(readlink -f "$prov")"
                sed 's/^/    /' "$prov"
            else
                # legacy fallback: tarball left next to the unpack root
                local install_root tarball found=0
                for install_root in "$jdk_home/.." "$jdk_home/../.."; do
                    [[ -d "$install_root" ]] || continue
                    for tarball in "$install_root"/*.tar.gz "$install_root"/*.tar.xz; do
                        [[ -f "$tarball" ]] || continue
                        echo "jdk tarball     : $(readlink -f "$tarball")"
                        echo "jdk tarball sha256 : $(sha256sum "$tarball" | awk '{print $1}')"
                        found=1
                        break 2
                    done
                done
                if [[ "$found" == 0 ]]; then
                    echo "jdk provenance  : unknown, pre-provenance install (no independent git checkout, no PROVENANCE.txt, no tarball)"
                fi
            fi
        fi

        echo "knobs:"
        local kv
        for kv in "$@"; do
            echo "    $kv"
        done
    } > "$file"

    echo "$file"
}
