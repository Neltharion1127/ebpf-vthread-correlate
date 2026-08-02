#!/usr/bin/env bash
# run-batch.sh — the FORMAL batch definition, as code.
#
# Lesson from the 2026-07-05 bare-metal batch: the batch was launched as two ad-hoc
# commands (measure-oslevel.sh + profile-matrix.sh with default knobs), so every run
# that needed a NON-DEFAULT knob silently never happened — no Churn oslevel A/C
# (triage #16), no ParkUnpark COUNT runs (triage #11), no Transition N-sweep (GAP-9).
# This script IS the batch definition: the full run list with its knobs written down,
# executed in order, fail-fast (set -e), RUNINFO at the top, artifact inventory check
# against the built-in expected set at the bottom (missing items -> non-zero exit).
#
# Usage:
#   taskset -c <cpus> scripts/run-batch.sh       # full formal batch
#   BATCH_ID=<name> scripts/run-batch.sh         # explicit reproducible batch name
#   SKIP_MATRIX=1 scripts/run-batch.sh           # gap-fill batch without step 9
#   PREFLIGHT_ONLY=1 scripts/run-batch.sh         # check host; create no output
#
# Every step's knobs are hard-coded here on purpose; the comment on each step names
# the triage item (ANALYSIS-BAREMETAL.md §2 / v2 ANALYSIS.md §5a) it answers.
#
# SPEC=jmh-defaults: since the D3/D4/D5/D7 spec change, the matrix gc pass, the
# N-sweep and the oslevel A/C/B states all run on the JMH 1.37 built-in defaults
# (5 forks, warmup 5x10s, measurement 5x10s — no -f/-wi/-i injected anywhere;
# see result/analysis/JMH-PARAMS.md). Two deliberate exceptions, unchanged:
# COUNT mode (-f 1 -wi 0 -r 1, correctness) and the profiling pass (-f 1,
# attribution-only).
# PROF_EVENT=cpu on the formal batch: bare metal has PMU access, so the
# profiling pass uses perf-events sampling with KERNEL stacks — the attribution
# upgrade for observation cost (itimer was the VM-era compatibility compromise;
# the 20260705 batch's flame graphs are itimer, do not mix in differentials).
# Requires kernel.perf_event_paranoid<=1 and kernel.kptr_restrict=0 — checked
# up front below (fail-fast), set by scripts/env-bootstrap.sh.
# EXPECTED WALL TIME on this spec: roughly 5 hours for the full batch
# (12 matrix gc cells + 12 N-sweep cells at ~9 min each ≈ 3.5 h, oslevel
# Transition/Churn/ParkUnpark A/C/B at ~9 min per state ≈ 80 min, COUNT runs
# and the profiling pass add the rest) — versus ~1 h under the old reduced spec.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

[[ -f "$REPO_ROOT/config/env.sh" ]] || {
    echo "ERROR: config/env.sh missing — run ./setup.sh first (installs the vthread JDK + writes env.sh)." >&2
    exit 1
}
# shellcheck source=/dev/null
source "$REPO_ROOT/config/env.sh"
# shellcheck source=lib/runinfo.sh
source "$SCRIPT_DIR/lib/runinfo.sh"
# shellcheck source=lib/benchmark-preflight.sh
source "$SCRIPT_DIR/lib/benchmark-preflight.sh"

