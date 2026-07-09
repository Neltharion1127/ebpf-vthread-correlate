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
#   scripts/run-batch.sh                  # full formal batch (matrix included, LAST)
#   SKIP_MATRIX=1 scripts/run-batch.sh    # gap-fill mode: everything except the
#                                         # 10-cell matrix (use when the matrix of the
#                                         # current batch already exists — the matrix
#                                         # pass OVERWRITES the fixed-name gc JSONs /
#                                         # collapsed CSVs by convention)
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
# EXPECTED WALL TIME on this spec: roughly 4-5 hours for the full batch
# (10 matrix gc cells + 12 N-sweep cells at ~9 min each ≈ 3.5 h, oslevel
# Transition/Churn A/C/B at ~9 min per state ≈ 45 min, COUNT runs and the
# profiling pass add the rest) — versus ~1 h under the old reduced spec.
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

SKIP_MATRIX="${SKIP_MATRIX:-0}"
PROF_EVENT="${PROF_EVENT:-cpu}"   # formal batch = perf events w/ kernel stacks (see header)

# Fail fast at batch start, not 4 hours in at step 8: PROF_EVENT=cpu needs the
# perf sysctls (same privilege context as bpftrace's sudo).
if [[ "$PROF_EVENT" == cpu && "$SKIP_MATRIX" != "1" ]]; then
    _paranoid="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
    _kptr="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)"
    if ! [[ "$_paranoid" =~ ^-?[0-9]+$ ]] || (( _paranoid > 1 )) || [[ "$_kptr" != 0 ]]; then
        echo "ERROR: PROF_EVENT=cpu needs kernel.perf_event_paranoid<=1 (now: $_paranoid) and kernel.kptr_restrict=0 (now: $_kptr)." >&2
        echo "       sudo sysctl -w kernel.perf_event_paranoid=1 kernel.kptr_restrict=0   (scripts/env-bootstrap.sh does this)" >&2
        exit 1
    fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS="$REPO_ROOT/result/benchmark"
OSLEVEL="$RESULTS/oslevel"
NSWEEP_DIR="$RESULTS/nsweep-$STAMP"     # N-sweep gc JSONs go to their OWN dir so the
                                        # main batch's fixed-name Transition JSONs are
                                        # never overwritten by a gap-fill run.
BATCH_LOG="$RESULTS/run-batch-$STAMP.log"
MARKER="$(mktemp "${TMPDIR:-/tmp}/run-batch-marker.XXXXXX")"
trap 'rm -f "$MARKER"' EXIT
mkdir -p "$RESULTS" "$OSLEVEL"

exec > >(tee "$BATCH_LOG") 2>&1

echo "run-batch: formal batch definition (SKIP_MATRIX=$SKIP_MATRIX)"
RUNINFO_FILE="$(write_runinfo "$RESULTS" "run-batch.sh" "${JAVA_HOME}/bin/java" \
    "SPEC=jmh-defaults" "PROF_EVENT=$PROF_EVENT" \
    "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)" \
    "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)" \
    "SKIP_MATRIX=$SKIP_MATRIX" "STAMP=$STAMP" "NSWEEP_DIR=$NSWEEP_DIR" "BATCH_LOG=$BATCH_LOG")"
echo "RUNINFO: $RUNINFO_FILE"
echo "LOG:     $BATCH_LOG"
echo

# The publish/jvmalloc COUNT variants (steps 5/6) need the agent .so at fork time.
[[ -f "$AGENT_PATH" ]] || make -C "$REPO_ROOT/JVMTI-agent"

step() { printf '\n\033[1m==== batch step %s ====\033[0m\n' "$*"; }

# 1. Transition A/C/B — publish residual.
#    Also the ENVIRONMENT SENTINEL for gap-fill runs: compare this A/C against the
#    main batch's A/C — CI overlap means same-batch-comparable, non-overlap means
#    the gap-fill data must be labelled a separate batch.
step "1/8 oslevel Transition A/C/B  (#13 publish residual, #14 observation cost, sentinel)"
"$SCRIPT_DIR/measure-oslevel.sh"

# 2. Churn A/C, no B — DIRECT lifecycle-probe pricing, per-vthread (#16: the
#    upstream flag-on cost number). B is skipped: no consumer needed to price
#    publish; counter evidence comes from step 3 instead.
step "2/8 oslevel Churn A/C (RUN_B=0)  (#16 lifecycle probe flag-on pricing)"
BENCH=churn RUN_B=0 "$SCRIPT_DIR/measure-oslevel.sh"

