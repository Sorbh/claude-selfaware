#!/bin/bash
# ============================================================
# install.sh — Installs the selfaware skill (v2)
# Self-contained skill folder + usage hooks + launchd keep-alive
# + the claude-m marathon launcher. macOS only.
# ============================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILL_DIR="$CLAUDE_DIR/skills/selfaware"
COMMANDS_DIR="$CLAUDE_DIR/commands"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claudeselfaware.keepalive"
PLIST="$LAUNCH_AGENTS/$PLIST_LABEL.plist"
HOOK_CMD="$SKILL_DIR/scripts/usage-hook.sh"

# Scripts that make up the skill (retired: claude-marathon.sh, tmux-resume-watcher.sh)
SCRIPTS=(usage-lib.sh usage-check.sh usage-info.sh usage-hook.sh keepalive.sh codex-delegate.sh claude-m marathon-daemon.sh selftest.sh)

echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │   🧠 selfaware installer     │"
echo "  └─────────────────────────────────────┘"
echo ""

mkdir -p "$SKILL_DIR/scripts" "$COMMANDS_DIR" "$BIN_DIR" "$LAUNCH_AGENTS"

# ---- Copy the self-contained skill (SKILL.md + scripts) ----
cp "$SRC_DIR/SKILL.md" "$SKILL_DIR/"
for s in "${SCRIPTS[@]}"; do
  cp "$SRC_DIR/scripts/$s" "$SKILL_DIR/scripts/"
  chmod +x "$SKILL_DIR/scripts/$s"
done
echo "  ✅ Skill → $SKILL_DIR"

# ---- Slash commands ----
cp "$SRC_DIR/commands/selfaware-usage-info.md" "$COMMANDS_DIR/"
cp "$SRC_DIR/commands/selfaware-test.md" "$COMMANDS_DIR/"
cp "$SRC_DIR/commands/selfaware-task-update.md" "$COMMANDS_DIR/"
# Remove the pre-rename command file if present (idempotent upgrade).
rm -f "$COMMANDS_DIR/usage-check.md"
echo "  ✅ Slash commands → /selfaware-usage-info, /selfaware-test, /selfaware-task-update"

# ---- claude-m on PATH (symlink to the skill copy) ----
ln -sf "$SKILL_DIR/scripts/claude-m" "$BIN_DIR/claude-m"
echo "  ✅ claude-m → $BIN_DIR/claude-m"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "     ⚠️  $BIN_DIR is not on your PATH — add it to use 'claude-m' directly." ;;
esac

# ---- Codex probe (real test ping, cached) ----
echo ""
echo "  🤖 Probing Codex..."
CODEX_OK="false"
if command -v codex >/dev/null 2>&1; then
  if codex exec "Reply with only the word: ok" >/dev/null 2>&1; then
    CODEX_OK="true"; echo "  ✅ Codex works — delegation + Codex keep-alive available"
  else
    echo "  ⚠️  Codex installed but the test call failed (e.g. model/account not entitled)."
    echo "     Delegation and Codex keep-alive will be disabled until this is fixed."
  fi
else
  echo "  ⏭  codex CLI not found — Codex features skipped"
fi
printf '%s' "$CODEX_OK" > /tmp/claude-codex-probe 2>/dev/null || true

# ---- Keychain check ----
echo ""
echo "  🔑 Keychain check..."
TOKEN_TEST=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || echo "")
if [ -n "$TOKEN_TEST" ]; then
  echo "  ✅ OAuth token accessible"
else
  echo "  ⚠️  Token not found. Run: security dump-keychain | grep -i claude"
fi

# ============================================================
# Usage hooks (SessionStart + UserPromptSubmit)
# ============================================================
echo ""
echo "  🪝 Usage hooks — check usage automatically each session/turn."
read -r -p "     Install hooks [g]lobal, [p]roject, or [s]kip? [g/p/s] " HSCOPE < /dev/tty || HSCOPE="s"
SETTINGS=""
case "$HSCOPE" in
  g|G) SETTINGS="$CLAUDE_DIR/settings.json" ;;
  p|P)
    read -r -p "     Project dir [default: $PWD]: " PROJ < /dev/tty || PROJ=""
    PROJ="${PROJ:-$PWD}"
    mkdir -p "$PROJ/.claude"
    SETTINGS="$PROJ/.claude/settings.json"
    ;;
  *) echo "  ⏭  Hooks skipped." ;;
