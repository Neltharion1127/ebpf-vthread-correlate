package uk.ac.ncl.jensen.harness;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;
import io.opentelemetry.context.ContextStorage;
import io.opentelemetry.context.Scope;
import uk.ac.ncl.jensen.BufferSyncContextStorage;

import java.io.BufferedWriter;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Emits low-rate write(2) markers with independent syscall-count and trace-context identities.
 *
 * <p>The launcher must supply
 * {@code --add-opens=java.base/java.io=ALL-UNNAMED} so the dedicated
 * {@link FileDescriptor}'s integer fd can be read without replacing the direct
 * {@link FileOutputStream} write path.
 */
public final class MarkerHarness {
    private static final int COUNT_BASE = 1000;
    private static final int MAX_VTHREADS = 512;
    private static final String TRACE_ID_HIGH = "cafebabe00c0ffee";

    private MarkerHarness() {
    }

    public static void main(String[] args) throws Exception {
        int vthreadCount = args.length > 0 ? Integer.parseInt(args[0]) : 16;
        int markersPerThread = args.length > 1 ? Integer.parseInt(args[1]) : 8;
        Path outputDir = args.length > 2 ? Path.of(args[2]) : Path.of(".");
        boolean leakyFinalScope = args.length > 3 && "--leaky-final-scope".equals(args[3]);

        if (args.length > 4 || (args.length > 3 && !leakyFinalScope)) {
            throw new IllegalArgumentException(
                    "usage: MarkerHarness [N] [M] [outputDir] [--leaky-final-scope]");
        }
        if (vthreadCount < 1 || vthreadCount > MAX_VTHREADS) {
            throw new IllegalArgumentException("N must be in 1.." + MAX_VTHREADS);
        }
        if (markersPerThread < 1) {
            throw new IllegalArgumentException("M must be positive");
        }

        // Match VThreadTest: install the wrapper before the first context-storage use.
        ContextStorage.addWrapper(BufferSyncContextStorage::new);

        Files.createDirectories(outputDir);
        Path manifestPath = outputDir.resolve("manifest.csv");
        Path goPath = outputDir.resolve("go");

        try (FileOutputStream markerOutput = new FileOutputStream("/dev/null");
             BufferedWriter manifest = Files.newBufferedWriter(
                     manifestPath,
                     StandardCharsets.UTF_8,
                     StandardOpenOption.CREATE_NEW,
                     StandardOpenOption.WRITE)) {
            long pid = ProcessHandle.current().pid();
            int fd = integerFd(markerOutput.getFD());

            manifest.write("# pid=" + pid + ",fd=" + fd);
            manifest.newLine();
            manifest.write("k,seq,expected_traceId,expected_spanId,expected_vthread_id,fd,count");
            manifest.newLine();
            manifest.flush();

            System.out.println("PID=" + pid);
            System.out.println("FD=" + fd);
            System.out.println("MANIFEST=" + manifestPath.toAbsolutePath());
            System.out.flush();

            while (!Files.exists(goPath)) {
                Thread.sleep(25);
            }

            AtomicReference<Throwable> failure = new AtomicReference<>();
            List<Thread> threads = new ArrayList<>(vthreadCount);

            /*
             * Run lifetimes one at a time. This retains real park/thaw and carrier
             * scheduling while deterministically exposing the old consumer's
             * freeze-less-termination window before the next lifetime's seq=0.
             */
            for (int k = 0; k < vthreadCount; k++) {
                final int markerK = k;
                Thread thread = Thread.ofVirtual()
                        .name("marker-harness-" + markerK)
                        .unstarted(() -> runMarkers(
                                markerK,
                                markersPerThread,
                                fd,
                                markerOutput,
                                manifest,
                                failure,
                                leakyFinalScope));
                threads.add(thread);
                thread.start();
                thread.join();
                if (failure.get() != null) {
                    break;
                }
            }

            for (Thread thread : threads) {
                thread.join();
            }
            Throwable thrown = failure.get();
            if (thrown != null) {
                throw new RuntimeException("marker virtual thread failed", thrown);
            }
        } finally {
            BufferSyncContextStorage.closePlatformThreadBuffer();
        }
    }

    private static void runMarkers(
            int k,
            int markersPerThread,
            int fd,
            FileOutputStream markerOutput,
            BufferedWriter manifest,
            AtomicReference<Throwable> failure,
            boolean leakyFinalScope) {
        try {
            long expectedVthreadId = Thread.currentThread().threadId();
            for (int seq = 0; seq < markersPerThread; seq++) {
                String traceId = TRACE_ID_HIGH + String.format("%016x", k);
                long spanValue = ((long) (k + 1) << 32) | (((long) seq + 1) & 0xffffffffL);
                String spanId = String.format("%016x", spanValue);
                SpanContext spanContext = SpanContext.create(
                        traceId,
                        spanId,
                        TraceFlags.getSampled(),
                        TraceState.getDefault());
                Span span = Span.wrap(spanContext);
                Scope scope = span.makeCurrent();
                boolean leakThisScope = leakyFinalScope && seq + 1 == markersPerThread;

                try {
                    int count = COUNT_BASE + k;
                    markerOutput.write(new byte[count]);

                    synchronized (manifest) {
                        manifest.write(k + "," + seq + "," + traceId + "," + spanId
                                + "," + expectedVthreadId + "," + fd + "," + count);
                        manifest.newLine();
                        manifest.flush();
                    }
                } finally {
                    if (!leakThisScope) {
                        scope.close();
                        span.end();
                    }
                }

                // seq=0 precedes this virtual thread's first park; every later
                // marker follows at least one thaw. Jitter keeps the run low-rate.
                if (seq + 1 < markersPerThread) {
                    Thread.sleep(ThreadLocalRandom.current().nextLong(2, 11));
                }
            }
        } catch (Throwable thrown) {
            failure.compareAndSet(null, thrown);
        }
    }

    private static int integerFd(FileDescriptor descriptor) throws ReflectiveOperationException {
        Field fdField = FileDescriptor.class.getDeclaredField("fd");
        fdField.setAccessible(true);
        return fdField.getInt(descriptor);
    }
}
