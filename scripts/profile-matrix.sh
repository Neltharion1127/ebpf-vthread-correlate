#!/usr/bin/env bash
# profile-matrix.sh — end-to-end pipeline for benchmark #1.
#
#   build agent + jar  ->  run the JMH matrix twice per cell
#     (1) -prof gc                        : clean Score + gc.alloc.rate.norm  (trustworthy time/heap)
#     (2) -prof async event=$PROF_EVENT   : collapsed CPU stacks              (attribution only)
#   ->  parse a time/alloc table  ->  generate plain + differential flame graphs
#
# PROF_EVENT selects the async-profiler sampling event for pass (2):
#   itimer (default) — SIGPROF wall-clock-ish CPU sampling, works everywhere
#                      (VMs/containers without PMU access); the historical event —
#                      every pre-2026-07-06 batch (incl. the 20260705 bare-metal
#                      batch) is itimer. Local smoke tests rely on this default.
#   cpu              — perf-events sampling incl. KERNEL stacks; needs a real PMU
#                      (bare metal) and kernel.perf_event_paranoid<=1 +
#                      kernel.kptr_restrict=0 (guarded below; env-bootstrap.sh
#                      sets them). This is the attribution upgrade for observation
#                      cost (uprobe/eBPF cost shows up in kernel frames).
# JMH's async integration names outputs per event (collapsed-<event>.csv) — do
# NOT mix events within one differential pair; gen-flamegraphs.sh discovers by
# one event name per invocation.
#
# One command, re-runnable (including on bare-metal). Pairs with gen-flamegraphs.sh
# in the same dir, which it calls for the figures.
#
# Usage:
#   scripts/profile-matrix.sh
#   QUICK=1 scripts/profile-matrix.sh        # gc + Table A only (no profiling pass, no flamegraphs)
#   DRY_RUN=1 scripts/profile-matrix.sh      # print the matrix without running anything
#   PROF_PASS_ARGS="-f 1 -wi 5 -i 10 -w 1 -r 1" scripts/profile-matrix.sh
#   PROF_EVENT=cpu scripts/profile-matrix.sh    # perf-events sampling (bare metal)
#   ONLY="Transition|jvmalloc" scripts/profile-matrix.sh   # run matching cells only
#
# Env knobs: PROF_DIR RESULTS OUT_DIR ASPROF PROF_EVENT PROF_PASS_ARGS DRY_RUN QUICK NPARAM ONLY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
source config/env.sh
# shellcheck source=lib/runinfo.sh
source "$SCRIPT_DIR/lib/runinfo.sh"

JAVA="$JAVA_HOME/bin/java"
JAR="$REPO_ROOT/target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
ASPROF="${ASPROF:-$REPO_ROOT/lib/libasyncProfiler.so}"
PROF_DIR="${PROF_DIR:-$REPO_ROOT/result/benchmark/collapsed}"
RESULTS="${RESULTS:-$REPO_ROOT/result/benchmark}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/result/figures}"
# The profiling pass keeps -f 1 deliberately: attribution-only, a single fork
# suffices for collapsed stacks and its time figures are discarded — it does NOT
# follow the jmh-defaults statistical spec.
# -w 1 -r 1 pin the historical 1s iterations explicitly: they used to come from the
# (now removed) @Warmup/@Measurement annotations, and without them the pass would
# silently inherit the 10s JMH default and grow ~10x in wall time for no benefit.
PROF_PASS_ARGS="${PROF_PASS_ARGS:--f 1 -wi 5 -i 10 -w 1 -r 1}"
PROF_EVENT="${PROF_EVENT:-itimer}"      # async-profiler event: itimer (default) | cpu (see header)
COLLAPSED_MIN_LINES="${COLLAPSED_MIN_LINES:-50}"  # empty-artifact guard threshold (see below)
DRY_RUN="${DRY_RUN:-0}"
QUICK="${QUICK:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}" # formal batch builds once before any measurement
BATCH_ID="${BATCH_ID:-standalone}"
NPARAM="${NPARAM:-}"   # e.g. NPARAM="yieldsPerVthread=1000,10000,100000"; empty = source @Param default
ONLY="${ONLY:-}"       # substring filter on "Bench|variant" cells; empty = run all (unchanged)

# ---- the matrix: "Bench|variant|<jvm arg to append, empty for baseline>" ----
# The full benchmark x variant product.
CELLS=(
  "VThreadTransitionBenchmark|baseline|"
  "VThreadTransitionBenchmark|agent|-agentpath:$AGENT_PATH"
  "VThreadTransitionBenchmark|jvmtipublish|-agentpath:$AGENT_PATH=publish=jvmti"
  "VThreadTransitionBenchmark|jvmalloc|-Dvthread.trace.jvmAlloc=true"
  "VThreadParkUnparkBenchmark|baseline|"
  "VThreadParkUnparkBenchmark|agent|-agentpath:$AGENT_PATH"
  "VThreadParkUnparkBenchmark|jvmtipublish|-agentpath:$AGENT_PATH=publish=jvmti"
  "VThreadParkUnparkBenchmark|jvmalloc|-Dvthread.trace.jvmAlloc=true"
  "VThreadChurnBenchmark|baseline|"
  "VThreadChurnBenchmark|agent|-agentpath:$AGENT_PATH"
  "VThreadChurnBenchmark|jvmtipublish|-agentpath:$AGENT_PATH=publish=jvmti"
  "VThreadChurnBenchmark|jvmalloc|-Dvthread.trace.jvmAlloc=true"
)

say () { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
run () { echo "+ $*"; [ "$DRY_RUN" = 1 ] || "$@"; }

# ---- guards (skip the hard checks in dry-run) ----
say "environment"
echo "JAVA_HOME = $JAVA_HOME"
echo "agent     = $AGENT_PATH"
if [ "$DRY_RUN" != 1 ]; then
    # S4: fail loudly on a bad JAVA_HOME before anything downstream consumes it
    [ -x "$JAVA" ] || { echo "ABORT: java not executable at resolved path: $JAVA (check config/env.sh JAVA_HOME)"; exit 1; }
    echo "java      = $("$JAVA" -version 2>&1 | head -1)"
    case "$("$JAVA" -version 2>&1)" in
        *fastdebug*) echo "ABORT: JAVA_HOME is a fastdebug build — it distorts ratios. Point env.sh at the release-flag build."; exit 1;;
    esac
    [ -f "$AGENT_PATH" ]  || { echo "ABORT: agent not built. Run: make -C JVMTI-agent"; exit 1; }
    if [[ "$QUICK" != "1" ]]; then
        [ -f "$ASPROF" ]  || { echo "ABORT: async-profiler lib not found at $ASPROF"; exit 1; }
    fi
    command -v mvn >/dev/null 2>&1 || { echo "ABORT: mvn not on PATH (ran under sudo? re-run as yourself)"; exit 1; }
    # PROF_EVENT=cpu needs perf_events with kernel symbols; fail loudly up front
    # rather than let async-profiler degrade/produce empty stacks mid-matrix.
    if [ "$PROF_EVENT" = cpu ] && [ "$QUICK" != 1 ]; then
        paranoid="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
        kptr="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)"
        if ! [[ "$paranoid" =~ ^-?[0-9]+$ ]] || [ "$paranoid" -gt 1 ] || [ "$kptr" != 0 ]; then
            echo "ABORT: PROF_EVENT=cpu needs kernel.perf_event_paranoid<=1 (now: $paranoid) and kernel.kptr_restrict=0 (now: $kptr)."
            echo "       Fix (root, same privilege context as bpftrace):"
            echo "         sudo sysctl -w kernel.perf_event_paranoid=1 kernel.kptr_restrict=0"
            echo "       (scripts/env-bootstrap.sh sets these on a fresh box; or use PROF_EVENT=itimer)"
            exit 1
        fi
    fi
fi
mkdir -p "$RESULTS"
[[ "$QUICK" == "1" ]] || mkdir -p "$PROF_DIR"

if [ "$DRY_RUN" != 1 ]; then
    RUNINFO_FILE="$(write_runinfo "$RESULTS" "profile-matrix.sh" "$JAVA" \
        "BATCH_ID=$BATCH_ID" "ONLY=$ONLY" "QUICK=$QUICK" "DRY_RUN=$DRY_RUN" \
        "SKIP_BUILD=$SKIP_BUILD" "NPARAM=$NPARAM" \
        "PROF_EVENT=$PROF_EVENT" "PROF_PASS_ARGS=$PROF_PASS_ARGS" \
        "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)" \
        "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)" \
        "ASPROF=$ASPROF" "AGENT_PATH=$AGENT_PATH" \
        "PROF_DIR=$PROF_DIR" "RESULTS=$RESULTS" "OUT_DIR=$OUT_DIR")"
    echo "RUNINFO   = $RUNINFO_FILE"
fi

# ---- build ----
say "build"
if [[ "$SKIP_BUILD" == "1" ]]; then
    echo "build skipped: caller supplied a prebuilt, batch-frozen agent and JAR"
else
    run make -C JVMTI-agent
    run mvn -q clean package
fi

