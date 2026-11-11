#!/usr/bin/env python3
"""Generate compact, single-column LaTeX tables from one formal benchmark batch.

New batches live below result/benchmark/batches/<batch-id>/. Legacy timestamped
batches remain readable (the newest legacy batch owns the fixed-name matrix JSONs).

Usage:
  python3 scripts/py/gen_paper_tables.py --list-batches
  python3 scripts/py/gen_paper_tables.py --batch 20260803-formal-rerun-1
  python3 scripts/py/gen_paper_tables.py --batch latest
  python3 scripts/py/gen_paper_tables.py --chart

Alongside the matrix tables this also writes channel-overhead.pdf, a seaborn
bar chart of per-variant runtime relative to baseline (variant/baseline, with
propagated error bars) for \\includegraphics. That one output needs matplotlib
and seaborn; if they are missing the tables are still generated and the figure
is skipped with a warning.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RESULTS_ROOT = REPO_ROOT / "result" / "benchmark"
DEFAULT_OUT_DIR = REPO_ROOT / "paper-tables" / "tex"
DEFAULT_BATCH = "20260803-formal-rerun-1"

VARIANT_ORDER = ["baseline", "agent", "jvmtipublish", "jvmalloc"]
BENCH_ORDER = ["Transition", "ParkUnpark", "Churn"]

EXPECTED_MATRIX_CELLS = {
    ("Transition", "baseline"), ("Transition", "agent"),
    ("Transition", "jvmtipublish"), ("Transition", "jvmalloc"),
    ("ParkUnpark", "baseline"), ("ParkUnpark", "agent"),
    ("ParkUnpark", "jvmtipublish"), ("ParkUnpark", "jvmalloc"),
    ("Churn", "baseline"), ("Churn", "agent"),
    ("Churn", "jvmtipublish"), ("Churn", "jvmalloc"),
}
EXPECTED_NSWEEP_CELLS = {
    ("Transition", variant, n)
    for variant in VARIANT_ORDER
    for n in (1000, 10000, 100000)
}
EXPECTED_COUNT_CELLS = {
    ("churn", "baseline"),
    ("parkunpark", "baseline"),
    ("parkunpark", "jvmtipublish"),
    ("parkunpark", "jvmalloc"),
}

MAIN_JSON_RE = re.compile(r"^VThread(\w+?)Benchmark_(\w+)_gc\.json$")
STATE_HEADER_RE = re.compile(r"^((?:S[0-3])|[A-Z]) [—-] (.+)$")
JMH_RESULT_RE = re.compile(
    r"^(\S+(?:Benchmark\.\w+))\s+(\S+)\s+avgt\s+(\d+)\s+([\d.]+)\s*±\s*([\d.]+)\s+(\S+)\s*$"
)
COUNT_KV_RE = re.compile(r"(\w+)=('[^']*'|\S*)")
BPFTRACE_COUNTER_RE = re.compile(
    r"^@(freeze_total|thaw_total|start_total|end_total):\s*(\d+)\s*$"
)
S3_COUNTER_LOG_RE = re.compile(
    r"^S3_bpftrace_real_buffer-(transition|parkunpark|churn)-.+\.log$"
)

COUNT_FIELDS = [
    "bench", "class", "ops", "freeze_total", "thaw_total", "thaw_top",
    "start_total", "end_total", "end_unmatched", "freezes_per_op",
    "top_thaws_per_op", "starts_per_op", "extra_jvmargs",
]

VARIANT_LABELS = {
    "baseline": "Baseline",
    "agent": "Agent",
    "jvmtipublish": "JVMTI publish",
    "jvmalloc": "JVM alloc",
}

# Chart styling. Paul Tol's "vibrant" qualitative scheme (blue/orange/teal) is
# colourblind-safe and passes the dataviz validator in light mode (worst adjacent
# CVD dE 10.5); the orange's sub-3:1 surface contrast is relieved by the direct
# value labels. INK follows the journal convention of a near-black grey rather
# than pure black. See https://personal.sron.nl/~pault/ for the source scheme.
PAUL_TOL_VIBRANT = ["#0077bb", "#ee7733", "#009988"]
CHART_INK = "#373737"
CHART_AXIS_GREY = "#4d4d4d"

STALE_OUTPUTS = {
    "tab-transition.tex",
    "tab-parkunpark.tex",
    "tab-churn.tex",
    "tab-oslevel-jmh.tex",
    "tab-oslevel-bpftrace.tex",
    "tab-oslevel-count.tex",
}

FACTORIAL_STATE_LABELS = {
    "S0": "S0: jvmAlloc off; probes off; no consumer",
    "S1": "S1: jvmAlloc on; probes off; no consumer",
    "S2": "S2: jvmAlloc on; probes on; no consumer",
    "S3": "S3: jvmAlloc on; probes on; consumer attached",
}

FACTORIAL_CONTRASTS = (
    ("S1", "S0", r"S1$-$S0: allocation alone"),
    ("S2", "S1", r"S2$-$S1: probe residual, real buffer"),
    ("S2", "S0", r"S2$-$S0: total dormant deployed"),
    ("S3", "S2", r"S3$-$S2: observation"),
    ("S3", "S0", r"S3$-$S0: total cost, consumer attached"),
)


@dataclass(frozen=True)
class BatchLayout:
    batch_id: str
    root: Path
    matrix_dir: Path
    nsweep_dir: Path
    oslevel_dir: Path
    legacy: bool = False


def is_factorial_only(layout: BatchLayout) -> bool:
    """Return whether run-batch intentionally omitted COUNT/N-sweep/matrix work."""
    return any(
        "FACTORIAL_ONLY=1" in path.read_text(errors="replace")
        for path in layout.root.glob("RUNINFO-*.txt")
    )


def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


def fail(msg: str) -> "None":
    raise SystemExit(f"error: {msg}")


def latex_escape(value: object) -> str:
    s = str(value)
    replacements = {
        "\\": r"\textbackslash{}",
        "&": r"\&",
        "%": r"\%",
        "$": r"\$",
        "#": r"\#",
        "_": r"\_",
        "{": r"\{",
        "}": r"\}",
        "~": r"\textasciitilde{}",
        "^": r"\textasciicircum{}",
    }
    return "".join(replacements.get(ch, ch) for ch in s)


def fmt(value: float, precision: int = 1) -> str:
    return f"{value:.{precision}f}"


def signed_percent(value: float, precision: int = 1) -> str:
    # Do not emit the visually misleading strings +0.0% or -0.0%.
    if round(value, precision) == 0:
        return f"{0:.{precision}f}\\%"
    return f"{value:+.{precision}f}\\%"


def difference(
    candidate: float,
    candidate_error: float,
    reference: float,
    reference_error: float,
) -> tuple[float, float, float, bool]:
    """Return absolute/relative delta and independent propagated uncertainty.

    JMH's reported score errors have the same confidence level within a run. For
    independently executed configurations, root-sum-square propagation gives the
    corresponding uncertainty on their difference. ``nonsignificant`` here means
    that zero lies inside that propagated interval; it must not be read as a
    speedup merely because the sample mean is negative.
    """
    absolute = candidate - reference
    error = math.hypot(candidate_error, reference_error)
    relative = absolute / reference * 100.0
    return absolute, error, relative, abs(absolute) <= error


def runtime_ratio(
    candidate: float,
    candidate_error: float,
    reference: float,
    reference_error: float,
) -> tuple[float, float]:
    """Return candidate/reference and its first-order propagated uncertainty.

    Same independence assumption as difference(): the two JMH scores come from
    separately executed configurations, so their relative errors add in
    quadrature. For a quotient that gives
    ``sigma_R = R * hypot(sigma_cand/cand, sigma_ref/ref)``. Significance is not
    decided here -- the chart keeps difference()'s n.s. verdict so it agrees with
    tab:main-matrix; for R near 1 (the only n.s. cases) the two criteria coincide.
    """
    ratio = candidate / reference
    ratio_error = ratio * math.hypot(
        candidate_error / candidate,
        reference_error / reference,
    )
    return ratio, ratio_error


def relative_cell(value: float, nonsignificant: bool, precision: int = 1) -> str:
    suffix = " (n.s.)" if nonsignificant else ""
    return signed_percent(value, precision) + suffix


def compact_factorial_cell(
    absolute: float,
    error: float,
    relative: float,
    nonsignificant: bool,
) -> str:
    """Format a narrow two-line factorial contrast cell for acmsmall."""
    return (
        r"\begin{tabular}{@{}r@{}}"
        f"${absolute:+.0f} \\pm {error:.0f}$"
        r"\\"
        + relative_cell(relative, nonsignificant, precision=2)
        + r"\end{tabular}"
    )


def percentage_point_gap(
    candidate: float,
    candidate_error: float,
    reference: float,
    reference_error: float,
    baseline: float,
    baseline_error: float,
) -> tuple[float, float, bool]:
    """Return a percentage-point gap and its propagated uncertainty.

    The numerator is a difference, so its independent error is root-sum-square.
    The workload baseline scales that difference into percentage points; its
    uncertainty is propagated as the denominator of the ratio.
    """
    absolute = candidate - reference
    absolute_error = math.hypot(candidate_error, reference_error)
    points = absolute / baseline * 100.0
    points_error = math.hypot(
        absolute_error / baseline * 100.0,
        absolute * baseline_error / (baseline * baseline) * 100.0,
    )
    return points, points_error, abs(points) <= points_error


def variant_label(variant: str) -> str:
    return VARIANT_LABELS.get(variant, variant)


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def variant_sort_key(variant: str) -> tuple[int, int | str]:
    try:
        return (0, VARIANT_ORDER.index(variant))
    except ValueError:
        return (1, variant)


def bench_sort_key(bench: str) -> tuple[int, int | str]:
    bench = {
        "transition": "Transition",
        "parkunpark": "ParkUnpark",
        "churn": "Churn",
    }.get(bench.lower(), bench)
    try:
        return (0, BENCH_ORDER.index(bench))
    except ValueError:
        return (1, bench)


def booktabs_table(
    caption: str,
    label: str,
    col_spec: str,
    header_cells: list[str],
    rows: list[list[str]],
    source_note: str,
    wide: bool = False,
) -> str:
    environment = "table*" if wide else "table"
    lines = [f"% auto-generated by scripts/py/gen_paper_tables.py -- {source_note}"]
    lines.extend([
        f"\\begin{{{environment}}}",
        r"  \centering",
        r"  \small",
        r"  \setlength{\tabcolsep}{3pt}",
        f"  \\caption{{{caption}}}",
        f"  \\label{{{label}}}",
        f"  \\begin{{tabular}}{{@{{}}{col_spec}@{{}}}}",
        r"    \toprule",
        "    " + " & ".join(header_cells) + r" \\",
        r"    \midrule",
    ])
    lines.extend("    " + " & ".join(row) + r" \\" for row in rows)
    lines.extend([
        r"    \bottomrule",
        r"  \end{tabular}",
        f"\\end{{{environment}}}",
    ])
    return "\n".join(lines) + "\n"


def list_batches() -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    batches_root = RESULTS_ROOT / "batches"
    if batches_root.is_dir():
        for path in batches_root.iterdir():
            if not path.is_dir():
                continue
            log = path / "run-batch.log"
            complete = log.is_file() and "run-batch RESULT: OK" in log.read_text(errors="replace")
            found.append((path.name, "batch-dir" if complete else "batch-dir-incomplete"))
    for path in RESULTS_ROOT.glob("run-batch-*.log"):
        if "run-batch RESULT: OK" not in path.read_text(errors="replace"):
            continue
        batch_id = path.name.removeprefix("run-batch-").removesuffix(".log")
        found.append((batch_id, "legacy"))
    return sorted(set(found))


def resolve_batch(requested: str | None) -> BatchLayout:
    available = list_batches()
    if not available:
        fail(f"no batches found below {RESULTS_ROOT}")

    if requested in (None, "latest"):
        # Timestamp-like IDs sort chronologically; explicit named IDs are still
        # deterministic. Never silently select an unfinished batch as "latest".
        completed = [
            batch_id for batch_id, kind in available
            if kind in ("batch-dir", "legacy")
        ]
        if not completed:
            fail("no completed batches found (use an explicit --batch with --allow-partial for inspection)")
        requested = sorted(completed)[-1]

    new_root = RESULTS_ROOT / "batches" / requested
    if new_root.is_dir():
        return BatchLayout(
            batch_id=requested,
            root=new_root,
            matrix_dir=new_root / "matrix",
            nsweep_dir=new_root / "nsweep",
            oslevel_dir=new_root / "oslevel",
        )

    legacy_log = RESULTS_ROOT / f"run-batch-{requested}.log"
    if not legacy_log.is_file():
        choices = ", ".join(batch_id for batch_id, _ in available)
        fail(f"unknown batch '{requested}'; available: {choices}")

    legacy_ids = sorted(batch_id for batch_id, kind in available if kind == "legacy")
    if requested != legacy_ids[-1]:
        fail(
            f"legacy batch {requested} has timestamped OS/N-sweep data, but its fixed-name "
            f"matrix JSONs were overwritten by {legacy_ids[-1]}; use the batch log for archival recovery"
        )
    return BatchLayout(
        batch_id=requested,
        root=RESULTS_ROOT,
        matrix_dir=RESULTS_ROOT,
        nsweep_dir=RESULTS_ROOT / f"nsweep-{requested}",
        oslevel_dir=RESULTS_ROOT / "oslevel",
        legacy=True,
    )


def load_json_entries(path: Path, single: bool) -> list[dict]:
    data = json.loads(path.read_text())
    if not isinstance(data, list) or not data:
        raise ValueError(f"unexpected JMH JSON shape in {path}")
    if single and len(data) != 1:
        raise ValueError(f"expected exactly one JMH entry in {path}, got {len(data)}")
    return data


def load_matrix(layout: BatchLayout) -> list[dict]:
    entries: list[dict] = []
    for path in sorted(layout.matrix_dir.glob("*.json")):
        match = MAIN_JSON_RE.match(path.name)
        if not match:
            continue
        bench, variant = match.groups()
        data = load_json_entries(path, single=True)[0]
        params = data.get("params", {})
        if len(params) != 1:
            warn(f"matrix: {path.name} has {len(params)} parameters; expected one")
        param_name, param_value = next(iter(params.items())) if params else ("", "")
        primary = data["primaryMetric"]
        alloc = data.get("secondaryMetrics", {}).get("gc.alloc.rate.norm")
        if alloc is None:
            warn(f"matrix: {path.name} has no gc.alloc.rate.norm; skipping")
            continue
        entries.append({
            "path": path,
            "bench": bench,
            "variant": variant,
            "param_name": param_name,
            "param_value": param_value,
            "score": float(primary["score"]),
            "score_err": float(primary["scoreError"]),
            "score_unit": primary["scoreUnit"],
            "alloc": float(alloc["score"]),
            "alloc_err": float(alloc["scoreError"]),
            "alloc_unit": alloc["scoreUnit"],
        })
    entries.sort(key=lambda e: (bench_sort_key(e["bench"]), variant_sort_key(e["variant"])))
    return entries


def gen_matrix_table(layout: BatchLayout, matrix: list[dict]) -> str:
    """Emit all workloads and variants from the complete 3-by-4 matrix."""
    rows: list[list[str]] = []
    params: list[str] = []
    names = {
        "Transition": "Transition",
        "ParkUnpark": "Park/unpark",
        "Churn": "Churn",
    }
    for bench in BENCH_ORDER:
        selected = [entry for entry in matrix if entry["bench"] == bench]
        if not selected:
            continue
        baseline = next((entry for entry in selected if entry["variant"] == "baseline"), None)
        if baseline is None:
            warn(f"matrix: {bench} baseline is missing; cannot compute overhead")
            continue
        params.append(f"{names[bench]}: {selected[0]['param_name']}={selected[0]['param_value']}")
        for index, entry in enumerate(selected):
            absolute, error, relative, nonsignificant = difference(
                entry["score"], entry["score_err"],
                baseline["score"], baseline["score_err"],
            )
            if entry["variant"] == "baseline":
                delta = relative_cell_value = "--"
            else:
                delta = f"${fmt(absolute)} \\pm {fmt(error)}$"
                relative_cell_value = relative_cell(relative, nonsignificant)
            rows.append([
                latex_escape(names[bench]) if index == 0 else "",
                latex_escape(variant_label(entry["variant"])),
                f"${fmt(entry['score'])} \\pm {fmt(entry['score_err'])}$",
                delta,
                relative_cell_value,
                f"${fmt(entry['alloc'])} \\pm {fmt(entry['alloc_err'])}$",
            ])
    if not rows:
        return ""
    return booktabs_table(
        caption=(
            "Complete benchmark matrix (" + "; ".join(latex_escape(param) for param in params) + "). "
            r"Time and allocation are raw JMH score $\pm$ error. Each $\Delta t$ is "
            r"the absolute difference $\pm$ propagated error and relative change from "
            r"that workload's baseline; n.s. marks zero within the independently "
            r"propagated interval. Alloc. (B/op) is the JMH GC profiler's managed-heap "
            r"metric and does not capture the off-heap 64 B buffer allocated through "
            r"Unsafe.allocateMemory."
        ),
        label="tab:main-matrix",
        col_spec="llrrrr",
        header_cells=[
            "Workload", "Variant", r"Time ($\mu$s/op)",
            r"$\Delta t$ ($\mu$s/op)", "Relative", "Alloc. (B/op)",
        ],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.matrix_dir)}",
        wide=True,
    )


def gen_matrix_gap_table(layout: BatchLayout, matrix: list[dict]) -> str:
    rows: list[list[str]] = []
    names = {
        "Transition": "Transition",
        "ParkUnpark": "Park/unpark",
        "Churn": "Churn",
    }
    for bench in BENCH_ORDER:
        cells = {entry["variant"]: entry for entry in matrix if entry["bench"] == bench}
        if not {"baseline", "agent", "jvmtipublish"} <= cells.keys():
            continue
        baseline = cells["baseline"]
        agent = cells["agent"]
        jvmtipublish = cells["jvmtipublish"]
        points, points_error, nonsignificant = percentage_point_gap(
            jvmtipublish["score"], jvmtipublish["score_err"],
            agent["score"], agent["score_err"],
            baseline["score"], baseline["score_err"],
        )
        rows.append([
            latex_escape(names[bench]),
            rf"${points:+.3f} \pm {points_error:.3f}$"
            + (" (n.s.)" if nonsignificant else ""),
        ])
    if not rows:
        return ""
    return booktabs_table(
        caption=(
            r"JVMTI-publish minus agent overhead gap, in percentage points relative "
            r"to each workload's baseline. Errors include independent propagation "
            r"through the difference and baseline denominator; n.s. marks zero within "
            r"the propagated interval."
        ),
        label="tab:jvmti-agent-gap",
        col_spec="lr",
        header_cells=["Workload", "JVMTI$-$agent gap (pp)"],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.matrix_dir)}",
    )


def gen_channel_overhead_chart(
    layout: BatchLayout,
    matrix: list[dict],
    out_dir: Path,
) -> Path | None:
    """Render per-variant runtime slowdown relative to baseline as a vector PDF.

    This shares gen_matrix_table's data source: it consumes the same ``matrix``
    list produced by load_matrix() and works from the raw JMH scores. Each bar is
    the runtime ratio variant/baseline (baseline = 1.0), with a first-order
    propagated error bar from runtime_ratio(); the n.s. flag is still taken from
    difference() so the figure agrees with tab:main-matrix on significance.
    Nothing here re-reads or re-parses JMH output.

    A linear y-axis is used deliberately: the ratios span only ~1x-5.5x, zero
    overhead (1.0) is the natural neutral point, and a log axis cannot place the
    baseline. matplotlib/seaborn are imported lazily with the Agg backend so
    table generation keeps working (headless, no plotting dependency) when they
    are absent. Returns the written path, or None when nothing was plotted or the
    plotting stack is unavailable.
    """
    try:
        import matplotlib
        matplotlib.use("Agg")  # headless: render without a display
        import matplotlib.pyplot as plt
        import matplotlib.ticker as mticker
        import seaborn as sns
    except ImportError as exc:
        warn(f"channel-overhead chart skipped; install matplotlib and seaborn: {exc}")
        return None

    names = {
        "Transition": "Transition",
        "ParkUnpark": "Park/unpark",
        "Churn": "Churn",
    }
    # Baseline is the 1.0x reference line, not a bar; keep the rest in order.
    plotted_variants = [variant for variant in VARIANT_ORDER if variant != "baseline"]

    workloads: list[str] = []
    variants: list[str] = []
    ratios: list[float] = []
    ratio_values: dict[tuple[str, str], float] = {}
    ratio_errors: dict[tuple[str, str], float] = {}
    overhead_pct: dict[tuple[str, str], float] = {}
    nonsignificant_flags: dict[tuple[str, str], bool] = {}
    for bench in BENCH_ORDER:
        selected = [entry for entry in matrix if entry["bench"] == bench]
        baseline = next((entry for entry in selected if entry["variant"] == "baseline"), None)
        if baseline is None:
            continue
        by_variant = {entry["variant"]: entry for entry in selected}
        for variant in plotted_variants:
            entry = by_variant.get(variant)
            if entry is None:
                continue
            ratio, ratio_error = runtime_ratio(
                entry["score"], entry["score_err"],
                baseline["score"], baseline["score_err"],
            )
            _, _, relative, nonsignificant = difference(
                entry["score"], entry["score_err"],
                baseline["score"], baseline["score_err"],
            )
            workload_label = names[bench]
            variant_display = variant_label(variant)
            workloads.append(workload_label)
            variants.append(variant_display)
            ratios.append(ratio)
            ratio_values[(workload_label, variant_display)] = ratio
            ratio_errors[(workload_label, variant_display)] = ratio_error
            overhead_pct[(workload_label, variant_display)] = relative
            nonsignificant_flags[(workload_label, variant_display)] = nonsignificant
    if not ratios:
        return None

    order = [names[bench] for bench in BENCH_ORDER if names[bench] in workloads]
    hue_order = [variant_label(variant) for variant in plotted_variants
                 if variant_label(variant) in variants]
    top = max(r + ratio_errors[(w, v)]
              for w, v, r in zip(workloads, variants, ratios)) + 0.9

    bottom = 0.8  # linear lower bound, just under the 1.0x baseline
    rc = {
        "font.size": 8,
        "axes.labelsize": 9,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "legend.fontsize": 8,
        "pdf.fonttype": 42,  # embed TrueType so the text stays selectable
        "ps.fonttype": 42,
        # Journal palette for the non-data ink: near-black text, grey furniture.
        "text.color": CHART_INK,
        "axes.labelcolor": CHART_INK,
        "axes.edgecolor": CHART_AXIS_GREY,
        "axes.linewidth": 0.6,
        "xtick.labelcolor": CHART_INK,
        "ytick.labelcolor": CHART_INK,
    }
    with matplotlib.rc_context(rc):
        fig, ax = plt.subplots(figsize=(7, 2.6))
        sns.barplot(
            x=workloads, y=ratios, hue=variants,
            order=order, hue_order=hue_order,
            palette=PAUL_TOL_VIBRANT[:len(hue_order)],
            errorbar=None,  # seaborn's bootstrap CI off; we draw propagated bars
            edgecolor="none", linewidth=0,
            ax=ax,
        )

        ax.set_ylim(bottom, top)
        ax.yaxis.set_major_locator(mticker.MultipleLocator(1.0))
        ax.set_ylabel("runtime relative to baseline (×)")
        ax.set_xlabel("")

        # Baseline reference: a thin dashed line at 1.0x, labelled in the left
        # margin just above it (every bar sits at or above 1.0, so the left gap
        # is the clear spot).
        ax.axhline(1.0, color=CHART_AXIS_GREY, linewidth=0.8,
                   linestyle=(0, (4, 3)), zorder=1)
        ax.text(0.012, 1.0, "baseline", transform=ax.get_yaxis_transform(),
                ha="left", va="bottom", fontsize=6.5, color="0.5")

        # Propagated error bars plus a stacked label above each bar: the ratio
        # (primary, ink) on top, the equivalent overhead % (secondary, grey)
        # underneath, and a grey "n.s." closest to the bar when the uncertainty
        # spans the baseline. Significance is read from the data, never keyed to a
        # workload name. seaborn emits one BarContainer per hue level in hue_order
        # (its label is a private "_container*" tag, so map by position), each
        # indexed by order.
        for container, variant_display in zip(ax.containers, hue_order):
            for index, workload_label in enumerate(order):
                if index >= len(container):
                    continue
                key = (workload_label, variant_display)
                ratio = ratio_values.get(key)
                if ratio is None or not math.isfinite(ratio):
                    continue
                error = ratio_errors.get(key, 0.0)
                bar = container[index]
                center = bar.get_x() + bar.get_width() / 2
                if error > 0:
                    ax.errorbar(
                        center, ratio, yerr=error, fmt="none",
                        ecolor=CHART_INK, elinewidth=0.8, capsize=2, zorder=5,
                    )
                cap = ratio + error
                # Stack bottom -> top above the error cap; ratio ends up on top.
                stack: list[tuple[str, str, float]] = []
                if nonsignificant_flags.get(key, False):
                    stack.append(("n.s.", "0.5", 6.5))
                relative = overhead_pct.get(key)
                if relative is not None:
                    stack.append((f"{relative:+.1f}%", "0.45", 6.5))
                stack.append((f"{ratio:.2f}×", CHART_INK, 7.0))
                offset = 2.0
                for text, color, size in stack:
                    ax.annotate(
                        text, xy=(center, cap), xytext=(0, offset),
                        textcoords="offset points", ha="center", va="bottom",
                        color=color, fontsize=size,
                    )
                    offset += 8.0

        ax.set_axisbelow(True)  # grid under the bars
        ax.grid(axis="y", color="0.9", linewidth=0.5)
        ax.grid(axis="x", visible=False)
        sns.despine(ax=ax)  # drop the top and right spines
        # Grey tick marks (spine colour comes from axes.edgecolor); tick text
        # stays ink via xtick/ytick.labelcolor above.
        ax.tick_params(color=CHART_AXIS_GREY, width=0.6, length=3)

        handles, labels = ax.get_legend_handles_labels()
        ax.legend(
            handles, labels,
            loc="lower center", bbox_to_anchor=(0.5, 1.0),
            ncol=len(hue_order), frameon=False,
            handlelength=1.2, columnspacing=1.4, borderpad=0.0,
        )

        out_dir.mkdir(parents=True, exist_ok=True)
        output = out_dir / "channel-overhead.pdf"
        # A PDF cannot carry a leading '%'-comment like the .tex tables, so the
        # same batch-provenance string goes into the PDF metadata instead.
        source_note = f"batch {layout.batch_id}; {display_path(layout.matrix_dir)}"
        fig.savefig(
            output, format="pdf", bbox_inches="tight",
            metadata={
                "Creator": "scripts/py/gen_paper_tables.py",
                "Title": "Runtime relative to baseline",
                "Subject": source_note,
            },
        )
        plt.close(fig)
    return output


def oslevel_logs(layout: BatchLayout) -> list[Path]:
    paths = sorted(layout.oslevel_dir.glob("measure-oslevel-*.log"))
    if layout.legacy:
        date_prefix = layout.batch_id.split("-", 1)[0]
        paths = [path for path in paths if date_prefix in path.name]
    return paths


def load_abc(layout: BatchLayout) -> dict[str, dict[str, dict]]:
    by_bench: dict[str, dict[str, dict]] = {}
    for path in oslevel_logs(layout):
        if "-count-" in path.name:
            continue
        state = ("?", "")
        parsed: list[dict] = []
        for line in path.read_text().splitlines():
            header = STATE_HEADER_RE.match(line)
            if header:
                state = header.groups()
                continue
            result = JMH_RESULT_RE.match(line)
            if not result:
                continue
            bench_full, param, count, score, error, unit = result.groups()
            parsed.append({
                "state": state[0], "state_desc": state[1], "benchmark": bench_full,
                "param": param, "count": int(count), "score": float(score),
                "error": float(error), "unit": unit, "path": path,
            })
        if not parsed:
            continue
        bench_full = parsed[0]["benchmark"]
        if "TransitionBenchmark" in bench_full:
            bench = "Transition"
        elif "ParkUnparkBenchmark" in bench_full:
            bench = "ParkUnpark"
        elif "ChurnBenchmark" in bench_full:
            bench = "Churn"
        else:
            warn(f"ABC: unknown benchmark in {path.name}: {bench_full}")
            continue
        if bench in by_bench:
            warn(f"ABC: multiple non-COUNT logs for {bench}; using {path.name}")
        by_bench[bench] = {entry["state"]: entry for entry in parsed}
    return by_bench


def gen_deployed_factorial(layout: BatchLayout, abc: dict[str, dict[str, dict]]) -> str:
    complete: dict[str, dict[str, dict]] = {}
    for bench in BENCH_ORDER:
        states = abc.get(bench, {})
        if all(state in states for state in FACTORIAL_STATE_LABELS):
            complete[bench] = states
        elif states:
            warn(f"deployed factorial: {bench} is incomplete ({', '.join(sorted(states))})")
    if len(complete) != len(BENCH_ORDER):
        return ""

    rows: list[list[str]] = []
    for candidate, reference, label in FACTORIAL_CONTRASTS:
        row = [label]
        for bench in BENCH_ORDER:
            states = complete[bench]
            absolute, error, relative_value, nonsignificant = difference(
                states[candidate]["score"], states[candidate]["error"],
                states[reference]["score"], states[reference]["error"],
            )
            row.append(
                compact_factorial_cell(
                    absolute, error, relative_value, nonsignificant
                )
            )
        rows.append(row)
    return booktabs_table(
        caption=(
            r"Deployed-configuration factorial contrasts. S0 is jvmAlloc off, probes "
            r"off, and no consumer; S1 is jvmAlloc on, probes off, and no consumer; "
            r"S2 is jvmAlloc on, probes on, and no consumer; S3 is jvmAlloc on, probes "
            r"on, with the consumer attached. S1$-$S0 isolates allocation, S2$-$S1 "
            r"the real-buffer probe residual, S2$-$S0 total dormant deployed cost, "
            r"S3$-$S2 observation, and S3$-$S0 total cost with the consumer attached. "
            r"Their percentage denominators are S0, S1, S0, S2, and S0 respectively. "
            r"Cells show difference $\pm$ propagated error in $\mu$s/op and relative "
            r"percentage; n.s. marks zero within that interval."
        ),
        label="tab:dormancy-gradient-results",
        col_spec="lrrr",
        header_cells=["Contrast", "Transition", "Park/unpark", "Churn"],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.oslevel_dir)}",
    )


def gen_deployed_factorial_state_means(
    layout: BatchLayout,
    abc: dict[str, dict[str, dict]],
) -> str:
    rows: list[list[str]] = []
    for bench in BENCH_ORDER:
        states = abc.get(bench, {})
        if not all(state in states for state in FACTORIAL_STATE_LABELS):
            continue
        rows.append([
            latex_escape(bench),
            *[
                f"${fmt(states[state]['score'])} \\pm {fmt(states[state]['error'])}$"
                for state in FACTORIAL_STATE_LABELS
            ],
        ])
    if not rows:
        return ""
    return booktabs_table(
        caption=(
            r"Raw JMH state means for the deployed-configuration factorial. S0 is "
            r"jvmAlloc off, probes off, and no consumer; S1 is jvmAlloc on, probes off, "
            r"and no consumer; S2 is jvmAlloc on, probes on, and no consumer; S3 is "
            r"jvmAlloc on, probes on, with the consumer attached. Values are score "
            r"$\pm$ JMH error in $\mu$s/op."
        ),
        label="tab:deployed-factorial-state-means",
        col_spec="lrrrr",
        header_cells=["Workload", "S0", "S1", "S2", "S3"],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.oslevel_dir)}",
        wide=True,
    )


def load_s3_probe_counters(layout: BatchLayout) -> dict[str, dict[str, int | Path]]:
    """Load the counters produced alongside the same S3 runs parsed by load_abc."""
    by_bench: dict[str, dict[str, int | Path]] = {}
    for path in sorted(layout.oslevel_dir.glob("S3_bpftrace_real_buffer-*.log")):
        match = S3_COUNTER_LOG_RE.match(path.name)
        if not match:
            continue
        bench = {
            "transition": "Transition",
            "parkunpark": "ParkUnpark",
            "churn": "Churn",
        }[match.group(1)]
        counters: dict[str, int] = {}
        for line in path.read_text(errors="replace").splitlines():
            counter = BPFTRACE_COUNTER_RE.match(line)
            if counter:
                name, value = counter.groups()
                counters[name] = int(value)
        missing = {
            "freeze_total", "thaw_total", "start_total", "end_total",
        } - counters.keys()
        if missing:
            warn(f"S3 counters: {path.name} missing {', '.join(sorted(missing))}; skipping")
            continue
        if bench in by_bench:
            warn(f"S3 counters: multiple logs for {bench}; using {path.name}")
        by_bench[bench] = {**counters, "path": path}
    return by_bench


def probe_firing_metrics(bench: str, counters: dict[str, int | Path]) -> tuple[str, float]:
    start_total = int(counters["start_total"])
    if start_total <= 0:
        raise ValueError(f"{bench}: @start_total must be positive")
    ops_scale = {"ParkUnpark": 2, "Churn": 1000}.get(bench, 1)
    ops = start_total / ops_scale
    if ops_scale == 1:
        ops_divisor = f"${start_total}$"
    else:
        rendered_ops = fmt(ops, 0) if ops.is_integer() else fmt(ops)
        ops_divisor = rf"$({start_total}/{ops_scale})={rendered_ops}$"
    total = sum(
        int(counters[field])
        for field in ("freeze_total", "thaw_total", "start_total", "end_total")
    )
    return ops_divisor, total / ops


def gen_probe_firing_cost(
    layout: BatchLayout,
    abc: dict[str, dict[str, dict]],
    counters: dict[str, dict[str, int | Path]],
) -> str:
    rows: list[list[str]] = []
    for bench in BENCH_ORDER:
        states = abc.get(bench, {})
        if not all(state in states for state in ("S2", "S3")) or bench not in counters:
            continue
        ops_divisor, events_per_op = probe_firing_metrics(bench, counters[bench])
        absolute, error, _, nonsignificant = difference(
            states["S3"]["score"], states["S3"]["error"],
            states["S2"]["score"], states["S2"]["error"],
        )
        rows.append([
            latex_escape(bench),
            ops_divisor,
            fmt(events_per_op, 1),
            f"${fmt(absolute / events_per_op * 1000.0)} \\pm "
            f"{fmt(error / events_per_op * 1000.0)}$"
            + (" (n.s.)" if nonsignificant else ""),
        ])
    if not rows:
        return ""
    return booktabs_table(
        caption=(
            r"Observation cost per probe firing. Events/op is "
            r"(@freeze\_total+@thaw\_total+@start\_total+@end\_total)/ops, "
            r"with ops derived from @start\_total directly for Transition, divided "
            r"by two for ParkUnpark, and divided by 1000 for Churn. Cost is the "
            r"S3$-$S2 difference divided by events/op; its error is the propagated "
            r"difference error divided by the same observed count."
        ),
        label="tab:probe-firing-cost",
        col_spec="lrrr",
        header_cells=["Workload", "Ops divisor", "Events/op", "Cost (ns/firing)"],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.oslevel_dir)}",
    )


def gen_factorial_chart(layout: BatchLayout, abc: dict[str, dict[str, dict]]) -> str:
    """Emit a single-column, greyscale pgfplots chart from the table's records."""
    for bench in BENCH_ORDER:
        missing = set(FACTORIAL_STATE_LABELS) - abc.get(bench, {}).keys()
        if missing:
            raise ValueError(f"chart: {bench} missing {', '.join(sorted(missing))}")
    styles = {
        "S0": "draw=black, fill=white",
        "S1": "draw=black, fill=black!20",
        "S2": "draw=black, fill=black!50",
        "S3": "draw=black, fill=black!85",
    }
    legend_labels = {
        "S0": "S0: jvmAlloc off, probes off, no consumer",
        "S1": "S1: jvmAlloc on, probes off, no consumer",
        "S2": "S2: jvmAlloc on, probes on, no consumer",
        "S3": "S3: jvmAlloc on, probes on, consumer attached",
    }
    lines = [
        f"% auto-generated by scripts/py/gen_paper_tables.py -- batch {layout.batch_id}; "
        f"{display_path(layout.oslevel_dir)}",
        r"\begin{tikzpicture}",
        r"  \begin{axis}[",
        r"    width=\columnwidth, height=0.78\columnwidth,",
        r"    ybar=1pt, bar width=4pt, ymode=log, log origin=infty,",
        r"    ylabel={Time ($\mu$s/op)},",
        r"    symbolic x coords={Transition,ParkUnpark,Churn}, xtick=data,",
        r"    xticklabels={Transition,Park/unpark,Churn},",
        r"    tick label style={font=\scriptsize},",
        r"    x tick label style={rotate=18,anchor=east},",
        r"    legend style={font=\scriptsize,draw=none,at={(0.5,1.02)},anchor=south,legend columns=1},",
        r"    error bars/.cd, y dir=both, y explicit,",
        r"  ]",
    ]
    for state in FACTORIAL_STATE_LABELS:
        coordinates = " ".join(
            f"({bench},{abc[bench][state]['score']:.3f}) +- "
            f"(0,{abc[bench][state]['error']:.3f})"
            for bench in BENCH_ORDER
        )
        lines.extend([
            f"    \\addplot+[{styles[state]}] coordinates {{{coordinates}}};",
            f"    \\addlegendentry{{{legend_labels[state]}}}",
        ])
    lines.extend([
        r"  \end{axis}",
        r"\end{tikzpicture}",
    ])
    return "\n".join(lines) + "\n"


