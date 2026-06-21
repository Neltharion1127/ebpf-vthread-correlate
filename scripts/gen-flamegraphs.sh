#!/usr/bin/env bash
# gen-flamegraphs.sh — regenerate plain + differential flame graphs from the
# itimer collapsed stacks produced by the JMH async-profiler pass.
#
# Idempotent and re-runnable: auto-discovers every <Bench>_<variant> cell under
# PROF_DIR, emits one plain flame per cell and one differential flame per
# (variant - baseline) pair (plus any EXTRA_PAIRS), and writes an index.html.
# Re-run after any new profiling (e.g. bare-metal) to refresh every figure.
#
# Pure perl over existing folded files — does NOT run java/JMH, so it is immune
# to the env.sh PATH/fastdebug trap.
#
# Usage:
#   scripts/gen-flamegraphs.sh
#   PROF_DIR=/path/to/prof  OUT_DIR=/path/to/out  scripts/gen-flamegraphs.sh
#
# Tunables (env vars): PROF_DIR OUT_DIR FG COLLAPSED_NAME SPARSE_THRESHOLD WIDTH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROF_DIR="${PROF_DIR:-$REPO_ROOT/result/benchmark/collapsed}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/result/figures}"
FG="${FG:-$REPO_ROOT/tools/FlameGraph}"
COLLAPSED_NAME="${COLLAPSED_NAME:-collapsed-itimer.csv}"
SPARSE_THRESHOLD="${SPARSE_THRESHOLD:-2000}"
WIDTH="${WIDTH:-1600}"

# Extra non-baseline differential pairs: "Bench:from:to" (from is the 'before').
# Default isolates the pure per-transition publish cost (agent already pays the
# capability tax; the delta to jvmtipublish is just GetLongField + carrier TLS).
EXTRA_PAIRS=(
  "VThreadTransitionBenchmark:agent:jvmtipublish"
)

# --- bootstrap FlameGraph (clone once) ---
if [ ! -f "$FG/flamegraph.pl" ]; then
    echo "FlameGraph not found at $FG — cloning brendangregg/FlameGraph ..."
    mkdir -p "$(dirname "$FG")"
    git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG"
fi
for s in flamegraph.pl difffolded.pl; do
    [ -f "$FG/$s" ] || { echo "ERROR: $FG/$s missing after clone"; exit 1; }
done
command -v perl >/dev/null 2>&1 || { echo "ERROR: perl not on PATH"; exit 1; }

mkdir -p "$OUT_DIR"

# --- helpers ---
short_name () { local b="${1#VThread}"; b="${b%Benchmark}"; printf '%s' "${b,,}"; }
samples ()    { awk '{s+=$NF} END{printf "%d", s+0}' "$1"; }
sparse ()     { [ "$(samples "$1")" -lt "$SPARSE_THRESHOLD" ]; }

