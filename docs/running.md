# Running

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

# Without a buffer allocator: Java still runs, but the probes report
# trace_buffer_addr=0, so correlate.bt cannot print traceId/spanId.
bash scripts/run-otel.sh

# Run a specific test class.
bash scripts/test.sh PinnedTest
```

`scripts/test.sh` accepts either a short class name such as `PinnedTest` or a
fully-qualified name. It also honours `USE_AGENT=1`.

## Script reference

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
  `QUICK=1 scripts/profile-matrix.sh` for a fast run that produces only the GC
  JSON and the summary table.
- `scripts/run-usdt.sh`: separately checks the `-XX:+VThreadTraceProbes`
  USDT-gated path under a JMH harness with bpftrace attached.
- `config/env.sh`: local machine-specific paths used by all scripts.

## Buffer allocation: JVM or JVMTI agent

The per-vthread buffer can be allocated in two ways, which the paper compares:

- **JVM allocation** (`-Dvthread.trace.jvmAlloc=true`): the patched JDK
  allocates a zeroed 64-byte buffer in `VirtualThread.start()` and frees it in
  `afterDone()`. The correctness harness and the formal S0–S3 benchmarks use
  this path.
- **JVMTI agent** (`USE_AGENT=1`): on `VirtualThreadStart` the agent allocates
  the buffer and stores its address in `VirtualThread.traceBufferAddress`; on
  `VirtualThreadEnd` it frees the buffer and clears the field. The JVM does not
  need to know about OpenTelemetry or the buffer layout.

The example runs above use the agent. The agent path comes from `AGENT_PATH` in
`config/env.sh`; build it once (or after editing the agent source) with
`make -C JVMTI-agent`, then run the Java side with `USE_AGENT=1`
(`run-otel-agent.sh`, or `USE_AGENT=1` on `run-otel.sh` / `test.sh`).

If neither path allocates a buffer, the Java program still runs, but the probes
report `trace_buffer_addr=0` and `correlate.bt` cannot read any trace context.

**`publish=jvmti` mode:** the default agent mode allocates/frees buffers only;
the correlator still uses the JVM's USDT probe arguments to publish the mounted
buffer address into BPF maps. With `AGENT_OPTS=publish=jvmti`, or the JMH
`-agentpath:$AGENT_PATH=publish=jvmti` profile, the agent also registers
`VirtualThreadMount`/`VirtualThreadUnmount` extension callbacks and writes the
mounted vthread's buffer address into a carrier-local TLS slot. This mode exists
to compare the per-transition cost of a JVMTI callback publish path against the
USDT publish path. `correlate.bt` currently reads the USDT-provided address; it
does not read the agent's TLS slot.

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

With the four-probe `correlate.bt`, each virtual thread also prints one
`[start]` line at its first mount and one `[end]` line when it terminates.

Key observations:
- A single carrier thread multiplexes multiple vthreads sequentially.
- Each `[write]` carries the `vthread_id` **and** the OTel `traceId`/`spanId`
  of the span active at the time of the syscall, read directly from the
  off-heap buffer — no JVM cooperation at syscall time.
- `freeze_result=ok` on normal park; a vthread's FIRST mount emits no thaw at
  all. Each remount emits one `thaw_kind=top` followed by a stack-depth-
  dependent number of `return_barrier` thaws (e.g. 12 events on a shallow
  stack in a single measurement; logs in `result/blindspot/`). Events
  with `trace_buffer_addr=0` or `valid=0` are intentionally not printed.
- When a nested inner span is active, the `spanId` on `[write]` events matches
  the inner span, not the child span, confirming the buffer is updated correctly
  on scope open/close.

### PinnedTest — pinned virtual threads

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