def load_nsweep(layout: BatchLayout) -> list[dict]:
    entries: list[dict] = []
    for path in sorted(layout.nsweep_dir.glob("*.json")):
        match = MAIN_JSON_RE.match(path.name)
        if not match:
            continue
        bench, variant = match.groups()
        for data in load_json_entries(path, single=False):
            params = data.get("params", {})
            if len(params) != 1:
                warn(f"N-sweep: skipping entry with params={params} in {path.name}")
                continue
            param_name, param_value = next(iter(params.items()))
            primary = data["primaryMetric"]
            alloc = data.get("secondaryMetrics", {}).get("gc.alloc.rate.norm")
            entries.append({
                "bench": bench, "variant": variant, "param_name": param_name, "n": int(param_value),
                "score": float(primary["score"]), "score_err": float(primary["scoreError"]),
                "score_unit": primary["scoreUnit"],
                "alloc": float(alloc["score"]) if alloc else None,
                "alloc_err": float(alloc["scoreError"]) if alloc else None,
                "alloc_unit": alloc["scoreUnit"] if alloc else None,
            })
    entries.sort(key=lambda e: (bench_sort_key(e["bench"]), variant_sort_key(e["variant"]), e["n"]))
    return entries


def gen_nsweep(layout: BatchLayout, entries: list[dict]) -> str:
    if not entries:
        return ""
    benches = sorted({entry["bench"] for entry in entries}, key=bench_sort_key)
    parts: list[str] = []
    for bench in benches:
        selected = [entry for entry in entries if entry["bench"] == bench]
        baseline = {entry["n"]: entry for entry in selected if entry["variant"] == "baseline"}
        time_rows: list[list[str]] = []
        alloc_rows: list[list[str]] = []
        for entry in selected:
            base = baseline.get(entry["n"])
            time_comparison = None
            if base:
                time_comparison = difference(
                    entry["score"], entry["score_err"],
                    base["score"], base["score_err"],
                )
            time_rows.append([
                latex_escape(variant_label(entry["variant"])), str(entry["n"]),
                f"${fmt(entry['score'])} \\pm {fmt(entry['score_err'])}$",
                fmt(entry["score"] / entry["n"], 5),
                "--" if entry["variant"] == "baseline" or time_comparison is None
                else relative_cell(time_comparison[2], time_comparison[3]),
            ])
            if entry["alloc"] is not None:
                alloc_comparison = None
                if base and base["alloc"] is not None:
                    alloc_comparison = difference(
                        entry["alloc"], entry["alloc_err"],
                        base["alloc"], base["alloc_err"],
                    )
                alloc_rows.append([
                    latex_escape(variant_label(entry["variant"])), str(entry["n"]),
                    f"${fmt(entry['alloc'])} \\pm {fmt(entry['alloc_err'])}$",
                    fmt(entry["alloc"] / entry["n"], 3),
                    "--" if entry["variant"] == "baseline" or alloc_comparison is None
                    else relative_cell(alloc_comparison[2], alloc_comparison[3]),
                ])
        source = f"batch {layout.batch_id}; {display_path(layout.nsweep_dir)}"
        parts.append(booktabs_table(
            caption=(
                f"{latex_escape(bench)} N-sweep, time axis. Per-unit time is raw score divided by N. "
                "n.s. marks zero within the independently propagated error interval."
            ),
            label=f"tab:{bench.lower()}-nsweep-time",
            col_spec="llrrr",
            header_cells=["Variant", "N", r"Time ($\mu$s/op)", r"$\mu$s/N", r"$\Delta t$"],
            rows=time_rows,
            source_note=source,
        ))
        if alloc_rows:
            parts.append(booktabs_table(
                caption=(
                    f"{latex_escape(bench)} N-sweep, allocation axis. Per-unit allocation is raw score divided by N. "
                    "n.s. marks zero within the independently propagated error interval."
                ),
                label=f"tab:{bench.lower()}-nsweep-alloc",
                col_spec="llrrr",
                header_cells=["Variant", "N", "Alloc. (B/op)", "B/N", r"$\Delta$ alloc."],
                rows=alloc_rows,
                source_note=source,
            ))
    return "\n".join(parts)


