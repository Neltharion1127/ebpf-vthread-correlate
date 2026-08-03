#!/usr/bin/env bash
# measure-oslevel.sh — legacy A/C/B, deployed S0/S1/S2/S3, and COUNT orchestration.
#
# SEPARATE from run-usdt.sh (the "probe alive" acceptance script). This script does NOT
# modify bpf/correlate.bt, scripts/run-usdt.sh or scripts/profile-matrix.sh; it only
# consumes bpf/correlate-probesonly.bt (the cropped consumer).
#
# Three states — ALL run in forked JVMs (this cell only means anything under
# correct fork isolation; never -f 0):
#   A  baseline    : flag OFF, no bpftrace                  -> publish OFF, observe OFF
#   C  publish-on  : flag ON,  no bpftrace / no consumer    -> publish ON,  observe OFF
#   B  observed    : flag ON,  cropped bpftrace attached    -> publish ON,  observe ON
#
#   C - A = publish residual   (expected ~0: cost of emitting USDT with no consumer)
#   B - C = observation cost    (cost added by the eBPF consumer maintaining its maps)
#
# FACTORIAL=1 replaces the legacy three-state path with the self-contained deployed
# configuration grid used by formal batches:
#   S0  jvmAlloc=false, probes OFF, no consumer
#   S1  jvmAlloc=true,  probes OFF, no consumer
#   S2  jvmAlloc=true,  probes ON,  no consumer
#   S3  jvmAlloc=true,  probes ON,  probesonly consumer attached
# yielding S1-S0 allocation, S2-S1 buffered publication, S2-S0 total dormant,
# and S3-S2 observation.  S2/S3 have identical JVM commands by construction.
#
# BEHAVIOUR CHANGE (jmh-defaults spec): the non-COUNT path no longer injects an
# implicit `-f 2 -wi 3 -i 5`. F= / WI= / I= are now optional knobs — when UNSET,
# the corresponding -f/-wi/-i flag is NOT passed at all, so the formal statistical
# spec falls through to the JMH 1.37 built-in defaults (5 forks, warmup 5x10s,
# measurement 5x10s; see result/analysis/JMH-PARAMS.md). Set them explicitly only
# for special-purpose runs (e.g. quick orchestration checks or CI-tightening
# reruns with a recorded, deliberate spec). Rationale: formally cited oslevel
# numbers must come from the same default spec as the main matrix, eliminating
# deviation D7. The COUNT path is NOT affected (see below — correctness, not spec).
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
# the B state (flag on + probesonly consumer) with `-f 1 -wi 0 -r 1` — no warmup
# so warmup iterations cannot pollute the counters, single fork so the counter
# set maps to exactly one benchmark JVM, 1s iterations pinned (ops estimate
# depends on it). Correctness requirements — this hard-coded spec deliberately
# does NOT follow the jmh-defaults statistical spec. Measurement iterations stay at the default
# (or MI= overrides). ALL time figures in COUNT mode are meaningless (cold JVM,
# single fork) and are labelled as such; the deliverable is the "COUNT RESULT:"
# line: total measured ops parsed from the JMH log plus the derived
# freezes_per_op / top_thaws_per_op / starts_per_op.
#
# EXTRA_JVMARGS= : extra JVM args routed into the fork via -jvmArgsAppend
# (space-separated; e.g. EXTRA_JVMARGS="-agentpath:...=publish=jvmti" or
# "-Dvthread.trace.jvmAlloc=true" for ParkUnpark counting variants). Applies in
# legacy and COUNT modes (default empty); in legacy non-COUNT mode it is appended
# to ALL states so each state still differs only by flag/consumer. FACTORIAL=1
# owns its axes explicitly and rejects EXTRA_JVMARGS.
#
# On a VM, every number this script prints is DIRECTIONAL — NOT citable as an
# absolute overhead; citable numbers require bare metal AND the jmh-defaults spec
# (F/WI/I unset). Explicitly set F/WI/I mark a special-purpose run whose numbers
# are for orchestration checks or bound-tightening experiments, recorded as
# SPEC=custom in RUNINFO.
#
# Observed-state attach is by libjvm FILE PATH (USDT), never `bpftrace -c PID`:
#   JMH forking (`-f` >= 1) runs the benchmark in a child JVM; a PID-scoped `-c` probe
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

