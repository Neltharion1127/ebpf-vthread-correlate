# ebpf-vthread-correlate

Companion code for the paper *Towards Runtime-Aware Observability for Java
Virtual Threads* (Wenjie Ding, arXiv preprint, 2026). The raw data behind every
table and figure in the paper is in [`paper-data/`](paper-data/), together with
instructions for regenerating them.

The project uses eBPF to attribute Linux syscalls to specific Java virtual
threads, and correlates those syscalls with their OpenTelemetry trace/span IDs
without changing the application's syscall call sites. It requires a patched
OpenJDK 21, [Neltharion1127/jdk21u](https://github.com/Neltharion1127/jdk21u)
(branch `vthread-lifecycle-probes`, release tag `vthread-probes-v2`).

The system has four moving parts:

1. **Patched JDK** ([jdk21u](https://github.com/Neltharion1127/jdk21u)): adds
   four USDT probes on the virtual-thread lifecycle (`vthread__start`,
   `vthread__thaw`, `vthread__freeze`, `vthread__end`), gated by the product
   flag `-XX:+VThreadTraceProbes`, and a `VirtualThread.traceBufferAddress`
   field. With `-Dvthread.trace.jvmAlloc=true`, the JVM itself allocates a
   64-byte off-heap trace buffer for each virtual thread in `start()` and frees
   it in `afterDone()`.

2. **eBPF side** (`bpf/correlate.bt`): a bpftrace script that consumes the four
   probes to track which virtual thread is mounted on each carrier OS thread,
   then reads the OTel trace context directly from that thread's buffer on every
   `write(2)` syscall.

3. **Java side** (`BufferSyncContextStorage`): a custom OTel `ContextStorage`
   wrapper that keeps the per-vthread buffer in sync with the current OTel span
   whenever a scope is opened or closed.

4. **JVMTI agent** (`JVMTI-agent/vthread_trace_agent.c`): an alternative way to
   allocate the buffer from outside the JVM, used in the paper as a controlled
   comparison with JVM-side allocation. Its opt-in `publish=jvmti` mode also
   publishes the buffer address to a carrier TLS slot on every mount/unmount,
   as Elastic's agent does.

The repo also contains the dual-channel **correctness harness** used in the
paper (`scripts/harness/`, see [Correctness harness](docs/correctness-harness.md)) and
JMH benchmarks for the overhead questions the paper measures:

- per-scope OTel context storage overhead (`ContextStorageBenchmark`)
- per-transition virtual-thread mount/unmount overhead
  (`VThreadTransitionBenchmark`, `VThreadParkUnparkBenchmark`)
- per-vthread lifecycle/allocation overhead (`VThreadChurnBenchmark`)

For the internals — probes, buffer layout, enum decoding — see
[docs/how-it-works.md](docs/how-it-works.md).

## Repository layout

```
bpf/                 bpftrace consumers: correlate.bt (full), correlate-probesonly.bt
                     (benchmark consumer), harness-{2,4}probe.bt (correctness harness)
JVMTI-agent/         JVMTI agent: alternative buffer allocator, optional publish=jvmti mode
src/main/java/       BufferSyncContextStorage, MarkerHarness, JMH benchmarks, examples
scripts/             run/test helpers; run-batch.sh (formal batch), measure-oslevel.sh
                     (S0–S3), profile-matrix.sh (benchmark matrix)
scripts/harness/     correctness harness: run-harness.sh, reconcile.py
scripts/py/          gen_paper_tables.py: paper tables and figure from a batch
repro/blindspot/     reproducers for the two-probe failure modes
paper-data/          raw data behind the paper's tables and figures
docs/                detailed documentation
```

## Quick start

Four steps to reproduce the benchmarks from a clean checkout:

1. **Clone the repo.** It is paired with a companion
   [`jdk21u`](https://github.com/Neltharion1127/jdk21u) fork that ships the
   modified OpenJDK as a pre-built release. `./setup.sh` pulls that JDK for you,
   so you do **not** have to build OpenJDK.

   ```bash
   git clone https://github.com/Neltharion1127/ebpf-vthread-correlate
   cd ebpf-vthread-correlate
   ```
2. **Run `scripts/env-bootstrap.sh`.** It installs the necessary dependencies.

3. **Run `./setup.sh`.** It detects your CPU arch, downloads the matching
   pre-built vthread-trace JDK from the `jdk21u` release, verifies its SHA256,
   extracts it under `.vthread-jdk/`, generates `config/env.sh`, and reports any
   missing external tools (bpftrace, async-profiler, Maven).

   ```bash
   ./setup.sh
   ```

   See [Setup](docs/setup.md#setup) for what it writes and the self-built-JDK alternative.

4. **Smoke-test, then run the formal batch.** Run a short smoke test once, then
   let the batch driver build and run every paper experiment under one ID.

   ```bash
   F=1 WI=1 I=1 scripts/measure-oslevel.sh  # short, non-citable smoke test
   taskset -c 2-15 scripts/run-batch.sh     # formal S0–S3 + COUNT + N-sweep + matrix
   ```

   Read [Benchmarking](docs/benchmarking.md#benchmarking) and
   [Reproducible measurement](docs/benchmarking.md#reproducible-measurement) before trusting numbers.

For how the correlation actually works, see [How it works](docs/how-it-works.md).

## Reproducing the paper

| Paper result | How to reproduce |
|---|---|
| Correctness (§7.2, Table 6) | `scripts/harness/run-harness.sh <4probe\|2probe> <clean\|leaky>` — see [docs/correctness-harness.md](docs/correctness-harness.md) |
| Cost decomposition and two-channel comparison (§7.3–7.4, Tables 7–8, Figure 2) | `taskset -c 2-15 scripts/run-batch.sh` on bare metal, then `python3 scripts/py/gen_paper_tables.py --batch <batch-id>` — see [docs/benchmarking.md](docs/benchmarking.md) |
| The paper's tables, from the published data | see [paper-data/README.md](paper-data/README.md) |

## Documentation

| Document | Contents |
|---|---|
| [docs/setup.md](docs/setup.md) | prerequisites, `setup.sh`, `config/env.sh`, the JVMTI agent build |
| [docs/running.md](docs/running.md) | running the tracer and the example programs, script reference, buffer allocation modes, expected output |
| [docs/benchmarking.md](docs/benchmarking.md) | JMH benchmarks, the benchmark matrix, S0–S3 cost decomposition, bare-metal measurement and the formal batch |
| [docs/correctness-harness.md](docs/correctness-harness.md) | the dual-channel correctness harness |
| [docs/how-it-works.md](docs/how-it-works.md) | the four probes, BPF map rules, buffer layout, context synchronisation, enum decoding |
| [docs/building-jdk.md](docs/building-jdk.md) | building the patched JDK from source |
