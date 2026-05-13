# ebpf-vthread-correlate

Proof of concept: use eBPF (bpftrace) to attribute Linux syscalls to specific
Java virtual threads by correlating USDT probes inserted into a modified OpenJDK.

## How it works

The modified JDK fires two USDT probes on the virtual thread carrier path:

| Probe | When | Args |
|---|---|---|
| `hotspot:vthread__thaw` | Virtual thread mounts onto a carrier thread | `vthread_id`, `thaw_kind`, `trace_buffer_addr` |
| `hotspot:vthread__freeze` | Virtual thread yields the carrier thread | `vthread_id`, `freeze_result`, `trace_buffer_addr` |

`correlate.bt` maintains a BPF map keyed by `(uint64)curtask` (the
`task_struct` pointer, unique per OS thread):

```
thaw  → @vthread[curtask] = vthread_id
write → if @vthread[curtask]: print attribution
freeze → delete @vthread[curtask]
```

The map is keyed by `curtask` rather than `tid` so the script works correctly
in both container environments (where `bpf_get_ns_current_pid_tgid` may fail)
and on bare-metal Linux.

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

**`trace_buffer_addr`** is the address of an off-heap buffer allocated per
virtual thread. On thaw, `trace_id` is read from this buffer with `uptr()`,
providing a user-visible correlation token that travels with the vthread.

## Prerequisites

- Linux kernel ≥ 5.8 with BTF enabled
- bpftrace ≥ 0.16
- Self-built OpenJDK with `vthread__thaw` / `vthread__freeze` USDT probes
  (requires `--enable-dtrace` at configure time — see Build section)

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
bash scripts/test.sh              # VThreadTest (normal freeze/thaw)
bash scripts/test.sh PinnedTest   # PinnedTest  (pinned vthreads)
```

## Expected output

### VThreadTest — normal virtual threads

Each virtual thread parks via `LockSupport.parkNanos`, triggering a real
freeze/thaw cycle. Every `println` write is attributed to the correct vthread:

```
[thaw]   carrier tid=267464  vthread_id=0x14  kind=top                trace_buf=0xffff...  trace_id=0
[write]  carrier tid=267464  vthread_id=0x14  fd=1  count=16
[freeze] carrier tid=267464  vthread_id=0x14  result=ok               trace_buf=0xffff...
[thaw]   carrier tid=267464  vthread_id=0x17  kind=top                trace_buf=0xffff...  trace_id=0
[write]  carrier tid=267464  vthread_id=0x17  fd=1  count=13
...
```

Key observations:
- A single carrier thread multiplexes multiple vthreads sequentially.
- Each `[write]` carries the `vthread_id` of the currently-mounted vthread.
- `freeze_result=ok` on normal park; `thaw_kind=top` on first mount, `return_barrier` on subsequent thaws.

### PinnedTest — pinned virtual threads

Virtual threads inside a `synchronized` block cannot be unmounted from their
carrier. The freeze probe fires with `result=pinned_monitor`, and no thaw
events are generated, so writes are **not** attributed to any vthread:

```
[freeze] carrier tid=269571  vthread_id=0x14  result=pinned_monitor   trace_buf=0xffff...
[freeze] carrier tid=269572  vthread_id=0x16  result=pinned_monitor   trace_buf=0xffff...
...
(no [thaw] events, no [write] attributions)
```

This contrast demonstrates that the correlation layer correctly handles both
the normal mount/unmount path and the pinned path without false positives.