F="${F:-}"                            # forks; UNSET = do not pass -f (JMH default: 5)
WI="${WI:-}"                          # warmup iterations; UNSET = do not pass -wi (JMH default: 5x10s)
I="${I:-}"                            # measurement iterations; UNSET = do not pass -i (JMH default: 5x10s)
MI="${MI:-${I:-5}}"                   # COUNT-mode measurement iterations (COUNT always passes -i)
RUN_C="${RUN_C:-1}"                   # 1 = run C so publish residual / observation cost split
RUN_B="${RUN_B:-1}"                   # 0 = skip B (A/C only — publish pricing without a consumer;
                                      #     no probe self-check in that case, pair it with a COUNT run)
COUNT="${COUNT:-0}"                   # 1 = counters-only mode: B state only, -f 1 -wi 0
FACTORIAL="${FACTORIAL:-0}"           # 1 = formal S0/S1/S2/S3 alloc x probes x consumer run
DRY_RUN="${DRY_RUN:-0}"               # 1 = print the states' commands and exit
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}" # seconds to wait for bpftrace USDT attach
EXTRA_JVMARGS="${EXTRA_JVMARGS:-}"    # extra fork args via -jvmArgsAppend (space-separated)

if [[ "$COUNT" == "1" && "$FACTORIAL" == "1" ]]; then
    echo "ERROR: COUNT=1 and FACTORIAL=1 are mutually exclusive" >&2
    exit 1
fi
if [[ "$FACTORIAL" == "1" && -n "$EXTRA_JVMARGS" ]]; then
    echo "ERROR: FACTORIAL=1 owns the jvmAlloc/probes axes; EXTRA_JVMARGS must be empty" >&2
    exit 1
fi
if [[ "$FACTORIAL" == "1" && ( "$RUN_B" != "1" || "$RUN_C" != "1" ) ]]; then
    echo "ERROR: FACTORIAL=1 requires RUN_B=1 and RUN_C=1" >&2
    exit 1
fi

PROBES_BT="$REPO_ROOT/bpf/correlate-probesonly.bt"
SHADED_JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
JAR="$REPO_ROOT/target/benchmarks.jar"
OUT="${OUT:-$REPO_ROOT/result/benchmark/oslevel}"
BATCH_ID="${BATCH_ID:-standalone}"
mkdir -p "$OUT"

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
S0_LOG="$OUT/S0_both_off-$TAG.log"
S1_LOG="$OUT/S1_jvmalloc_probes_off-$TAG.log"
S2_LOG="$OUT/S2_both_on_no_consumer-$TAG.log"
S3_LOG="$OUT/S3_observed_real_buffer-$TAG.log"
S3_BT_LOG="$OUT/S3_bpftrace_real_buffer-$TAG.log"
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
# runs ~1s (pinned by -r 1 in the COUNT invocation, all three benchmarks emit
# us/op), so ops/iter ≈ 1e6/score. The ±1 op/iter estimation error is
# irrelevant at counter-adjudication precision.
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

[[ "$COUNT" == "1" && "$RUN_B" == "0" ]] && die "COUNT=1 runs ONLY the B state; RUN_B=0 contradicts it"

# All states share the SAME JMH invocation; states differ ONLY by the flag value
# and by whether bpftrace is attached. That keeps C-A a pure publish delta and B-C a pure
# observation delta. NOTE: forked JVMs always, never -f 0. -f/-wi/-i are injected only
# when F=/WI=/I= are explicitly set (unset = JMH built-in defaults govern; see header).
# COUNT mode is the one sanctioned exception with a HARD-CODED -f 1 -wi 0: correctness
# requirement, not a statistical-spec choice — it does NOT follow the jmh-defaults spec
# (wi=0 keeps warmup invocations out of the counter totals, single fork maps the counter
# set to exactly one benchmark JVM).
#
# The flag is routed into the FORK via -jvmArgsAppend, NOT the host `java` line: the
# benchmarks declare @Fork(jvmArgs={...}), and JMH's @Fork(jvmArgs) REPLACES the forked
# JVM args, so -XX:+VThreadTraceProbes on the host java is silently dropped before the
# child that actually runs the benchmark ever sees it (verified: it never reached the
# fork, so every state measured publish-off — a fake ~0 residual). EXTRA_JVMARGS rides
# the same -jvmArgsAppend route for the same reason.
if [[ "$COUNT" == "1" ]]; then
    # -r 1 pins the historical 1s measurement iterations explicitly: they used to
    # come from the (now removed) @Measurement(time=1) annotation, and ops_from_log's
    # ops-per-iteration estimate assumes ~1s iterations — without -r 1 the JMH 10s
    # default would silently inflate every *_per_op figure 10x.
    COMMON_JMH=(-jar "$JAR" "$CLASS" -f 1 -wi 0 -r 1 -i "$MI")
