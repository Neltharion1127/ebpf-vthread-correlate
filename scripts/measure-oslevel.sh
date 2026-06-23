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
# EVERY number this script prints is DIRECTIONAL and VM-only — NOT citable as an
# absolute overhead. The small warmup/iteration defaults exist solely to validate the
# orchestration on the VM (all three states start, bpftrace catches the forked child
# JVM, counters are non-zero).
#
# B-state attach is by libjvm FILE PATH (USDT), never `bpftrace -c PID`:
#   JMH `-f 2` forks a child JVM and runs the benchmark there; a PID-scoped `-c` probe
#   binds to the parent and would miss the child. Path attach catches the forked JVM
#   regardless of PID. We poll the bpftrace log for the BEGIN "tracing started" marker
#   before launching JMH (no bare sleep), and self-check @freeze_total/@thaw_total > 0
#   afterwards — if the probes did not fire in the child we FAIL loudly rather than
#   print a fake good-looking number.
#
# Run as your normal user; only bpftrace uses sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Reuse run-usdt.sh conventions: release-flag JDK that has -XX:+VThreadTraceProbes.
JDK="${JDK:-/home/jie/csc8499/jdk21u/build/release-flag/images/jdk}"
JAVA="${JAVA:-$JDK/bin/java}"
LIBJVM="${LIBJVM:-$JDK/lib/server/libjvm.so}"

# CPU-dense, probe-heavy benchmark — best for exercising the orchestration.
CLASS="${CLASS:-uk.ac.ncl.jensen.benchmark.VThreadTransitionBenchmark}"

WI="${WI:-3}"                         # warmup iterations (small: VM orchestration check)
I="${I:-5}"                           # measurement iterations (small: VM orchestration check)
RUN_C="${RUN_C:-1}"                   # 1 = run C so publish residual / observation cost split
DRY_RUN="${DRY_RUN:-0}"               # 1 = print the three states' commands and exit
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}" # seconds to wait for bpftrace USDT attach

PROBES_BT="$REPO_ROOT/bpf/correlate-probesonly.bt"
SHADED_JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
JAR="$REPO_ROOT/target/benchmarks.jar"
OUT="$REPO_ROOT/result/benchmark/oslevel"
mkdir -p "$OUT"

A_LOG="$OUT/A_baseline_flag_off.log"
C_LOG="$OUT/C_publish_on_no_consumer.log"
B_LOG="$OUT/B_observed_jmh.log"
BT_LOG="$OUT/B_bpftrace.log"

die() { echo "ERROR: $*" >&2; exit 1; }
print_cmd() { printf '  '; printf '%q ' "$@"; printf '\n'; }

# Reused verbatim from run-usdt.sh.
score_num_from_log() {
    awk '/ avgt / { score = $5 } END { if (score != "") print score }' "$1"
}
count_from_log() {
    local map_name="$1"
    awk -v key="$map_name:" '$1 == key { value = $2 } END { if (value != "") print value; else print 0 }' "$2"
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

# All three states share the SAME JMH invocation; states differ ONLY by the flag value
# and by whether bpftrace is attached. That keeps C-A a pure publish delta and B-C a pure
# observation delta. NOTE: -f 2 (forked), never -f 0.
#
# The flag is routed into the FORK via -jvmArgsAppend, NOT the host `java` line: the
# benchmarks declare @Fork(jvmArgs={...}), and JMH's @Fork(jvmArgs) REPLACES the forked
# JVM args, so -XX:+VThreadTraceProbes on the host java is silently dropped before the
# child that actually runs the benchmark ever sees it (verified: it never reached the
# fork, so every state measured publish-off — a fake ~0 residual).
COMMON_JMH=(-jar "$JAR" "$CLASS" -f 2 -wi "$WI" -i "$I")
A_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:-VThreadTraceProbes")
C_CMD=("$JAVA" "${COMMON_JMH[@]}" -jvmArgsAppend "-XX:+VThreadTraceProbes")
B_CMD=("${C_CMD[@]}")   # B's JMH command is byte-for-byte identical to C.

echo "measure-oslevel: A/C/B OS-level observation overhead  (DIRECTIONAL, VM-only — not citable)"
echo "  C - A = publish residual (expected ~0);  B - C = observation cost"
echo
echo "JMH jar: $(readlink -f "$JAR" 2>/dev/null || echo "$JAR")"
echo "JDK:     $JDK"
echo "JAVA:    $JAVA"
echo "LIBJVM:  $LIBJVM"
echo "CLASS:   $CLASS"
echo "WI/I:    $WI / $I   (small — orchestration check only)"
echo "OUT:     $OUT"
echo

if [[ "$DRY_RUN" == "1" ]]; then
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

echo "B — observed (flag on, cropped bpftrace attached by libjvm path)"
run_b

# --- parse + self-check ----------------------------------------------------------------
A_SCORE="$(score_num_from_log "$A_LOG")"
B_SCORE="$(score_num_from_log "$B_LOG")"
FREEZE_TOTAL="$(count_from_log "@freeze_total" "$BT_LOG")"
THAW_TOTAL="$(count_from_log "@thaw_total" "$BT_LOG")"
C_SCORE=""

FAIL=0
[[ -n "$A_SCORE" ]] || { echo "FAIL: could not parse A JMH score from $A_LOG" >&2; FAIL=1; }
[[ -n "$B_SCORE" ]] || { echo "FAIL: could not parse B JMH score from $B_LOG" >&2; FAIL=1; }
if [[ "$RUN_C" == "1" ]]; then
    C_SCORE="$(score_num_from_log "$C_LOG")"
    [[ -n "$C_SCORE" ]] || { echo "FAIL: could not parse C JMH score from $C_LOG" >&2; FAIL=1; }
fi
if [[ "${FREEZE_TOTAL:-0}" -le 0 || "${THAW_TOTAL:-0}" -le 0 ]]; then
    echo "FAIL: USDT probes did not fire in the forked JVM (@freeze_total=$FREEZE_TOTAL @thaw_total=$THAW_TOTAL)." >&2
    echo "      B is meaningless — likely the fork/attach pitfall. NOT emitting a fake number." >&2
    FAIL=1
fi

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
echo "  probe firings in forked JVM: @freeze_total=$FREEZE_TOTAL  @thaw_total=$THAW_TOTAL"

if [[ "$FAIL" != "0" ]]; then
    echo
    echo "RESULT: FAIL — see messages above; any numbers shown are not trustworthy." >&2
    exit 1
fi
echo
echo "RESULT: OK — orchestration validated (probes fired in the -f 2 child). Still directional/VM-only."
