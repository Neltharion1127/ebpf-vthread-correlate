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
@Fork(value = 1, jvmArgs = {"--enable-preview", "--enable-native-access=ALL-UNNAMED"},
      jvm = "/home/jie/csc8499/jdk21u/build/linux-aarch64-server-release/images/jdk/bin/java")
@State(org.openjdk.jmh.annotations.Scope.Thread)
public class ContextStorageBenchmark {

    private Tracer tracer;
    private Span parentSpan;
    private Context parentCtx;

    @Param({"false", "true"})
    private boolean useBufferSync;

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
    public void makeCurrent_and_close() {
        try (Scope s = parentCtx.makeCurrent()) {
            Span child = tracer.spanBuilder("child").startSpan();
            try (Scope cs = child.makeCurrent()) {
                // simulate one span lifecycle
            } finally {
                child.end();
            }
        }
    }
}
