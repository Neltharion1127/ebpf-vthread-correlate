package uk.ac.ncl.jensen.benchmark;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

/**
 * Benchmark #1 (W2 variant) — park/unpark transitions.
 *
 * Two virtual threads ping-pong via LockSupport.park()/unpark(). park() on a
 * virtual thread unmounts the continuation; the partner's unpark() makes it
 * runnable again, and it remounts. This is the "park-unpark" workload from the
 * evaluation matrix — closer to real blocking semantics than the yield
 * microbenchmark, at the cost of scheduling noise from the two-thread handoff.
 *
 * Use the yield benchmark (VThreadTransitionBenchmark) for the clean
 * per-transition number; use this one to show the effect under a realistic
 * blocking handoff. The explicit turn state keeps LockSupport's permitted
 * spurious returns or early unparks from deadlocking the benchmark.
 *
 * Same launch-time configuration matrix as the yield benchmark (baseline /
 * +agent / +agent publish=jvmti / +bpftrace) via profile-matrix.sh.
 */
// No @Warmup/@Measurement and no @Fork(value): the statistical spec deliberately
// falls through to the JMH 1.37 built-in defaults (5 forks, warmup 5x10s,
// measurement 5x10s) — see result/analysis/JMH-PARAMS.md. @Fork stays only to
// pin the forked-JVM arg set (single-variable guarantee).
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Fork(jvmArgs = {"--enable-preview", "--enable-native-access=ALL-UNNAMED"})
@State(Scope.Benchmark)
public class VThreadParkUnparkBenchmark {

    @Param({"10000"})
    int rounds;

    static final class Handoff {
        volatile int turn;
    }

    @Benchmark
    public void parkUnpark_pingPong(Blackhole bh) throws InterruptedException {
        final int n = rounds;
        final Handoff handoff = new Handoff();
        final Thread[] peer = new Thread[2];

        // peer[0] (A) and peer[1] (B) alternate via an explicit condition.
        // park()/unpark() provide the blocking handoff, but the volatile turn is
        // the source of truth so a spurious return cannot lose synchronization.
        peer[0] = Thread.ofVirtual().unstarted(() -> {
            for (int i = 0; i < n; i++) {
                while (handoff.turn != 0) {
                    LockSupport.park();        // A unmounts
                }
                handoff.turn = 1;
                LockSupport.unpark(peer[1]);
            }
        });
        peer[1] = Thread.ofVirtual().unstarted(() -> {
            for (int i = 0; i < n; i++) {
                while (handoff.turn != 1) {
                    LockSupport.park();        // B unmounts
                }
                handoff.turn = 0;
                LockSupport.unpark(peer[0]);
            }
        });

        peer[1].start();
        peer[0].start();
        peer[0].join();
        peer[1].join();
        bh.consume(peer);
    }
}
