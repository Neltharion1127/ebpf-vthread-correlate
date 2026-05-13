import java.util.concurrent.locks.LockSupport;

public class VThreadTest {
    public static void main(String[] args) throws Exception {
        System.out.println("Starting virtual thread test...");

        for (int i = 0; i < 5; i++) {
            final int id = i;
            Thread vt = Thread.ofVirtual().start(() -> {
                // println triggers write(2) on stdout — should appear in bpftrace output
                // attributed to the virtual thread currently mounted on this carrier.
                System.out.println("VT-" + id + " parking...");
                // parkNanos causes a freeze: the virtual thread yields the carrier thread.
                LockSupport.parkNanos(500_000_000L); // 500 ms
                // On resume a thaw fires before this line executes.
                System.out.println("VT-" + id + " resumed");
            });
        }

        Thread.sleep(3000);
        System.out.println("Done.");
    }
}
