# paper-data — raw data for the arXiv paper

This directory holds the raw data behind every table and figure in the evaluation of

> Wenjie Ding. *Towards Runtime-Aware Observability for Java Virtual Threads.* arXiv preprint, 2026.

Everything here is copied unmodified from the original result directories, with one
exception: the EC2 instance hostname in the `RUNINFO-*.txt` files is replaced by
`<ec2-host>`.

## Layout

```
paper-data/
├── correctness/                       12 runs of the dual-channel correctness harness
│   └── <timestamp>-<protocol>-<scope>/
│       ├── manifest.csv               ground truth: expected trace context + virtual thread per marker
│       ├── consumer.log               what the eBPF consumer attributed (+ bpftrace counters at exit)
│       ├── java.log                   harness JVM output
│       ├── reconcile.log              human-readable output of scripts/harness/reconcile.py
│       └── summary.json               machine-readable output of reconcile.py
└── benchmark/20260803-formal-rerun-1/ the formal JMH batch (bare-metal x86-64)
    ├── RUNINFO-*.txt, build-artifacts.sha256, run-batch.log   provenance
    ├── oslevel/                       S0–S3 cost-decomposition runs + probe-count runs
    ├── matrix/                        baseline / jvmalloc / agent / jvmtipublish JMH JSON
    └── nsweep/                        N-sweep (not used in the paper; required by the table generator)
```

## Where each result in the paper comes from

| Paper | Source |
|---|---|
| Table 5, performance column | `benchmark/…/RUNINFO-*.txt`, `build-artifacts.sha256` |
| Table 6 (correctness) | `correctness/*/summary.json`, summed per protocol and scope mode (see run list below) |
| §7.2: all two-probe failures at the first marker; content-correct but identity-wrong markers | `per_seq` in `summary.json`; per-marker cross-tabulation by re-running `reconcile.py` |
| §5.4: `freeze_unmatched` / `end_unmatched` stay at zero; 128 insertions = 128 deletions | bpftrace counters at the end of `correctness/*-4probe-*/consumer.log` |
| Table 4 configurations, Table 7 (cost decomposition) | `benchmark/…/oslevel/S{0,1,2,3}_*.log` |
| §7.3 probe events per operation (20,021 / 39,364 / 2,000) | counters in `benchmark/…/oslevel/S3_bpftrace_real_buffer-*.log` |
| Figure 2, Table 8, §7.4 (two-channel comparison) | `benchmark/…/matrix/*.json` |

### Correctness runs

| Protocol | Scope mode | Runs |
|---|---|---|
| four-probe | clean | `20260719-044802…`, `20260811-154505…`, `20260811-163526…`, `20260811-164501…`, `20260811-170222…` |
| four-probe | leaky-final | `20260719-044814…` |
| two-probe | clean | `20260719-044825…`, `20260811-154551…`, `20260811-163547…`, `20260811-164522…`, `20260811-170242…` |
| two-probe | leaky-final | `20260719-044855…` |

Each run uses 16 virtual threads × 8 markers = 128 markers. The runs were made on an
aarch64 virtual machine (Fedora 43, Linux 7.2, bpftrace 0.24.2) with the patched JDK
built from tag `vthread-probes-v2`. Earlier runs made while the harness itself was being
developed are not included.

## Reproducing the numbers

**Correctness (Table 6).** `reconcile.py` writes `summary.json` next to the manifest,
so work on a copy:

```bash
cp -r paper-data/correctness /tmp/correctness
for r in /tmp/correctness/*; do
  python3 scripts/harness/reconcile.py "$r/manifest.csv" "$r/consumer.log"
done
# each regenerated summary.json is identical to the archived one
```

**Benchmark tables and Figure 2.** `scripts/py/gen_paper_tables.py` reads batches from
`result/benchmark/batches/` (git-ignored), so place the batch there first:

```bash
mkdir -p result/benchmark/batches
cp -r paper-data/benchmark/20260803-formal-rerun-1 result/benchmark/batches/
python3 scripts/py/gen_paper_tables.py --batch 20260803-formal-rerun-1 --out-dir /tmp/tables
```

This writes the LaTeX tables and `channel-overhead.pdf` (the figure needs matplotlib and
seaborn). The generated tables reproduce Tables 7 and 8 of the paper exactly.