# --- discover cells: <PROF_DIR>/<Bench>_<variant>/.../<COLLAPSED_NAME> ---
declare -A CELL_FILE          # "<Bench>|<variant>" -> collapsed path
declare -A BENCHES            # "<Bench>" -> 1
mapfile -t FILES < <(find "$PROF_DIR" -type f -name "$COLLAPSED_NAME" 2>/dev/null | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no $COLLAPSED_NAME found under $PROF_DIR"; exit 1; }

for f in "${FILES[@]}"; do
    rel="${f#"$PROF_DIR"/}"
    cell="${rel%%/*}"          # <Bench>_<variant>
    bench="${cell%_*}"
    variant="${cell##*_}"
    CELL_FILE["$bench|$variant"]="$f"
    BENCHES["$bench"]=1
done

echo "Discovered ${#FILES[@]} cells under $PROF_DIR:"
for k in $(printf '%s\n' "${!CELL_FILE[@]}" | sort); do
    f="${CELL_FILE[$k]}"; n="$(samples "$f")"
    printf '  %-42s %8d samples%s\n' "$k" "$n" "$(sparse "$f" && echo '  (SPARSE)')"
done
echo

# --- PART 1: plain flames (one per cell) ---
echo "== plain flames =="
for k in $(printf '%s\n' "${!CELL_FILE[@]}" | sort); do
    bench="${k%|*}"; variant="${k#*|}"
    f="${CELL_FILE[$k]}"; sn="$(short_name "$bench")"; n="$(samples "$f")"
    sub="$n samples"; sparse "$f" && sub="$sub (SPARSE)"
    out="$OUT_DIR/${sn}_${variant}.svg"
    perl "$FG/flamegraph.pl" --colors java --width "$WIDTH" \
        --title "$bench · $variant · itimer CPU" --subtitle "$sub" \
        "$f" > "$out"
    echo "  -> $out"
done
echo

# --- diff helper ---
make_diff () {  # <bench> <from-variant> <to-variant> <out.svg> <title>
    local bench="$1" from="$2" to="$3" out="$4" title="$5"
    local ff="${CELL_FILE[$bench|$from]:-}" tf="${CELL_FILE[$bench|$to]:-}"
    [ -n "$ff" ] && [ -n "$tf" ] || { echo "  skip ${bench}: $from or $to missing"; return; }
    { sparse "$ff" || sparse "$tf"; } && title="$title (SPARSE, indicative only)"
    perl "$FG/difffolded.pl" -n -s "$ff" "$tf" \
        | perl "$FG/flamegraph.pl" --width "$WIDTH" --title "$title" > "$out"
    echo "  -> $out"
}

# --- PART 2a: differential flames vs baseline ---
echo "== differential flames (red = added by variant vs baseline) =="
for bench in $(printf '%s\n' "${!BENCHES[@]}" | sort); do
    sn="$(short_name "$bench")"
    [ -n "${CELL_FILE[$bench|baseline]:-}" ] || { echo "  skip $bench: no baseline"; continue; }
    for k in $(printf '%s\n' "${!CELL_FILE[@]}" | sort); do
        [ "${k%|*}" = "$bench" ] || continue
        variant="${k#*|}"; [ "$variant" != baseline ] || continue
        make_diff "$bench" baseline "$variant" \
            "$OUT_DIR/${sn}_diff_${variant}_minus_baseline.svg" \
            "$bench Δ · $variant − baseline · red = added by $variant"
    done
done
echo

# --- PART 2b: extra (non-baseline) pairs ---
if [ "${#EXTRA_PAIRS[@]}" -gt 0 ]; then
    echo "== extra differential pairs =="
    for p in "${EXTRA_PAIRS[@]}"; do
        IFS=':' read -r bench from to <<<"$p"
        sn="$(short_name "$bench")"
        make_diff "$bench" "$from" "$to" \
            "$OUT_DIR/${sn}_diff_${to}_minus_${from}.svg" \
            "$bench Δ · $to − $from · red = added by $to"
    done
    echo
fi

# --- PART 3: index.html ---
mapfile -t SHORTS < <(for b in "${!BENCHES[@]}"; do printf '%s\n' "$(short_name "$b")"; done | sort -u)
{
    echo '<!doctype html><meta charset=utf-8><title>vthread flame graphs</title>'
    echo '<style>body{font:14px/1.6 system-ui,sans-serif;max-width:60em;margin:2em auto;padding:0 1em}'
    echo 'h2{margin:1.6em 0 .3em;border-bottom:1px solid #ddd}a{display:block;padding:1px 0}'
    echo '.d a{color:#b00}small{color:#666}</style>'
    echo '<h1>vthread benchmark flame graphs</h1>'
    echo "<small>itimer CPU · release-flag JDK · generated $(date -u +%FT%TZ)</small>"
    for sn in "${SHORTS[@]}"; do
        ls "$OUT_DIR/${sn}_"*.svg >/dev/null 2>&1 || continue
        echo "<h2>$sn</h2><div><strong>plain</strong>"
        for svg in "$OUT_DIR/${sn}_"*.svg; do
            b="$(basename "$svg")"; case "$b" in *_diff_*) continue;; esac
            echo "<a href=\"$b\">$b</a>"
        done
        echo "</div><div class=d><strong>differential</strong>"
        for svg in "$OUT_DIR/${sn}_diff_"*.svg; do
            [ -e "$svg" ] || continue
            echo "<a href=\"$(basename "$svg")\">$(basename "$svg")</a>"
        done
        echo "</div>"
    done
} > "$OUT_DIR/index.html"
echo "  -> $OUT_DIR/index.html"
echo

echo "Done. $(ls "$OUT_DIR"/*.svg 2>/dev/null | wc -l) SVGs in $OUT_DIR"