else
    COMMON_JMH=(-jar "$JAR" "$CLASS")
    [[ -n "$F" ]]  && COMMON_JMH+=(-f "$F")
    [[ -n "$WI" ]] && COMMON_JMH+=(-wi "$WI")
    [[ -n "$I" ]]  && COMMON_JMH+=(-i "$I")
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

# Self-contained deployed-configuration factorial.  jvmAlloc=false is explicit in
# S0 so the baseline never relies on an undocumented property default.  S2 and S3
# are byte-for-byte identical JVM commands; only bpftrace attachment differs.
S0_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:-VThreadTraceProbes" -jvmArgsAppend "-Dvthread.trace.jvmAlloc=false")
S1_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:-VThreadTraceProbes" -jvmArgsAppend "-Dvthread.trace.jvmAlloc=true")
S2_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:+VThreadTraceProbes" -jvmArgsAppend "-Dvthread.trace.jvmAlloc=true")
S3_CMD=("${S2_CMD[@]}")

OBS_CMD=("${B_CMD[@]}")
OBS_LOG="$B_LOG"
OBS_BT_LOG="$BT_LOG"
OBS_LABEL="B — observed (flag on, cropped bpftrace attached by libjvm path)"
if [[ "$FACTORIAL" == "1" ]]; then
    OBS_CMD=("${S3_CMD[@]}")
    OBS_LOG="$S3_LOG"
    OBS_BT_LOG="$S3_BT_LOG"
    OBS_LABEL="S3 — observed (jvmAlloc on, probes on, cropped bpftrace attached by libjvm path)"
fi

# From here on, everything (including the final RESULT:/"COUNT RESULT:" lines)
# is archived in the timestamped main log (GAP-5 fix). DRY_RUN stays
# side-effect-free: no log, no RUNINFO.
if [[ "$DRY_RUN" != "1" ]]; then
    exec > >(tee "$MAIN_LOG") 2>&1
    RUNINFO_FILE="$(write_runinfo "$OUT" "measure-oslevel.sh" "$JAVA" \
        "SPEC=$([[ -z "$F$WI$I" ]] && echo jmh-defaults || echo custom)" "F=$F" "WI=$WI" "I=$I" \
        "BATCH_ID=$BATCH_ID" "BENCH=$BENCH" "CLASS=$CLASS" "COUNT=$COUNT" "FACTORIAL=$FACTORIAL" "MI=$MI" \
        "RUN_C=$RUN_C" "RUN_B=$RUN_B" "EXTRA_JVMARGS=$EXTRA_JVMARGS" "ATTACH_TIMEOUT=$ATTACH_TIMEOUT" \
        "JDK=$JDK" "JAVA=$JAVA" "LIBJVM=$LIBJVM" "OUT=$OUT" "TAG=$TAG")"
fi

if [[ "$FACTORIAL" == "1" ]]; then
    echo "measure-oslevel: S0/S1/S2/S3 deployed-configuration factorial"
    echo "  S1-S0 = allocation; S2-S1 = buffered probe residual; S2-S0 = total dormant; S3-S2 = observation"
else
    echo "measure-oslevel: A/C/B OS-level observation overhead  (DIRECTIONAL, VM-only — not citable)"
    echo "  C - A = publish residual (expected ~0);  B - C = observation cost"
