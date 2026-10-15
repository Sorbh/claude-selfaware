#!/bin/bash
# ============================================================
# install.sh — Installs the selfaware skill for Claude Code
# and Codex. macOS only.
# ============================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

install_to() {
  local dir="$1/selfaware"
  mkdir -p "$dir/scripts"
  cp "$SRC_DIR/SKILL.md" "$dir/"
  cp "$SRC_DIR/scripts/usage.sh" "$SRC_DIR/scripts/statusline.sh" "$dir/scripts/"
  chmod +x "$dir/scripts/usage.sh" "$dir/scripts/statusline.sh"
  echo "  ✅ $dir"
}

install_to "$HOME/.claude/skills"

# Codex reads skills from ~/.codex/skills. Skip it if that already
# points at ~/.claude/skills (a common symlink setup).
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
if [ -d "${CODEX_HOME:-$HOME/.codex}" ] && \
   [ "$(cd "$CODEX_SKILLS" 2>/dev/null && pwd -P)" != "$(cd "$HOME/.claude/skills" && pwd -P)" ]; then
  install_to "$CODEX_SKILLS"
fi

# Status line: set it only if none is configured; never replace yours.
SETTINGS="$HOME/.claude/settings.json"
STATUSLINE="$HOME/.claude/skills/selfaware/scripts/statusline.sh"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
CURRENT=$(jq -r '.statusLine.command // empty' "$SETTINGS")
if [ -z "$CURRENT" ]; then
  tmp=$(mktemp)
  jq --arg cmd "$STATUSLINE" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$tmp" \
    && mv "$tmp" "$SETTINGS"
  echo "  ✅ Status line → $SETTINGS"
# Already wired up if the command (or the script it runs) mentions selfaware.
elif ! { echo "$CURRENT"; cat "${CURRENT##* }" 2>/dev/null; } | grep -q selfaware; then
  echo "  ℹ️  You already have a status line. To add usage to it, append the output of:"
  echo "       $STATUSLINE"
fi

echo ""
"$HOME/.claude/skills/selfaware/scripts/usage.sh" || true
