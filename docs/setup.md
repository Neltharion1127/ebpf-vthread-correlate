# Prerequisites and setup

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
  table, and `scripts/harness/reconcile.py` classifies the correctness runs.
- **bpftrace ≥ 0.16**, run as **root/sudo** — only the USDT / OS-level scripts
  (`scripts/run.sh`, `scripts/run-usdt.sh`, `scripts/measure-oslevel.sh`,
  `scripts/harness/run-harness.sh`) use it.
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
- **[jdk21u](https://github.com/Neltharion1127/jdk21u) source** (branch
  `vthread-lifecycle-probes`) — produces the `libjvm` carrying the four
  `vthread__*` USDT probes and the `-XX:+VThreadTraceProbes` flag, plus the
  `VirtualThread.traceBufferAddress` field, `Thread.getTraceBufferAddress()` and
  the optional JVM-side buffer allocation. See
  [Appendix: Building the JDK yourself](building-jdk.md).

**root/sudo scope:** only the bpftrace scripts above need `sudo`; `setup.sh`,
`scripts/profile-matrix.sh`, and `scripts/gen-flamegraphs.sh` all run as your
normal user.

All scripts use the single patched JDK configured in `config/env.sh`. The probe
flag (`-XX:±VThreadTraceProbes`) and the allocation property
(`-Dvthread.trace.jvmAlloc`) are chosen per run on the command line.

## Setup

`./setup.sh` is the main path. It writes `config/env.sh` — the single source of
truth for JDK paths — with `JAVA_HOME`, `LIBJVM_PATH`, and `JDK` already filled
in, so every script in this repo finds the pre-built JDK with no manual editing.

Only if you built the JDK yourself instead of using the release download, copy
the template and edit the paths by hand:

```bash
cp config/env.sh.example config/env.sh   # then edit JAVA_HOME / LIBJVM_PATH
```

See [Appendix: Building the JDK yourself](building-jdk.md)
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
