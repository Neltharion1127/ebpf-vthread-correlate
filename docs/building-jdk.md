# Building the JDK yourself

You only need this if you are **not** using the pre-built release JDK that
`./setup.sh` downloads. Most reproducers should just run `./setup.sh` — see
[Quick start](../README.md#quick-start). Build from source only when you are modifying the
JVM itself.

The probes are gated behind the `dtrace` JVM feature. Two packages are needed
on Fedora/RHEL — `systemtap-sdt-devel` alone is **not** enough:

```bash
sudo dnf install -y systemtap-sdt-dtrace   # provides /usr/bin/dtrace wrapper
sudo dnf install -y systemtap-sdt-devel    # provides /usr/include/sys/sdt.h
```

Both methods below produce a **release** JDK, never fastdebug: a fastdebug
`libjvm` distorts the benchmark ratios, and `profile-matrix.sh` aborts if it
detects one. Throughout, `<arch>` is `x86_64` or `aarch64`, so the build
configuration is named `linux-<arch>-server-release`. Set `CC`/`CXX` explicitly
on the `configure` line to avoid ccache symlink-detection errors.

## Method A — distributable release build (glibc-compatible)

This is how the current release JDK is actually built. Configure and build the
whole image inside an `ubuntu:20.04` container (glibc 2.31) so the binaries run
on any Linux with glibc ≥ 2.31, then tar the image.

```bash
# inside an ubuntu:20.04 container, in the jdk21u source tree:
CC=/usr/bin/gcc CXX=/usr/bin/g++ bash configure \
  --with-boot-jdk=/path/to/boot-jdk-21 \
  --with-debug-level=release \
  --enable-dtrace \
  --disable-warnings-as-errors \
  --with-native-debug-symbols=none

make images

# package the whole image for distribution (top-level dir is jdk/):
tar -C build/linux-<arch>-server-release/images -czf jdk-vthread-<arch>.tar.gz jdk
```

`make images` produces the complete JDK under
`build/linux-<arch>-server-release/images/jdk`. That directory is what `setup.sh`
ships and what `config/env.sh`'s `JAVA_HOME` points at.

## Method B — fast local iteration (rebuild libjvm only)

When you are editing JVM code and re-compiling repeatedly, rebuilding the whole
image every time is slow. Configure release once, then rebuild only HotSpot:

```bash
CC=/usr/bin/gcc CXX=/usr/bin/g++ bash configure \
  --with-boot-jdk=/path/to/boot-jdk-21 \
  --enable-ccache \
  --with-debug-level=release \
  --enable-dtrace \
  --disable-warnings-as-errors

# recompile just libjvm.so (much faster than `make images`):
make CONF=linux-<arch>-server-release hotspot
```

`make hotspot` writes the freshly built library into the **exploded image**, not
the packaged image:

```
build/linux-<arch>-server-release/jdk/lib/server/libjvm.so           # refreshed by `make hotspot`
build/linux-<arch>-server-release/images/jdk/lib/server/libjvm.so    # refreshed only by `make images`
```

The exploded image (`build/linux-<arch>-server-release/jdk`) is itself a runnable
JDK — it has a working `bin/java` and now carries your rebuilt `libjvm.so`. The
simplest correct setup is therefore to point `config/env.sh` straight at it, with
**no copy**:

```bash
CONF=linux-<arch>-server-release            # <arch> = x86_64 | aarch64
export JAVA_HOME="/path/to/jdk21u/build/$CONF/jdk"
export LIBJVM_PATH="$JAVA_HOME/lib/server/libjvm.so"
export JDK="$JAVA_HOME"
```

If instead your `config/env.sh` points at the packaged `images/jdk`, a bare
`make hotspot` does **not** refresh it. You must then either re-run
`make CONF=linux-<arch>-server-release images`, or copy the rebuilt library over
the packaged one:

```bash
cp build/$CONF/jdk/lib/server/libjvm.so \
   build/$CONF/images/jdk/lib/server/libjvm.so
```

That copy only works if `images/jdk` already exists from a previous
`make images`. On a release tree that has only ever had `make hotspot` run,
`images/jdk` does not exist and the copy fails — which is why the old
fastdebug-era recipe cannot be followed verbatim. Point `env.sh` at the exploded
`jdk/` image instead.

## Verify the probes are present

Either way, confirm the USDT probes made it into the library `config/env.sh`
points at:

```bash
readelf -n "$LIBJVM_PATH" | grep vthread
# expect: vthread__start (2 args), vthread__thaw and vthread__freeze (3 args each)
# and vthread__end (1 arg); thaw and freeze appear once per call site
```
