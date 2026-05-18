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

cd "$PROJECT_DIR"

echo "=== Using JDK: $JAVA_HOME ==="
"$JAVA_HOME/bin/java" -version

echo ""
echo "=== Compiling with custom JDK ==="
mvn clean compile -q

echo ""
echo "=== Resolving classpath ==="
CP=$(mvn -q dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=/dev/stdout -q 2>/dev/null | tail -1)
CP="target/classes:$CP"

echo ""
echo "=== Running VThreadTest ==="
"$JAVA_HOME/bin/java" \
    --add-exports java.base/sun.misc=ALL-UNNAMED \
    -cp "$CP" \
    VThreadTest