fi
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
    if [[ -z "$F$WI$I" ]]; then
        echo "SPEC:    jmh-defaults — no -f/-wi/-i passed (JMH 1.37: 5 forks, warmup 5x10s, measurement 5x10s)"
    else
        echo "SPEC:    custom — F='${F:-(default)}' WI='${WI:-(default)}' I='${I:-(default)}' (special-purpose run, not the formal spec)"
    fi
    [[ "$RUN_B" == "0" ]] && echo "RUN_B:   0   (A/C only — no observed state, no probe self-check this run)"
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
    if [[ "$FACTORIAL" == "1" ]]; then
        echo "DRY_RUN=1 — FACTORIAL mode; printing all four commands."
        echo
        echo "S0  both off (jvmAlloc=false, probes off, no bpftrace):"
        print_cmd "${S0_CMD[@]}"
        echo "S1  allocation only (jvmAlloc=true, probes off, no bpftrace):"
        print_cmd "${S1_CMD[@]}"
        echo "S2  deployed dormant (jvmAlloc=true, probes on, no bpftrace):"
        print_cmd "${S2_CMD[@]}"
        echo "S3  observed (same JVM command as S2, bpftrace attached):"
        print_cmd "${S3_CMD[@]}"
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
    echo "(no -f 0 anywhere; forked JVMs in every state — fork count from F= if set, else JMH default 5)"
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

    : > "$OBS_BT_LOG"
    sudo bpftrace "$BT_TMP" >"$OBS_BT_LOG" 2>&1 &
    local sudo_pid=$!

    # Wait for the BEGIN attach marker — never a bare sleep.
    local waited=0
    until grep -q "tracing started" "$OBS_BT_LOG" 2>/dev/null; do
        if [[ ! -e "/proc/$sudo_pid" ]]; then
            echo "----- bpftrace log -----" >&2; cat "$OBS_BT_LOG" >&2; echo "------------------------" >&2
            die "bpftrace exited before attaching to USDT in $LIBJVM"
        fi
        if (( waited >= ATTACH_TIMEOUT )); then
            echo "----- bpftrace log -----" >&2; cat "$OBS_BT_LOG" >&2; echo "------------------------" >&2
            die "timed out after ${ATTACH_TIMEOUT}s waiting for bpftrace to attach"
        fi
        sleep 1; ((++waited))
    done
    echo "  bpftrace attached after ${waited}s via libjvm path — no -c, no PID scope"
    echo

    # Legacy B == C; factorial S3 == S2.  Only bpftrace attachment differs.
    print_cmd "${OBS_CMD[@]}"
    "${OBS_CMD[@]}" | tee "$OBS_LOG"
    echo

    # SIGINT bpftrace (by its unique temp path) so END dumps the counters into OBS_BT_LOG;
    # wait for the flush before parsing.
    sudo pkill -INT -f "$BT_TMP" 2>/dev/null || true
    wait "$sudo_pid" 2>/dev/null || true
    rm -f "$BT_TMP"
    BT_TMP=""
}

if [[ "$COUNT" == "1" ]]; then
    echo "COUNT MODE — time figures meaningless, counters only. Skipping A and C."
    echo
elif [[ "$FACTORIAL" == "1" ]]; then
    echo "S0 — both off (jvmAlloc=false, probes off, no bpftrace)"
    print_cmd "${S0_CMD[@]}"
    "${S0_CMD[@]}" | tee "$S0_LOG"
    echo

    echo "S1 — allocation only (jvmAlloc=true, probes off, no bpftrace)"
    print_cmd "${S1_CMD[@]}"
    "${S1_CMD[@]}" | tee "$S1_LOG"
    echo

    echo "S2 — deployed dormant (jvmAlloc=true, probes on, no consumer)"
    print_cmd "${S2_CMD[@]}"
    "${S2_CMD[@]}" | tee "$S2_LOG"
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

if [[ "$RUN_B" == "1" ]]; then
    echo "$OBS_LABEL"
    run_b
fi

# --- parse + self-check ----------------------------------------------------------------
if [[ "$RUN_B" == "1" ]]; then
    FREEZE_TOTAL="$(count_from_log "@freeze_total" "$OBS_BT_LOG")"
    THAW_TOTAL="$(count_from_log "@thaw_total" "$OBS_BT_LOG")"
    THAW_TOP="$(count_from_log "@thaw_kind[0]" "$OBS_BT_LOG")"
    THAW_NULLBUF="$(count_from_log "@thaw_nullbuf" "$OBS_BT_LOG")"
    START_TOTAL="$(count_from_log "@start_total" "$OBS_BT_LOG")"
    END_TOTAL="$(count_from_log "@end_total" "$OBS_BT_LOG")"
    END_UNMATCHED="$(count_from_log "@end_unmatched" "$OBS_BT_LOG")"
    FREEZE_UNMATCHED="$(count_from_log "@freeze_unmatched" "$OBS_BT_LOG")"
    PINNED_TOTAL="$(count_from_log "@pinned_total" "$OBS_BT_LOG")"
