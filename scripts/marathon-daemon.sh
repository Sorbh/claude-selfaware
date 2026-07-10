#!/bin/bash
# ============================================================
# marathon-daemon.sh — Shared watcher for all claude-m sessions.
#
# A SINGLE background process drives EVERY tmux session tagged
# with @claude_marathon=1 (usage is account-global, so one poll
# covers them all):
#   • at the 5-hour limit (≥90%) → tells each session to checkpoint
#     to TASK_STATE.md and pause (the usage hook can't — no user
#     message fires it in an unattended session).
#   • waits for the window to reset (reuses usage-lib reset logic).
#   • after reset → nudges each session to continue.
#
# Lifecycle: spawned by the first `claude-m`; exits when the last
# tagged session closes. A pidfile prevents double-spawn.
#
# macOS compatible.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-lib.sh
source "$SCRIPT_DIR/usage-lib.sh" 2>/dev/null || { echo "usage-lib.sh missing"; exit 1; }

TAG="@claude_marathon"
PIDFILE="${MARATHON_PIDFILE:-/tmp/claude-marathon-daemon.pid}"
CHECK_INTERVAL="${MARATHON_CHECK_INTERVAL:-60}"   # seconds between polls
WRAP_AT="${MARATHON_WRAP_AT:-90}"                 # % that triggers wind-down
RESUME_BELOW="${MARATHON_RESUME_BELOW:-85}"       # % that confirms a reset
BUFFER_SECONDS="${MARATHON_BUFFER_SECONDS:-120}"  # extra wait past resets_at

# ---- Optional Telegram (off by default) ----
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

WRAP_MSG="[selfaware] Usage has hit the 5-hour limit. Checkpoint your current work to TASK_STATE.md now (## Done, ## In Progress, ## Next Steps, ## Files Touched), then stop. I will resume you automatically after the window resets."
RESUME_MSG="Limit reset — read TASK_STATE.md if present and continue exactly where you left off."

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" -d text="🤖 marathon: $*" >/dev/null 2>&1
  fi
}

# ---- Single-instance guard ----
if [ -f "$PIDFILE" ]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || echo "")"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "marathon-daemon already running (pid $old_pid)"; exit 0
  fi
fi
echo $$ > "$PIDFILE"
cleanup() { [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; }
trap cleanup EXIT

# ---- List tmux sessions carrying the tag ----
tagged_sessions() {
  tmux list-sessions -F "#{session_name} #{$TAG}" 2>/dev/null | awk '$2==1{print $1}'
}

# ---- Send a line + Enter to a session (dismiss an exit menu first) ----
send_line() {
  local sess="$1" msg="$2" pane
  pane="$(tmux capture-pane -t "$sess" -p 2>/dev/null || echo "")"
  if echo "$pane" | grep -qiE "exit without saving|continue\?"; then
    tmux send-keys -t "$sess" Enter 2>/dev/null; sleep 2
  fi
  tmux send-keys -t "$sess" "$msg" 2>/dev/null
  sleep 1
  tmux send-keys -t "$sess" Enter 2>/dev/null
}

broadcast() {
  local msg="$1" s
  for s in $(tagged_sessions); do
    log "→ [$s] $2"
    send_line "$s" "$msg"
  done
}

# ---- Sleep until the 5-hour window resets, then confirm it dropped ----
wait_for_reset() {
  usage_snapshot >/dev/null 2>&1
  local epoch now wait
  epoch="$(usage_iso_to_epoch "$USAGE_FIVE_RESETS")"
  if [ -n "$epoch" ]; then
    now="$(date +%s)"; wait=$(( epoch - now + BUFFER_SECONDS ))
    if [ "$wait" -gt 0 ]; then
      log "⏸ Paused. Window resets in $(( wait / 60 ))m — sleeping."
      sleep "$wait"
    fi
  else
    log "⏸ Reset time unknown — waiting 5m."; sleep 300
  fi
  # Confirm usage actually dropped before resuming.
  usage_snapshot >/dev/null 2>&1
  if usage_is_above "${USAGE_FIVE_PCT:-0}" "$RESUME_BELOW"; then
    log "⚠️ Still at ${USAGE_FIVE_PCT}% after reset window — waiting 5m more."; sleep 300
  fi
}

# ============================================================
# Main loop
# ============================================================
log "👁 marathon-daemon started (pid $$). Watching '$TAG' sessions."
wrapped=false

while true; do
  if ! command -v tmux >/dev/null 2>&1; then log "tmux not found — exiting."; break; fi

  sessions="$(tagged_sessions)"
  if [ -z "$sessions" ]; then
    log "No tagged sessions remain — exiting."
    break
  fi

  if usage_snapshot >/dev/null 2>&1; then
    if usage_is_above "${USAGE_FIVE_PCT:-0}" "$WRAP_AT"; then
      if [ "$wrapped" = false ]; then
        log "🔴 Usage ${USAGE_FIVE_PCT}% ≥ ${WRAP_AT}% — sending wrap-up to all sessions."
        broadcast "$WRAP_MSG" "wrap-up"
        wrapped=true
      fi
      wait_for_reset
      log "▶️ Window reset — resuming all sessions."
      broadcast "$RESUME_MSG" "resume"
      wrapped=false
      continue   # re-poll immediately
    else
      wrapped=false   # healthy — clear the episode flag
    fi
  fi

  sleep "$CHECK_INTERVAL"
done

log "marathon-daemon stopped."
