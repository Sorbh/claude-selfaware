#!/bin/bash
# ============================================================
# usage-lib.sh — Shared usage/reset logic for selfaware.
#
# Sourced (not executed) by:
#   usage-check.sh      — emits the XML <usage_status> block
#   usage-hook.sh       — SessionStart / UserPromptSubmit hook
#   keepalive.sh        — launchd keep-alive ping
#   marathon-daemon.sh  — multi-session tmux watcher
#
# Provides token reading, cached usage fetch, reset-time math,
# status banding, and a daily-cached real Codex probe.
#
# macOS compatible (Keychain, `stat -f`, `date -jf`).
# ============================================================
#
# Usage:
#   source "$(dirname "$0")/usage-lib.sh"
#   if usage_snapshot; then
#     echo "$USAGE_STATUS / $USAGE_FIVE_PCT% / resets in $USAGE_MINS_TO_RESET"
#   else
#     echo "usage unavailable: $USAGE_ERROR"   # USAGE_STATUS is UNKNOWN
#   fi
# ============================================================

# ---- Config (override before sourcing if needed) ----
: "${USAGE_CACHE:=/tmp/claude-usage-cache.json}"
: "${USAGE_POLL_INTERVAL:=120}"           # seconds before a fresh usage fetch
: "${USAGE_ENDPOINT:=https://api.anthropic.com/api/oauth/usage}"
: "${USAGE_USER_AGENT:=claude-code/2.0.32}"
: "${USAGE_KEYCHAIN_SERVICE:=Claude Code-credentials}"
: "${CODEX_PROBE_CACHE:=/tmp/claude-codex-probe}"   # holds "true"/"false"
: "${CODEX_PROBE_TTL:=86400}"             # 24h — Codex entitlement rarely changes
: "${CODEX_PROBE_PROMPT:=Reply with only the word: ok}"

# Thresholds (percent). Override to retune the bands.
: "${USAGE_WARN_FIVE:=80}"
: "${USAGE_WARN_SEVEN:=80}"
: "${USAGE_CRIT_FIVE:=90}"
: "${USAGE_CRIT_SEVEN:=90}"
: "${USAGE_MOD_FIVE:=60}"
: "${USAGE_MOD_SEVEN:=70}"
: "${USAGE_RESET_SOON_MIN:=30}"           # CRITICAL_BUFFER window (minutes)

