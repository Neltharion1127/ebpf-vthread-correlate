package uk.ac.ncl.jensen.benchmark;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.concurrent.TimeUnit;

/**
 * Benchmark #1 — virtual-thread mount/unmount (transition) overhead.
 *
 * Workload (W2): one virtual thread performs N {@code Thread.yield()} calls. On a
 * virtual thread, yield() unmounts the continuation (freeze) and remounts it
 * (thaw), so N yields == N freeze/thaw cycles with near-zero blocking wall time.
 * This is the right primitive for isolating per-transition cost — Thread.sleep
 * would bury an ns/us-scale signal under milliseconds of timer wait.
 *
 * Per op = (1 vthread start) + (N transitions) + (1 vthread end). With N large the
 * start/end (and the JVMTI agent's buffer alloc/free, if the agent is loaded) are
 * amortised to ~0; per-transition cost  ≈  reported_op_time / N. The lifecycle
 * cost is measured separately by VThreadChurnBenchmark.
 *
 * Configurations are chosen at JVM LAUNCH, not via @Param, because -agentpath and
 * a USDT consumer must be present when the fork starts. Use profile-matrix.sh:
 *   - baseline : custom JDK, no agent, no bpftrace
 *   - +agent   : -agentpath:libvthread_trace_agent.so
 *                Tests whether merely acquiring can_support_virtual_threads slows
 *                the transition path. The agent's own comment claims it does NOT;
 *                baseline-vs-+agent here is the experiment that confirms/refutes it.
 *   - +usdt    : correlate.bt attached in perf mode (HOTSPOT_VTHREAD_*_ENABLED
 *                flips true) — measures the JVM-modification publish cost on the
 *                freeze/thaw path.
 *
 * NOTE: must run on the patched JDK ($JAVA_HOME/bin/java). Numbers taken inside
 * OrbStack/LXC are for familiarisation only; the evaluation needs bare metal.
 */
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 10, time = 1)
@Fork(value = 2, jvmArgs = {"--enable-preview", "--enable-native-access=ALL-UNNAMED"})
@State(Scope.Benchmark)
public class VThreadTransitionBenchmark {

    @Param({"10000"})
    int yieldsPerVthread;

    @Benchmark
    public void transition_yield(Blackhole bh) throws InterruptedException {
        final int n = yieldsPerVthread;
        Thread vt = Thread.ofVirtual().unstarted(() -> {
            for (int i = 0; i < n; i++) {
                Thread.yield();   // freeze + thaw; observable side effect, not elided
            }
        });
        vt.start();
        vt.join();
        bh.consume(vt);
    }
}
