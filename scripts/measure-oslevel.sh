#!/usr/bin/env bash
# measure-oslevel.sh — A/C/B three-state quantification of OS-level observation overhead.
#
# SEPARATE from run-usdt.sh (the "probe alive" acceptance script). This script does NOT
# modify bpf/correlate.bt, scripts/run-usdt.sh or scripts/profile-matrix.sh; it only
# consumes bpf/correlate-probesonly.bt (the cropped consumer).
#
# Three states — ALL use `-f 2` (this cell only means anything under correct fork
# isolation; never -f 0):
#   A  baseline    : flag OFF, no bpftrace                  -> publish OFF, observe OFF
#   C  publish-on  : flag ON,  no bpftrace / no consumer    -> publish ON,  observe OFF
#   B  observed    : flag ON,  cropped bpftrace attached    -> publish ON,  observe ON
#
#   C - A = publish residual   (expected ~0: cost of emitting USDT with no consumer)
#   B - C = observation cost    (cost added by the eBPF consumer maintaining its maps)
#
# Workload selection (BENCH=, default preserves historical behaviour):
#   BENCH=transition  (default)  uk.ac.ncl.jensen.benchmark.VThreadTransitionBenchmark
#   BENCH=churn                  uk.ac.ncl.jensen.benchmark.VThreadChurnBenchmark
#   BENCH=parkunpark             uk.ac.ncl.jensen.benchmark.VThreadParkUnparkBenchmark
#   (CLASS= still wins over BENCH if set explicitly, as before.)
#
# Churn C−A semantics: on BENCH=churn the C−A delta measures the DIRECT cost of
# the lifecycle probes — each vthread pays two JNI transitions (notifyVThread
# start/end) plus the vthread__start/vthread__end USDT fires, and by design
# prediction its body (Blackhole.consumeCPU(1)) never blocks, so no freeze/thaw
# publish should be mixed in. If the B-state counters confirm @freeze_total≈0,
# C−A on churn is PURE lifecycle-probe isolation (zero freeze/thaw publish
# contribution); the recorded @freeze_total value is itself the verdict on that
# prediction.
#
# COUNT mode (COUNT=1): counters-only run. Skips A and C entirely and runs ONLY
# the B state (flag on + probesonly consumer) with `-f 1 -wi 0` — no warmup so
# warmup iterations cannot pollute the counters, single fork so the counter set
# maps to exactly one benchmark JVM. Measurement iterations stay at the default
# (or MI= overrides). ALL time figures in COUNT mode are meaningless (cold JVM,
# single fork) and are labelled as such; the deliverable is the "COUNT RESULT:"
# line: total measured ops parsed from the JMH log plus the derived
# freezes_per_op / top_thaws_per_op / starts_per_op.
#
# EXTRA_JVMARGS= : extra JVM args routed into the fork via -jvmArgsAppend
# (space-separated; e.g. EXTRA_JVMARGS="-agentpath:...=publish=jvmti" or
# "-Dvthread.trace.jvmAlloc=true" for ParkUnpark counting variants). Applies in
# every mode (default empty); in non-COUNT mode it is appended to ALL states so
# each state still differs only by flag/consumer.
#
# EVERY number this script prints is DIRECTIONAL and VM-only — NOT citable as an
# absolute overhead. The small warmup/iteration defaults exist solely to validate the
# orchestration on the VM (all three states start, bpftrace catches the forked child
# JVM, counters are non-zero).
#
# B-state attach is by libjvm FILE PATH (USDT), never `bpftrace -c PID`:
#   JMH `-f 2` forks a child JVM and runs the benchmark there; a PID-scoped `-c` probe
#   binds to the parent and would miss the child. Path attach catches the forked JVM
#   regardless of PID. We poll the bpftrace log for the BEGIN "tracing started" marker
#   before launching JMH (no bare sleep), and self-check the probes afterwards —
#   if the probes did not fire in the child we FAIL loudly rather than print a
#   fake good-looking number. The self-check is WORKLOAD-AWARE (see
#   check_probe_counts): transition/parkunpark assert all four probes fired
#   (@freeze_total/@thaw_total/@start_total/@end_total > 0, @end_unmatched == 0);
#   churn asserts only the lifecycle pair (@start_total > 0, @end_total > 0,
#   @start_total == @end_total, @end_unmatched == 0) because a legitimate churn
#   run may have @freeze_total == 0 — see the churn C−A paragraph above.
#
# Output files carry a <bench>-<timestamp> tag (never overwriting the old
# git-tracked fixed-name logs), and ALL stdout — including the RESULT:/
# "COUNT RESULT:" lines — is tee'd into the timestamped main log. A
# RUNINFO-<timestamp>.txt provenance record is written at startup
# (scripts/lib/runinfo.sh).
#
# Run as your normal user; only bpftrace uses sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/runinfo.sh
source "$SCRIPT_DIR/lib/runinfo.sh"

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

