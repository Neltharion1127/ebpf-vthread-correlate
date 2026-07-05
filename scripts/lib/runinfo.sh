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
        local jdk_home
        jdk_home="$(cd "$(dirname "$java_bin")/.." 2>/dev/null && pwd || true)"
        echo "jdk home  : ${jdk_home:-unresolvable}"
        if [[ -n "$jdk_home" ]] && git -C "$jdk_home" rev-parse --git-dir >/dev/null 2>&1; then
            echo "jdk git HEAD    : $(git -C "$jdk_home" rev-parse HEAD 2>/dev/null || echo unknown)"
            echo "jdk git branch  : $(git -C "$jdk_home" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
            echo "jdk git dirty   : $(git -C "$jdk_home" status --porcelain 2>/dev/null | wc -l) entries"
        else
            # tarball install (setup.sh layout): tarball sits next to the unpack root
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
                echo "jdk provenance  : not a git checkout, no tarball found — UNRECORDED (record manually)"
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
