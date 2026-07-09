package uk.ac.ncl.jensen.benchmark;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.concurrent.TimeUnit;

/**
 * Benchmark #1b — virtual-thread lifecycle (churn) overhead.
 *
 * Workload (W1): create + start + join a batch of short-lived virtual threads.
 * Each vthread fires exactly one VirtualThreadStart and one VirtualThreadEnd, so
 * this is the workload that actually exercises the JVMTI agent: with the agent
 * loaded each start does calloc(64) + SetLongField(traceBufferAddress) and each
 * end does GetLongField + free. baseline (no agent) vs +agent isolates that cost.
 *
 * This — not the transition benchmark — is the correct workload for the agent,
 * because the agent hooks Start/End (per-vthread), not mount/unmount
 * (per-transition). A transition-heavy W2 workload barely touches it.
 *
 * Per op = (batch vthread starts) + (trivial body) + (batch ends). Reported
 * op_time / vthreadsPerOp  ≈  per-vthread lifecycle cost.
 */
// No @Warmup/@Measurement and no @Fork(value): the statistical spec deliberately
// falls through to the JMH 1.37 built-in defaults (5 forks, warmup 5x10s,
// measurement 5x10s) — see result/analysis/JMH-PARAMS.md. @Fork stays only to
// pin the forked-JVM arg set (single-variable guarantee).
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Fork(jvmArgs = {"--enable-preview", "--enable-native-access=ALL-UNNAMED"})
@State(Scope.Benchmark)
public class VThreadChurnBenchmark {

    @Param({"1000"})
    int vthreadsPerOp;

    @Benchmark
    public void churn(Blackhole bh) throws InterruptedException {
        final int batch = vthreadsPerOp;
        Thread[] ts = new Thread[batch];
        var b = Thread.ofVirtual();
        for (int i = 0; i < batch; i++) {
            ts[i] = b.start(() -> Blackhole.consumeCPU(1));
        }
        for (Thread t : ts) {
            t.join();
        }
        bh.consume(ts);
    }
}