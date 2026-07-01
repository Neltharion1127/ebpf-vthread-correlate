# ebpf-vthread-correlate

Proof of concept: use eBPF (bpftrace) to attribute Linux syscalls to specific
Java virtual threads, and correlate those syscalls with their OpenTelemetry
trace/span IDs without changing the application's syscall call sites.

The system has three moving parts:

1. **eBPF side** (`bpf/correlate.bt`): a bpftrace script that hooks USDT probes
   in a modified JDK to track which virtual thread is mounted on each carrier OS
   thread, then reads the OTel trace context directly from an off-heap buffer on
   every `write(2)` syscall.

2. **Java side** (`BufferSyncContextStorage`): a custom OTel `ContextStorage`
   wrapper that keeps the per-vthread off-heap buffer in sync with the current
   OTel span whenever a scope is opened or closed.

3. **JVMTI agent** (`JVMTI-agent/vthread_trace_agent.c`): an optional runtime
   agent that allocates and frees a 64-byte trace buffer for each virtual thread
   and stores the raw address in the patched `VirtualThread.traceBufferAddress`
   field. Without the agent the Java program still runs, but the USDT probe
   reports `trace_buffer_addr=0`, so `correlate.bt` skips trace-context reads.
   (It also has an opt-in `publish=jvmti` mode used only for overhead
   comparison — see [Running](#running).)

The repo also contains JMH benchmarks for the three overhead questions this
prototype currently measures:

- per-scope OTel context storage overhead (`ContextStorageBenchmark`)
- per-transition virtual-thread mount/unmount overhead
  (`VThreadTransitionBenchmark`, `VThreadParkUnparkBenchmark`)
- per-vthread lifecycle/allocation overhead (`VThreadChurnBenchmark`)

For the internals — probes, buffer layout, enum decoding — see
[How it works](#how-it-works).

## Quick start

Three steps to reproduce the benchmarks from a clean checkout:

1. **Clone the repo.** It is paired with a companion `jdk21u` fork that ships the
   modified OpenJDK as a pre-built release. `./setup.sh` pulls that JDK for you,
   so you do **not** have to build OpenJDK.

   ```bash
   git clone https://github.com/Neltharion1127/ebpf-vthread-correlate
   cd ebpf-vthread-correlate
   ```
2. **Run `/scripts/env-bootstrap.sh`.** It will install necessary denpencies.

3. **Run `./setup.sh`.** It detects your CPU arch, downloads the matching
   pre-built vthread-trace JDK from the `jdk21u` release, verifies its SHA256,
   extracts it under `.vthread-jdk/`, generates `config/env.sh`, and reports any
   missing external tools (bpftrace, async-profiler, Maven).

   ```bash
   ./setup.sh
   ```

   See [Setup](#setup) for what it writes and the self-built-JDK alternative.

3. **Smoke-test, then run the matrix.** Confirm the harness works with the A/C/B
   OS-level smoke test first, then run the full benchmark matrix.

   ```bash
   scripts/measure-oslevel.sh      # A/C/B smoke test — confirms the harness works
   scripts/profile-matrix.sh       # full benchmark matrix (QUICK=1 for a fast pass)
   ```

   Read [Benchmarking](#benchmarking) and
   [Reproducible measurement](#reproducible-measurement) before trusting numbers.

For how the correlation actually works, see [How it works](#how-it-works).

## Prerequisites

The test machine runs a **pre-built release JDK** that `./setup.sh` downloads,
checksum-verifies, and wires into `config/env.sh` — you do **not** need to build
OpenJDK to run the benchmarks. Dependencies therefore split into two groups.

Two of them are architecture-specific and must match the test machine's CPU
(`x86_64` or `aarch64`), exactly like the JDK download:

- the pre-built vthread-trace JDK (`setup.sh` selects the asset for `uname -m`)
- the async-profiler `.so` placed at `lib/libasyncProfiler.so`

### Test-machine runtime dependencies (given the pre-built release JDK)

- **glibc ≥ 2.31** — the pre-built JDK is compiled in an `ubuntu:20.04`
  (glibc 2.31) container, so it is forward-compatible with newer Linux but will
  not start on older glibc.
- **wget, tar, sha256sum** — normally preinstalled; `setup.sh` uses them to
  download, unpack, and verify the JDK.
- **Maven ≥ 3.8** — builds the shaded JMH jar. The POM forks
  `$JAVA_HOME/bin/javac`, so `JAVA_HOME` must point at the pre-built JDK; running
  `source config/env.sh` first ensures that.
- **make + gcc** — `scripts/profile-matrix.sh` runs `make -C JVMTI-agent` to
  compile the agent `.so`. The JVMTI/JNI headers come from the pre-built JDK, so
  no separate JDK-dev package is needed.
- **python3** (standard library only) — `profile-matrix.sh` parses the results
  table.
- **bpftrace ≥ 0.16**, run as **root/sudo** — only the USDT / OS-level scripts
  (`scripts/run.sh`, `scripts/run-usdt.sh`, `scripts/measure-oslevel.sh`) use it.
  The `profile-matrix.sh` JMH matrix never touches bpftrace.
- **Linux kernel ≥ 5.8 with BTF enabled** — needed for bpftrace to read the USDT
  probes.
- **async-profiler 4.4** at `lib/libasyncProfiler.so` — used by the itimer pass
  of a full (non-`QUICK`) `profile-matrix.sh` run. The presence guard is
  unconditional, so `QUICK=1` runs still require the file to exist even though
  that mode never reads it — put the matching-arch `.so` in place before running
  either way.

### Only when building the JDK yourself (skip when using the release JDK)

- **systemtap-sdt-devel** — provides `sys/sdt.h` and `/usr/bin/dtrace`, required
  by `--enable-dtrace`.
- **boot JDK 21 + gcc/g++ + autoconf** — the OpenJDK `configure` / `make`
  toolchain.
- **jdk21u source** — produces the `libjvm` carrying the `vthread__freeze` /
  `vthread__thaw` USDT probes and `Thread.getTraceBufferAddress()` (plus the
  `VirtualThread.traceBufferAddress` field). See
  [Appendix: Building the JDK yourself](#appendix-building-the-jdk-yourself).

**root/sudo scope:** only the bpftrace scripts above need `sudo`; `setup.sh`,
`scripts/profile-matrix.sh`, and `scripts/gen-flamegraphs.sh` all run as your
normal user.

The current scripts assume two possible custom-JDK variants:

- the normal patched JDK in `config/env.sh`, used for Java runs, the agent, and
  the benchmark matrix
- an optional release-flag JDK used by `scripts/run-usdt.sh` to compare
  `-XX:-VThreadTraceProbes`, `-XX:+VThreadTraceProbes` with bpftrace attached,
  and `-XX:+VThreadTraceProbes` without bpftrace

## Setup

`./setup.sh` is the main path. It writes `config/env.sh` — the single source of
truth for JDK paths — with `JAVA_HOME`, `LIBJVM_PATH`, and `JDK` already filled
in, so every script in this repo finds the pre-built JDK with no manual editing.

Only if you built the JDK yourself instead of using the release download, copy
the template and edit the paths by hand:

```bash
cp config/env.sh.example config/env.sh   # then edit JAVA_HOME / LIBJVM_PATH
```

See [Appendix: Building the JDK yourself](#appendix-building-the-jdk-yourself)
for the correct release build paths.

Agent mode and the benchmark matrix also read `AGENT_PATH`, which `setup.sh` does
not write. If it is not already in your `config/env.sh`, add this line (it
resolves relative to the file, so the repo can move):

```bash
export AGENT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/JVMTI-agent/libvthread_trace_agent.so"
```

Build the JVMTI agent if you want eBPF to read live OTel trace context:

```bash
source config/env.sh
cd JVMTI-agent
make
```

## Running

Open two terminals.

**Terminal 1 — start the eBPF tracer:**

```bash
# Verbose validation mode, current script default.
bash scripts/run.sh

# Summary/perf mode: no per-event printf, counters printed at END.
VERBOSE=0 bash scripts/run.sh
```

**Terminal 2 — run a Java test:**

```bash
# OTel-instrumented virtual threads with the JVMTI trace-buffer agent enabled.
bash scripts/run-otel-agent.sh

# Equivalent explicit form:
USE_AGENT=1 bash scripts/run-otel.sh

# Enable verbose agent logging or the optional JVMTI publish path.
AGENT_OPTS=verbose USE_AGENT=1 bash scripts/run-otel.sh
AGENT_OPTS=publish=jvmti USE_AGENT=1 bash scripts/run-otel.sh

# Degraded mode: Java still runs, but the USDT probe reports trace_buffer_addr=0,
# so correlate.bt cannot print traceId/spanId from the virtual-thread buffer.
bash scripts/run-otel.sh

# Run a specific test class.
bash scripts/test.sh PinnedTest
```

`scripts/test.sh` accepts either a short class name such as `PinnedTest` or a
fully-qualified name. It also honours `USE_AGENT=1`.

### Script reference

- `scripts/run.sh`: substitutes `LIBJVM_PATH` into `bpf/correlate.bt` and starts
  `sudo bpftrace`. It passes `${VERBOSE:-1}` to the bpftrace script, so plain
  `bash scripts/run.sh` is verbose validation mode and `VERBOSE=0 bash
  scripts/run.sh` is summary/perf mode.
- `scripts/run-otel.sh`: builds the shaded jar with Maven and runs
  `uk.ac.ncl.jensen.VThreadTest` with the patched JDK. It honours
  `USE_AGENT=1` and appends `AGENT_OPTS` to `-agentpath` when set.
- `scripts/run-otel-agent.sh`: wrapper for `USE_AGENT=1 scripts/run-otel.sh`.
- `scripts/test.sh`: compiles the project and runs a selected Java class from
  `target/classes`; defaults to `uk.ac.ncl.jensen.VThreadTest`.
- `scripts/profile-matrix.sh`: builds the agent and shaded JMH jar, runs the
  benchmark matrix, and generates GC JSON, tables, and flame graphs. Use
  `QUICK=1 scripts/profile-matrix.sh` for the fast GC/Table A-only run.
- `scripts/run-usdt.sh`: separately checks the `-XX:+VThreadTraceProbes`
  USDT-gated path under a JMH harness with bpftrace attached.
- `config/env.sh`: local machine-specific paths used by all scripts.

### JVMTI agent (Plan A)

The current implementation uses **Plan A**: the JVM exposes an empty
`VirtualThread.traceBufferAddress` field and the USDT probes, while the JVMTI
agent owns buffer allocation. On `VirtualThreadStart` the agent allocates a
zeroed 64-byte buffer and stores its address in the field; on
`VirtualThreadEnd` it frees the buffer and clears the field. The JVM does not
know about OpenTelemetry or the buffer layout.

The agent path comes from `AGENT_PATH` in `config/env.sh`; the local
configuration in this repo points it at `JVMTI-agent/libvthread_trace_agent.so`.
Build it once (or after editing the agent source) with `make -C JVMTI-agent`,
then run the Java side with `USE_AGENT=1` — the Terminal 2 commands above are the
supported entry points (`run-otel-agent.sh`, or `USE_AGENT=1` on `run-otel.sh` /
`test.sh`).

**Agent mode vs default mode:** with `USE_AGENT=1` the agent allocates the
per-vthread buffer so eBPF can read live `traceId`/`spanId`; without it the JVM
runs in degraded mode (no buffer allocated, so eBPF sees no trace context).

**`publish=jvmti` mode:** the default agent mode allocates/frees buffers only;
the correlator still uses the JVM's USDT probe arguments to publish the mounted
buffer address into BPF maps. With `AGENT_OPTS=publish=jvmti`, or the JMH
`-agentpath:$AGENT_PATH=publish=jvmti` profile, the agent also registers
`VirtualThreadMount`/`VirtualThreadUnmount` extension callbacks and writes the
mounted vthread's buffer address into a carrier-local TLS slot. This mode exists
to compare the per-transition cost of a JVMTI callback publish path against the
USDT publish path. `correlate.bt` currently reads the USDT-provided address; it
does not read the agent's TLS slot.

### Expected output

#### VThreadTest (OTel) — normal virtual threads with trace correlation

Each virtual thread parks via `LockSupport.parkNanos`, triggering a real
freeze/thaw cycle. `BufferSyncContextStorage` keeps the trace buffer up to date
as child and inner spans open and close. Once the buffer has `valid=1`, `[write]`
lines carry the `traceId` and `spanId` for the span active at the time of the
syscall. Early mount events can be skipped if the virtual thread has not entered
an OTel scope yet.

```
[write]  carrier tid=267464  vthread_id=0x14  fd=1  count=80          traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[freeze] carrier tid=267464  vthread_id=0x14  result=ok               traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[thaw]   carrier tid=267464  vthread_id=0x14  kind=return_barrier     traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[write]  carrier tid=267464  vthread_id=0x17  fd=1  count=75          traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
...
```

Key observations:
- A single carrier thread multiplexes multiple vthreads sequentially.
- Each `[write]` carries the `vthread_id` **and** the OTel `traceId`/`spanId`
  of the span active at the time of the syscall, read directly from the
  off-heap buffer — no JVM cooperation at syscall time.
- `freeze_result=ok` on normal park; `thaw_kind=top` on first mount,
  `return_barrier` on subsequent thaws. Events with `trace_buffer_addr=0` or
  `valid=0` are intentionally not printed.
- When a nested inner span is active, the `spanId` on `[write]` events matches
  the inner span, not the child span, confirming the buffer is updated correctly
  on scope open/close.

#### PinnedTest — pinned virtual threads

Virtual threads inside a `synchronized` block cannot be unmounted from their
carrier. `PinnedTest` creates this workload by parking inside a monitor. The JVM
freeze probe reports `result=pinned_monitor`, but the current bpftrace script
prints only events whose trace buffer has `valid=1`.

`VThreadTest` now also includes an OTel-instrumented pinned-monitor phase. It
first performs an unpinned park so the thaw path populates the carrier cache,
then parks inside a private monitor and writes after the pinned park. That final
write should remain correlated because `correlate.bt` keeps the cache entry on
pinned freeze results.

Because `PinnedTest` does not create OTel spans or install
`BufferSyncContextStorage`, a plain `bash scripts/test.sh PinnedTest` run may
produce no bpftrace lines. That is expected with the current valid-flag guard:
there is no valid trace context to print. If you instrument a pinned workload
with OTel context, pinned freeze events should appear with `result=pinned_monitor`
when the buffer is valid.

## Benchmarking

`ContextStorageBenchmark` measures the overhead of `BufferSyncContextStorage`
relative to the default OTel `ContextStorage`:

```bash
source config/env.sh   # exports JAVA_HOME so Maven uses the custom JDK
mvn clean package -q
"$JAVA_HOME/bin/java" --enable-preview --enable-native-access=ALL-UNNAMED \
     -jar target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar \
     -prof gc
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

# Fast JSON/Table A-only run: no itimer profiling or flame graphs.
QUICK=1 bash scripts/profile-matrix.sh
```

It runs:

| Benchmark | Purpose |
|---|---|
| `VThreadTransitionBenchmark` | one virtual thread performs many `Thread.yield()` calls; isolates per freeze/thaw transition cost |
| `VThreadParkUnparkBenchmark` | two virtual threads ping-pong with `LockSupport.park()`/`unpark()`; closer to blocking handoff behavior |
| `VThreadChurnBenchmark` | starts and joins many short-lived virtual threads; isolates lifecycle allocation/free cost |

`profile-matrix.sh` records GC JSON under `result/benchmark/` for these
launch-time configurations. In full mode it also records collapsed itimer stacks
under `result/benchmark/collapsed/` and regenerates flame graphs under
`result/figures/`; with `QUICK=1` it skips those profiling outputs.

| Profile | Meaning |
|---|---|
| `baseline` | patched JDK, no JVMTI agent, no bpftrace |
| `agent` | `-agentpath:$AGENT_PATH`; buffer lifecycle callbacks only |
| `jvmtipublish` | `-agentpath:$AGENT_PATH=publish=jvmti`; lifecycle plus JVMTI mount/unmount publish callback |
| `jvmalloc` | `-Dvthread.trace.jvmAlloc=true`; JVM-side allocation path when supported by the patched JDK |

### The matrix cells (why 10, not 12)

`profile-matrix.sh` runs **10 cells**: the three workloads crossed with a
per-workload subset of the four variants, not the full 3 × 4 = 12 product. Two
combinations are deliberately left out.

| Workload | Variants run | Omitted |
|---|---|---|
| `VThreadTransitionBenchmark` | `baseline`, `agent`, `jvmtipublish`, `jvmalloc` | — |
| `VThreadParkUnparkBenchmark` | `baseline`, `jvmtipublish`, `jvmalloc` | `agent` |
| `VThreadChurnBenchmark` | `baseline`, `agent`, `jvmalloc` | `jvmtipublish` |

Each variant is only paired with the workloads where it changes the thing that
workload isolates:

- `agent` adds per-vthread **lifecycle** (start/end) buffer allocation cost, so
  it is run for Transition and Churn. It is dropped for ParkUnpark, whose two
  long-lived vthreads ping-pong for the whole run and hit almost no lifecycle
  events — `agent` there would essentially reproduce `baseline`.
- `jvmtipublish` adds per-**transition** mount/unmount callback cost, so it is
  run for the two transition-heavy workloads (Transition and ParkUnpark). It is
  dropped for Churn, whose short-lived threads barely mount/unmount, so the
  publish path is not what that workload stresses.
- `baseline` and `jvmalloc` run for all three.

### Two profiling passes per cell

For every cell `profile-matrix.sh` runs the benchmark twice, for two different
purposes:

- **`-prof gc`** — a clean pass at JMH's annotation `@Fork`/`@Warmup` defaults
  with no profiler attached. This gives the trustworthy `Score` (time) and
  `gc.alloc.rate.norm` (bytes/op) that feed Table A and the `*_gc.json` files.
- **`-prof async event=itimer output=collapsed`** — an itimer-sampled pass whose
  **time is discarded**; it exists only for CPU attribution (the collapsed
  stacks that become the plain and differential flame graphs). `QUICK=1` skips
  this pass entirely.

The USDT publish cost is measured separately because a USDT consumer must be
attached when the benchmark fork starts:

```bash
bash scripts/run-usdt.sh
```

That script uses its own `JDK`, `JAVA`, and `LIBJVM` defaults, overridable by
environment variables, and writes logs under `result/benchmark/usdt-flag/`.
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
  taskset -c 2,3 scripts/profile-matrix.sh
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

## How it works

The modified JDK fires two USDT probes on the virtual thread carrier path:

| Probe | When | Args |
|---|---|---|
| `hotspot:vthread__thaw` | Virtual thread mounts onto a carrier thread | `vthread_id`, `thaw_kind`, `trace_buffer_addr` |
| `hotspot:vthread__freeze` | Virtual thread yields the carrier thread | `vthread_id`, `freeze_result`, `trace_buffer_addr` |

`correlate.bt` maintains two BPF maps keyed by `(uint64)curtask` (the
`task_struct` pointer, unique per OS thread):

```
thaw  → @vthread[curtask] = vthread_id
        @vtbuf[curtask]   = trace_buffer_addr
write → if @vthread[curtask] and buffer valid: read traceId/spanId and print
freeze ok/ok_bottom → delete @vthread[curtask], delete @vtbuf[curtask]
freeze pinned/failed → keep the carrier cache entry
```

The maps are keyed by `curtask` rather than `tid` so the script works correctly
in both container environments (where `bpf_get_ns_current_pid_tgid` may fail)
and on bare-metal Linux.

The pinned/failed-freeze guard matters on JDK 21: a virtual thread that parks
inside a `synchronized` monitor emits `freeze_result=pinned_monitor`, but it
does not unmount from the carrier. The correlator therefore keeps the cache entry
for results `2..4` and only deletes it after successful freeze results `0..1`.
This is what allows writes after a pinned park, still in the same mount window,
to remain correlated.

### Off-heap trace buffer layout

Each virtual thread can have a 64-byte off-heap buffer allocated by the JVMTI
agent. The `BufferSyncContextStorage` wrapper keeps this buffer in sync with the
active OTel span. `correlate.bt` reads the buffer on probe/syscall events only
when the probe address is non-zero and the `valid` byte is set.

| Offset | Size | Field |
|---|---|---|
| 0–15 | 16 bytes | OTel `traceId` (128-bit, written byte-by-byte in W3C/network order) |
| 16–23 | 8 bytes | OTel `spanId` (64-bit, written byte-by-byte in W3C/network order) |
| 24 | 1 byte | `valid` flag: `1` means trace/span fields contain a current valid span |
| 25 | 1 byte | Reserved |
| 26–27 | 2 bytes | Reserved for future attribute-data size |
| 28–63 | 36 bytes | Reserved for future attribute data |

The virtual-thread ID is not stored in the buffer. It comes from the
`vthread_id` USDT argument and is tracked separately in the `@vthread` BPF map.

**Endianness note:** Java writes traceId/spanId byte-by-byte in the same order as
the canonical OTel hex strings. eBPF reads the fields as raw `uint64` values
(little-endian on ARM64 LE / x86_64), then `bswap()` at print time restores the
display order.

### OTel context synchronisation (`BufferSyncContextStorage`)

`BufferSyncContextStorage` wraps the default OTel `ContextStorage`. On every
`attach()` call it clears the `valid` byte, writes the current span's `traceId`
and `spanId`, publishes those writes with a release fence, then sets `valid=1`.
When there is no valid span it clears bytes `0..23` and leaves `valid=0`.

- **Virtual thread with the JVMTI agent**: the agent allocates the buffer and
  stores its address in `VirtualThread.traceBufferAddress`. Java retrieves the
  address via `Thread.getTraceBufferAddress()` and wraps it in a `MemorySegment`
  without copying.
- **Platform thread, or virtual thread without the agent**: the address is zero,
  so Java falls back to a per-thread `ThreadLocal` buffer. This keeps the Java
  wrapper usable, but eBPF cannot see that fallback buffer because the USDT probe
  still carries `trace_buffer_addr=0`.

When the scope is closed the wrapper re-syncs the buffer to whatever span is now
current (the enclosing span), so nested spans are handled correctly.

### Enum decoding

The script decodes the numeric enum values from the JVM source into
human-readable strings using BPF maps initialised in `BEGIN`:

**`freeze_result`** (from `continuationFreezeThaw.cpp`):

| Value | Name | Meaning |
|---|---|---|
| 0 | `ok` | Normal freeze succeeded |
| 1 | `ok_bottom` | Freeze reached bottom of continuation |
| 2 | `pinned_cs` | Pinned by critical section |
| 3 | `pinned_native` | Pinned by native frame |
| 4 | `pinned_monitor` | Pinned by `synchronized` monitor |
| 5 | `exception` | Freeze failed with exception |

**`thaw_kind`** (from `continuation.hpp`):

| Value | Name | Meaning |
|---|---|---|
| 0 | `top` | Initial thaw, mounting vthread for the first time |
| 1 | `return_barrier` | Thaw triggered by return barrier |
| 2 | `return_barrier_ex` | Return barrier thaw with exception |

## Appendix: Building the JDK yourself

You only need this if you are **not** using the pre-built release JDK that
`./setup.sh` downloads. Most reproducers should just run `./setup.sh` — see
[Quick start](#quick-start). Build from source only when you are modifying the
JVM itself.

The probes are gated behind the `dtrace` JVM feature. Two packages are needed
on Fedora/RHEL — `systemtap-sdt-devel` alone is **not** enough:

```bash
sudo dnf install -y systemtap-sdt-dtrace   # provides /usr/bin/dtrace wrapper
sudo dnf install -y systemtap-sdt-devel    # provides /usr/include/sys/sdt.h
```

Both methods below produce a **release** JDK, never fastdebug: a fastdebug
`libjvm` distorts the benchmark ratios, and `profile-matrix.sh` aborts if it
detects one. Throughout, `<arch>` is `x86_64` or `aarch64`, so the build
configuration is named `linux-<arch>-server-release`. Set `CC`/`CXX` explicitly
on the `configure` line to avoid ccache symlink-detection errors.

### Method A — distributable release build (glibc-compatible)

This is how the current release JDK is actually built. Configure and build the
whole image inside an `ubuntu:20.04` container (glibc 2.31) so the binaries run
on any Linux with glibc ≥ 2.31, then tar the image.

```bash
# inside an ubuntu:20.04 container, in the jdk21u source tree:
CC=/usr/bin/gcc CXX=/usr/bin/g++ bash configure \
  --with-boot-jdk=/path/to/boot-jdk-21 \
  --with-debug-level=release \
  --enable-dtrace \
  --disable-warnings-as-errors \
  --with-native-debug-symbols=none

make images

# package the whole image for distribution (top-level dir is jdk/):
tar -C build/linux-<arch>-server-release/images -czf jdk-vthread-<arch>.tar.gz jdk
```

`make images` produces the complete JDK under
`build/linux-<arch>-server-release/images/jdk`. That directory is what `setup.sh`
ships and what `config/env.sh`'s `JAVA_HOME` points at.

### Method B — fast local iteration (rebuild libjvm only)

When you are editing JVM code and re-compiling repeatedly, rebuilding the whole
image every time is slow. Configure release once, then rebuild only HotSpot:

```bash
CC=/usr/bin/gcc CXX=/usr/bin/g++ bash configure \
  --with-boot-jdk=/path/to/boot-jdk-21 \
  --enable-ccache \
  --with-debug-level=release \
  --enable-dtrace \
  --disable-warnings-as-errors

# recompile just libjvm.so (much faster than `make images`):
make CONF=linux-<arch>-server-release hotspot
```

`make hotspot` writes the freshly built library into the **exploded image**, not
the packaged image:

```
build/linux-<arch>-server-release/jdk/lib/server/libjvm.so           # refreshed by `make hotspot`
build/linux-<arch>-server-release/images/jdk/lib/server/libjvm.so    # refreshed only by `make images`
```

The exploded image (`build/linux-<arch>-server-release/jdk`) is itself a runnable
JDK — it has a working `bin/java` and now carries your rebuilt `libjvm.so`. The
simplest correct setup is therefore to point `config/env.sh` straight at it, with
**no copy**:

```bash
CONF=linux-<arch>-server-release            # <arch> = x86_64 | aarch64
export JAVA_HOME="/path/to/jdk21u/build/$CONF/jdk"
export LIBJVM_PATH="$JAVA_HOME/lib/server/libjvm.so"
export JDK="$JAVA_HOME"
```

If instead your `config/env.sh` points at the packaged `images/jdk`, a bare
`make hotspot` does **not** refresh it. You must then either re-run
`make CONF=linux-<arch>-server-release images`, or copy the rebuilt library over
the packaged one:

```bash
cp build/$CONF/jdk/lib/server/libjvm.so \
   build/$CONF/images/jdk/lib/server/libjvm.so
```

That copy only works if `images/jdk` already exists from a previous
`make images`. On a release tree that has only ever had `make hotspot` run,
`images/jdk` does not exist and the copy fails — which is why the old
fastdebug-era recipe cannot be followed verbatim. Point `env.sh` at the exploded
`jdk/` image instead.

### Verify the probes are present

Either way, confirm the USDT probes made it into the library `config/env.sh`
points at:

```bash
readelf -n "$LIBJVM_PATH" | grep vthread
# expect: vthread__thaw and vthread__freeze entries with 3 arguments each
```
