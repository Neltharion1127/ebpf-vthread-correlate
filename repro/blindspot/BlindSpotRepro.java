import java.io.FileOutputStream;
import java.util.Arrays;

/**
 * BlindSpotRepro — minimal reproducer for the "first-mount blind spot" of the
 * thaw-based carrier->vthread correlation.
 *
 * Hypothesis under test: a virtual thread's FIRST mount enters via
 * Continuation.enterSpecial (fresh entry), NOT via the thaw path, so any
 * syscall it issues BEFORE its first park cannot be attributed — the
 * carrier->vthread map (built on vthread__thaw) has no entry yet.
 *
 * Sequence on the virtual thread:
 *   a. print own threadId() to stderr (for manual attribution check)
 *   b. PHASE_A: write exactly 101 bytes  — BEFORE the first park
 *   c. Thread.sleep(200)                 — forces unmount (freeze) + remount (thaw)
 *   d. PHASE_B: write exactly 103 bytes  — AFTER the first thaw
 *
 * 101/103 are chosen so the bpftrace side can filter sys_enter_write
 * unambiguously against the JVM's own writes (including step a's stderr print).
 *
 * Run with:
 *   $JDK/bin/java -XX:+VThreadTraceProbes \
 *       -Djdk.virtualThreadScheduler.parallelism=1 BlindSpotRepro
 */
public class BlindSpotRepro {
    public static void main(String[] args) throws Exception {
        // Unbuffered: each write(byte[]) is one write(2) syscall.
        try (FileOutputStream out = new FileOutputStream("/tmp/blindspot.out")) {
            byte[] phaseA = new byte[101];
            byte[] phaseB = new byte[103];
            Arrays.fill(phaseA, (byte) 'A');
            Arrays.fill(phaseB, (byte) 'B');

            Thread vt = Thread.ofVirtual().name("blindspot-vt").start(() -> {
                System.err.println("VTHREAD_ID=" + Thread.currentThread().threadId());
                try {
                    out.write(phaseA);          // PHASE_A: before first park
                    Thread.sleep(200);          // freeze + thaw
                    out.write(phaseB);          // PHASE_B: after first thaw
                } catch (Exception e) {
                    e.printStackTrace();
                    System.exit(1);
                }
            });
            vt.join();
        }
        System.err.println("DONE");
    }
}
