#!/usr/bin/env bash
# run-blindspot.sh — single-shot reproducer for the first-mount attribution
# blind spot. Compile BlindSpotRepro.java, attach blindspot.bt by libjvm FILE
# PATH (same convention as measure-oslevel.sh: poll for the BEGIN "tracing
# started" marker, never a bare sleep), run the Java reproducer, then SIGINT
# bpftrace so END dumps @freeze_total/@thaw_total for the probes-fired
# self-check.
#
# Usage: run-blindspot.sh [MainClass] [BtScript]
#   MainClass defaults to BlindSpotRepro (the verified first-mount repro);
#   pass MisattributionRepro for the stale-mapping/misattribution repro.
#   BtScript defaults to blindspot.bt (the recorded-defect baseline consumer);
#   pass blindspot-fixed.bt for the lifecycle-probe fix verification. The
#   script tag is part of the log file names.
#
# Env knobs (fix-verification additions; defaults preserve old behaviour):
#   TRACE_FLAG=off   omit -XX:+VThreadTraceProbes (flag-off regression run;
#                    the probes-fired self-check is skipped, zeros expected)
#   ALLOC_OPTS=...   buffer-allocation java option(s); default
#                    -Dvthread.trace.jvmAlloc=true, set to
#                    -agentpath:<libvthread_trace_agent.so> for the JVMTI
#                    allocation path
#
# Raw bpftrace output -> result/blindspot/blindspot-<MainClass>-<timestamp>.log
# Java stdout/stderr  -> result/blindspot/blindspot-<MainClass>-<timestamp>-java.log
#
# Run as your normal user; only bpftrace uses sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

MAIN_CLASS="${1:-BlindSpotRepro}"
[[ -f "$SCRIPT_DIR/$MAIN_CLASS.java" ]] || { echo "ERROR: no such reproducer: $SCRIPT_DIR/$MAIN_CLASS.java" >&2; exit 1; }
BT_NAME="${2:-blindspot.bt}"
[[ -f "$SCRIPT_DIR/$BT_NAME" ]] || { echo "ERROR: no such bpftrace script: $SCRIPT_DIR/$BT_NAME" >&2; exit 1; }
BT_TAG="${BT_NAME%.bt}"

# JDK resolution — same priority as run-usdt.sh / measure-oslevel.sh:
#   1. explicit JDK= on the command line wins
#   2. otherwise config/env.sh (setup.sh writes JDK; hand-written copies may
#      only export JAVA_HOME — accept that as the same thing)
#   3. neither -> fail loudly; never fall back to the system JDK (it lacks
#      -XX:+VThreadTraceProbes and would silently produce wrong data)
if [[ -z "${JDK:-}" && -f "$REPO_ROOT/config/env.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/config/env.sh"
fi
if [[ -z "${JDK:-}" && -n "${JAVA_HOME:-}" ]]; then
    JDK="$JAVA_HOME"
fi
if [[ -z "${JDK:-}" ]]; then
    echo "ERROR: no vthread-trace JDK configured." >&2
    echo "       Run ./setup.sh first, or pass one explicitly: JDK=/path/to/jdk $0" >&2
    exit 1
fi
JAVA="${JAVA:-$JDK/bin/java}"
JAVAC="${JAVAC:-$JDK/bin/javac}"
LIBJVM="${LIBJVM:-$JDK/lib/server/libjvm.so}"

BT_SRC="$SCRIPT_DIR/$BT_NAME"
OUT="$REPO_ROOT/result/blindspot"
CLASSES="$SCRIPT_DIR/classes"
STAMP="$(date +%Y%m%d-%H%M%S)"
BT_LOG="$OUT/blindspot-$MAIN_CLASS-$BT_TAG-$STAMP.log"
JAVA_LOG="$OUT/blindspot-$MAIN_CLASS-$BT_TAG-$STAMP-java.log"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -x "$JAVA" ]]   || die "java not executable: $JAVA"
[[ -x "$JAVAC" ]]  || die "javac not executable: $JAVAC"
[[ -f "$LIBJVM" ]] || die "libjvm not found: $LIBJVM"
[[ -f "$BT_SRC" ]] || die "bpftrace program not found: $BT_SRC"
command -v bpftrace >/dev/null 2>&1 || die "bpftrace not found"