def classify_count_variant(extra_jvmargs: str) -> str:
    if not extra_jvmargs:
        return "baseline"
    if "publish=jvmti" in extra_jvmargs:
        return "jvmtipublish"
    if "jvmAlloc" in extra_jvmargs:
        return "jvmalloc"
    return extra_jvmargs


def load_probe_counts(layout: BatchLayout) -> list[dict]:
    paths = sorted(layout.oslevel_dir.glob("COUNT-*.txt"))
    if layout.legacy:
        date_prefix = layout.batch_id.split("-", 1)[0]
        paths = [path for path in paths if date_prefix in path.name]
    parsed: list[dict] = []
    for path in paths:
        values = dict(COUNT_KV_RE.findall(path.read_text()))
        missing = [field for field in COUNT_FIELDS if field not in values]
        if missing:
            warn(f"probe counts: {path.name} missing {missing}")
        entry = {key: value.strip("'") for key, value in values.items()}
        entry["path"] = path
        entry["missing_fields"] = missing
        parsed.append(entry)
    return parsed


def gen_probe_counts(layout: BatchLayout, parsed: list[dict]) -> str:
    if not parsed:
        return ""

    rows: list[list[str]] = []
    for values in sorted(parsed, key=lambda v: (bench_sort_key(v.get("bench", "")), variant_sort_key(classify_count_variant(v.get("extra_jvmargs", ""))))):
        rows.append([
            latex_escape({
                "churn": "Churn",
                "parkunpark": "ParkUnpark",
                "transition": "Transition",
            }.get(values.get("bench", ""), values.get("bench", "--"))),
            latex_escape(variant_label(classify_count_variant(values.get("extra_jvmargs", "")))),
            latex_escape(values.get("ops", "--")),
            latex_escape(values.get("freezes_per_op", "--")),
            latex_escape(values.get("top_thaws_per_op", "--")),
            latex_escape(values.get("starts_per_op", "--")),
            latex_escape(values.get("end_unmatched", "--")),
        ])
    return booktabs_table(
        caption="Probe-count validation runs. COUNT-mode timing is intentionally excluded.",
        label="tab:probe-counts",
        col_spec="llrrrrr",
        header_cells=["Workload", "Variant", "Ops", "Freeze/op", "Top thaw/op", "Start/op", "Unmatched"],
        rows=rows,
        source_note=f"batch {layout.batch_id}; {display_path(layout.oslevel_dir)}/COUNT-*.txt",
    )


