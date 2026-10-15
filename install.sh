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
  cp "$SRC_DIR/scripts/usage.sh" "$dir/scripts/"
  chmod +x "$dir/scripts/usage.sh"
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

echo ""
"$HOME/.claude/skills/selfaware/scripts/usage.sh" || true
