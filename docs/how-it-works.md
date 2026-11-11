# How it works

The modified JDK fires four USDT probes on the virtual-thread lifecycle. All four
are gated by the product flag `-XX:+VThreadTraceProbes` (default off): without
the flag, none of them fires.

| Probe | When | Args |
|---|---|---|
| `hotspot:vthread__start` | First mount, once per virtual thread, from `VirtualThread.run()` before user code runs. The first mount goes through no thaw, so without this probe it would be invisible. | `vthread_id`, `trace_buffer_addr` |
| `hotspot:vthread__thaw` | Remount: once with `kind=top`, then once per return-barrier re-entry (several events per logical remount) | `vthread_id`, `thaw_kind`, `trace_buffer_addr` |
| `hotspot:vthread__freeze` | The virtual thread tries to unmount (park/yield); `freeze_result` says whether it unmounted or stayed pinned | `vthread_id`, `freeze_result`, `trace_buffer_addr` |
| `hotspot:vthread__end` | Termination, once per virtual thread, after the task returns. The final unmount goes through no freeze, so without this probe the carrier's entry would never be removed. | `vthread_id` |

`start` fires after the JVMTI `VirtualThreadStart` callback and `end` before the
JVMTI `VirtualThreadEnd` callback, so the consumer's mapping always lies inside
the buffer's lifetime, whichever side (JVM or JVMTI agent) allocates the buffer.

`correlate.bt` maintains two BPF maps keyed by `(uint64)curtask` (the
`task_struct` pointer, unique per OS thread):

```
start                 → @vthread[curtask] = vthread_id
                        @vtbuf[curtask]   = trace_buffer_addr
thaw kind=top         → same insert as start
thaw return_barrier   → ignored (neither insert nor delete)
write                 → if @vthread[curtask] and buffer valid: read traceId/spanId and print
freeze ok/ok_bottom   → delete @vthread[curtask], delete @vtbuf[curtask]
freeze pinned/failed  → keep the carrier cache entry
end                   → delete @vthread[curtask], delete @vtbuf[curtask]
```

Return-barrier thaws are ignored because they can fire even after a virtual
thread has terminated; inserting on them would recreate a stale entry.

**Why four probes, not two.** With only `freeze`/`thaw`, a virtual thread's first
mount leaves its carrier unmapped, and its termination leaves a stale entry that
the next virtual thread on the same carrier inherits. The first case drops
events; the second silently attributes them to the wrong virtual thread. The
correctness harness (`scripts/harness/`) reproduces both failures with
`bpf/harness-2probe.bt` and shows that `bpf/harness-4probe.bt` eliminates them.

The maps are keyed by `curtask` rather than `tid` so the script works correctly
in both container environments (where `bpf_get_ns_current_pid_tgid` may fail)
and on bare-metal Linux.

The pinned/failed-freeze guard matters on JDK 21: a virtual thread that parks
inside a `synchronized` monitor emits `freeze_result=pinned_monitor`, but it
does not unmount from the carrier. The correlator therefore keeps the cache entry
for results `2..4` and only deletes it after successful freeze results `0..1`.
This is what allows writes after a pinned park, still in the same mount window,
to remain correlated.

## Off-heap trace buffer layout

Each virtual thread can have a 64-byte off-heap buffer, allocated by the JVM
(`-Dvthread.trace.jvmAlloc=true`) or by the JVMTI agent. The `BufferSyncContextStorage` wrapper keeps this buffer in sync with the
active OTel span. `correlate.bt` reads the buffer on probe/syscall events only
when the probe address is non-zero and the `valid` byte is set.

| Offset | Size | Field |
|---|---|---|
| 0–15 | 16 bytes | OTel `traceId` (128-bit, written byte-by-byte in W3C/network order) |
| 16–23 | 8 bytes | OTel `spanId` (64-bit, written byte-by-byte in W3C/network order) |
| 24 | 1 byte | `valid` flag: `1` means trace/span fields contain a current valid span |
| 25 | 1 byte | Reserved (defined as `trace-flags` in the merged OTEP 4947; not populated here) |
| 26–27 | 2 bytes | Reserved for future attribute-data size |
| 28–63 | 36 bytes | Reserved for future attribute data |

The virtual-thread ID is not stored in the buffer. It comes from the
`vthread_id` USDT argument and is tracked separately in the `@vthread` BPF map.

**Endianness note:** Java writes traceId/spanId byte-by-byte in the same order as
the canonical OTel hex strings. eBPF reads the fields as raw `uint64` values
(little-endian on ARM64 LE / x86_64), then `bswap()` at print time restores the
display order.

## OTel context synchronisation (`BufferSyncContextStorage`)

`BufferSyncContextStorage` wraps the default OTel `ContextStorage`. On every
`attach()` call it clears the `valid` byte, writes the current span's `traceId`
and `spanId`, publishes those writes with a release fence, then sets `valid=1`.
When there is no valid span it clears bytes `0..23` and leaves `valid=0`.

- **Virtual thread with a buffer** (JVM allocation or the JVMTI agent): the
  buffer's address is stored in `VirtualThread.traceBufferAddress`. Java retrieves the
  address via `Thread.getTraceBufferAddress()` and wraps it in a `MemorySegment`
  without copying.
- **Platform thread, or virtual thread without a buffer**: the address is zero,
  so Java falls back to a per-thread `ThreadLocal` buffer. This keeps the Java
  wrapper usable, but eBPF cannot see that fallback buffer because the USDT probe
  still carries `trace_buffer_addr=0`.

When the scope is closed the wrapper re-syncs the buffer to whatever span is now
current (the enclosing span), so nested spans are handled correctly.

## Enum decoding

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
| 0 | `top` | First thaw event of a remount (fires once per logical remount; a vthread's first mount emits no thaw) |
| 1 | `return_barrier` | Thaw triggered by return barrier |
| 2 | `return_barrier_ex` | Return barrier thaw with exception |