die() { echo "ERROR: $*" >&2; exit 1; }
print_cmd() { printf '  '; printf '%q ' "$@"; printf '\n'; }

# Workload selection. transition (the historical default) is CPU-dense and
# probe-heavy — best for exercising the orchestration; churn isolates the
# lifecycle probes; parkunpark is the blocking-handoff workload.
BENCH="${BENCH:-transition}"
case "$BENCH" in
    transition) BENCH_CLASS="uk.ac.ncl.jensen.benchmark.VThreadTransitionBenchmark" ;;
    churn)      BENCH_CLASS="uk.ac.ncl.jensen.benchmark.VThreadChurnBenchmark" ;;
    parkunpark) BENCH_CLASS="uk.ac.ncl.jensen.benchmark.VThreadParkUnparkBenchmark" ;;
    *) die "unknown BENCH='$BENCH' (expected transition | churn | parkunpark)" ;;
esac
CLASS="${CLASS:-$BENCH_CLASS}"

WI="${WI:-3}"                         # warmup iterations (small: VM orchestration check)
I="${I:-5}"                           # measurement iterations (small: VM orchestration check)
MI="${MI:-$I}"                        # COUNT-mode measurement iterations override
RUN_C="${RUN_C:-1}"                   # 1 = run C so publish residual / observation cost split
COUNT="${COUNT:-0}"                   # 1 = counters-only mode: B state only, -f 1 -wi 0
DRY_RUN="${DRY_RUN:-0}"               # 1 = print the states' commands and exit
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}" # seconds to wait for bpftrace USDT attach
EXTRA_JVMARGS="${EXTRA_JVMARGS:-}"    # extra fork args via -jvmArgsAppend (space-separated)

PROBES_BT="$REPO_ROOT/bpf/correlate-probesonly.bt"
SHADED_JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
JAR="$REPO_ROOT/target/benchmarks.jar"
OUT="$REPO_ROOT/result/benchmark/oslevel"
mkdir -p "$OUT"

# Timestamped output names (S5/GAP-5 fix): never overwrite the git-tracked
# fixed-name logs from earlier batches.
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ "$COUNT" == "1" ]]; then
    TAG="$BENCH-count-$STAMP"
else
    TAG="$BENCH-$STAMP"
fi
A_LOG="$OUT/A_baseline_flag_off-$TAG.log"
C_LOG="$OUT/C_publish_on_no_consumer-$TAG.log"
B_LOG="$OUT/B_observed_jmh-$TAG.log"
BT_LOG="$OUT/B_bpftrace-$TAG.log"
MAIN_LOG="$OUT/measure-oslevel-$TAG.log"
COUNT_FILE="$OUT/COUNT-$TAG.txt"

# Reused verbatim from run-usdt.sh.
score_num_from_log() {
    awk '/ avgt / { score = $5 } END { if (score != "") print score }' "$1"
}
count_from_log() {
    local map_name="$1"
    awk -v key="$map_name:" '$1 == key { value = $2 } END { if (value != "") print value; else print 0 }' "$2"
}

