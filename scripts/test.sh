#!/usr/bin/env bash
# test.sh — compile and run a Java test using the self-built JDK.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT_DIR/config/env.sh"

# Optional first argument selects the test class (default: VThreadTest).
# Accepts either short name (VThreadTest) or fully-qualified name.
CLASS="${1:-VThreadTest}"
PACKAGE="uk.ac.ncl.jensen"
case "$CLASS" in
    *.*) FQCN="$CLASS" ;;          # already fully-qualified
    *)   FQCN="${PACKAGE}.${CLASS}" ;;
esac
CLASS_FILE="target/classes/$(echo "$FQCN" | tr '.' '/').class"

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

if [[ ! -f "$ROOT_DIR/$CLASS_FILE" ]]; then
    echo "error: compiled class $FQCN not found ($ROOT_DIR/$CLASS_FILE)" >&2
    exit 1
fi

echo "Resolving runtime classpath ..."
CP="$(mvn -q dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=/dev/stdout -q 2>/dev/null | tail -1)"
if [[ -n "$CP" ]]; then
    CP="target/classes:$CP"
else
    CP="target/classes"
fi

echo "Running $FQCN ..."
echo ""
"$JAVA_HOME/bin/java" \
    --enable-preview \
    --enable-native-access=ALL-UNNAMED \
    -cp "$CP" \
    "$FQCN"
