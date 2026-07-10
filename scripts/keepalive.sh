#!/bin/bash
# ============================================================
# keepalive.sh — Sends a tiny dummy prompt to keep the rolling
# usage windows warm. Invoked by the launchd agent every 5h.
#
#   keepalive.sh [--claude] [--codex]
#     --claude   ping the Claude CLI   (default if no flag given)
#     --codex    ping the Codex CLI    (only if its probe succeeds)
#
# Skips entirely when 5-hour usage is already above SKIP_IF_ABOVE
# (no point warming a window that's already in use).
#
# Spends a tiny amount of quota by design. macOS compatible.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-lib.sh
source "$SCRIPT_DIR/usage-lib.sh" 2>/dev/null || true

SKIP_IF_ABOVE="${SKIP_IF_ABOVE:-70}"
DUMMY_PROMPT="Reply with only the word: ok"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# ---- Parse flags (default: claude only) ----
DO_CLAUDE=false
DO_CODEX=false
for arg in "$@"; do
  case "$arg" in
    --claude) DO_CLAUDE=true ;;
    --codex)  DO_CODEX=true ;;
  esac
done
[ "$DO_CLAUDE" = false ] && [ "$DO_CODEX" = false ] && DO_CLAUDE=true

echo "$LOG_PREFIX Keep-alive starting (claude=$DO_CLAUDE codex=$DO_CODEX)..."

# ---- Skip if usage already high ----
if declare -f usage_snapshot >/dev/null 2>&1 && usage_snapshot >/dev/null 2>&1; then
  if usage_is_above "${USAGE_FIVE_PCT:-0}" "$SKIP_IF_ABOVE"; then
    echo "$LOG_PREFIX Usage at ${USAGE_FIVE_PCT}% (> ${SKIP_IF_ABOVE}%) — skipping keep-alive."
    exit 0
  fi
fi

# ---- Ping Claude ----
if [ "$DO_CLAUDE" = true ]; then
  if command -v claude >/dev/null 2>&1; then
    echo "$LOG_PREFIX Pinging Claude CLI..."
    claude -p "$DUMMY_PROMPT" >/dev/null 2>&1 \
      && echo "$LOG_PREFIX ✅ Claude pinged" \
      || echo "$LOG_PREFIX ⚠️ Claude ping failed"
  else
    echo "$LOG_PREFIX ⏭ claude CLI not found"
  fi
fi

# ---- Ping Codex (only if its probe currently passes) ----
if [ "$DO_CODEX" = true ]; then
  if ! command -v codex >/dev/null 2>&1; then
    echo "$LOG_PREFIX ⏭ codex CLI not found"
  elif [ "$(usage_codex_probe_run 2>/dev/null)" != "true" ]; then
    echo "$LOG_PREFIX ⚠️ Codex probe failing (account/model not entitled) — skipping Codex ping"
  else
    echo "$LOG_PREFIX Pinging Codex CLI..."
    codex exec "$DUMMY_PROMPT" >/dev/null 2>&1 \
      && echo "$LOG_PREFIX ✅ Codex pinged" \
      || echo "$LOG_PREFIX ⚠️ Codex ping failed"
  fi
fi

echo "$LOG_PREFIX Keep-alive done."