# COUNT mode: total measured ops from the JMH log. avgt prints one
# "Iteration   N: <score> us/op" line per measurement iteration (warmup lines
# carry a leading '#', and -wi 0 means there are none anyway); each iteration
# runs ~1s (@Measurement(time=1), all three benchmarks emit us/op), so
# ops/iter ≈ 1e6/score. The ±1 op/iter estimation error is irrelevant at
# counter-adjudication precision.
ops_from_log() {
    awk '$1 == "Iteration" { score = $3 + 0; if (score > 0) ops += int(1000000 / score + 0.5) }
         END { printf "%d\n", ops }' "$1"
}

# Check-only: never builds (do not touch pom/build per task). Hint the user instead.
ensure_jar() {
    if [[ ! -f "$JAR" ]]; then
        if [[ -f "$SHADED_JAR" ]]; then
            ln -sf "$(basename "$SHADED_JAR")" "$JAR"
        else
            die "JMH jar missing: $JAR (and no $SHADED_JAR). Build it first: 'source config/env.sh && mvn -q clean package' (or run scripts/run-usdt.sh once)."
        fi
    fi
}

require_runtime() {
    [[ -x "$JAVA" ]]   || die "java not executable: $JAVA"
    [[ -f "$LIBJVM" ]] || die "libjvm not found: $LIBJVM"
    [[ -f "$PROBES_BT" ]] || die "cropped bpftrace program not found: $PROBES_BT"
    command -v bpftrace >/dev/null 2>&1 || die "bpftrace not found"
}

ensure_jar
require_runtime

# All states share the SAME JMH invocation; states differ ONLY by the flag value
# and by whether bpftrace is attached. That keeps C-A a pure publish delta and B-C a pure
# observation delta. NOTE: -f 2 (forked), never -f 0. COUNT mode is the one sanctioned
# exception: -f 1 -wi 0, because it discards every time figure and only harvests counters
# (wi=0 keeps warmup invocations out of the counter totals).
#
# The flag is routed into the FORK via -jvmArgsAppend, NOT the host `java` line: the
# benchmarks declare @Fork(jvmArgs={...}), and JMH's @Fork(jvmArgs) REPLACES the forked
# JVM args, so -XX:+VThreadTraceProbes on the host java is silently dropped before the
# child that actually runs the benchmark ever sees it (verified: it never reached the
# fork, so every state measured publish-off — a fake ~0 residual). EXTRA_JVMARGS rides
# the same -jvmArgsAppend route for the same reason.
if [[ "$COUNT" == "1" ]]; then
    COMMON_JMH=(-jar "$JAR" "$CLASS" -f 1 -wi 0 -i "$MI")
else
    COMMON_JMH=(-jar "$JAR" "$CLASS" -f 2 -wi "$WI" -i "$I")
fi
EXTRA_APPEND=()
if [[ -n "$EXTRA_JVMARGS" ]]; then
    read -r -a _extra_args <<<"$EXTRA_JVMARGS"
    for _a in "${_extra_args[@]}"; do
        EXTRA_APPEND+=(-jvmArgsAppend "$_a")
    done
fi
A_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:-VThreadTraceProbes" ${EXTRA_APPEND[@]+"${EXTRA_APPEND[@]}"})
C_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:+VThreadTraceProbes" ${EXTRA_APPEND[@]+"${EXTRA_APPEND[@]}"})
B_CMD=("${C_CMD[@]}")   # B's JMH command is byte-for-byte identical to C.

