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
freeze → delete @vthread[curtask], delete @vtbuf[curtask]
```

The maps are keyed by `curtask` rather than `tid` so the script works correctly
in both container environments (where `bpf_get_ns_current_pid_tgid` may fail)
and on bare-metal Linux.

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

## Prerequisites

- Linux kernel ≥ 5.8 with BTF enabled
- bpftrace ≥ 0.16
- Maven ≥ 3.8 (for building the Java side)
- `make` and a C compiler such as `gcc` (for building the JVMTI agent)
- Self-built OpenJDK with `vthread__thaw` / `vthread__freeze` USDT probes and
  `Thread.getTraceBufferAddress()` plus a `VirtualThread.traceBufferAddress`
  field (requires `--enable-dtrace` at configure time — see Build section)

## Build the JDK with USDT probes

The probes are gated behind the `dtrace` JVM feature. Two packages are needed
on Fedora/RHEL — `systemtap-sdt-devel` alone is **not** enough:

```bash
sudo dnf install -y systemtap-sdt-dtrace   # provides /usr/bin/dtrace wrapper
sudo dnf install -y systemtap-sdt-devel    # provides /usr/include/sys/sdt.h
```

Configure with `CC`/`CXX` set explicitly to avoid ccache symlink detection errors:

```bash
cd ~/path/to/jdk21u
CC=/usr/bin/gcc CXX=/usr/bin/g++ bash configure \
  --with-boot-jdk=/usr/lib/jvm/java-21-openjdk \
  --enable-ccache \
  --with-debug-level=fastdebug \
  --disable-warnings-as-errors \
  --enable-dtrace
```

Build only the HotSpot library (much faster than `make images`):

```bash
make CONF=linux-aarch64-server-fastdebug hotspot

# Copy the result into the JDK image directory
cp build/linux-aarch64-server-fastdebug/jdk/lib/server/libjvm.so \
   build/linux-aarch64-server-fastdebug/images/jdk/lib/server/libjvm.so
```

Verify probes are present:

```bash
readelf -n build/.../images/jdk/lib/server/libjvm.so | grep vthread
# expect: vthread__thaw and vthread__freeze entries with 3 arguments each
```

## Setup

```bash
cp config/env.sh.example config/env.sh
```

Edit `config/env.sh` and set `JAVA_HOME` and `LIBJVM_PATH` to your patched JDK
build paths. For agent mode, also set `AGENT_PATH` if it is not already present:

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
bash scripts/run.sh
```

**Terminal 2 — run a Java test:**

```bash
# OTel-instrumented virtual threads with the JVMTI trace-buffer agent enabled.
bash scripts/run-otel-agent.sh

# Equivalent explicit form:
USE_AGENT=1 bash scripts/run-otel.sh

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
  `sudo bpftrace`.
- `scripts/run-otel.sh`: builds the shaded jar with Maven and runs
  `uk.ac.ncl.jensen.VThreadTest` with the patched JDK.
- `scripts/run-otel-agent.sh`: wrapper for `USE_AGENT=1 scripts/run-otel.sh`.
- `scripts/test.sh`: compiles the project and runs a selected Java class from
  `target/classes`; defaults to `uk.ac.ncl.jensen.VThreadTest`.
- `config/env.sh`: local machine-specific paths used by all scripts.

## Expected output

### VThreadTest (OTel) — normal virtual threads with trace correlation

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

### PinnedTest — pinned virtual threads

Virtual threads inside a `synchronized` block cannot be unmounted from their
carrier. `PinnedTest` creates this workload by parking inside a monitor. The JVM
freeze probe reports `result=pinned_monitor`, but the current bpftrace script
prints only events whose trace buffer has `valid=1`.

Because `PinnedTest` does not create OTel spans or install
`BufferSyncContextStorage`, a plain `bash scripts/test.sh PinnedTest` run may
produce no bpftrace lines. That is expected with the current valid-flag guard:
there is no valid trace context to print. If you instrument a pinned workload
with OTel context, pinned freeze events should appear with `result=pinned_monitor`
when the buffer is valid.

## Benchmarking

A JMH benchmark (`ContextStorageBenchmark`) measures the overhead of
`BufferSyncContextStorage` relative to the default OTel `ContextStorage`:

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

## Running with the JVMTI agent (Plan A)

The current implementation uses **Plan A**: the JVM exposes an empty
`VirtualThread.traceBufferAddress` field and the USDT probes, while the JVMTI
agent owns buffer allocation. On `VirtualThreadStart` the agent allocates a
zeroed 64-byte buffer and stores its address in the field; on
`VirtualThreadEnd` it frees the buffer and clears the field. The JVM does not
know about OpenTelemetry or the buffer layout.

**1. Build the agent** (once, or after editing the agent source):

```bash
source config/env.sh
make -C JVMTI-agent         # produces libvthread_trace_agent.so
```

**2. Run the Java side with the agent attached:**

```bash
# Explicit toggle:
USE_AGENT=1 bash scripts/run-otel.sh

# Or the convenience wrapper (same thing):
bash scripts/run-otel-agent.sh

# Verbose agent logging is supported by run-otel.sh:
AGENT_OPTS=verbose USE_AGENT=1 bash scripts/run-otel.sh

# test.sh honours the same toggle (e.g. for PinnedTest):
USE_AGENT=1 bash scripts/test.sh PinnedTest
```

The agent path comes from `AGENT_PATH` in `config/env.sh`. The local
configuration in this repo points it at `JVMTI-agent/libvthread_trace_agent.so`.

**Agent mode vs default mode:** with `USE_AGENT=1` the agent allocates the
per-vthread buffer so eBPF can read live `traceId`/`spanId`; without it the JVM
runs in degraded mode (no buffer allocated, so eBPF sees no trace context).
