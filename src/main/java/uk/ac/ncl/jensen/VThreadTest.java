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
