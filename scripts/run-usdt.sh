#!/usr/bin/env bash
# run-usdt.sh - quick VThreadTraceProbes/JMH/USDT verification.
#
# This is intentionally separate from profile-matrix.sh:
# - profile-matrix.sh follows config/env.sh and the normal benchmark matrix.
# - this script explicitly uses the release-flag JDK so it can test
#   -XX:+VThreadTraceProbes without permanently editing config/env.sh.
#
# Run as your normal user. Only the bpftrace command uses sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Resolve the vthread-trace JDK by priority — and never silently fall back to
# the system JDK (an ordinary JDK has no -XX:+VThreadTraceProbes and would
# quietly produce wrong data):
#   1. an explicit JDK= on the command line wins over everything
#   2. otherwise read config/env.sh (written by ./setup.sh)
#   3. neither set -> fail loudly; do NOT use the system JAVA_HOME
if [[ -z "${JDK:-}" && -f "$REPO_ROOT/config/env.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/config/env.sh"
fi
if [[ -z "${JDK:-}" ]]; then
    echo "ERROR: no vthread-trace JDK configured." >&2
    echo "       Run ./setup.sh first (downloads the JDK + writes config/env.sh)," >&2
    echo "       or pass one explicitly: JDK=/path/to/jdk $0" >&2
    echo "       (Refusing to use the system JAVA_HOME — it lacks -XX:+VThreadTraceProbes.)" >&2
    exit 1
fi
JAVA="${JAVA:-$JDK/bin/java}"
LIBJVM="${LIBJVM:-$JDK/lib/server/libjvm.so}"

CLASS="${CLASS:-uk.ac.ncl.jensen.benchmark.VThreadParkUnparkBenchmark}"
FALLBACK_CLASS="uk.ac.ncl.jensen.benchmark.VThreadTransitionBenchmark"

WARMUP="${WARMUP:-3}"
ITER="${ITER:-5}"
RUN_C="${RUN_C:-1}"

SHADED_JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
JAR="$REPO_ROOT/target/benchmarks.jar"
OUT="$REPO_ROOT/result/benchmark/usdt-flag"
mkdir -p "$OUT"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

print_cmd() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

quote_cmd() {
    printf '%q ' "$@"
}

needs_build() {
    [[ ! -f "$SHADED_JAR" ]] && return 0
    find src/main/java pom.xml -type f -newer "$SHADED_JAR" | grep -q .
}

ensure_jar() {
    if needs_build; then
        [[ -f config/env.sh ]] || die "config/env.sh missing; copy config/env.sh.example and set JAVA_HOME for Maven compilation"
        echo "Building JMH jar with repo convention: source config/env.sh; mvn -q clean package"
        (
            set -euo pipefail
            # shellcheck source=/dev/null
            source config/env.sh
            command -v mvn >/dev/null 2>&1 || die "mvn not found after sourcing config/env.sh"
            mvn -q clean package
        )
    fi

    [[ -f "$SHADED_JAR" ]] || die "missing shaded jar after build: $SHADED_JAR"
    ln -sf "$(basename "$SHADED_JAR")" "$JAR"
}

score_num_from_log() {
    awk '/ avgt / { score = $5 } END { if (score != "") print score }' "$1"
}

count_from_log() {
    local map_name="$1"
    awk -v key="$map_name:" '$1 == key { value = $2 } END { if (value != "") print value; else print 0 }' "$2"
}

require_runtime() {
    [[ -x "$JAVA" ]] || die "java not executable: $JAVA"
    [[ -f "$LIBJVM" ]] || die "libjvm not found: $LIBJVM"
    command -v bpftrace >/dev/null 2>&1 || die "bpftrace not found"
}

select_benchmark_class() {
    local list
    list="$("$JAVA" -jar "$JAR" -l)"

    if [[ "$list" == *"$CLASS"* ]]; then
        return
    fi

    if [[ "$list" == *"$FALLBACK_CLASS"* ]]; then
        echo "Requested benchmark not found: $CLASS"
        echo "Falling back to: $FALLBACK_CLASS"
        CLASS="$FALLBACK_CLASS"
        return
    fi

    echo "$list" >&2
    die "neither $CLASS nor $FALLBACK_CLASS is present in the JMH jar"
}

ensure_jar
require_runtime
select_benchmark_class

echo "JMH jar: $(readlink -f "$JAR")"
echo "JDK:     $JDK"
echo "JAVA:    $JAVA"
echo "LIBJVM:  $LIBJVM"
echo "CLASS:   $CLASS"
echo "OUT:     $OUT"
echo

COMMON_JMH=(-jar "$JAR" "$CLASS" -f 0 -wi "$WARMUP" -i "$ITER")

A_CMD=("$JAVA" -XX:-VThreadTraceProbes "${COMMON_JMH[@]}")
B_JAVA_CMD=("$JAVA" -Djmh.ignoreLock=true -XX:+VThreadTraceProbes "${COMMON_JMH[@]}")
C_CMD=("${B_JAVA_CMD[@]}")

A_LOG="$OUT/A_control_flag_off.log"
B_LOG="$OUT/B_flag_on_bpftrace.log"
C_LOG="$OUT/C_flag_on_no_bpftrace.log"

echo "A - control, flag off"
print_cmd "${A_CMD[@]}"
"${A_CMD[@]}" | tee "$A_LOG"
echo

BPFTRACE_PROGRAM="usdt:$LIBJVM:hotspot:vthread__freeze { @f = count(); } usdt:$LIBJVM:hotspot:vthread__thaw { @t = count(); }"
B_JAVA_STRING="$(quote_cmd "${B_JAVA_CMD[@]}")"

echo "B - flag on, bpftrace attached"
printf '  sudo bpftrace -e %q -c %q\n' "$BPFTRACE_PROGRAM" "$B_JAVA_STRING"
sudo bpftrace -e "$BPFTRACE_PROGRAM" -c "$B_JAVA_STRING" | tee "$B_LOG"
echo

if [[ "$RUN_C" == "1" ]]; then
    echo "C - flag on, no bpftrace"
    print_cmd "${C_CMD[@]}"
    "${C_CMD[@]}" | tee "$C_LOG"
    echo
fi

A_SCORE="$(score_num_from_log "$A_LOG")"
B_SCORE="$(score_num_from_log "$B_LOG")"
F_COUNT="$(count_from_log "@f" "$B_LOG")"
T_COUNT="$(count_from_log "@t" "$B_LOG")"

[[ -n "$A_SCORE" ]] || die "could not parse A JMH score from $A_LOG"
[[ -n "$B_SCORE" ]] || die "could not parse B JMH score from $B_LOG"

DELTA="$(awk -v a="$A_SCORE" -v b="$B_SCORE" 'BEGIN { printf "%.3f", b - a }')"

echo "Summary"
echo "  A score: $A_SCORE us/op"
echo "  B score: $B_SCORE us/op"
echo "  @f:      $F_COUNT"
echo "  @t:      $T_COUNT"
echo "  B - A:   $DELTA us/op"

if [[ "$RUN_C" == "1" ]]; then
    C_SCORE="$(score_num_from_log "$C_LOG")"
    [[ -n "$C_SCORE" ]] || die "could not parse C JMH score from $C_LOG"
    echo "  C score: $C_SCORE us/op"
fi

if [[ "$F_COUNT" == "0" || "$T_COUNT" == "0" ]]; then
    die "USDT counters did not fire through the JMH harness"
fi

echo
echo "OK: VThreadTraceProbes fired through JMH -f 0. This is directional VM-only data."
