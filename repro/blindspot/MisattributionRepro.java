import java.io.FileOutputStream;
import java.util.Arrays;

/**
 * MisattributionRepro — silent-misattribution reproducer, building on the
 * verified first-mount blind spot (see BlindSpotRepro.java).
 *
 * Hypothesis under test: a virtual thread's final termination does NOT go
 * through freeze (the continuation runs to completion and returns — the
 * verified run ended with return-barrier thaws and no trailing freeze), so
 * the carrier keeps a STALE carrier->vthread map entry forever. When the next
 * fresh vthread is scheduled onto the same carrier and issues a write BEFORE
 * its first park, that write is not UNMAPPED — it is silently attributed to
 * the previous, already-terminated vthread.
 *
 * Sequence (parallelism=1, so both vthreads share the one carrier):
 *   VT1: print "VT1_ID=" + threadId(); write 101B; sleep(200); write 103B; end.
 *        (same lifecycle as the verified repro: goes through freeze/thaw,
 *        terminates without freeze, leaving its mapping on the carrier)
 *   main: join VT1, sleep 100ms (termination margin), then start VT2.
 *   VT2: print "VT2_ID=" + threadId(); write exactly 107B; end.
 *        No park, no sleep, nothing that could yield — first-mount only.
 *
 * Expected if the hypothesis holds: the 107B write is attributed to VT1_ID.
 *
 * Run with:
 *   $JDK/bin/java -XX:+VThreadTraceProbes \
 *       -Djdk.virtualThreadScheduler.parallelism=1 MisattributionRepro
 */
public class MisattributionRepro {
    public static void main(String[] args) throws Exception {
        try (FileOutputStream out = new FileOutputStream("/tmp/blindspot.out")) {
            byte[] b101 = new byte[101];
            byte[] b103 = new byte[103];
            byte[] b107 = new byte[107];
            Arrays.fill(b101, (byte) 'A');
            Arrays.fill(b103, (byte) 'B');
            Arrays.fill(b107, (byte) 'C');

            Thread vt1 = Thread.ofVirtual().name("misattr-vt1").start(() -> {
                System.err.println("VT1_ID=" + Thread.currentThread().threadId());
                try {
                    out.write(b101);            // before first park (known UNMAPPED)
                    Thread.sleep(200);          // freeze + thaw
                    out.write(b103);            // after first thaw (known mapped)
                } catch (Exception e) {
                    e.printStackTrace();
                    System.exit(1);
                }
            });
            vt1.join();
            Thread.sleep(100);                  // margin for VT1 termination to complete

            Thread vt2 = Thread.ofVirtual().name("misattr-vt2").start(() -> {
                System.err.println("VT2_ID=" + Thread.currentThread().threadId());
                try {
                    out.write(b107);            // before first park; never parks at all
                } catch (Exception e) {
                    e.printStackTrace();
                    System.exit(1);
                }
            });
            vt2.join();
        }
        System.err.println("DONE");
    }
}
