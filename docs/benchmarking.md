# Benchmarking and reproducible measurement

## Benchmarking

`ContextStorageBenchmark` measures the overhead of `BufferSyncContextStorage`
relative to the default OTel `ContextStorage`:

```bash
source config/env.sh   # exports JAVA_HOME so Maven uses the custom JDK
mvn clean package -q
"$JAVA_HOME/bin/java" --enable-preview --enable-native-access=ALL-UNNAMED \
     -jar target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar \
     ContextStorageBenchmark -prof gc
```

The benchmark runs `makeCurrent()` + child span creation + `close()` in a tight
loop for both `useBufferSync=false` (baseline) and `useBufferSync=true` (with
buffer writes). In buffer-sync mode each scope transition clears `valid`, writes
16 bytes of trace ID and 8 bytes of span ID, publishes with release fences, and
sets `valid=1` when the span context is valid.

The current virtual-thread benchmark matrix is driven by `scripts/profile-matrix.sh`:

```bash
source config/env.sh
make -C JVMTI-agent
bash scripts/profile-matrix.sh

# Fast run (GC JSON + summary table only): no itimer profiling or flame graphs.
QUICK=1 bash scripts/profile-matrix.sh
```

It runs:

| Benchmark | Purpose |
|---|---|
| `VThreadTransitionBenchmark` | one virtual thread performs many `Thread.yield()` calls; isolates per freeze/thaw transition cost |
| `VThreadParkUnparkBenchmark` | two virtual threads ping-pong with `LockSupport.park()`/`unpark()`; closer to blocking handoff behavior |
| `VThreadChurnBenchmark` | starts and joins many short-lived virtual threads; isolates lifecycle allocation/free cost |

When run standalone, `profile-matrix.sh` uses the legacy result paths. The formal
`run-batch.sh` driver supplies batch-scoped paths under
`result/benchmark/batches/<batch-id>/` for the matrix JSON, N-sweep, OS-level
logs, collapsed stacks, flame graphs, provenance, and the complete batch log.
An existing batch ID is never overwritten.

| Profile | Meaning |
|---|---|
| `baseline` | patched JDK, no JVMTI agent, no bpftrace |
| `agent` | `-agentpath:$AGENT_PATH`; buffer lifecycle callbacks only |
| `jvmtipublish` | `-agentpath:$AGENT_PATH=publish=jvmti`; lifecycle plus JVMTI mount/unmount publish callback |
| `jvmalloc` | `-Dvthread.trace.jvmAlloc=true`; JVM-side allocation path when supported by the patched JDK |

### The matrix cells (full 12-cell product)

`profile-matrix.sh` runs all **12 cells** in the three-workload by four-variant
product.

| Workload | Variants run | Omitted |
|---|---|---|
| `VThreadTransitionBenchmark` | `baseline`, `agent`, `jvmtipublish`, `jvmalloc` | — |
| `VThreadParkUnparkBenchmark` | `baseline`, `agent`, `jvmtipublish`, `jvmalloc` | — |
| `VThreadChurnBenchmark` | `baseline`, `agent`, `jvmtipublish`, `jvmalloc` | — |

The full product keeps the primary workload/variant pairings and adds controls
where a variant is expected to have little effect:

- `agent` adds per-vthread **lifecycle** (start/end) buffer allocation cost.
  ParkUnpark's two long-lived vthreads make its `agent` cell a useful control
  alongside the lifecycle-heavy Churn result.
- `jvmtipublish` adds per-**transition** mount/unmount callback cost. Churn's
  short-lived threads make its `jvmtipublish` cell a useful control alongside
  the transition-heavy workloads.
- `baseline` and `jvmalloc` run for all three.

### Two profiling passes per cell

For every cell `profile-matrix.sh` runs the benchmark twice, for two different
purposes:

- **`-prof gc`** — a clean pass at JMH's annotation `@Fork`/`@Warmup` defaults
  with no profiler attached. This gives the trustworthy `Score` (time) and
  `gc.alloc.rate.norm` (bytes/op) that feed the summary table and the `*_gc.json`
  files.
- **`-prof async event=itimer output=collapsed`** — an itimer-sampled pass whose
  **time is discarded**; it exists only for CPU attribution (the collapsed
  stacks that become the plain and differential flame graphs). `QUICK=1` skips
  this pass entirely.

The USDT publication and observation costs are measured separately, because a
USDT consumer must be attached when the benchmark fork starts.
`scripts/measure-oslevel.sh` (called by `run-batch.sh`) runs the paper's S0–S3
cost decomposition:

