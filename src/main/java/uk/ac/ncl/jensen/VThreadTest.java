package uk.ac.ncl.jensen;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.ContextStorage;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.opentelemetry.exporter.logging.LoggingSpanExporter;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.locks.LockSupport;

public class VThreadTest {

    public static void main(String[] args) throws Exception {

        // Register the custom ContextStorage before initializing the SDK.
        ContextStorage.addWrapper(BufferSyncContextStorage::new);

        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
                .addSpanProcessor(SimpleSpanProcessor.create(
                        LoggingSpanExporter.create()))
                .build();

        OpenTelemetry otel = OpenTelemetrySdk.builder()
                .setTracerProvider(tracerProvider)
                .buildAndRegisterGlobal();

        Tracer tracer = otel.getTracer("vthread-test");

        System.out.println("=== OTel + auto buffer sync ===");

        Span parentSpan = tracer.spanBuilder("parent-request").startSpan();
        try (Scope parentScope = parentSpan.makeCurrent()) {

            String parentTraceId = parentSpan.getSpanContext().getTraceId();
            System.out.println("[Main] traceId=" + parentTraceId);

            // ── Phase 1: normal freeze/thaw lifecycle ────────────────────────
            List<Thread> vts = new ArrayList<>();
            for (int i = 0; i < 3; i++) {
                final int id = i;
                final Context parentCtx = Context.current();

                Thread vt = Thread.ofVirtual().start(() -> {
                    try (Scope s = parentCtx.makeCurrent()) {

                        // Create a child span; the buffer is updated automatically.
                        Span childSpan = tracer.spanBuilder("vt-task-" + id).startSpan();
                        try (Scope childScope = childSpan.makeCurrent()) {

                            System.out.println("VT-" + id
                                    + " threadId=" + Thread.currentThread().threadId()
                                    + " traceId=" + childSpan.getSpanContext().getTraceId()
                                    + " spanId=" + childSpan.getSpanContext().getSpanId());

                            // Simulate a nested span; the buffer should switch to the new spanId.
                            Span innerSpan = tracer.spanBuilder("vt-inner-" + id).startSpan();
                            try (Scope innerScope = innerSpan.makeCurrent()) {
                                System.out.println("VT-" + id + " inner spanId="
                                        + innerSpan.getSpanContext().getSpanId());
                                LockSupport.parkNanos(500_000_000L);
                            } finally {
                                innerSpan.end();
                            }
                            // After scope.close(), the buffer should restore the child spanId.

                            System.out.println("VT-" + id + " resumed, back to spanId="
                                    + Span.current().getSpanContext().getSpanId());

                        } finally {
                            childSpan.end();
                        }
                    }
                });
                vts.add(vt);
            }
            for (Thread vt : vts) vt.join();

            // ── Phase 2: pinned-monitor lifecycle (JDK 21 only; JEP 491
            //    removes monitor pinning in JDK 24+) ───────────────────────────
            //
            // Regression test for the correlator's cache-eviction fix.
            // Required event order, per vthread:
            //
            //   (a) plain park        -> freeze ok, unmount; the thaw on resume
            //                            inserts this carrier's cache entry.
            //   (b) park inside a     -> freeze attempt FAILS with
            //       synchronized block   pinned_monitor (result=4); the vthread
            //                            stays mounted and the carrier blocks.
            //   (c) write(2) after    -> SAME mount window as (b). This write
            //       the pinned park     must still be correlated. The unfixed
            //                            correlator evicted the cache at (b)
            //                            and loses this write.
            //
            // Step (a) is essential: a vthread's FIRST mount has no thaw event,
            // so without it there is no cache entry for (b) to wrongly evict
            // and the fix is not exercised.
            //
            // Each task uses its own lock: the monitor must be uncontended so
            // the only park inside it is the explicit parkNanos (a clean
            // pinned_monitor, not contended-monitorenter noise).
            List<Thread> pinnedVts = new ArrayList<>();
            for (int i = 0; i < 2; i++) {
                final int id = i;
                final Context parentCtx = Context.current();
                final Object lock = new Object();

                Thread vt = Thread.ofVirtual().start(() -> {
                    try (Scope s = parentCtx.makeCurrent()) {

                        Span span = tracer.spanBuilder("vt-pinned-" + id).startSpan();
                        try (Scope sc = span.makeCurrent()) {

                            System.out.println("PIN-" + id
                                    + " threadId=" + Thread.currentThread().threadId()
                                    + " spanId=" + span.getSpanContext().getSpanId());

                            // (a) unpinned park: freeze ok -> thaw populates the cache.
                            LockSupport.parkNanos(200_000_000L);

                            synchronized (lock) {
                                // (b) pinned park: freeze fails, vthread stays mounted.
                                LockSupport.parkNanos(200_000_000L);

                                // (c) the write that proves the fix.
                                System.out.println("PIN-" + id
                                        + " after pinned park, spanId="
                                        + Span.current().getSpanContext().getSpanId());
                            }
                        } finally {
                            span.end();
                        }
                    }
                });
                pinnedVts.add(vt);
            }
            for (Thread vt : pinnedVts) vt.join();

        } finally {
            parentSpan.end();
        }

        try {
            tracerProvider.shutdown();
            System.out.println("Done.");
        } finally {
            BufferSyncContextStorage.closePlatformThreadBuffer();
        }
    }
}