def batch_log_path(layout: BatchLayout) -> Path:
    if layout.legacy:
        return RESULTS_ROOT / f"run-batch-{layout.batch_id}.log"
    return layout.root / "run-batch.log"


def describe_cells(cells: set[tuple]) -> str:
    return ", ".join("/".join(map(str, cell)) for cell in sorted(cells))


def compare_expected(name: str, actual_items: list[tuple], expected: set[tuple]) -> list[str]:
    issues: list[str] = []
    actual = set(actual_items)
    if len(actual_items) != len(actual):
        issues.append(f"{name} contains duplicate cells")
    missing = expected - actual
    unexpected = actual - expected
    if missing:
        issues.append(f"{name} missing [{describe_cells(missing)}]")
    if unexpected:
        issues.append(f"{name} unexpected [{describe_cells(unexpected)}]")
    return issues


def assert_self_check(
    name: str,
    actual: float,
    expected: float,
    precision: int,
    actual_nonsignificant: bool | None,
    expected_nonsignificant: bool | None,
    unit: str,
    report: bool = True,
) -> None:
    tolerance = 0.5 * 10 ** (-precision)
    if (
        not math.isclose(actual, expected, rel_tol=0.0, abs_tol=tolerance)
        or actual_nonsignificant != expected_nonsignificant
    ):
        significance = (
            "" if actual_nonsignificant is None
            else " n.s." if actual_nonsignificant else " significant"
        )
        fail(
            f"self-check {name}: got {actual:+.{precision}f}{unit}{significance}; "
            f"expected {expected:+.{precision}f}{unit}"
            + (
                "" if expected_nonsignificant is None
                else " n.s." if expected_nonsignificant else " significant"
            )
        )
    significance = (
        "" if actual_nonsignificant is None
        else " n.s." if actual_nonsignificant else " significant"
    )
    if report:
        print(
            f"self-check: PASS {name} {actual:+.{precision}f}{unit}{significance}",
            file=sys.stderr,
        )


