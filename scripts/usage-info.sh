#!/bin/bash
# ============================================================
# usage-info.sh — Human-readable usage check
# Run manually or via a Claude Code slash command.
# macOS compatible.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-lib.sh
source "$SCRIPT_DIR/usage-lib.sh"

CACHE="$USAGE_CACHE"
FORCE_REFRESH=${1:-false}  # Pass "refresh" to force a fresh fetch

# ---- Refresh if stale (>60s) or forced ----
needs_refresh=false
if [ "$FORCE_REFRESH" = "refresh" ] || [ ! -f "$CACHE" ]; then
  needs_refresh=true
elif [ $(( $(date +%s) - $(stat -f %m "$CACHE") )) -gt 60 ]; then
  needs_refresh=true
fi

if [ "$needs_refresh" = true ]; then
  token=$(usage_get_token)
  if [ -z "$token" ]; then
    echo "❌ Could not read OAuth token from Keychain."
    echo "   Try: security find-generic-password -s \"$USAGE_KEYCHAIN_SERVICE\" -w"
    echo "   If empty, check: security dump-keychain | grep -i claude"
    exit 1
  fi

  response=$(curl -s -w "\n%{http_code}" "$USAGE_ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: $USAGE_USER_AGENT" \
    -H "Content-Type: application/json")

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" != "200" ]; then
    echo "❌ API returned HTTP $http_code"
    [ "$http_code" = "429" ] && echo "   Rate limited. Wait a few minutes."
    [ "$http_code" = "401" ] && echo "   Token expired. Restart Claude Code to refresh."
    exit 1
  fi

  echo "$body" > "$CACHE"
  echo "📡 Fetched fresh data"
else
  age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  echo "📋 Cached data (${age}s old)"
fi

echo ""

# ---- Display ----
jq -r '
  def bar(pct):
    (pct / 5 | floor) as $filled |
    ("█" * $filled) + ("░" * (20 - $filled));

  def status(pct):
    if pct >= 90 then "🔴 CRITICAL"
    elif pct >= 80 then "🟡 WARNING"
    elif pct >= 50 then "🟢 MODERATE"
    else "🟢 LOW"
    end;

  "┌─────────────────────────────────────────┐",
  "│         Claude Usage Dashboard          │",
  "├─────────────────────────────────────────┤",
  "│ 5-Hour Window                           │",
  "│ \(bar(.five_hour.utilization // 0))  \(.five_hour.utilization // 0 | tostring | .[0:5])%  │",
  "│ Status: \(status(.five_hour.utilization // 0))                      │",
  "│ Resets: \(.five_hour.resets_at // "N/A" | .[0:19])        │",
  "├─────────────────────────────────────────┤",
  "│ 7-Day Window                            │",
  "│ \(bar(.seven_day.utilization // 0))  \(.seven_day.utilization // 0 | tostring | .[0:5])%  │",
  "│ Status: \(status(.seven_day.utilization // 0))                      │",
  "│ Resets: \(.seven_day.resets_at // "N/A" | .[0:19])        │",
  (if .seven_day_opus then
  "├─────────────────────────────────────────┤",
  "│ 7-Day Opus Window                       │",
  "│ \(bar(.seven_day_opus.utilization // 0))  \(.seven_day_opus.utilization // 0 | tostring | .[0:5])%  │",
  "│ Resets: \(.seven_day_opus.resets_at // "N/A" | .[0:19])        │"
  else empty end),
  "└─────────────────────────────────────────┘"
' "$CACHE"