# 3. Churn COUNT — pure-isolation precondition, @freeze_total MUST be 0
#    (churn vthreads never block by design), asserted workload-aware (lifecycle
#    pair only; freeze_total recorded, not asserted — its value IS the verdict).
step "3/8 oslevel Churn COUNT  (#16 precondition: freeze_total == 0)"
BENCH=churn COUNT=1 "$SCRIPT_DIR/measure-oslevel.sh"

# 4-6. ParkUnpark COUNT x 3 variants — TRUE per-op denominators ( alloc-axis
#    adjudication needs freezes_per_op per variant; VM showed ~9% variant drift).
step "4/8 oslevel ParkUnpark COUNT, baseline  (#11 true denominator)"
COUNT=1 BENCH=parkunpark "$SCRIPT_DIR/measure-oslevel.sh"

step "5/8 oslevel ParkUnpark COUNT, publish=jvmti  (#11 true denominator)"
COUNT=1 BENCH=parkunpark EXTRA_JVMARGS="-agentpath:$AGENT_PATH=publish=jvmti" \
    "$SCRIPT_DIR/measure-oslevel.sh"

step "6/8 oslevel ParkUnpark COUNT, jvmAlloc  (#11 true denominator)"
COUNT=1 BENCH=parkunpark EXTRA_JVMARGS="-Dvthread.trace.jvmAlloc=true" \
    "$SCRIPT_DIR/measure-oslevel.sh"

# 7. Transition N-sweep — per-yield convergence curve, both axes from the gc pass.
#    QUICK=1: no profiling pass, no flamegraphs. RESULTS redirected so the main
#    batch's fixed-name Transition JSONs are not overwritten.
step "7/8 Transition N-sweep, gc pass only  (GAP-9 convergence curve)"
NPARAM="yieldsPerVthread=1000,10000,100000" ONLY="Transition" QUICK=1 \
    RESULTS="$NSWEEP_DIR" "$SCRIPT_DIR/profile-matrix.sh"

# 8. Full 10-cell matrix (gc + profiling pass [event=$PROF_EVENT] + flamegraphs)
#    — the main tables. LAST so a late failure cannot cost the cheap runs above.
#    NOTE: overwrites the fixed-name gc JSONs / collapsed CSVs — that is the
#    formal-batch convention; use SKIP_MATRIX=1 for gap-fill runs on a batch
#    whose matrix already exists.
if [[ "$SKIP_MATRIX" != "1" ]]; then
    step "8/8 full 10-cell matrix  (main tables, PROF_EVENT=$PROF_EVENT)"
    PROF_EVENT="$PROF_EVENT" "$SCRIPT_DIR/profile-matrix.sh"
else
    step "8/8 full 10-cell matrix — SKIPPED (SKIP_MATRIX=1)"
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

expect "1 Transition A/C/B RESULT: OK (#13/#14, sentinel)" \
    "$OSLEVEL"/measure-oslevel-transition-*.log -- "RESULT: OK"
expect "2 Churn A/C RESULT: OK (#16)" \
    "$OSLEVEL"/measure-oslevel-churn-2*.log -- "RESULT: OK"
expect "3 Churn COUNT line (#16 freeze_total precondition)" \
    "$OSLEVEL"/COUNT-churn-count-*.txt -- "freeze_total="
expect "4 ParkUnpark COUNT baseline (#11)" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "extra_jvmargs=''"
expect "5 ParkUnpark COUNT publish=jvmti (#11)" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "publish=jvmti"
expect "6 ParkUnpark COUNT jvmAlloc (#11)" \
    "$OSLEVEL"/COUNT-parkunpark-count-*.txt -- "jvmAlloc"
for v in baseline agent jvmtipublish jvmalloc; do
    expect "7 N-sweep gc JSON: Transition/$v (GAP-9)" \
        "$NSWEEP_DIR/VThreadTransitionBenchmark_${v}_gc.json"
done
if [[ "$SKIP_MATRIX" != "1" ]]; then
    for f in VThreadTransitionBenchmark_{baseline,agent,jvmtipublish,jvmalloc} \
             VThreadParkUnparkBenchmark_{baseline,jvmtipublish,jvmalloc} \
             VThreadChurnBenchmark_{baseline,agent,jvmalloc}; do
        expect "8 matrix gc JSON: $f" "$RESULTS/${f}_gc.json"
    done
fi

echo
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "run-batch RESULT: INCOMPLETE — ${#MISSING[@]} expected artifact(s) missing (listed above)."
    exit 1
fi
echo "run-batch RESULT: OK — expected artifact set complete. Batch log: $BATCH_LOG"
