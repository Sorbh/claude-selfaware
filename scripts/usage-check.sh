#!/bin/bash
# ============================================================
# usage-check.sh — Emits the XML <usage_status> block.
# Thin wrapper over usage-lib.sh (all logic lives there).
# Claude / the hook / humans can call this for a status read.
#
#   usage-check.sh                 # cached read (fast)
#   usage-check.sh --refresh-codex # force a real Codex probe first (slow)
#
# macOS compatible.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-lib.sh
source "$SCRIPT_DIR/usage-lib.sh"

# Optionally run a synchronous, real Codex probe before reporting so the
# <codex_available> field reflects a fresh check (used by manual runs / installer).
if [ "${1:-}" = "--refresh-codex" ]; then
  usage_codex_probe_run >/dev/null 2>&1
fi

usage_snapshot
usage_emit_xml
