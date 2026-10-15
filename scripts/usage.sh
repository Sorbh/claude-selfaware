#!/bin/bash
# ============================================================
# usage.sh — Show Claude and/or Codex usage and reset times.
#
#   usage.sh            # both
#   usage.sh claude     # Claude only (5-hour + 7-day windows)
#   usage.sh codex      # Codex only  (5-hour + weekly windows)
#
# Claude: OAuth token from the macOS Keychain → api.anthropic.com/api/oauth/usage
# Codex:  token from ~/.codex/auth.json       → chatgpt.com/backend-api/wham/usage
# macOS (Keychain, `date -r`). Needs curl + jq.
# ============================================================

WHICH="${1:-all}"

# Seconds → "2h05m" / "3d4h" / "12m"
human() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm\n' "$h" "$m"
  else echo "${m}m"; fi
}

# label pct reset_epoch → one formatted line
line() {
  local label=$1 pct=$2 epoch=$3
  if [ -z "$epoch" ] || [ "$epoch" = "null" ]; then
    printf '  %-7s %5s%%  (no active window)\n' "$label" "$pct"
    return
  fi
  local left=$((epoch - $(date +%s)))
  printf '  %-7s %5s%%  resets %s (in %s)\n' "$label" "$pct" \
    "$(date -r "$epoch" '+%a %b %d %H:%M')" "$(human "$left")"
}

claude_usage() {
  echo "Claude"
  local token json
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$token" ] && { echo "  unavailable: no Claude Code OAuth token in Keychain"; return 1; }

  json=$(curl -s -m 10 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.32")
  local code=${json##*$'\n'}; json=${json%$'\n'*}
  [ "$code" = "200" ] || { echo "  unavailable: API returned HTTP $code"; return 1; }

  local w pct reset epoch
  for w in five_hour:5-hour seven_day:7-day seven_day_opus:Opus-7d; do
    pct=$(jq -r ".${w%%:*}.utilization // empty" <<<"$json")
    [ -z "$pct" ] && continue
    reset=$(jq -r ".${w%%:*}.resets_at // empty" <<<"$json")
    epoch=""
    if [ -n "$reset" ]; then
      reset=${reset%%.*}; reset=${reset%Z}; reset=${reset%+00:00}
      epoch=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "$reset" +%s 2>/dev/null)
    fi
    line "${w#*:}" "${pct%.*}" "$epoch"
  done
}

codex_usage() {
  echo "Codex"
  local auth="${CODEX_HOME:-$HOME/.codex}/auth.json" token acct json
  token=$(jq -r '.tokens.access_token // empty' "$auth" 2>/dev/null)
  acct=$(jq -r '.tokens.account_id // empty' "$auth" 2>/dev/null)
  [ -z "$token" ] && { echo "  unavailable: no ChatGPT login in $auth (run: codex login)"; return 1; }

  json=$(curl -s -m 10 -w '\n%{http_code}' https://chatgpt.com/backend-api/wham/usage \
    -H "Authorization: Bearer $token" \
    -H "chatgpt-account-id: $acct" \
    -H "User-Agent: codex-cli")
  local code=${json##*$'\n'}; json=${json%$'\n'*}
  [ "$code" = "200" ] || { echo "  unavailable: API returned HTTP $code (try running codex once to refresh login)"; return 1; }

  local w pct epoch
  for w in primary_window:5-hour secondary_window:weekly; do
    pct=$(jq -r ".rate_limit.${w%%:*}.used_percent // empty" <<<"$json")
    [ -z "$pct" ] && continue
    epoch=$(jq -r ".rate_limit.${w%%:*}.reset_at // empty" <<<"$json")
    line "${w#*:}" "${pct%.*}" "$epoch"
  done
  [ "$(jq -r '.rate_limit.limit_reached' <<<"$json")" = "true" ] && echo "  LIMIT REACHED"
  return 0
}

case "$WHICH" in
  claude) claude_usage ;;
  codex)  codex_usage ;;
  all)    claude_usage; echo; codex_usage ;;
  *)      echo "usage: $0 [claude|codex|all]" >&2; exit 2 ;;
esac
