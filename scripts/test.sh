#!/usr/bin/env bash
# test.sh — compile and run VThreadTest using the self-built JDK.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT_DIR/config/env.sh"
OUT_DIR="$ROOT_DIR/java/out"

# Optional first argument selects the test class (default: VThreadTest).
CLASS="${1:-VThreadTest}"
JAVA_SRC="$ROOT_DIR/java/${CLASS}.java"

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

echo "Using JDK: $JAVA_HOME"

mkdir -p "$OUT_DIR"

if [[ ! -f "$JAVA_SRC" ]]; then
    echo "error: $JAVA_SRC not found" >&2
    exit 1
fi

echo "Compiling $JAVA_SRC ..."
"$JAVA_HOME/bin/javac" -d "$OUT_DIR" "$JAVA_SRC"

echo "Running $CLASS ..."
echo ""
"$JAVA_HOME/bin/java" -cp "$OUT_DIR" "$CLASS"
