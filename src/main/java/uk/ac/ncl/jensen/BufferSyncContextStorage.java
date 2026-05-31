package uk.ac.ncl.jensen;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.ContextStorage;
import io.opentelemetry.context.Scope;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.VarHandle;

public class BufferSyncContextStorage implements ContextStorage {

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

    private MemorySegment getBufferSegment() {
        Thread t = Thread.currentThread();
        long addr = t.getTraceBufferAddress();
        if (addr != 0) {
            // Virtual thread: wrap the JVM-allocated buffer at the raw address.
            return MemorySegment.ofAddress(addr).reinterpret(BUFFER_SIZE);
        }
        // Platform thread: use the ThreadLocal buffer allocated on demand.
        return platformThreadBuffer.get().segment();
    }

    private void syncToBuffer(Context ctx) {
        MemorySegment seg = getBufferSegment();

        Span span = Span.fromContext(ctx);
        SpanContext sc = span.getSpanContext();

        if (sc.isValid()) {
            writeTraceId(seg, sc.getTraceId());
            writeSpanId(seg, sc.getSpanId());
        } else {
            for (int i = 8; i < 32; i++) {
                seg.set(ValueLayout.JAVA_BYTE, i, (byte) 0);
            }
        }
        VarHandle.releaseFence();
    }

    private void writeTraceId(MemorySegment seg, String traceId) {
        for (int i = 0; i < 16; i++) {
            seg.set(ValueLayout.JAVA_BYTE, 8 + i, hexToByte(traceId, i * 2));
        }
    }

    private void writeSpanId(MemorySegment seg, String spanId) {
        for (int i = 0; i < 8; i++) {
            seg.set(ValueLayout.JAVA_BYTE, 24 + i, hexToByte(spanId, i * 2));
        }
    }

    private static byte hexToByte(String hex, int index) {
        int hi = Character.digit(hex.charAt(index), 16);
        int lo = Character.digit(hex.charAt(index + 1), 16);
        return (byte) ((hi << 4) | lo);
    }

    private static final class PlatformThreadBuffer implements AutoCloseable {
        private MemorySegment seg;

        private PlatformThreadBuffer() {
            seg = Arena.global().allocate(BUFFER_SIZE);
            seg.fill((byte) 0);
            seg.set(ValueLayout.JAVA_LONG, 0, Thread.currentThread().threadId());
        }

        private MemorySegment segment() {
            if (seg == null) {
                throw new IllegalStateException("platform thread buffer is already closed");
            }
            return seg;
        }

        @Override
        public void close() {
            seg = null;
        }
    }
}