# From here on, everything (including the final RESULT:/"COUNT RESULT:" lines)
# is archived in the timestamped main log (GAP-5 fix). DRY_RUN stays
# side-effect-free: no log, no RUNINFO.
if [[ "$DRY_RUN" != "1" ]]; then
    exec > >(tee "$MAIN_LOG") 2>&1
    RUNINFO_FILE="$(write_runinfo "$OUT" "measure-oslevel.sh" "$JAVA" \
        "BENCH=$BENCH" "CLASS=$CLASS" "COUNT=$COUNT" "WI=$WI" "I=$I" "MI=$MI" \
        "RUN_C=$RUN_C" "EXTRA_JVMARGS=$EXTRA_JVMARGS" "ATTACH_TIMEOUT=$ATTACH_TIMEOUT" \
        "JDK=$JDK" "JAVA=$JAVA" "LIBJVM=$LIBJVM" "OUT=$OUT" "TAG=$TAG")"
fi

echo "measure-oslevel: A/C/B OS-level observation overhead  (DIRECTIONAL, VM-only — not citable)"
echo "  C - A = publish residual (expected ~0);  B - C = observation cost"
echo
echo "JMH jar: $(readlink -f "$JAR" 2>/dev/null || echo "$JAR")"
echo "JDK:     $JDK"
echo "JAVA:    $JAVA"
echo "LIBJVM:  $LIBJVM"
echo "BENCH:   $BENCH"
echo "CLASS:   $CLASS"
if [[ "$COUNT" == "1" ]]; then
    echo "MODE:    COUNT MODE — time figures meaningless, counters only (B state only, -f 1 -wi 0 -i $MI)"
else
    echo "WI/I:    $WI / $I   (small — orchestration check only)"
fi
[[ -n "$EXTRA_JVMARGS" ]] && echo "EXTRA:   $EXTRA_JVMARGS   (via -jvmArgsAppend, all states)"
echo "OUT:     $OUT"
[[ "$DRY_RUN" != "1" ]] && echo "RUNINFO: $RUNINFO_FILE"
[[ "$DRY_RUN" != "1" ]] && echo "LOG:     $MAIN_LOG"
echo

if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$COUNT" == "1" ]]; then
        echo "DRY_RUN=1 — COUNT mode: only the B state would run; printing its command only."
        echo
        echo "B  observed   (flag ON, cropped bpftrace attached by libjvm PATH, then JMH -f 1 -wi 0):"
        print_cmd "${B_CMD[@]}"
        exit 0
    fi
    echo "DRY_RUN=1 — printing the three states' commands only; nothing is executed."
    echo
    echo "A  baseline   (flag OFF, no bpftrace):"
    print_cmd "${A_CMD[@]}"
    echo
    echo "C  publish-on (flag ON, no bpftrace / no consumer):"
    print_cmd "${C_CMD[@]}"
    echo
    echo "B  observed   (flag ON, cropped bpftrace attached by libjvm PATH, then identical JMH):"
    echo "  # 1) sed LIBJVM_PATH -> $LIBJVM into a temp copy of $PROBES_BT"
    echo "  # 2) launch in background (NO -c, NO PID scope):"
    echo "       sudo bpftrace <tmp.bt>   >\"$BT_LOG\" 2>&1 &"
    echo "  # 3) poll \"$BT_LOG\" for 'tracing started' (timeout ${ATTACH_TIMEOUT}s), then run the SAME JMH as C:"
    print_cmd "${B_CMD[@]}"
    echo "  # 4) SIGINT bpftrace so its END dumps @freeze_total / @thaw_total"
    echo
    echo "(no -f 0 anywhere; every state uses -f 2)"
    exit 0
fi

# --- B-state orchestration -------------------------------------------------------------
# Temp/state for the backgrounded bpftrace; cleaned up by the EXIT trap on any abort.
BT_TMP=""
stop_bpftrace() {
    # Tear down by the unique temp .bt path (it is in bpftrace's argv). This avoids a
    # root-written pidfile, which fails under root-squash filesystems (e.g. OrbStack /tmp,
    # where root sudo cannot write a user-owned mktemp file -> empty pidfile -> hang).
    [[ -n "$BT_TMP" ]] && sudo pkill -INT -f "$BT_TMP" 2>/dev/null || true
    [[ -n "$BT_TMP" ]] && rm -f "$BT_TMP"
    BT_TMP=""
}
trap stop_bpftrace EXIT

