#!/usr/bin/env bash
# Run the dual-channel vthread attribution correctness harness.
set -euo pipefail

usage() {
    echo "usage: $0 <4probe|2probe> <clean|leaky> [N] [M]" >&2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $# -ge 2 && $# -le 4 ]] || { usage; exit 2; }
VARIANT="$1"
MODE="$2"
N="${3:-16}"
M="${4:-8}"
case "$VARIANT" in
    4probe|2probe) ;;
    *) usage; exit 2 ;;
esac
case "$MODE" in
    clean|leaky) ;;
    *) usage; exit 2 ;;
esac
[[ "$N" =~ ^[0-9]+$ ]] && (( N >= 1 && N <= 512 )) || die "N must be in 1..512"
[[ "$M" =~ ^[0-9]+$ ]] && (( M >= 1 )) || die "M must be positive"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# This harness intentionally resolves the in-tree patched JDK build instead of
# falling back to a system JDK or an unrelated configured image.
if [[ -z "${JDK:-}" ]]; then
    shopt -s nullglob
    jdk_candidates=("$REPO_ROOT"/../jdk21u/build/*/images/jdk)
    shopt -u nullglob
    usable_jdks=()
    for candidate in "${jdk_candidates[@]}"; do
        [[ -x "$candidate/bin/java" && -x "$candidate/bin/javac" ]] && usable_jdks+=("$candidate")
    done
    if (( ${#usable_jdks[@]} != 1 )); then
        printf 'Found %d usable patched JDK builds under %s/../jdk21u/build; set JDK explicitly.\n' \
            "${#usable_jdks[@]}" "$REPO_ROOT" >&2
        printf '  %s\n' "${usable_jdks[@]}" >&2
        exit 1
    fi
    JDK="${usable_jdks[0]}"
fi

JAVA="$JDK/bin/java"
LIBJVM="$JDK/lib/server/libjvm.so"
JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
BT_SOURCE="$REPO_ROOT/bpf/harness-$VARIANT.bt"
RECONCILE="$SCRIPT_DIR/reconcile.py"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}"

[[ -x "$JAVA" ]] || die "java not executable: $JAVA"
[[ -x "$JDK/bin/javac" ]] || die "javac not executable: $JDK/bin/javac"
[[ -f "$LIBJVM" ]] || die "libjvm not found: $LIBJVM"
[[ -f "$BT_SOURCE" ]] || die "BPF consumer not found: $BT_SOURCE"
[[ -f "$RECONCILE" ]] || die "reconciler not found: $RECONCILE"
command -v mvn >/dev/null 2>&1 || die "mvn not found"
command -v bpftrace >/dev/null 2>&1 || die "bpftrace not found"
command -v sudo >/dev/null 2>&1 || die "sudo not found"

STAMP="$(date +%Y%m%d-%H%M%S-%N)"
RESULT_DIR="$REPO_ROOT/result/harness/$STAMP-$VARIANT-$MODE"
JAVA_LOG="$RESULT_DIR/java.log"
CONSUMER_LOG="$RESULT_DIR/consumer.log"
MANIFEST="$RESULT_DIR/manifest.csv"
SUMMARY="$RESULT_DIR/summary.json"
GO_FILE="$RESULT_DIR/go"
mkdir -p "$RESULT_DIR"

echo "Variant: $VARIANT"
echo "Mode:    $MODE"
echo "JDK:     $JDK"
echo "LIBJVM:  $LIBJVM"
echo "N/M:     $N/$M"
echo "Result:  $RESULT_DIR"
echo

echo "== compile harness with patched JDK =="
JAVA_HOME="$JDK" mvn -q -DskipTests package
[[ -f "$JAR" ]] || die "shaded runtime jar missing after build: $JAR"

BT_TMP=""
BT_PID=""
JAVA_PID=""

stop_bpftrace() {
    if [[ -n "$BT_PID" ]]; then
        sudo pkill -INT -f "$BT_TMP" 2>/dev/null || true
        wait "$BT_PID" 2>/dev/null || true
        BT_PID=""
    fi
}

cleanup() {
    if [[ -n "$JAVA_PID" ]] && kill -0 "$JAVA_PID" 2>/dev/null; then
        kill "$JAVA_PID" 2>/dev/null || true
        wait "$JAVA_PID" 2>/dev/null || true
    fi
    stop_bpftrace
    if [[ -n "$BT_TMP" ]]; then
        rm -f "$BT_TMP"
    fi
}
trap cleanup EXIT

echo "== start MarkerHarness (waiting for go file) =="
marker_args=("$N" "$M" "$RESULT_DIR")
if [[ "$MODE" == "leaky" ]]; then
    marker_args+=(--leaky-final-scope)
fi
"$JAVA" \
    --enable-preview \
    --enable-native-access=ALL-UNNAMED \
    --add-opens=java.base/java.io=ALL-UNNAMED \
    -XX:+VThreadTraceProbes \
    -Dvthread.trace.jvmAlloc=true \
    -cp "$JAR" \
    uk.ac.ncl.jensen.harness.MarkerHarness "${marker_args[@]}" \
    >"$JAVA_LOG" 2>&1 &
JAVA_PID=$!

startup_deadline=$((SECONDS + ATTACH_TIMEOUT))
TARGET_PID=""
MARKER_FD=""
while [[ -z "$TARGET_PID" || -z "$MARKER_FD" ]]; do
    TARGET_PID="$(awk -F= '$1 == "PID" { print $2; exit }' "$JAVA_LOG" 2>/dev/null || true)"
    MARKER_FD="$(awk -F= '$1 == "FD" { print $2; exit }' "$JAVA_LOG" 2>/dev/null || true)"
    if ! kill -0 "$JAVA_PID" 2>/dev/null; then
        cat "$JAVA_LOG" >&2
        die "MarkerHarness exited before publishing PID and fd"
    fi
    (( SECONDS < startup_deadline )) || { cat "$JAVA_LOG" >&2; die "timed out waiting for MarkerHarness PID/fd"; }
    [[ -n "$TARGET_PID" && -n "$MARKER_FD" ]] || sleep 0.1
done
[[ "$TARGET_PID" =~ ^[0-9]+$ && "$MARKER_FD" =~ ^[0-9]+$ ]] || die "invalid PID/fd in $JAVA_LOG"
[[ "$TARGET_PID" == "$JAVA_PID" ]] || die "reported JVM PID $TARGET_PID differs from launcher PID $JAVA_PID"
echo "  PID=$TARGET_PID fd=$MARKER_FD"

# Prime credentials before backgrounding sudo, where it cannot safely prompt.
sudo -n true 2>/dev/null || sudo true || die "sudo is required for bpftrace"

BT_TMP="$(mktemp "${TMPDIR:-/tmp}/vthread-harness.XXXXXX.bt")"
sed "s#LIBJVM_PATH#$LIBJVM#g" "$BT_SOURCE" > "$BT_TMP"
: > "$CONSUMER_LOG"

echo "== attach bpftrace =="
sudo bpftrace "$BT_TMP" "$TARGET_PID" "$MARKER_FD" >"$CONSUMER_LOG" 2>&1 &
BT_PID=$!

attach_deadline=$((SECONDS + ATTACH_TIMEOUT))
until grep -q "tracing started" "$CONSUMER_LOG" 2>/dev/null; do
    if ! kill -0 "$BT_PID" 2>/dev/null; then
        cat "$CONSUMER_LOG" >&2
        die "bpftrace exited before completing attachment"
    fi
    (( SECONDS < attach_deadline )) || { cat "$CONSUMER_LOG" >&2; die "timed out waiting for bpftrace attachment"; }
    sleep 0.1
done

echo "== release Java workload =="
touch "$GO_FILE"
set +e
wait "$JAVA_PID"
JAVA_RC=$?
set -e
JAVA_PID=""

# Let bpftrace's perf-event output drain, then use SIGINT so END runs.
sleep 1
stop_bpftrace

[[ -f "$MANIFEST" ]] || die "MarkerHarness did not create $MANIFEST"

echo "== reconcile =="
reconcile_args=("$MANIFEST" "$CONSUMER_LOG")
if [[ "$VARIANT" == "4probe" ]]; then
    reconcile_args+=(--expect-clean)
fi
set +e
python3 "$RECONCILE" "${reconcile_args[@]}" | tee "$RESULT_DIR/reconcile.log"
RECONCILE_RC=${PIPESTATUS[0]}
set -e

echo
echo "Archived:"
echo "  $MANIFEST"
echo "  $CONSUMER_LOG"
echo "  $SUMMARY"

if (( JAVA_RC != 0 )); then
    cat "$JAVA_LOG" >&2
    die "MarkerHarness exited with status $JAVA_RC"
fi
exit "$RECONCILE_RC"
