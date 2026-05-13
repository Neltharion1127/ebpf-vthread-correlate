import java.util.concurrent.locks.LockSupport;
import java.net.ServerSocket;
import java.net.Socket;

public class PinnedTest {
    static final Object lock = new Object();

    public static void main(String[] args) throws Exception {
        System.out.println("Starting PINNED test...");

        for (int i = 0; i < 5; i++) {
            final int id = i;
            Thread.ofVirtual().start(() -> {
                synchronized (lock) {  // 持有 monitor
                    System.out.println("VT-" + id + " inside synchronized, parking...");
                    LockSupport.parkNanos(500_000_000L);  // 在 synchronized 里 park → PINNED
                    System.out.println("VT-" + id + " resumed");
                }
            });
        }

        Thread.sleep(4000);
        System.out.println("Done.");
    }
}