| State | `jvmAlloc` | Probes | Consumer |
|---|---|---|---|
| S0 | off | off | none |
| S1 | on | off | none |
| S2 | on | on | none |
| S3 | on | on | `correlate-probesonly.bt` attached |

S1−S0 is the allocation cost, S2−S1 the publication residual, and S3−S2 the
observation cost. The S3 consumer maintains the map and counts events but does
not read the buffer. For a quick standalone check of the flag-gated probe path:

```bash
bash scripts/run-usdt.sh
```

That script takes the JDK from `JDK=` if set, otherwise from `config/env.sh`,
and refuses to fall back to the system JDK; `JAVA` and `LIBJVM` default to paths
inside that JDK. It writes logs under `result/benchmark/usdt-flag/`.
The container/OrbStack results are useful for direction and smoke testing; final
numbers should be collected on bare metal.

## Reproducible measurement

Every timing number this repo can produce inside a VM or container is
**directional only** — good for smoke-testing the orchestration
(`measure-oslevel.sh`, `run-usdt.sh` both say so explicitly) and for relative
direction, but the time axis is dominated by VM/hypervisor noise. Absolute
overhead figures must be collected on **bare metal**, echoing the "final numbers
should be collected on bare metal" note under [Benchmarking](#benchmarking).

Before collecting citable numbers on a bare-metal Linux host, pin the machine
into a low-variance state:

- **CPU frequency governor → performance** (stop it chasing load):

  ```bash
  sudo cpupower frequency-set -g performance
  # or, without cpupower, write sysfs directly:
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo performance | sudo tee "$f" >/dev/null
  done
  ```

- **Disable turbo boost** (so the clock does not drift mid-run):

  ```bash
  # intel_pstate driver:
  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null
  # generic cpufreq (acpi-cpufreq / amd):
  echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null
  ```

- **Disable SMT / hyper-threading** where the platform allows it, to remove
  sibling-core contention:

  ```bash
  echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null
  ```

- **Pin the benchmark to dedicated cores** with `taskset` — ideally cores you
  have isolated from the scheduler (`isolcpus=` on the kernel command line). The
  affinity mask is inherited by the JMH fork children:

  ```bash
  taskset -c 2-15 scripts/run-batch.sh
  ```

- **ASLR and THP both add run-to-run variance.** Disable transparent huge pages,
  and — only on a dedicated bench host — turn ASLR off while measuring:

  ```bash
  echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
  echo 0     | sudo tee /proc/sys/kernel/randomize_va_space         >/dev/null
  # restore randomize_va_space to 2 afterwards.
  ```

Restore the governor, turbo, SMT, and ASLR settings afterwards if the machine is
shared.

### Formal batch preflight and EC2 bare metal

`scripts/run-batch.sh` performs a read-only preflight before it creates a batch
directory or builds anything. It fails when an exposed CPU governor is not
`performance`, when an exposed turbo/boost control says boost is enabled, when
the source worktree is dirty, or when `PROF_EVENT=cpu` lacks the required perf
sysctls. It records but does not silently infer settings whose kernel interfaces
are unavailable.

Check an experiment host without creating output or starting a build:

```bash
PREFLIGHT_ONLY=1 scripts/run-batch.sh
```

On supported Intel EC2 instances, Turbo Boost can be disabled from Linux when
`intel_pstate/no_turbo` is exposed:

```bash
sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'
```

[AWS does not allow EC2 CPU options](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-cpu-options-rules.html)
(including `ThreadsPerCore=1`) for bare-metal instances. Consequently SMT is a
warning by default on EC2 metal rather than a hard failure.
`REQUIRE_SMT_OFF=1` upgrades it to a hard requirement on hosts where the
experiment controls SMT. CPU affinity behaves similarly: the default preflight
warns when the batch is not pinned, while `REQUIRE_CPU_PINNING=1` requires a
restricted `taskset` mask. AWS also documents the
[`intel_pstate/no_turbo` procedure](https://docs.aws.amazon.com/linux/al2/ug/processor_state_control.html)
for supported Intel EC2 instances.

The escape hatches `ALLOW_TURBO=1` and `ALLOW_DIRTY=1` are deliberate and are
recorded in RUNINFO; do not use them for the primary paper batch without stating
the deviation. Generate the selected batch's paper tables with:

```bash
python3 scripts/py/gen_paper_tables.py --list-batches
python3 scripts/py/gen_paper_tables.py --batch <batch-id>
```