mkdir -p "$OUT" "$CLASSES"

echo "JDK:    $JDK"
echo "LIBJVM: $LIBJVM"
echo "CLASS:  $MAIN_CLASS"
echo "BT:     $BT_NAME"
echo "OUT:    $BT_LOG"
echo

echo "== compile =="
"$JAVAC" -d "$CLASSES" "$SCRIPT_DIR/$MAIN_CLASS.java"

# --- bpftrace attach (path-scoped USDT, poll for BEGIN marker) ---------------
BT_TMP=""
BT_PID=""
stop_bpftrace() {
    [[ -n "$BT_TMP" ]] && sudo pkill -INT -f "$BT_TMP" 2>/dev/null || true
    [[ -n "$BT_PID" ]] && wait "$BT_PID" 2>/dev/null || true
    [[ -n "$BT_TMP" ]] && rm -f "$BT_TMP"
    BT_TMP=""; BT_PID=""
}
trap stop_bpftrace EXIT

# Prime sudo creds so the backgrounded bpftrace never blocks on a hidden prompt.
sudo -n true 2>/dev/null || sudo true || die "sudo required to attach bpftrace"

BT_TMP="$(mktemp "${TMPDIR:-/tmp}/blindspot.XXXXXX.bt")"
sed "s#LIBJVM_PATH#${LIBJVM}#g" "$BT_SRC" > "$BT_TMP"

echo "== attach bpftrace (by libjvm path) =="
: > "$BT_LOG"
sudo bpftrace "$BT_TMP" >"$BT_LOG" 2>&1 &
BT_PID=$!

waited=0
until grep -q "tracing started" "$BT_LOG" 2>/dev/null; do
    if [[ ! -e "/proc/$BT_PID" ]]; then
        echo "----- bpftrace log -----" >&2; cat "$BT_LOG" >&2; echo "------------------------" >&2
        die "bpftrace exited before attaching to USDT in $LIBJVM"
    fi
    if (( waited >= ATTACH_TIMEOUT )); then
        echo "----- bpftrace log -----" >&2; cat "$BT_LOG" >&2; echo "------------------------" >&2
        die "timed out after ${ATTACH_TIMEOUT}s waiting for bpftrace to attach"
    fi
    sleep 1; ((++waited))
done
echo "  bpftrace attached after ${waited}s"
echo

echo "== run reproducer =="
FLAG_OPTS=(-XX:+VThreadTraceProbes)
[[ "${TRACE_FLAG:-on}" == "off" ]] && FLAG_OPTS=()
ALLOC_OPTS="${ALLOC_OPTS:--Dvthread.trace.jvmAlloc=true}"
"$JAVA" ${FLAG_OPTS[@]+"${FLAG_OPTS[@]}"} $ALLOC_OPTS \
        -Djdk.virtualThreadScheduler.parallelism=1 \
        -cp "$CLASSES" "$MAIN_CLASS" 2>&1 | tee "$JAVA_LOG"
echo

# Give the perf buffer a moment to drain, then stop bpftrace (END dumps counters).
sleep 1
stop_bpftrace
trap - EXIT

echo "== raw bpftrace output ($BT_LOG) =="
cat "$BT_LOG"
echo

# Self-check (measure-oslevel.sh convention): probes must have fired.
# Skipped for TRACE_FLAG=off runs, whose whole point is all-zero counts.
if [[ "${TRACE_FLAG:-on}" == "off" ]]; then
    echo "NOTE: TRACE_FLAG=off — probes-fired self-check skipped (zero counts expected)"
else
    freeze_total="$(awk '$1 == "@freeze_total:" { v = $2 } END { print (v == "" ? 0 : v) }' "$BT_LOG")"
    thaw_total="$(awk '$1 == "@thaw_total:" { v = $2 } END { print (v == "" ? 0 : v) }' "$BT_LOG")"
    if [[ "${freeze_total:-0}" -le 0 || "${thaw_total:-0}" -le 0 ]]; then
        die "USDT probes did not fire (@freeze_total=$freeze_total @thaw_total=$thaw_total) — run is meaningless"
    fi
    echo "OK: probes fired (@freeze_total=$freeze_total @thaw_total=$thaw_total)"
fi
echo "Logs: $BT_LOG"
echo "      $JAVA_LOG"
