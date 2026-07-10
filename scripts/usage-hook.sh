#!/bin/bash
# ============================================================
# usage-hook.sh — Claude Code hook for automatic usage awareness.
#
# Wired to TWO hook events (see install.sh):
#   SessionStart      — once per session: surface a TASK_STATE.md
#                       checkpoint to resume + inject usage if actionable.
#   UserPromptSubmit  — before every reply: inject usage directive when
#                       at WARNING (80%) or above.
#
# Contract (Claude Code hooks):
#   - Reads the hook JSON payload on stdin.
#   - Emits {"hookSpecificOutput":{"hookEventName":..,"additionalContext":..}}
#     ONLY when there is something actionable to say; otherwise prints
#     nothing.
#   - ALWAYS exits 0. This hook NEVER blocks the turn (no exit 2), per spec:
#     "inform, never block." Fails open on UNKNOWN usage.
#
# macOS compatible.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-lib.sh
source "$SCRIPT_DIR/usage-lib.sh" 2>/dev/null || exit 0

# ---- Read hook payload from stdin ----
INPUT="$(cat 2>/dev/null)"
EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$EVENT" ] && EVENT="UserPromptSubmit"
[ -z "$CWD" ] && CWD="$PWD"

CONTEXT=""
nl=$'\n'

# ---- SessionStart: surface a checkpoint to resume (regardless of usage) ----
if [ "$EVENT" = "SessionStart" ]; then
  STATE_FILE="$CWD/TASK_STATE.md"
  if [ -f "$STATE_FILE" ]; then
    CONTEXT="[selfaware] A TASK_STATE.md checkpoint exists at ${STATE_FILE}. Read it first, tell the user what you're resuming, verify the recorded state, then continue from its Next Steps. Delete it once the task is fully complete."
  fi
fi

# ---- Usage check (both events): inject only when actionable (WARNING+) ----
if usage_snapshot; then
  case "$USAGE_STATUS" in
    WARNING|CRITICAL|CRITICAL_BUFFER)
      USAGE_LINE="[selfaware] Usage ${USAGE_STATUS}: 5h ${USAGE_FIVE_PCT}%, 7d ${USAGE_SEVEN_PCT}% (5h resets in ${USAGE_MINS_TO_RESET}m, codex_available=${USAGE_CODEX_AVAILABLE}). ${USAGE_DIRECTIVE}"
      if [ -n "$CONTEXT" ]; then
        CONTEXT="${CONTEXT}${nl}${USAGE_LINE}"
      else
        CONTEXT="$USAGE_LINE"
      fi
      ;;
    *)
      : # OK / MODERATE: stay silent — zero added tokens.
      ;;
  esac
fi
# UNKNOWN usage: fail open, inject nothing.

# ---- Emit JSON only if we have something to say ----
if [ -n "$CONTEXT" ]; then
  jq -n --arg event "$EVENT" --arg ctx "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:$event, additionalContext:$ctx}}'
fi

exit 0