def run_batch_self_checks(
    layout: BatchLayout,
    matrix: list[dict],
    abc: dict[str, dict[str, dict]],
) -> None:
    """Pin the formal rerun's paper claims to the parsed source measurements."""
    if layout.batch_id != DEFAULT_BATCH:
        return

    factorial_expectations = (
        ("Churn", "S1", "S0", 90.9, 1, False),
        ("Churn", "S2", "S0", 89.4, 1, False),
        ("Churn", "S2", "S1", -0.78, 2, True),
        ("Churn", "S3", "S2", -4.28, 2, False),
        ("Transition", "S2", "S0", 2.47, 2, True),
        ("Transition", "S3", "S2", 119.6, 1, False),
        ("ParkUnpark", "S2", "S0", 0.57, 2, True),
        ("ParkUnpark", "S3", "S2", 152.2, 1, False),
    )
    for bench, candidate, reference, expected, precision, expected_ns in factorial_expectations:
        states = abc.get(bench, {})
        if candidate not in states or reference not in states:
            continue
        _, _, relative, nonsignificant = difference(
            states[candidate]["score"], states[candidate]["error"],
            states[reference]["score"], states[reference]["error"],
        )
        assert_self_check(
            f"{bench} {candidate}-{reference}", relative, expected, precision,
            nonsignificant, expected_ns, "%",
        )

    s3_s0_expectations = {
        "Transition": (13238.4, 218.7, 125.05),
        "ParkUnpark": (27212.2, 850.0, 153.68),
        "Churn": (336.9, 28.8, 81.28),
    }
    for bench, expected in s3_s0_expectations.items():
        expected_absolute, expected_error, expected_relative = expected
        states = abc.get(bench, {})
        if not {"S0", "S3"} <= states.keys():
            continue
        absolute, error, relative, nonsignificant = difference(
            states["S3"]["score"], states["S3"]["error"],
            states["S0"]["score"], states["S0"]["error"],
        )
        assert_self_check(
            f"{bench} S3-S0 difference", absolute, expected_absolute, 1,
            None, None, " us/op", report=False,
        )
        assert_self_check(
            f"{bench} S3-S0 error", error, expected_error, 1,
            None, None, " us/op", report=False,
        )
        assert_self_check(
            f"{bench} S3-S0 relative", relative, expected_relative, 2,
            nonsignificant, False, "%", report=False,
        )
        print(
            f"self-check: PASS {bench} S3-S0 {absolute:+.1f} +/- {error:.1f} us/op; "
            f"{relative:+.2f}% significant",
            file=sys.stderr,
        )

    matrix_expectations = {
        "Transition": (1.258, 3.045, True),
        "ParkUnpark": (0.584, 3.749, True),
        "Churn": (12.897, 2.212, False),
    }
    for bench, (expected_points, expected_error, expected_ns) in matrix_expectations.items():
        cells = {entry["variant"]: entry for entry in matrix if entry["bench"] == bench}
        if not {"baseline", "agent", "jvmtipublish"} <= cells.keys():
            continue
        baseline = cells["baseline"]
        agent = cells["agent"]
        jvmtipublish = cells["jvmtipublish"]
        points, points_error, nonsignificant = percentage_point_gap(
            jvmtipublish["score"], jvmtipublish["score_err"],
            agent["score"], agent["score_err"],
            baseline["score"], baseline["score_err"],
        )
        assert_self_check(
            f"{bench} JVMTI-agent gap", points, expected_points, 3,
            nonsignificant, expected_ns, " pp", report=False,
        )
        assert_self_check(
            f"{bench} JVMTI-agent gap error", points_error, expected_error, 3,
            None, None, " pp", report=False,
        )
        significance = " n.s." if nonsignificant else " significant"
        print(
            f"self-check: PASS {bench} JVMTI-agent gap "
            f"{points:+.3f} +/- {points_error:.3f} pp{significance}",
            file=sys.stderr,
        )

    churn_matrix = {
        entry["variant"]: entry for entry in matrix if entry["bench"] == "Churn"
    }
    churn_states = abc.get("Churn", {})
    if (
        {"baseline", "jvmalloc"} <= churn_matrix.keys()
        and {"S0", "S1"} <= churn_states.keys()
    ):
        matrix_cost, matrix_error, _, _ = difference(
            churn_matrix["jvmalloc"]["score"], churn_matrix["jvmalloc"]["score_err"],
            churn_matrix["baseline"]["score"], churn_matrix["baseline"]["score_err"],
        )
        factorial_cost, factorial_error, _, _ = difference(
            churn_states["S1"]["score"], churn_states["S1"]["error"],
            churn_states["S0"]["score"], churn_states["S0"]["error"],
        )
        agreement = matrix_cost - factorial_cost
        agreement_error = math.hypot(matrix_error, factorial_error)
        agreement_nonsignificant = abs(agreement) <= agreement_error
        for name, actual, expected in (
            ("Churn matrix allocation cost", matrix_cost, 382.5),
            ("Churn matrix allocation error", matrix_error, 30.9),
            ("Churn factorial allocation cost", factorial_cost, 376.7),
            ("Churn factorial allocation error", factorial_error, 30.4),
            ("Churn allocation agreement", agreement, 5.8),
            ("Churn allocation agreement error", agreement_error, 43.4),
        ):
            assert_self_check(name, actual, expected, 1, None, None, " us/op", report=False)
        if not agreement_nonsignificant:
            fail("self-check Churn allocation cross-validation: zero is outside the interval")
        print(
            "self-check: PASS Churn allocation cross-validation "
            f"matrix {matrix_cost:+.1f} +/- {matrix_error:.1f} us/op; "
            f"factorial {factorial_cost:+.1f} +/- {factorial_error:.1f} us/op; "
            f"difference {agreement:+.1f} +/- {agreement_error:.1f} us/op n.s.",
            file=sys.stderr,
        )