# ---- run the matrix: gc (clean) + profiling (collapsed, event=$PROF_EVENT) per cell ----
for cell in "${CELLS[@]}"; do
    IFS='|' read -r bench variant arg <<<"$cell"
    # S3: ONLY= filter (empty = run all). "bench|variant" form matches the two
    # halves independently as substrings (so ONLY="Transition|jvmalloc" hits
    # VThreadTransitionBenchmark|jvmalloc); a form without '|' is a plain
    # substring match on the whole cell id.
    if [ -n "$ONLY" ]; then
        case "$ONLY" in
            *"|"*)
                only_bench="${ONLY%%|*}"; only_variant="${ONLY#*|}"
                [[ "$bench" == *"$only_bench"* && "$variant" == *"$only_variant"* ]] || continue
                ;;
            *)
                [[ "$bench|$variant" == *"$ONLY"* ]] || continue
                ;;
        esac
    fi
    say "$bench / $variant"

    append=(); [ -n "$arg" ] && append=(-jvmArgsAppend "$arg")
    pflag=(); [ -n "$NPARAM" ] && pflag=(-p "$NPARAM")
    if [ "$QUICK" != 1 ]; then
        celldir="$PROF_DIR/${bench}_${variant}"
        run rm -rf "$celldir"
    fi

    # (1) clean time + heap — no harness flags: the JMH 1.37 built-in defaults govern
    #     (5 forks, warmup 5x10s, measurement 5x10s; the jmh-defaults formal spec)
    run "$JAVA" -Djmh.ignoreLock=true -jar "$JAR" "$bench" "${append[@]}" "${pflag[@]}" \
        -prof gc  \
        -rf json -rff "$RESULTS/${bench}_${variant}_gc.json"

    if [ "$QUICK" != 1 ]; then
        # (2) CPU attribution — event=$PROF_EVENT (itimer: no perf perms needed;
        #     cpu: perf events incl. kernel stacks, guarded above); time discarded
        # shellcheck disable=SC2086
        run "$JAVA" -Djmh.ignoreLock=true -jar "$JAR" "$bench" "${append[@]}" \
            $PROF_PASS_ARGS \
            -prof "async:libPath=$ASPROF;event=$PROF_EVENT;output=collapsed;dir=$celldir"
        # Empty-artifact guard: a misconfigured event (typically cpu without PMU
        # access) can exit 0 yet leave an empty/near-empty collapsed file, which
        # would silently become an empty flame graph. JMH names the file
        # collapsed-<event>.csv (AsyncProfiler.java, outputFilePrefix = event).
        if [ "$DRY_RUN" != 1 ]; then
            collapsed_file="$(find "$celldir" -type f -name "collapsed-$PROF_EVENT.csv" | head -1)"
            [ -n "$collapsed_file" ] || { echo "ABORT: no collapsed-$PROF_EVENT.csv under $celldir — profiling pass produced nothing"; exit 1; }
            lines="$(wc -l < "$collapsed_file")"
            if [ "$lines" -lt "$COLLAPSED_MIN_LINES" ]; then
                echo "ABORT: $collapsed_file has only $lines stack lines (< $COLLAPSED_MIN_LINES) — event=$PROF_EVENT likely failed silently (PMU access? paranoid/kptr?)"
                exit 1
            fi
        fi
    fi
done

[ "$DRY_RUN" = 1 ] && { echo; echo "(dry run — nothing executed past the matrix print)"; exit 0; }

# ---- Table A: time + alloc.norm from the gc JSONs ----
say "Table A (clean -prof gc, release build)"
python3 - "$RESULTS" <<'PY'
import json, glob, os, sys
results = sys.argv[1]
# per-class nominal divisor + unit
NOM = [("Transition", 10000, "yield"), ("ParkUnpark", 10000, "round"), ("Churn", 1000, "vthread")]
rows = []
for f in sorted(glob.glob(os.path.join(results, "*_gc.json"))):
    stem = os.path.basename(f)[:-len("_gc.json")]
    bench, _, variant = stem.rpartition("_")
    try:
        data = json.load(open(f))
    except Exception as e:
        rows.append((bench, variant, "ERR", "", "")); continue
    for r in data:
        score = r["primaryMetric"]["score"]; unit = r["primaryMetric"]["scoreUnit"]
        sec = r.get("secondaryMetrics", {}).get("gc.alloc.rate.norm", {})
        anorm = sec.get("score", float("nan"))
        div, lab = 1, "op"
        for key, d, l in NOM:
            if key in bench: div, lab = d, l; break
        out_variant = variant
        if "Transition" in bench:
            n = r.get("params", {}).get("yieldsPerVthread")
            if n is not None:
                try:
                    div = int(n)
                    out_variant = f"{variant} N={n}"
                except ValueError:
                    pass
        rows.append((bench.replace("Benchmark",""), out_variant, f"{score:.3f} {unit}",
                     f"{anorm:.1f} B/op", f"{score/div:.4f} /{lab}"))
w = [max(len(r[i]) for r in rows+[("Benchmark","Variant","Score","alloc.norm","per nominal")]) for i in range(5)]
hdr = ("Benchmark","Variant","Score","alloc.norm","per nominal")
print("  " + "  ".join(h.ljust(w[i]) for i,h in enumerate(hdr)))
print("  " + "  ".join("-"*w[i] for i in range(5)))
for r in rows:
    print("  " + "  ".join(r[i].ljust(w[i]) for i in range(5)))
PY

# ---- flame graphs (plain + differential + index) ----
if [ "$QUICK" != 1 ]; then
    say "flame graphs"
    PROF_DIR="$PROF_DIR" OUT_DIR="$OUT_DIR" PROF_EVENT="$PROF_EVENT" "$SCRIPT_DIR/gen-flamegraphs.sh"
fi

say "done"
echo "  table JSON : $RESULTS/*_gc.json"
if [ "$QUICK" != 1 ]; then
    echo "  collapsed  : $PROF_DIR/<Bench>_<variant>/"
    echo "  flamegraphs: $OUT_DIR/  (open index.html)"
fi