run_b() {
    # Prime sudo creds so the backgrounded bpftrace never blocks on a hidden prompt.
    # Avoid `sudo -v` (its general validation wants a password even when specific
    # commands are NOPASSWD); prefer the passwordless path, fall back to one interactive
    # prompt on the tty.
    sudo -n true 2>/dev/null || sudo true || die "sudo is required to attach bpftrace (configure NOPASSWD for bpftrace, or run 'sudo -v' first)"

    BT_TMP="$(mktemp "${TMPDIR:-/tmp}/correlate-probesonly.XXXXXX.bt")"
    # Path-scoped USDT: substitute the real libjvm so probes attach by file, not PID.
    sed "s#LIBJVM_PATH#${LIBJVM}#g" "$PROBES_BT" > "$BT_TMP"

    : > "$BT_LOG"
    sudo bpftrace "$BT_TMP" >"$BT_LOG" 2>&1 &
    local sudo_pid=$!

    # Wait for the BEGIN attach marker — never a bare sleep.
    local waited=0
    until grep -q "tracing started" "$BT_LOG" 2>/dev/null; do
        if [[ ! -e "/proc/$sudo_pid" ]]; then
            echo "----- bpftrace log -----" >&2; cat "$BT_LOG" >&2; echo "------------------------" >&2
            die "bpftrace exited before attaching to USDT in $LIBJVM"
        fi
        if (( waited >= ATTACH_TIMEOUT )); then
            echo "----- bpftrace log -----" >&2; cat "$BT_LOG" >&2; echo "------------------------" >&2
            die "timed out after ${ATTACH_TIMEOUT}s waiting for bpftrace to attach"
        fi
        sleep 1; ((++waited))
    done
    echo "  bpftrace attached after ${waited}s via libjvm path — no -c, no PID scope"
    echo

    # B's JMH == C's JMH; only difference from C is that bpftrace is attached.
    print_cmd "${B_CMD[@]}"
    "${B_CMD[@]}" | tee "$B_LOG"
    echo

    # SIGINT bpftrace (by its unique temp path) so END dumps the counters into BT_LOG;
    # wait for the flush before parsing.
    sudo pkill -INT -f "$BT_TMP" 2>/dev/null || true
    wait "$sudo_pid" 2>/dev/null || true
    rm -f "$BT_TMP"
    BT_TMP=""
}

if [[ "$COUNT" == "1" ]]; then
    echo "COUNT MODE — time figures meaningless, counters only. Skipping A and C."
    echo
else
    echo "A — baseline (flag off, no bpftrace)"
    print_cmd "${A_CMD[@]}"
    "${A_CMD[@]}" | tee "$A_LOG"
    echo

    if [[ "$RUN_C" == "1" ]]; then
        echo "C — publish-on (flag on, no consumer)"
        print_cmd "${C_CMD[@]}"
        "${C_CMD[@]}" | tee "$C_LOG"
        echo
    fi
fi

echo "B — observed (flag on, cropped bpftrace attached by libjvm path)"
run_b

# --- parse + self-check ----------------------------------------------------------------
FREEZE_TOTAL="$(count_from_log "@freeze_total" "$BT_LOG")"
THAW_TOTAL="$(count_from_log "@thaw_total" "$BT_LOG")"
THAW_TOP="$(count_from_log "@thaw_kind[0]" "$BT_LOG")"
START_TOTAL="$(count_from_log "@start_total" "$BT_LOG")"
END_TOTAL="$(count_from_log "@end_total" "$BT_LOG")"
END_UNMATCHED="$(count_from_log "@end_unmatched" "$BT_LOG")"

FAIL=0