SKIP_MATRIX="${SKIP_MATRIX:-0}"
PROF_EVENT="${PROF_EVENT:-cpu}"   # formal batch = perf events w/ kernel stacks (see header)
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
BATCH_ID="${BATCH_ID:-$(date +%Y%m%d-%H%M%S)}"
[[ "$BATCH_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "ERROR: invalid BATCH_ID='$BATCH_ID' (use letters, digits, dot, underscore or hyphen)." >&2
    exit 1
}

# The preflight runs before creating output, so its dirty-tree check observes
# source state rather than the batch artifacts this script is about to create.
benchmark_preflight "$REPO_ROOT" "${JAVA_HOME}/bin/java" "$PROF_EVENT" "$SKIP_MATRIX"
if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
    echo "preflight-only mode: no batch directory created and no build or benchmark started"
    exit 0
fi

RESULTS_ROOT="$REPO_ROOT/result/benchmark"
BATCH_DIR="$RESULTS_ROOT/batches/$BATCH_ID"
OSLEVEL="$BATCH_DIR/oslevel"
NSWEEP_DIR="$BATCH_DIR/nsweep"
MATRIX_DIR="$BATCH_DIR/matrix"
COLLAPSED_DIR="$BATCH_DIR/collapsed"
FIGURES_DIR="$BATCH_DIR/figures"
BATCH_LOG="$BATCH_DIR/run-batch.log"

if [[ -e "$BATCH_DIR" ]]; then
    echo "ERROR: batch directory already exists; refusing to overwrite: $BATCH_DIR" >&2
    exit 1
fi
mkdir -p "$OSLEVEL" "$NSWEEP_DIR" "$MATRIX_DIR" "$COLLAPSED_DIR" "$FIGURES_DIR"

exec > >(tee "$BATCH_LOG") 2>&1

echo "run-batch: formal batch definition (BATCH_ID=$BATCH_ID, SKIP_MATRIX=$SKIP_MATRIX)"
RUNINFO_FILE="$(write_runinfo "$BATCH_DIR" "run-batch.sh" "${JAVA_HOME}/bin/java" \
    "SPEC=jmh-defaults" "PROF_EVENT=$PROF_EVENT" \
    "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)" \
    "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)" \
    "BATCH_ID=$BATCH_ID" "SKIP_MATRIX=$SKIP_MATRIX" "SOURCE_PREFLIGHT=passed" \
    "ALLOW_DIRTY=${ALLOW_DIRTY:-0}" "ALLOW_TURBO=${ALLOW_TURBO:-0}" \
    "REQUIRE_SMT_OFF=${REQUIRE_SMT_OFF:-0}" "REQUIRE_CPU_PINNING=${REQUIRE_CPU_PINNING:-0}" \
    "OSLEVEL=$OSLEVEL" "NSWEEP_DIR=$NSWEEP_DIR" "MATRIX_DIR=$MATRIX_DIR" \
    "COLLAPSED_DIR=$COLLAPSED_DIR" "FIGURES_DIR=$FIGURES_DIR" "BATCH_LOG=$BATCH_LOG")"
echo "RUNINFO: $RUNINFO_FILE"
echo "LOG:     $BATCH_LOG"
echo

step() { printf '\n\033[1m==== batch step %s ====\033[0m\n' "$*"; }

# Freeze the binaries before the first timing cell. profile-matrix.sh receives
# SKIP_BUILD=1 below, so no later step can silently switch to newer artifacts.
step "build (once, before every measurement)"
make -C "$REPO_ROOT/JVMTI-agent"
mvn -q clean package
JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
[[ -f "$AGENT_PATH" ]] || { echo "ERROR: agent build did not produce $AGENT_PATH" >&2; exit 1; }
[[ -f "$JAR" ]] || { echo "ERROR: Maven build did not produce $JAR" >&2; exit 1; }
ln -sfn "$(basename "$JAR")" "$REPO_ROOT/target/benchmarks.jar"
sha256sum "$AGENT_PATH" "$JAR" > "$BATCH_DIR/build-artifacts.sha256"

MARKER="$(mktemp "${TMPDIR:-/tmp}/run-batch-marker.XXXXXX")"
trap 'rm -f "$MARKER"' EXIT

# 1. Transition A/C/B — publish residual.
#    Also the ENVIRONMENT SENTINEL for gap-fill runs: compare this A/C against the
#    main batch's A/C — CI overlap means same-batch-comparable, non-overlap means
#    the gap-fill data must be labelled a separate batch.
step "1/9 oslevel Transition A/C/B (publish residual, observation cost, sentinel)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" "$SCRIPT_DIR/measure-oslevel.sh"

# 2. Churn A/C/B — lifecycle publish pricing plus observation cost. COUNT in
#    step 3 remains separate correctness evidence and is never used as timing.
step "2/9 oslevel Churn A/C/B (lifecycle publish and observation cost)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" BENCH=churn "$SCRIPT_DIR/measure-oslevel.sh"

# 3. Churn COUNT — pure-isolation precondition, @freeze_total MUST be 0
#    (churn vthreads never block by design), asserted workload-aware (lifecycle
#    pair only; freeze_total recorded, not asserted — its value IS the verdict).
step "3/9 oslevel Churn COUNT (precondition: freeze_total == 0)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" BENCH=churn COUNT=1 "$SCRIPT_DIR/measure-oslevel.sh"

# 4. ParkUnpark A/C/B — realistic blocking workload dormancy gradient.
step "4/9 oslevel ParkUnpark A/C/B (blocking publish and observation cost)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" BENCH=parkunpark "$SCRIPT_DIR/measure-oslevel.sh"

# 5-7. ParkUnpark COUNT x 3 variants — TRUE per-op denominators (alloc-axis
#    adjudication needs freezes_per_op per variant; VM showed ~9% variant drift).
step "5/9 oslevel ParkUnpark COUNT, baseline (true denominator)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" COUNT=1 BENCH=parkunpark "$SCRIPT_DIR/measure-oslevel.sh"

step "6/9 oslevel ParkUnpark COUNT, publish=jvmti (true denominator)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" COUNT=1 BENCH=parkunpark EXTRA_JVMARGS="-agentpath:$AGENT_PATH=publish=jvmti" \
    "$SCRIPT_DIR/measure-oslevel.sh"