else
    FREEZE_TOTAL=0; THAW_TOTAL=0; THAW_TOP=0; THAW_NULLBUF=0
    START_TOTAL=0; END_TOTAL=0; END_UNMATCHED=0; FREEZE_UNMATCHED=0; PINNED_TOTAL=0
fi

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
    if [[ "${FREEZE_UNMATCHED:-0}" -ne 0 ]]; then
        echo "FAIL: @freeze_unmatched=$FREEZE_UNMATCHED (expected 0)." >&2
        FAIL=1
    fi
    if [[ "${START_TOTAL:-0}" -ne "${END_TOTAL:-0}" ]]; then
        echo "FAIL: @start_total=$START_TOTAL != @end_total=$END_TOTAL (lifecycle probes must pair exactly)." >&2
        FAIL=1
    fi
    if [[ "${PINNED_TOTAL:-0}" -ne 0 ]]; then
        echo "FAIL: @pinned_total=$PINNED_TOTAL (expected 0 for the benchmark workloads)." >&2
        FAIL=1
    fi
}

require_vm_option() { # <log> <exact-token>
    local log="$1" token="$2" line
    line="$(grep -m1 '^# VM options:' "$log" 2>/dev/null || true)"
    if [[ -z "$line" || " $line " != *" $token "* ]]; then
        echo "FAIL: actual fork options in $log do not contain '$token': ${line:-(missing # VM options line)}" >&2
        FAIL=1
    fi
}

reject_vm_option() { # <log> <substring>
    local log="$1" token="$2" line
    line="$(grep -m1 '^# VM options:' "$log" 2>/dev/null || true)"
    if [[ "$line" == *"$token"* ]]; then
        echo "FAIL: actual fork options in $log unexpectedly contain '$token': $line" >&2
        FAIL=1
    fi
}

check_factorial_options() {
    require_vm_option "$S0_LOG" "-XX:-VThreadTraceProbes"
    require_vm_option "$S0_LOG" "-Dvthread.trace.jvmAlloc=false"
    require_vm_option "$S1_LOG" "-XX:-VThreadTraceProbes"
    require_vm_option "$S1_LOG" "-Dvthread.trace.jvmAlloc=true"
    require_vm_option "$S2_LOG" "-XX:+VThreadTraceProbes"
    require_vm_option "$S2_LOG" "-Dvthread.trace.jvmAlloc=true"
    require_vm_option "$S3_LOG" "-XX:+VThreadTraceProbes"
    require_vm_option "$S3_LOG" "-Dvthread.trace.jvmAlloc=true"
    for log in "$S0_LOG" "$S1_LOG" "$S2_LOG" "$S3_LOG"; do
        reject_vm_option "$log" "-agentpath:"
    done

    local s2_opts s3_opts
    s2_opts="$(grep -m1 '^# VM options:' "$S2_LOG" 2>/dev/null || true)"
    s3_opts="$(grep -m1 '^# VM options:' "$S3_LOG" 2>/dev/null || true)"
    if [[ -z "$s2_opts" || "$s2_opts" != "$s3_opts" ]]; then
        echo "FAIL: S2 and S3 actual fork options are not byte-for-byte identical" >&2
        echo "  S2: ${s2_opts:-(missing)}" >&2
        echo "  S3: ${s3_opts:-(missing)}" >&2
        FAIL=1
    fi
}

