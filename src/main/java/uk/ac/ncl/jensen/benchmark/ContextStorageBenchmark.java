package uk.ac.ncl.jensen.benchmark;

import uk.ac.ncl.jensen.BufferSyncContextStorage;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.ContextStorage;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.trace.SdkTracerProvider;

import org.openjdk.jmh.annotations.*;
import java.util.concurrent.TimeUnit;

@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 1)
@Measurement(iterations = 5, time = 1)
@Fork(value = 1, jvmArgs = {"--enable-preview", "--enable-native-access=ALL-UNNAMED"})
@State(org.openjdk.jmh.annotations.Scope.Thread)
public class ContextStorageBenchmark {

    private Tracer tracer;
    private Span parentSpan;
    private Context parentCtx;

    @Param({"false", "true"})
    private boolean useBufferSync;

    @Param({"1", "3", "5"})
    private int spanDepth;

    @Setup(Level.Trial)
    public void setup() {
        if (useBufferSync) {
            ContextStorage.addWrapper(BufferSyncContextStorage::new);
        }

        SdkTracerProvider tracerProvider = SdkTracerProvider.builder().build();

        OpenTelemetry otel = OpenTelemetrySdk.builder()
                .setTracerProvider(tracerProvider)
                .buildAndRegisterGlobal();

        tracer = otel.getTracer("benchmark");
        parentSpan = tracer.spanBuilder("parent").startSpan();
        parentCtx = Context.current().with(parentSpan);
    }

    @Benchmark
    public void nested_spans() {
        try (Scope s = parentCtx.makeCurrent()) {
            createNestedSpans(spanDepth);
        }
    }

    private void createNestedSpans(int depth) {
        if (depth <= 0) return;

        Span span = tracer.spanBuilder("level-" + depth).startSpan();
        try (Scope s = span.makeCurrent()) {
            createNestedSpans(depth - 1);
        } finally {
            span.end();
        }
    }
}