def completeness_issues(
    layout: BatchLayout,
    matrix: list[dict],
    abc: dict[str, dict[str, dict]],
    nsweep: list[dict],
    counts: list[dict],
    s3_counters: dict[str, dict[str, int | Path]],
) -> list[str]:
    """Validate the exact formal-batch contract before writing paper tables."""
    issues: list[str] = []
    log = batch_log_path(layout)
    if not log.is_file():
        issues.append(f"batch completion log missing: {display_path(log)}")
    elif "run-batch RESULT: OK" not in log.read_text(errors="replace"):
        issues.append(f"batch completion log is not successful: {display_path(log)}")

    valid_oslevel_sets = ({"A", "C", "B"}, {"S0", "S1", "S2", "S3"})
    incomplete_abc = [
        bench for bench in BENCH_ORDER
        if set(abc.get(bench, {})) not in valid_oslevel_sets
    ]
    if incomplete_abc:
        issues.append("complete oslevel state set missing for " + ", ".join(incomplete_abc))

    missing_s3_counters = set(BENCH_ORDER) - s3_counters.keys()
    if missing_s3_counters:
        issues.append(
            "S3 probe-counter logs missing for "
            + ", ".join(sorted(missing_s3_counters, key=bench_sort_key))
        )

    if not is_factorial_only(layout):
        issues.extend(compare_expected(
            "matrix",
            [(entry["bench"], entry["variant"]) for entry in matrix],
            EXPECTED_MATRIX_CELLS,
        ))
        issues.extend(compare_expected(
            "N-sweep",
            [(entry["bench"], entry["variant"], entry["n"]) for entry in nsweep],
            EXPECTED_NSWEEP_CELLS,
        ))
        issues.extend(compare_expected(
            "COUNT",
            [
                (entry.get("bench", ""), classify_count_variant(entry.get("extra_jvmargs", "")))
                for entry in counts
            ],
            EXPECTED_COUNT_CELLS,
        ))
        for entry in counts:
            if entry["missing_fields"]:
                issues.append(
                    f"COUNT {entry['path'].name} missing fields: {', '.join(entry['missing_fields'])}"
                )
    return issues


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--batch", default=DEFAULT_BATCH,
        help=f"batch ID, or 'latest' (default: {DEFAULT_BATCH})",
    )
    parser.add_argument("--list-batches", action="store_true", help="list available batch IDs and exit")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR, help="LaTeX output directory")
    parser.add_argument("--allow-partial", action="store_true", help="write available tables instead of failing on missing categories")
    parser.add_argument(
        "--chart", action="store_true",
        help="also emit the deployed-factorial pgfplots fragment",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.list_batches:
        for batch_id, kind in list_batches():
            print(f"{batch_id}\t{kind}")
        return

    layout = resolve_batch(args.batch)
    matrix = load_matrix(layout)
    abc = load_abc(layout)
    nsweep = load_nsweep(layout)
    counts = load_probe_counts(layout)
    s3_counters = load_s3_probe_counters(layout)
    run_batch_self_checks(layout, matrix, abc)
    generated = {
        "tab-dormancy-gradient.tex": gen_deployed_factorial(layout, abc),
        "tab-deployed-factorial-state-means.tex": gen_deployed_factorial_state_means(
            layout, abc
        ),
        "tab-probe-firing-cost.tex": gen_probe_firing_cost(layout, abc, s3_counters),
    }
    if not is_factorial_only(layout):
        generated.update({
            "tab-main-matrix.tex": gen_matrix_table(layout, matrix),
            "tab-jvmti-agent-gap.tex": gen_matrix_gap_table(layout, matrix),
            # "tab-nsweep.tex": gen_nsweep(layout, nsweep),
            # "tab-probe-counts.tex": gen_probe_counts(layout, counts),
        })
    issues = completeness_issues(layout, matrix, abc, nsweep, counts, s3_counters)
    issues.extend(
        f"no generated content for {filename}"
        for filename, content in generated.items() if not content
    )
    if issues and not args.allow_partial:
        fail(
            f"batch {layout.batch_id} is incomplete for paper tables:\n  - "
            + "\n  - ".join(issues)
        )
    for issue in issues:
        warn(f"partial batch: {issue}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for filename in sorted(STALE_OUTPUTS):
        stale = args.out_dir / filename
        if stale.is_file() and stale.read_text(errors="replace").startswith(
            "% auto-generated by scripts/py/gen_paper_tables.py"
        ):
            stale.unlink()
            print(f"removed stale generated table {stale.relative_to(REPO_ROOT) if stale.is_relative_to(REPO_ROOT) else stale}")
    for filename, content in generated.items():
        if not content:
            warn(f"{filename}: no data; not written")
            continue
        output = args.out_dir / filename
        output.write_text(content)
        print(f"wrote {output.relative_to(REPO_ROOT) if output.is_relative_to(REPO_ROOT) else output}")
    if not is_factorial_only(layout):
        chart_pdf = gen_channel_overhead_chart(layout, matrix, args.out_dir)
        if chart_pdf is not None:
            print(f"wrote {chart_pdf.relative_to(REPO_ROOT) if chart_pdf.is_relative_to(REPO_ROOT) else chart_pdf}")
    if args.chart:
        chart_output = args.out_dir / "fig-deployed-factorial.pgfplots.tex"
        try:
            chart_output.write_text(gen_factorial_chart(layout, abc))
        except (KeyError, OSError, ValueError) as exc:
            warn(f"chart emission failed; tables were still generated: {exc}")
        else:
            print(
                "wrote "
                + str(
                    chart_output.relative_to(REPO_ROOT)
                    if chart_output.is_relative_to(REPO_ROOT)
                    else chart_output
                )
            )
    print(f"generated batch: {layout.batch_id} ({'legacy layout' if layout.legacy else layout.root.relative_to(REPO_ROOT)})")


if __name__ == "__main__":
    main()
