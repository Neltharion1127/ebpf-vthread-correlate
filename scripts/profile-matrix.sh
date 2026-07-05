#!/usr/bin/env bash
# profile-matrix.sh — end-to-end pipeline for benchmark #1.
#
#   build agent + jar  ->  run the JMH matrix twice per cell
#     (1) -prof gc                 : clean Score + gc.alloc.rate.norm  (trustworthy time/heap)
#     (2) -prof async event=itimer : collapsed CPU stacks              (attribution only)
#   ->  parse a time/alloc table  ->  generate plain + differential flame graphs
#
# One command, re-runnable (including on bare-metal). Pairs with gen-flamegraphs.sh
# in the same dir, which it calls for the figures.
#
# Usage:
#   scripts/profile-matrix.sh
#   QUICK=1 scripts/profile-matrix.sh        # gc + Table A only (no itimer, no flamegraphs)
#   DRY_RUN=1 scripts/profile-matrix.sh      # print the matrix without running anything
#   ITIMER_ARGS="-f 1 -wi 5 -i 10" scripts/profile-matrix.sh
#   ONLY="Transition|jvmalloc" scripts/profile-matrix.sh   # run matching cells only
#
# Env knobs: PROF_DIR RESULTS OUT_DIR ASPROF ITIMER_ARGS DRY_RUN QUICK NPARAM ONLY
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
ITIMER_ARGS="${ITIMER_ARGS:--f 1 -wi 5 -i 10}"
DRY_RUN="${DRY_RUN:-0}"
QUICK="${QUICK:-0}"
NPARAM="${NPARAM:-}"   # e.g. NPARAM="yieldsPerVthread=1000,10000,100000"; empty = source @Param default
ONLY="${ONLY:-}"       # substring filter on "Bench|variant" cells; empty = run all (unchanged)

# ---- the matrix: "Bench|variant|<jvm arg to append, empty for baseline>" ----
# The intentional per-benchmark variant selection.
CELLS=(
  "VThreadTransitionBenchmark|baseline|"
  "VThreadTransitionBenchmark|agent|-agentpath:$AGENT_PATH"
  "VThreadTransitionBenchmark|jvmtipublish|-agentpath:$AGENT_PATH=publish=jvmti"
  "VThreadTransitionBenchmark|jvmalloc|-Dvthread.trace.jvmAlloc=true"
  "VThreadParkUnparkBenchmark|baseline|"
  "VThreadParkUnparkBenchmark|jvmtipublish|-agentpath:$AGENT_PATH=publish=jvmti"
  "VThreadParkUnparkBenchmark|jvmalloc|-Dvthread.trace.jvmAlloc=true"
  "VThreadChurnBenchmark|baseline|"
  "VThreadChurnBenchmark|agent|-agentpath:$AGENT_PATH"
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
    [ -f "$ASPROF" ]      || { echo "ABORT: async-profiler lib not found at $ASPROF"; exit 1; }
    command -v mvn >/dev/null 2>&1 || { echo "ABORT: mvn not on PATH (ran under sudo? re-run as yourself)"; exit 1; }
fi
mkdir -p "$RESULTS" "$PROF_DIR"

# Provenance record (GAP-1/2/4); DRY_RUN stays side-effect-free.
if [ "$DRY_RUN" != 1 ]; then
    RUNINFO_FILE="$(write_runinfo "$RESULTS" "profile-matrix.sh" "$JAVA" \
        "ONLY=$ONLY" "QUICK=$QUICK" "DRY_RUN=$DRY_RUN" "NPARAM=$NPARAM" \
        "ITIMER_ARGS=$ITIMER_ARGS" "ASPROF=$ASPROF" "AGENT_PATH=$AGENT_PATH" \
        "PROF_DIR=$PROF_DIR" "RESULTS=$RESULTS" "OUT_DIR=$OUT_DIR")"
    echo "RUNINFO   = $RUNINFO_FILE"
fi

# ---- build ----
say "build"
run make -C JVMTI-agent
run mvn -q clean package

# ---- run the matrix: gc (clean) + itimer (collapsed) per cell ----
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

    # (1) clean time + heap — annotation @Fork/@Warmup defaults, no profiler perturbation
    run "$JAVA" -Djmh.ignoreLock=true -jar "$JAR" "$bench" "${append[@]}" "${pflag[@]}" \
        -prof gc  \
        -rf json -rff "$RESULTS/${bench}_${variant}_gc.json"

    if [ "$QUICK" != 1 ]; then
        # (2) CPU attribution — itimer (no perf perms needed); time here is discarded
        # shellcheck disable=SC2086
        run "$JAVA" -Djmh.ignoreLock=true -jar "$JAR" "$bench" "${append[@]}" \
            $ITIMER_ARGS \
            -prof "async:libPath=$ASPROF;event=itimer;output=collapsed;dir=$celldir"
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
    PROF_DIR="$PROF_DIR" OUT_DIR="$OUT_DIR" "$SCRIPT_DIR/gen-flamegraphs.sh"
fi

say "done"
echo "  table JSON : $RESULTS/*_gc.json"
if [ "$QUICK" != 1 ]; then
    echo "  collapsed  : $PROF_DIR/<Bench>_<variant>/"
    echo "  flamegraphs: $OUT_DIR/  (open index.html)"
fi
