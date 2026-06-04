#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$PROJECT_DIR/config/env.sh"

if [[ ! -f "$CONFIG" ]]; then
    echo "error: $CONFIG not found — copy config/env.sh.example to config/env.sh and fill in the paths" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "error: JAVA_HOME is not set in $CONFIG" >&2
    exit 1
fi
if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
    echo "error: $JAVA_HOME/bin/java not found or not executable" >&2
    exit 1
fi

export PATH="$JAVA_HOME/bin:$PATH"

# Locate mvn: prefer env var, then PATH, then SDKMAN's well-known location.
if [[ -z "${MVN:-}" ]]; then
    if command -v mvn &>/dev/null; then
        MVN=mvn
    elif [[ -x "${HOME}/.sdkman/candidates/maven/current/bin/mvn" ]]; then
        MVN="${HOME}/.sdkman/candidates/maven/current/bin/mvn"
    else
        echo "error: mvn not found — set MVN=/path/to/mvn or install Maven" >&2
        exit 1
    fi
fi

cd "$PROJECT_DIR"

echo "=== Using JDK: $JAVA_HOME ==="
"$JAVA_HOME/bin/java" -version

echo ""
echo "=== Building shaded jar with custom JDK ==="
"$MVN" clean package -q -DskipTests

JAR="target/ebpf-vthread-correlate-1.0-SNAPSHOT.jar"
if [[ ! -f "$JAR" ]]; then
    echo "error: shaded jar $JAR not found after build" >&2
    exit 1
fi

# Optional JVMTI agent (Plan A): set USE_AGENT=1 to have the agent allocate the
# per-vthread trace buffer. Default (USE_AGENT unset/0) runs in degraded mode.
JAVA_OPTS=(--enable-preview --enable-native-access=ALL-UNNAMED)
if [[ "${USE_AGENT:-0}" == "1" ]]; then
    if [[ -z "${AGENT_PATH:-}" ]]; then
        echo "error: USE_AGENT=1 but AGENT_PATH is not set in $CONFIG" >&2
        exit 1
    fi
    if [[ ! -f "$AGENT_PATH" ]]; then
        echo "error: AGENT_PATH=$AGENT_PATH does not exist — build it with 'cd JVMTI-agent && make'" >&2
        exit 1
    fi
    JAVA_OPTS=(-agentpath:"$AGENT_PATH" "${JAVA_OPTS[@]}")
    echo "=== JVMTI agent enabled: $AGENT_PATH ==="
else
    echo "=== JVMTI agent disabled (set USE_AGENT=1 to enable) ==="
fi

echo ""
echo "=== Running VThreadTest ==="
"$JAVA_HOME/bin/java" \
    "${JAVA_OPTS[@]}" \
    -cp "$JAR" \
    uk.ac.ncl.jensen.VThreadTest