# ---- File age in seconds (macOS stat); echoes a large number if missing ----
usage_file_age() {
  local f="$1"
  [ -f "$f" ] || { echo 999999999; return; }
  echo $(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
}

# ---- Float compare: usage_is_above 81 80  -> true (exit 0) ----
usage_is_above() {
  echo "$1 >= $2" | bc -l 2>/dev/null | grep -q '^1'
}

# ---- Read OAuth token from Keychain (echoes token or empty) ----
usage_get_token() {
  security find-generic-password -s "$USAGE_KEYCHAIN_SERVICE" -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# ---- Convert ISO-8601 to epoch seconds. Handles fractional seconds and a
#      trailing Z or +HH:MM / -HH:MM offset. The endpoint returns UTC, so the
#      naive datetime is parsed under TZ=UTC to avoid a local-time skew that
#      would otherwise falsely trip reset_soon / CRITICAL_BUFFER.
#      Echoes epoch, or empty on parse failure. ----
usage_iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && return 1
  local clean="${iso%Z}"                          # trailing Z
  clean="${clean%%.*}"                            # fractional seconds (+ any offset after the dot)
  clean="${clean%+[0-9][0-9]:[0-9][0-9]}"         # trailing +HH:MM offset
  clean="${clean%-[0-9][0-9]:[0-9][0-9]}"         # trailing -HH:MM offset
  TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null
}

# ---- Minutes until an ISO reset time; echoes integer or "unknown" ----
usage_mins_to_reset() {
  local iso="$1" reset_epoch now diff
  [ -z "$iso" ] || [ "$iso" = "unknown" ] && { echo "unknown"; return; }
  reset_epoch=$(usage_iso_to_epoch "$iso")
  [ -z "$reset_epoch" ] && { echo "unknown"; return; }
  now=$(date +%s)
  diff=$(( reset_epoch - now ))
  [ "$diff" -lt 0 ] && diff=0
  echo $(( diff / 60 ))
}

# ---- Read a jq path from the usage cache, with a default ----
usage_field() {
  jq -r "$1 // \"$2\"" "$USAGE_CACHE" 2>/dev/null
}

# ---- Refresh the usage cache if stale. Returns 0 if cache is usable.
#      On failure with no existing cache, returns 1 and sets USAGE_ERROR. ----
usage_refresh_cache() {
  USAGE_ERROR=""
  local age; age=$(usage_file_age "$USAGE_CACHE")
  if [ "$age" -le "$USAGE_POLL_INTERVAL" ]; then
    return 0   # cache fresh enough
  fi

  local token; token=$(usage_get_token)
  if [ -z "$token" ]; then
    USAGE_ERROR="Could not read OAuth token from Keychain"
    [ -f "$USAGE_CACHE" ] && return 0   # fall back to stale cache
    return 1
  fi

  local http_code
  http_code=$(curl -s -w "%{http_code}" "$USAGE_ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: $USAGE_USER_AGENT" \
    -H "Content-Type: application/json" \
    -o "$USAGE_CACHE.tmp" 2>/dev/null)

  if [ "$http_code" = "200" ] && jq empty "$USAGE_CACHE.tmp" 2>/dev/null; then
    mv "$USAGE_CACHE.tmp" "$USAGE_CACHE"
    return 0
  fi

  rm -f "$USAGE_CACHE.tmp"
  USAGE_ERROR="API returned HTTP ${http_code}"
  [ -f "$USAGE_CACHE" ] && return 0   # fall back to stale cache
  return 1
}

# ---- Real Codex probe (synchronous). Echoes "true"/"false" and caches it.
#      Used by the installer and keepalive; slow (one codex exec call). ----
usage_codex_probe_run() {
  local result="false"
  if command -v codex >/dev/null 2>&1; then
    if codex exec "$CODEX_PROBE_PROMPT" >/dev/null 2>&1; then
      result="true"
    fi
  fi
  printf '%s' "$result" > "$CODEX_PROBE_CACHE" 2>/dev/null
  echo "$result"
}

# ---- Fast Codex availability for hot paths (hook/snapshot).
#      Uses the cached probe; if stale/missing it refreshes in the BACKGROUND
#      (non-blocking) and returns a conservative "false" until proven working.
#      Echoes "true"/"false". ----
usage_codex_available() {
  if [ -f "$CODEX_PROBE_CACHE" ]; then
    local age; age=$(usage_file_age "$CODEX_PROBE_CACHE")
    if [ "$age" -le "$CODEX_PROBE_TTL" ]; then
      cat "$CODEX_PROBE_CACHE" 2>/dev/null
      return
    fi
  fi
  # Stale/missing: self-heal in background so we don't block the caller.
  if command -v codex >/dev/null 2>&1; then
    ( usage_codex_probe_run >/dev/null 2>&1 & ) >/dev/null 2>&1
  else
    printf 'false' > "$CODEX_PROBE_CACHE" 2>/dev/null
  fi
  # Conservative until proven: don't recommend Codex on an unknown.
  echo "false"
}

# ---- Populate USAGE_* globals from the cache + thresholds.
#      Returns 0 with data, or 1 (USAGE_STATUS=UNKNOWN) when unavailable. ----
usage_snapshot() {
  USAGE_FIVE_PCT=0;   USAGE_FIVE_RESETS="unknown"
  USAGE_SEVEN_PCT=0;  USAGE_SEVEN_RESETS="unknown"
  USAGE_OPUS_PCT="N/A"
  USAGE_MINS_TO_RESET="unknown"
  USAGE_RESET_SOON="false"
  USAGE_CODEX_AVAILABLE="false"
  USAGE_STATUS="UNKNOWN"
  USAGE_DIRECTIVE=""

  USAGE_CODEX_AVAILABLE=$(usage_codex_available)

  if ! usage_refresh_cache; then
    USAGE_DIRECTIVE="Usage data unavailable (${USAGE_ERROR:-unknown error}). Proceed with caution."
    return 1
  fi

  USAGE_FIVE_PCT=$(usage_field '.five_hour.utilization' 0)
  USAGE_FIVE_RESETS=$(usage_field '.five_hour.resets_at' unknown)
  USAGE_SEVEN_PCT=$(usage_field '.seven_day.utilization' 0)
  USAGE_SEVEN_RESETS=$(usage_field '.seven_day.resets_at' unknown)
  USAGE_OPUS_PCT=$(usage_field '.seven_day_opus.utilization' N/A)
  USAGE_MINS_TO_RESET=$(usage_mins_to_reset "$USAGE_FIVE_RESETS")

  if [ "$USAGE_MINS_TO_RESET" != "unknown" ] && [ "$USAGE_MINS_TO_RESET" -le "$USAGE_RESET_SOON_MIN" ]; then
    USAGE_RESET_SOON="true"
  fi

  if usage_is_above "$USAGE_FIVE_PCT" "$USAGE_CRIT_FIVE" || usage_is_above "$USAGE_SEVEN_PCT" "$USAGE_CRIT_SEVEN"; then
    USAGE_STATUS="CRITICAL"
    if [ "$USAGE_RESET_SOON" = "true" ] \
       && usage_is_above "$USAGE_FIVE_PCT" "$USAGE_CRIT_FIVE" \
       && ! usage_is_above "$USAGE_SEVEN_PCT" "$USAGE_CRIT_SEVEN"; then
      USAGE_STATUS="CRITICAL_BUFFER"
      USAGE_DIRECTIVE="Usage at ${USAGE_FIVE_PCT}% but 5-hour window resets in ${USAGE_MINS_TO_RESET} min. You MAY continue carefully through the buffer since it refreshes shortly. Keep a TASK_STATE.md ready. Do not start large new operations."
    else
      USAGE_DIRECTIVE="Usage critically high. Save all progress to TASK_STATE.md immediately. Stop after current action. Reset in ${USAGE_MINS_TO_RESET} min."
    fi
  elif usage_is_above "$USAGE_FIVE_PCT" "$USAGE_WARN_FIVE" || usage_is_above "$USAGE_SEVEN_PCT" "$USAGE_WARN_SEVEN"; then
    USAGE_STATUS="WARNING"
    if [ "$USAGE_CODEX_AVAILABLE" = "true" ]; then
      USAGE_DIRECTIVE="Usage above 80%. DELEGATE suitable independent tasks to Codex now (use codex-delegate.sh) to conserve Claude tokens. Finish your current sub-task, skip optional work, be concise, prepare to checkpoint."
    else
      USAGE_DIRECTIVE="Usage above 80%. Codex NOT available for offload. Finish current sub-task, skip optional work, be concise, prepare to checkpoint to TASK_STATE.md."
    fi
  elif usage_is_above "$USAGE_FIVE_PCT" "$USAGE_MOD_FIVE" || usage_is_above "$USAGE_SEVEN_PCT" "$USAGE_MOD_SEVEN"; then
    USAGE_STATUS="MODERATE"
    USAGE_DIRECTIVE="Usage moderate. Work normally but stay efficient. Check again after next checkpoint."
  else
    USAGE_STATUS="OK"
    USAGE_DIRECTIVE="Plenty of capacity. Work freely. Check again after next checkpoint."
  fi
  return 0
}

# ---- Emit the canonical <usage_status> XML from current USAGE_* globals ----
usage_emit_xml() {
  cat <<XML
<usage_status>
  <five_hour>
    <utilization>${USAGE_FIVE_PCT}%</utilization>
    <resets_at>${USAGE_FIVE_RESETS}</resets_at>
    <minutes_to_reset>${USAGE_MINS_TO_RESET}</minutes_to_reset>
  </five_hour>
  <seven_day>
    <utilization>${USAGE_SEVEN_PCT}%</utilization>
    <resets_at>${USAGE_SEVEN_RESETS}</resets_at>
  </seven_day>
  <opus_seven_day>
    <utilization>${USAGE_OPUS_PCT}</utilization>
  </opus_seven_day>
  <codex_available>${USAGE_CODEX_AVAILABLE}</codex_available>
  <reset_soon>${USAGE_RESET_SOON}</reset_soon>
  <status>${USAGE_STATUS}</status>
  <directive>${USAGE_DIRECTIVE}</directive>
</usage_status>
XML
}
