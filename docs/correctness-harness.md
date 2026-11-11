# Correctness harness

`scripts/harness/run-harness.sh` checks attribution against an independent
ground truth (paper §7.2). A Java harness (`MarkerHarness`) starts N virtual
threads that each issue M marker `write(2)` calls, whose byte counts encode the
sender and sequence number, and records the expected trace context and virtual
thread for every marker in `manifest.csv`. A bpftrace consumer records what it
attributes to the same syscalls, without going through the harness.

```bash
scripts/harness/run-harness.sh <4probe|2probe> <clean|leaky> [N] [M]   # defaults: N=16, M=8
```

- `4probe` / `2probe` select `bpf/harness-4probe.bt` (start/end + top-level
  thaw/successful freeze) or `bpf/harness-2probe.bt` (freeze/thaw only).
- `leaky` leaves the final scope open, so a terminated virtual thread's buffer
  still holds `valid=1`; `clean` closes it.
- The JVM runs with `-XX:+VThreadTraceProbes -Dvthread.trace.jvmAlloc=true`.
  The script looks for a patched JDK build under `../jdk21u/build/`; set `JDK=`
  to override. It needs Maven, bpftrace and sudo.

Each run writes `result/harness/<timestamp>-<variant>-<mode>/`, and
`scripts/harness/reconcile.py` classifies every marker on two planes: the
**content plane** (is the trace context correct?) and the **identity plane** (is
it attributed to the right virtual thread?). The runs used in the paper are in
[`paper-data/correctness/`](../paper-data/).
