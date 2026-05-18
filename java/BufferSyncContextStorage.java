import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.ContextStorage;
import io.opentelemetry.context.Scope;

import sun.misc.Unsafe;
import java.lang.reflect.Field;

public class BufferSyncContextStorage implements ContextStorage {

    private static final Unsafe U;
    static {
        try {
            Field f = Unsafe.class.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            U = (Unsafe) f.get(null);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static final int BUFFER_SIZE = 64;

    // Platform threads do not have a JVM-internal buffer, so allocate one on demand per thread.
    private static final ThreadLocal<PlatformThreadBuffer> platformThreadBuffer =
            ThreadLocal.withInitial(PlatformThreadBuffer::new);

    private final ContextStorage delegate;

    public BufferSyncContextStorage(ContextStorage delegate) {
        this.delegate = delegate;
    }

    @Override
    public Scope attach(Context toAttach) {
        Scope scope = delegate.attach(toAttach);
        syncToBuffer(toAttach);

        return () -> {
            scope.close();
            syncToBuffer(delegate.current());
        };
    }

    @Override
    public Context current() {
        return delegate.current();
    }

    public static void closePlatformThreadBuffer() {
        PlatformThreadBuffer buffer = platformThreadBuffer.get();
        buffer.close();
        platformThreadBuffer.remove();
    }

    private long getBufferAddress() {
        Thread t = Thread.currentThread();
        long addr = t.getTraceBufferAddress();
        if (addr != 0) {
            // Virtual thread: use the buffer allocated by the JVM.
            return addr;
        }
        // Platform thread: use the ThreadLocal buffer allocated on demand.
        return platformThreadBuffer.get().address();
    }

    private void syncToBuffer(Context ctx) {
        long bufAddr = getBufferAddress();

        Span span = Span.fromContext(ctx);
        SpanContext sc = span.getSpanContext();

        if (sc.isValid()) {
            writeTraceId(bufAddr, sc.getTraceId());
            writeSpanId(bufAddr, sc.getSpanId());
        } else {
            for (int i = 8; i < 32; i++) {
                U.putByte(bufAddr + i, (byte) 0);
            }
        }
    }

    private void writeTraceId(long bufAddr, String traceId) {
        for (int i = 0; i < 16; i++) {
            U.putByte(bufAddr + 8 + i,
                    (byte) Integer.parseInt(traceId.substring(i * 2, i * 2 + 2), 16));
        }
    }

    private void writeSpanId(long bufAddr, String spanId) {
        for (int i = 0; i < 8; i++) {
            U.putByte(bufAddr + 24 + i,
                    (byte) Integer.parseInt(spanId.substring(i * 2, i * 2 + 2), 16));
        }
    }

    private static final class PlatformThreadBuffer implements AutoCloseable {
        private long address;

        private PlatformThreadBuffer() {
            address = U.allocateMemory(BUFFER_SIZE);
            for (int i = 0; i < BUFFER_SIZE; i++) {
                U.putByte(address + i, (byte) 0);
            }
            U.putLong(address, Thread.currentThread().threadId());
        }

        private long address() {
            if (address == 0) {
                throw new IllegalStateException("platform thread buffer is already closed");
            }
            return address;
        }

        @Override
        public void close() {
            if (address != 0) {
                U.freeMemory(address);
                address = 0;
            }
        }
    }
}