# Workload-aware probe liveness self-check (BENCH-branched):
#   transition / parkunpark — both workloads block by construction (yield /
#   park unmounts), so all four probes MUST fire: the historical four-probe
#   assertion stands unchanged.
#   churn — the design prediction is that a churn vthread NEVER blocks
#   (body = Blackhole.consumeCPU(1)): start -> first mount (no thaw) -> end,
#   zero freezes. @freeze_total == 0 is therefore a LEGITIMATE outcome, and
#   keeping the @freeze_total>0 assertion would false-kill valid runs. Churn
#   liveness is asserted on the lifecycle pair instead (@start_total>0,
#   @end_total>0, @start_total==@end_total, @end_unmatched==0); @freeze_total
#   is recorded but NOT asserted — its actual value is the adjudication data
#   for the "pure isolation" prediction (see header).
check_probe_counts() {
    case "$BENCH" in
        churn)
            if [[ "${START_TOTAL:-0}" -le 0 || "${END_TOTAL:-0}" -le 0 ]]; then
                echo "FAIL: lifecycle probes did not fire in the forked JVM (@start_total=$START_TOTAL @end_total=$END_TOTAL)." >&2
                echo "      B is meaningless — likely the fork/attach pitfall. NOT emitting a fake number." >&2
                FAIL=1
            fi
            if [[ "${START_TOTAL:-0}" -ne "${END_TOTAL:-0}" ]]; then
                echo "FAIL: @start_total=$START_TOTAL != @end_total=$END_TOTAL (churn vthreads must pair start/end exactly — lifecycle leak or missed events)." >&2
                FAIL=1
            fi
            echo "  (churn self-check: @freeze_total=$FREEZE_TOTAL recorded, NOT asserted — zero is a legitimate no-blocking outcome)"
            ;;
        *)
            if [[ "${FREEZE_TOTAL:-0}" -le 0 || "${THAW_TOTAL:-0}" -le 0 || "${START_TOTAL:-0}" -le 0 || "${END_TOTAL:-0}" -le 0 ]]; then
                echo "FAIL: USDT probes did not fire in the forked JVM (@freeze_total=$FREEZE_TOTAL @thaw_total=$THAW_TOTAL @start_total=$START_TOTAL @end_total=$END_TOTAL)." >&2
                echo "      B is meaningless — likely the fork/attach pitfall. NOT emitting a fake number." >&2
                FAIL=1
            fi
            ;;
    esac
    if [[ "${END_UNMATCHED:-0}" -ne 0 ]]; then
        echo "FAIL: @end_unmatched=$END_UNMATCHED (expected 0 — tracer attached mid-lifetime, or a cache-protocol anomaly; see bpf/correlate.bt header)." >&2
        FAIL=1
    fi
}

if [[ "$COUNT" == "1" ]]; then
    check_probe_counts

    OPS="$(ops_from_log "$B_LOG")"
    if [[ "${OPS:-0}" -le 0 ]]; then
        echo "FAIL: could not parse any measured ops from $B_LOG (no 'Iteration N: <score> us/op' lines?)." >&2
        FAIL=1
    fi

    echo "============================================================"
    echo "COUNT MODE — time figures meaningless, counters only"
    echo "  ops estimated from avgt iteration scores (~±1 op per 1s iteration)"
    echo
    echo "  ops (measured iterations only, wi=0): ${OPS:-0}"
    echo "  @freeze_total=$FREEZE_TOTAL  @thaw_total=$THAW_TOTAL  @thaw_kind[0]=$THAW_TOP"
    echo "  @start_total=$START_TOTAL  @end_total=$END_TOTAL  @end_unmatched=$END_UNMATCHED"
    echo
    if [[ "${OPS:-0}" -gt 0 ]]; then
        FREEZES_PER_OP="$(awk -v n="$FREEZE_TOTAL" -v o="$OPS" 'BEGIN { printf "%.4f", n / o }')"
        TOP_THAWS_PER_OP="$(awk -v n="$THAW_TOP" -v o="$OPS" 'BEGIN { printf "%.4f", n / o }')"
        STARTS_PER_OP="$(awk -v n="$START_TOTAL" -v o="$OPS" 'BEGIN { printf "%.4f", n / o }')"
        COUNT_LINE="COUNT RESULT: bench=$BENCH class=$CLASS ops=$OPS freeze_total=$FREEZE_TOTAL thaw_total=$THAW_TOTAL thaw_top=$THAW_TOP start_total=$START_TOTAL end_total=$END_TOTAL end_unmatched=$END_UNMATCHED freezes_per_op=$FREEZES_PER_OP top_thaws_per_op=$TOP_THAWS_PER_OP starts_per_op=$STARTS_PER_OP extra_jvmargs='$EXTRA_JVMARGS'"
        echo "$COUNT_LINE"
        printf '%s\n' "$COUNT_LINE" > "$COUNT_FILE"
        echo "  (archived: $COUNT_FILE)"
    fi
    echo

    if [[ "$FAIL" != "0" ]]; then
        echo "RESULT: FAIL — see messages above; counters are not trustworthy." >&2
        exit 1
    fi
    echo "RESULT: OK — COUNT mode counters harvested (time figures meaningless by design)."
    exit 0
