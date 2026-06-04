#!/usr/bin/env bash
# run-otel-agent.sh — convenience wrapper for run-otel.sh with the JVMTI agent
# enabled (Plan A). Equivalent to: USE_AGENT=1 bash scripts/run-otel.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env USE_AGENT=1 "$SCRIPT_DIR/run-otel.sh" "$@"
