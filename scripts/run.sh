#!/usr/bin/env bash
# run.sh — substitute LIBJVM_PATH into correlate.bt and launch bpftrace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT_DIR/config/env.sh"
BPF_SRC="$ROOT_DIR/bpf/correlate.bt"
TMP_BT="$(mktemp /tmp/correlate.XXXXXX.bt)"

# Clean up the temp file on exit (Ctrl-C or normal exit).
trap 'rm -f "$TMP_BT"' EXIT

# Load user configuration.
if [[ ! -f "$CONFIG" ]]; then
    echo "error: $CONFIG not found — copy config/env.sh.example to config/env.sh and fill in the paths" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# Validate that the library actually exists before handing the path to bpftrace.
if [[ -z "${LIBJVM_PATH:-}" ]]; then
    echo "error: LIBJVM_PATH is not set in $CONFIG" >&2
    exit 1
fi
if [[ ! -f "$LIBJVM_PATH" ]]; then
    echo "error: LIBJVM_PATH=$LIBJVM_PATH does not exist" >&2
    exit 1
fi

echo "Using libjvm: $LIBJVM_PATH"
echo "Generating bpftrace script -> $TMP_BT"

# Replace the placeholder with the real path.
# Using | as sed delimiter to avoid conflicts with path separators.
sed "s|LIBJVM_PATH|$LIBJVM_PATH|g" "$BPF_SRC" > "$TMP_BT"

echo "Starting bpftrace (requires root)..."
echo "Press Ctrl-C to stop."
echo ""

sudo bpftrace "$TMP_BT"