check_factorial_buffer() {
    case "$BENCH" in
        churn)
            echo "  buffer self-check: Churn has @thaw_total=$THAW_TOTAL; @thaw_nullbuf=$THAW_NULLBUF is vacuous and is NOT accepted as allocator proof"
            ;;
        *)
            if [[ "${THAW_TOTAL:-0}" -le 0 ]]; then
                echo "FAIL: factorial S3 produced no thaws; cannot prove a real trace buffer was observed." >&2
                FAIL=1
            elif [[ "${THAW_NULLBUF:-0}" -ne 0 ]]; then
                echo "FAIL: factorial S3 @thaw_nullbuf=$THAW_NULLBUF, expected 0 of @thaw_total=$THAW_TOTAL with jvmAlloc=true." >&2
                FAIL=1
            else
                echo "  buffer self-check: PASS — @thaw_nullbuf=0 of @thaw_total=$THAW_TOTAL"
            fi
            ;;
    esac
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
        COUNT_LINE="COUNT RESULT: bench=$BENCH class=$CLASS ops=$OPS freeze_total=$FREEZE_TOTAL thaw_total=$THAW_TOTAL thaw_top=$THAW_TOP thaw_nullbuf=$THAW_NULLBUF start_total=$START_TOTAL end_total=$END_TOTAL end_unmatched=$END_UNMATCHED freeze_unmatched=$FREEZE_UNMATCHED pinned_total=$PINNED_TOTAL freezes_per_op=$FREEZES_PER_OP top_thaws_per_op=$TOP_THAWS_PER_OP starts_per_op=$STARTS_PER_OP extra_jvmargs='$EXTRA_JVMARGS'"
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

if [[ "$FACTORIAL" == "1" ]]; then
    S0_SCORE="$(score_num_from_log "$S0_LOG")"
    S1_SCORE="$(score_num_from_log "$S1_LOG")"
    S2_SCORE="$(score_num_from_log "$S2_LOG")"
    S3_SCORE="$(score_num_from_log "$S3_LOG")"

    [[ -n "$S0_SCORE" ]] || { echo "FAIL: could not parse S0 JMH score from $S0_LOG" >&2; FAIL=1; }
    [[ -n "$S1_SCORE" ]] || { echo "FAIL: could not parse S1 JMH score from $S1_LOG" >&2; FAIL=1; }
    [[ -n "$S2_SCORE" ]] || { echo "FAIL: could not parse S2 JMH score from $S2_LOG" >&2; FAIL=1; }
    [[ -n "$S3_SCORE" ]] || { echo "FAIL: could not parse S3 JMH score from $S3_LOG" >&2; FAIL=1; }

    check_probe_counts
    check_factorial_options
    check_factorial_buffer

    echo "============================================================"
    echo "Factorial summary — all contrasts are same-run-set comparisons"
    echo
    printf '  S0 both off        : %s us/op\n' "${S0_SCORE:-?}"
    printf '  S1 allocation only : %s us/op\n' "${S1_SCORE:-?}"
    printf '  S2 deployed dormant: %s us/op\n' "${S2_SCORE:-?}"
    printf '  S3 observed        : %s us/op\n' "${S3_SCORE:-?}"
    echo
    if [[ -n "$S0_SCORE" && -n "$S1_SCORE" && -n "$S2_SCORE" && -n "$S3_SCORE" ]]; then
        ALLOC_COST="$(awk -v s0="$S0_SCORE" -v s1="$S1_SCORE" 'BEGIN { printf "%.3f", s1 - s0 }')"
        PROBE_RESIDUAL="$(awk -v s1="$S1_SCORE" -v s2="$S2_SCORE" 'BEGIN { printf "%.3f", s2 - s1 }')"
        TOTAL_DORMANT="$(awk -v s0="$S0_SCORE" -v s2="$S2_SCORE" 'BEGIN { printf "%.3f", s2 - s0 }')"
        OBS_COST="$(awk -v s2="$S2_SCORE" -v s3="$S3_SCORE" 'BEGIN { printf "%.3f", s3 - s2 }')"
        printf '  S1 - S0 allocation cost        : %s us/op\n' "$ALLOC_COST"
        printf '  S2 - S1 buffered probe residual: %s us/op\n' "$PROBE_RESIDUAL"
        printf '  S2 - S0 total dormant cost     : %s us/op\n' "$TOTAL_DORMANT"
        printf '  S3 - S2 observation cost       : %s us/op\n' "$OBS_COST"
    fi
    echo
    echo "  S3 counters: @freeze_total=$FREEZE_TOTAL  @thaw_total=$THAW_TOTAL  @thaw_nullbuf=$THAW_NULLBUF"
    echo "               @start_total=$START_TOTAL  @end_total=$END_TOTAL  @end_unmatched=$END_UNMATCHED"
    echo "               @freeze_unmatched=$FREEZE_UNMATCHED  @pinned_total=$PINNED_TOTAL"

    if [[ "$FAIL" != "0" ]]; then
        echo
        echo "FACTORIAL RESULT: FAIL — see messages above; do not use these contrasts." >&2
        exit 1
    fi
    echo
    echo "FACTORIAL RESULT: OK — four states completed, actual fork options verified, S3 counters harvested."
    exit 0