step "7/9 oslevel ParkUnpark COUNT, jvmAlloc (true denominator)"
OUT="$OSLEVEL" BATCH_ID="$BATCH_ID" COUNT=1 BENCH=parkunpark EXTRA_JVMARGS="-Dvthread.trace.jvmAlloc=true" \
    "$SCRIPT_DIR/measure-oslevel.sh"

# 8. Transition N-sweep — per-yield convergence curve, both axes from the gc pass.
#    QUICK=1: no profiling pass and no flamegraphs. Its batch subdirectory is
#    separate from the main matrix by construction.
step "8/9 Transition N-sweep, gc pass only (convergence curve)"
SKIP_BUILD=1 BATCH_ID="$BATCH_ID" NPARAM="yieldsPerVthread=1000,10000,100000" ONLY="Transition" QUICK=1 \
    RESULTS="$NSWEEP_DIR" "$SCRIPT_DIR/profile-matrix.sh"

# 9. Full 12-cell matrix (gc + profiling pass [event=$PROF_EVENT] + flamegraphs)
#    — the main tables. LAST so a late failure cannot cost the cheap runs above.
#    Every output is scoped below this batch directory; an existing BATCH_ID is
#    rejected before any work, so previous formal results cannot be overwritten.
if [[ "$SKIP_MATRIX" != "1" ]]; then
    step "9/9 full 12-cell matrix (main tables, PROF_EVENT=$PROF_EVENT)"
    SKIP_BUILD=1 BATCH_ID="$BATCH_ID" PROF_EVENT="$PROF_EVENT" RESULTS="$MATRIX_DIR" \
        PROF_DIR="$COLLAPSED_DIR" OUT_DIR="$FIGURES_DIR" "$SCRIPT_DIR/profile-matrix.sh"
else
    step "9/9 full 12-cell matrix — SKIPPED (SKIP_MATRIX=1)"
fi

# ---- artifact inventory vs the built-in expected set -----------------------------------
step "inventory check"
MISSING=()

# newest file matching glob that is newer than the batch marker AND (optionally)
# contains the required line
have() { # <glob...> -- [required-grep]
    local pats=() pat="" f
    while [[ $# -gt 0 && "$1" != "--" ]]; do pats+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && { shift; pat="${1:-}"; }
    for f in "${pats[@]}"; do
        [[ -f "$f" && "$f" -nt "$MARKER" ]] || continue
        if [[ -z "$pat" ]] || grep -q "$pat" "$f"; then return 0; fi
    done
    return 1
}
expect() { # <desc> <have-args...>
    local desc="$1"; shift
    if have "$@"; then echo "  [OK]      $desc"; else echo "  [MISSING] $desc"; MISSING+=("$desc"); fi
}

expect "1 Transition A/C/B includes B-C (sentinel)" \
    "$OSLEVEL"/measure-oslevel-transition-*.log -- "B - C  observation cost"
expect "2 Churn A/C/B includes B-C" \
    "$OSLEVEL"/measure-oslevel-churn-2*.log -- "B - C  observation cost"
expect "3 Churn COUNT line (freeze_total precondition)" \
    "$OSLEVEL"/COUNT-churn-count-*.txt -- "freeze_total="
expect "4 ParkUnpark A/C/B includes B-C" \
    "$OSLEVEL"/measure-oslevel-parkunpark-2*.log -- "B - C  observation cost"
expect "5 ParkUnpark COUNT baseline" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "extra_jvmargs=''"
expect "6 ParkUnpark COUNT publish=jvmti" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "publish=jvmti"
expect "7 ParkUnpark COUNT jvmAlloc" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "jvmAlloc"
for v in baseline agent jvmtipublish jvmalloc; do
    expect "8 N-sweep gc JSON: Transition/$v" \
        "$NSWEEP_DIR/VThreadTransitionBenchmark_${v}_gc.json"
done
if [[ "$SKIP_MATRIX" != "1" ]]; then
    for f in VThreadTransitionBenchmark_{baseline,agent,jvmtipublish,jvmalloc} \
             VThreadParkUnparkBenchmark_{baseline,agent,jvmtipublish,jvmalloc} \
             VThreadChurnBenchmark_{baseline,agent,jvmtipublish,jvmalloc}; do
        expect "9 matrix gc JSON: $f" "$MATRIX_DIR/${f}_gc.json"
    done
fi

echo
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "run-batch RESULT: INCOMPLETE — ${#MISSING[@]} expected artifact(s) missing (listed above)."
    exit 1
fi
echo "run-batch RESULT: OK — expected artifact set complete."
echo "  batch id : $BATCH_ID"
echo "  batch dir: $BATCH_DIR"
echo "  batch log: $BATCH_LOG"
