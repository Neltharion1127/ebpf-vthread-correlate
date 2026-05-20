# ebpf-vthread-correlate

Proof of concept: use eBPF (bpftrace) to attribute Linux syscalls to specific
Java virtual threads, and correlate those syscalls with their OpenTelemetry
trace/span IDs — all without modifying application code.

The system has two parts:

1. **eBPF side** (`bpf/correlate.bt`): a bpftrace script that hooks USDT probes
   in a modified JDK to track which virtual thread is mounted on each carrier OS
   thread, then reads the OTel trace context directly from an off-heap buffer on
   every `write(2)` syscall.

2. **Java side** (`BufferSyncContextStorage`): a custom OTel `ContextStorage`
   wrapper that keeps the per-vthread off-heap buffer in sync with the current
   OTel span whenever a scope is opened or closed.

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
write → if @vthread[curtask]: read traceId/spanId from @vtbuf[curtask] and print
freeze → delete @vthread[curtask], delete @vtbuf[curtask]
```

The maps are keyed by `curtask` rather than `tid` so the script works correctly
in both container environments (where `bpf_get_ns_current_pid_tgid` may fail)
and on bare-metal Linux.

### Off-heap trace buffer layout

Each virtual thread has a 64-byte off-heap buffer allocated by the JVM. The
`BufferSyncContextStorage` wrapper keeps this buffer in sync with the active OTel
span. `correlate.bt` reads the buffer on every probe and syscall event.

| Offset | Size | Field |
|---|---|---|
| 0–7 | 8 bytes | Virtual thread ID (int64, written by JVM at construction) |
| 8–23 | 16 bytes | OTel `traceId` (128-bit, written big-endian byte-by-byte) |
| 24–31 | 8 bytes | OTel `spanId` (64-bit, written big-endian byte-by-byte) |
| 32–63 | 32 bytes | Reserved |

**Endianness note:** Java writes traceId/spanId byte-by-byte (big-endian /
network order). eBPF reads raw `uint64` values (little-endian on ARM64 LE /
x86_64), then `bswap()` at print time converts back to big-endian so the hex
output matches the OTel canonical string representation.

### OTel context synchronisation (`BufferSyncContextStorage`)

`BufferSyncContextStorage` wraps the default OTel `ContextStorage`. On every
`attach()` call it writes the current span's `traceId` and `spanId` into the
thread's trace buffer:

- **Virtual thread**: the JVM allocates the buffer internally; its address is
  retrieved via `Thread.getTraceBufferAddress()` and wrapped into a
  `MemorySegment` without copying.
- **Platform thread**: no JVM-internal buffer exists, so a 64-byte buffer is
  allocated per platform thread on demand using `Arena.global()` and stored in a
  `ThreadLocal`.

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
- Self-built OpenJDK with `vthread__thaw` / `vthread__freeze` USDT probes and
  `Thread.getTraceBufferAddress()` (requires `--enable-dtrace` at configure time
  — see Build section)

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
# Set LIBJVM_PATH and JAVA_HOME to your JDK build paths
```

## Running

Open two terminals.

**Terminal 1 — start the eBPF tracer:**

```bash
bash scripts/run.sh
```

**Terminal 2 — run a Java test:**

```bash
# OTel-instrumented virtual threads (normal freeze/thaw, with traceId/spanId output)
bash scripts/run-otel.sh

# Pinned virtual threads (demonstrates pinned_monitor detection)
bash scripts/test.sh PinnedTest
```

## Expected output

### VThreadTest (OTel) — normal virtual threads with trace correlation

Each virtual thread parks via `LockSupport.parkNanos`, triggering a real
freeze/thaw cycle. `BufferSyncContextStorage` keeps the trace buffer up to date
as child and inner spans open and close, so every `[write]` line carries the
correct OTel `traceId` and `spanId` for the span active at the time of the
syscall.

```
[thaw]   carrier tid=267464  vthread_id=0x14  kind=top                traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[write]  carrier tid=267464  vthread_id=0x14  fd=1  count=80          traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[freeze] carrier tid=267464  vthread_id=0x14  result=ok               traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[thaw]   carrier tid=267464  vthread_id=0x17  kind=top                traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
[write]  carrier tid=267464  vthread_id=0x17  fd=1  count=75          traceId=4bf92f3577b34da6a3ce929d0e0e4736  spanId=00f067aa0ba902b7
...
```

Key observations:
- A single carrier thread multiplexes multiple vthreads sequentially.
- Each `[write]` carries the `vthread_id` **and** the OTel `traceId`/`spanId`
  of the span active at the time of the syscall, read directly from the
  off-heap buffer — no JVM cooperation at syscall time.
- `freeze_result=ok` on normal park; `thaw_kind=top` on first mount,
  `return_barrier` on subsequent thaws.
- When a nested inner span is active, the `spanId` on `[write]` events matches
  the inner span, not the child span, confirming the buffer is updated correctly
  on scope open/close.

### PinnedTest — pinned virtual threads

Virtual threads inside a `synchronized` block cannot be unmounted from their
carrier. The freeze probe fires with `result=pinned_monitor`, and no thaw
events are generated, so writes are **not** attributed to any vthread:

```
[freeze] carrier tid=269571  vthread_id=0x14  result=pinned_monitor   traceId=0000000000000000000000000000000000  spanId=0000000000000000
[freeze] carrier tid=269572  vthread_id=0x16  result=pinned_monitor   traceId=0000000000000000000000000000000000  spanId=0000000000000000
...
(no [thaw] events, no [write] attributions)
```

This contrast demonstrates that the correlation layer correctly handles both
the normal mount/unmount path and the pinned path without false positives.

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
buffer writes). The overhead is dominated by two `MemorySegment` byte-by-byte
writes (16 + 8 bytes) per scope attach/close, executed on the critical path of
every OTel scope transition.