fi

A_SCORE="$(score_num_from_log "$A_LOG")"
B_SCORE=""
C_SCORE=""

[[ -n "$A_SCORE" ]] || { echo "FAIL: could not parse A JMH score from $A_LOG" >&2; FAIL=1; }
if [[ "$RUN_B" == "1" ]]; then
    B_SCORE="$(score_num_from_log "$B_LOG")"
    [[ -n "$B_SCORE" ]] || { echo "FAIL: could not parse B JMH score from $B_LOG" >&2; FAIL=1; }
fi
if [[ "$RUN_C" == "1" ]]; then
    C_SCORE="$(score_num_from_log "$C_LOG")"
    [[ -n "$C_SCORE" ]] || { echo "FAIL: could not parse C JMH score from $C_LOG" >&2; FAIL=1; }
fi
# Probe liveness self-check needs the B-state counters; with RUN_B=0 there is
# nothing to check (pair the run with a COUNT run for the counter evidence).
[[ "$RUN_B" == "1" ]] && check_probe_counts

echo "============================================================"
echo "Summary — DIRECTIONAL, VM-only — NOT citable as absolute overhead"
echo "  C - A = publish residual (expected ~0);  B - C = observation cost"
echo
printf '  A  baseline   : %s us/op   (directional, VM-only — not citable)\n' "${A_SCORE:-?}"
[[ "$RUN_C" == "1" ]] && printf '  C  publish-on : %s us/op   (directional, VM-only — not citable)\n' "${C_SCORE:-?}"
[[ "$RUN_B" == "1" ]] && printf '  B  observed   : %s us/op   (directional, VM-only — not citable)\n' "${B_SCORE:-?}"
echo
if [[ "$RUN_C" == "1" && -n "$A_SCORE" && -n "$C_SCORE" ]]; then
    PUB="$(awk -v a="$A_SCORE" -v c="$C_SCORE" 'BEGIN { printf "%.3f", c - a }')"
    printf '  C - A  publish residual : %s us/op   (directional, VM-only — not citable)\n' "$PUB"
fi
if [[ "$RUN_B" == "1" && "$RUN_C" == "1" && -n "$C_SCORE" && -n "$B_SCORE" ]]; then
    OBS="$(awk -v c="$C_SCORE" -v b="$B_SCORE" 'BEGIN { printf "%.3f", b - c }')"
    printf '  B - C  observation cost : %s us/op   (directional, VM-only — not citable)\n' "$OBS"
elif [[ "$RUN_B" == "1" && "$RUN_C" != "1" && -n "$A_SCORE" && -n "$B_SCORE" ]]; then
    BA="$(awk -v a="$A_SCORE" -v b="$B_SCORE" 'BEGIN { printf "%.3f", b - a }')"
    echo "  (RUN_C=0: cannot split publish vs observation)"
    printf '  B - A  publish+observe  : %s us/op   (directional, VM-only — not citable)\n' "$BA"
fi
echo
if [[ "$RUN_B" == "1" ]]; then
    echo "  probe firings in forked JVM: @freeze_total=$FREEZE_TOTAL  @thaw_total=$THAW_TOTAL  @start_total=$START_TOTAL  @end_total=$END_TOTAL  @end_unmatched=$END_UNMATCHED"
else
    echo "  (RUN_B=0: no observed state — no probe-firing counters this run)"
fi

if [[ "$FAIL" != "0" ]]; then
    echo
    echo "RESULT: FAIL — see messages above; any numbers shown are not trustworthy." >&2
    exit 1
fi
echo
if [[ "$RUN_B" == "1" ]]; then
    echo "RESULT: OK — orchestration validated (probes fired in the forked child JVM)."
else
    echo "RESULT: OK — A/C states completed (RUN_B=0: B skipped, no probe self-check — pair with a COUNT run). Still directional/VM-only."
fi
