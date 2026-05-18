#!/usr/bin/env bash
# test.sh — compile and run a Java test using the self-built JDK.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT_DIR/config/env.sh"

# Optional first argument selects the test class (default: VThreadTest).
CLASS="${1:-VThreadTest}"

# Load user configuration.
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
if [[ ! -x "$JAVA_HOME/bin/javac" ]]; then
    echo "error: $JAVA_HOME/bin/javac not found or not executable" >&2
    exit 1
fi

export PATH="$JAVA_HOME/bin:$PATH"

echo "Using JDK: $JAVA_HOME"
echo "Compiling project with Maven ..."

cd "$ROOT_DIR"
mvn clean compile -q

if [[ ! -f "$ROOT_DIR/target/classes/${CLASS}.class" ]]; then
    echo "error: compiled class $CLASS not found under target/classes" >&2
    exit 1
fi

echo "Resolving runtime classpath ..."
CP="$(mvn -q dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=/dev/stdout -q 2>/dev/null | tail -1)"
if [[ -n "$CP" ]]; then
    CP="target/classes:$CP"
else
    CP="target/classes"
fi

echo "Running $CLASS ..."
echo ""
"$JAVA_HOME/bin/java" \
    --add-exports java.base/sun.misc=ALL-UNNAMED \
    -cp "$CP" \
    "$CLASS"