fi

A_SCORE="$(score_num_from_log "$A_LOG")"
B_SCORE="$(score_num_from_log "$B_LOG")"
C_SCORE=""

[[ -n "$A_SCORE" ]] || { echo "FAIL: could not parse A JMH score from $A_LOG" >&2; FAIL=1; }
[[ -n "$B_SCORE" ]] || { echo "FAIL: could not parse B JMH score from $B_LOG" >&2; FAIL=1; }
if [[ "$RUN_C" == "1" ]]; then
    C_SCORE="$(score_num_from_log "$C_LOG")"
    [[ -n "$C_SCORE" ]] || { echo "FAIL: could not parse C JMH score from $C_LOG" >&2; FAIL=1; }
fi
check_probe_counts

echo "============================================================"
echo "Summary — DIRECTIONAL, VM-only — NOT citable as absolute overhead"
echo "  C - A = publish residual (expected ~0);  B - C = observation cost"
echo
printf '  A  baseline   : %s us/op   (directional, VM-only — not citable)\n' "${A_SCORE:-?}"
[[ "$RUN_C" == "1" ]] && printf '  C  publish-on : %s us/op   (directional, VM-only — not citable)\n' "${C_SCORE:-?}"
printf '  B  observed   : %s us/op   (directional, VM-only — not citable)\n' "${B_SCORE:-?}"
echo
if [[ "$RUN_C" == "1" && -n "$A_SCORE" && -n "$C_SCORE" && -n "$B_SCORE" ]]; then
    PUB="$(awk -v a="$A_SCORE" -v c="$C_SCORE" 'BEGIN { printf "%.3f", c - a }')"
    OBS="$(awk -v c="$C_SCORE" -v b="$B_SCORE" 'BEGIN { printf "%.3f", b - c }')"
    printf '  C - A  publish residual : %s us/op   (directional, VM-only — not citable)\n' "$PUB"
    printf '  B - C  observation cost : %s us/op   (directional, VM-only — not citable)\n' "$OBS"
elif [[ -n "$A_SCORE" && -n "$B_SCORE" ]]; then
    BA="$(awk -v a="$A_SCORE" -v b="$B_SCORE" 'BEGIN { printf "%.3f", b - a }')"
    echo "  (RUN_C=0: cannot split publish vs observation)"
    printf '  B - A  publish+observe  : %s us/op   (directional, VM-only — not citable)\n' "$BA"
fi
echo
echo "  probe firings in forked JVM: @freeze_total=$FREEZE_TOTAL  @thaw_total=$THAW_TOTAL  @start_total=$START_TOTAL  @end_total=$END_TOTAL  @end_unmatched=$END_UNMATCHED"

if [[ "$FAIL" != "0" ]]; then
    echo
    echo "RESULT: FAIL — see messages above; any numbers shown are not trustworthy." >&2
    exit 1
fi
echo
echo "RESULT: OK — orchestration validated (probes fired in the -f 2 child). Still directional/VM-only."