esac

if [ -n "$SETTINGS" ]; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp=$(mktemp)
  # Strip any prior selfaware entries, then add fresh ones. Idempotent.
  jq --arg cmd "$HOOK_CMD" '
    .hooks //= {}
    | .hooks.SessionStart = ((.hooks.SessionStart // []) | map(select((.hooks // []) | any(.command == $cmd) | not)))
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select((.hooks // []) | any(.command == $cmd) | not)))
    | .hooks.SessionStart += [ { hooks: [ { type: "command", command: $cmd, timeout: 15 } ] } ]
    | .hooks.UserPromptSubmit += [ { matcher: "*", hooks: [ { type: "command", command: $cmd, timeout: 15 } ] } ]
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "  ✅ Hooks → $SETTINGS"
fi

# ============================================================
# Keep-alive via launchd (survives sleep + reboot)
# ============================================================
echo ""
echo "  ⏰ Keep-alive — tiny ping every 5h to keep usage windows warm."
echo "     (launchd: runs on wake after sleep, reloads after reboot; skips if usage > 70%)"
read -r -p "     Enable Claude keep-alive? [y/N] " KA_CLAUDE < /dev/tty || KA_CLAUDE="n"

KA_CODEX="n"
if [ "$CODEX_OK" = "true" ]; then
  read -r -p "     Enable Codex keep-alive?  [y/N] " KA_CODEX < /dev/tty || KA_CODEX="n"
fi

# Remove any legacy cron keep-alive so the two schedulers never double-fire.
if crontab -l 2>/dev/null | grep -q "keepalive.sh"; then
  crontab -l 2>/dev/null | grep -v "keepalive.sh" | crontab - || true
  echo "  ♻️  Removed legacy keepalive cron line"
fi

if [[ "$KA_CLAUDE" =~ ^[Yy]$ ]] || [[ "$KA_CODEX" =~ ^[Yy]$ ]]; then
  # Build keepalive.sh argument list from the toggles.
  KA_ARGS=()
  [[ "$KA_CLAUDE" =~ ^[Yy]$ ]] && KA_ARGS+=("--claude")
  [[ "$KA_CODEX"  =~ ^[Yy]$ ]] && KA_ARGS+=("--codex")
  ARG_XML=""
  for a in "$SKILL_DIR/scripts/keepalive.sh" "${KA_ARGS[@]}"; do
    ARG_XML+="    <string>$a</string>"$'\n'
  done

  # Unload an existing agent before rewriting (idempotent).
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
$ARG_XML  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>0</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Hour</key><integer>5</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Hour</key><integer>20</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$CLAUDE_DIR/keepalive.log</string>
  <key>StandardErrorPath</key><string>$CLAUDE_DIR/keepalive.log</string>
</dict>
</plist>
PLIST_EOF

  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
  echo "  ✅ Keep-alive launchd agent installed (${KA_ARGS[*]:-none})"
else
  echo "  ⏭  Keep-alive not enabled."
fi

# ---- Test usage check ----
echo ""
echo "  📡 Testing usage check..."
"$SKILL_DIR/scripts/usage-check.sh" 2>/dev/null | grep -E '<status>|<codex_available>' || echo "  ⚠️  Check failed — verify token and network."

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🧠 selfaware installed!"
echo ""
echo "    • Hooks check usage each session + turn (inject only at 80%+)"
echo "    • 80%+ → delegate to Codex (if available)"
echo "    • 90%  → checkpoint to TASK_STATE.md, keep buffer"
echo "    • 90% but resets ≤30min → push through"
echo "    • claude-m \"task\"  → marathon tmux session, auto-resumes after reset"
echo "    • Keep-alive via launchd (survives sleep + reboot)"
echo ""
echo "  Manual: /selfaware-usage-info  |  Self-test: /selfaware-test  |  Checkpoint: /selfaware-task-update"
echo "  Dashboard: $SKILL_DIR/scripts/usage-info.sh"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
