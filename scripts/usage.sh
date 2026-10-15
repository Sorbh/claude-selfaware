#!/bin/bash
# ============================================================
# usage.sh — Show Claude and/or Codex usage, reset times, and pace.
#
#   usage.sh                 # both
#   usage.sh claude          # Claude only (5-hour + 7-day windows)
#   usage.sh codex           # Codex only  (5-hour + weekly windows)
#   usage.sh [...] --json    # machine-readable output
#
# Claude: OAuth token from the macOS Keychain (or ~/.claude/.credentials.json
#         on Linux) → api.anthropic.com/api/oauth/usage
# Codex:  token from ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage
#
# Responses are cached for SELFAWARE_TTL seconds (default 60) so status
# lines and repeated checks don't hit the API's rate limit. If the API
# fails, the last cached response is used and marked stale.
# Needs bash, curl, jq (1.6+). macOS or Linux.
# ============================================================

USAGE_LINE="usage: $0 [claude|codex|all] [--json]"
WHICH=all JSON=false
for a in "$@"; do
  case "$a" in
    claude|codex|all) WHICH=$a ;;
    --json)           JSON=true ;;
    -h|--help)        echo "$USAGE_LINE"; exit 0 ;;
    *)                echo "$USAGE_LINE" >&2; exit 2 ;;
  esac
done

TTL="${SELFAWARE_TTL:-60}"
CACHE_DIR="${TMPDIR:-/tmp}"; CACHE_DIR="${CACHE_DIR%/}"
NOW=$(date +%s)

# Seconds since a file was modified (macOS or GNU stat); huge if missing.
age_of() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || { echo 999999999; return; }
  echo $((NOW - m))
}

# download <file> <url> [curl header args...]
# Saves a 200 JSON response to <file>; otherwise echoes an error and returns 1.
download() {
  local file=$1 url=$2; shift 2
  local code
  code=$(curl -s -m 8 -o "$file.tmp" -w '%{http_code}' "$url" "$@" 2>/dev/null)
  if [ "$code" = "200" ] && jq empty "$file.tmp" 2>/dev/null; then
    mv "$file.tmp" "$file"; return 0
  fi
  rm -f "$file.tmp"
  echo "API returned HTTP ${code:-000}"
  return 1
}

# raw <tool>: make sure the cache file is fresh enough; echoes an error
# message if the API couldn't be reached (the cache may still be usable).
raw_claude() {
  local file="$CACHE_DIR/selfaware-claude.json" token
  [ "$(age_of "$file")" -le "$TTL" ] && return 0
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$token" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
  [ -z "$token" ] && { echo "no Claude Code login found (Keychain or ~/.claude/.credentials.json)"; return 1; }
  download "$file" https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.32"
}

raw_codex() {
  local file="$CACHE_DIR/selfaware-codex.json" auth="${CODEX_HOME:-$HOME/.codex}/auth.json" token acct
  [ "$(age_of "$file")" -le "$TTL" ] && return 0
  token=$(jq -r '.tokens.access_token // empty' "$auth" 2>/dev/null)
  acct=$(jq -r '.tokens.account_id // empty' "$auth" 2>/dev/null)
  [ -z "$token" ] && { echo "no ChatGPT login in $auth (run: codex login)"; return 1; }
  download "$file" https://chatgpt.com/backend-api/wham/usage \
    -H "Authorization: Bearer $token" \
    -H "chatgpt-account-id: $acct" \
    -H "User-Agent: codex-cli" \
    || { echo "(run codex once to refresh its login)"; return 1; }
}

# Turn each API's response into the same shape:
#   {tool, ok, error, stale_seconds, windows:[{name, used, resets_at, window_seconds}], extra}
NORMALIZE='
def iso: if . == null then null
  else sub("\\.[0-9]+"; "") | sub("(Z|[+-]00:00)$"; "") | . + "Z" | fromdateiso8601 end;
def money: if type == "object" and .amount_minor != null
  then "$" + (.amount_minor / pow(10; .exponent // 2) * 100 | round / 100 | tostring) else null end;

if $tool == "claude" then
  { windows:
      (if (.limits | type) == "array" and (.limits | length) > 0 then
        [ .limits[] | {
            name: (if .kind == "session" then "5-hour"
                   elif .kind == "weekly_all" then "7-day"
                   elif .scope.model.display_name then "\(.scope.model.display_name) 7d"
                   else .kind end),
            used: .percent,
            resets_at: (.resets_at | iso),
            window_seconds: (if .group == "session" then 18000 else 604800 end) } ]
      else
        . as $r
        | [ ["five_hour", "5-hour", 18000], ["seven_day", "7-day", 604800],
            ["seven_day_opus", "Opus 7d", 604800], ["seven_day_sonnet", "Sonnet 7d", 604800] ]
        | map(. as [$k, $n, $w] | $r[$k] | select(. != null)
              | {name: $n, used: .utilization, resets_at: (.resets_at | iso), window_seconds: $w})
      end),
    extra: (if .spend.enabled == true then
              "extra usage: \(.spend.used | money // "$0") used"
              + (if (.spend.limit | money) then " of \(.spend.limit | money)" else "" end)
            else null end) }
else
  { windows:
      [ .rate_limit.primary_window, .rate_limit.secondary_window | select(. != null) | {
          name: (if .limit_window_seconds == 18000 then "5-hour"
                 elif .limit_window_seconds == 604800 then "weekly"
                 else "\(.limit_window_seconds / 3600 | floor)h" end),
          used: .used_percent,
          resets_at: .reset_at,
          window_seconds: .limit_window_seconds } ],
    extra: (if .credits.unlimited == true then "credits: unlimited"
            elif .credits.has_credits == true then "credits: \(.credits.balance)"
            else null end) }
end'

# tool_json <tool>: normalized JSON for one tool.
tool_json() {
  local tool=$1 file="$CACHE_DIR/selfaware-$1.json" err stale=null
  err=$("raw_$tool")
  if [ -n "$err" ]; then
    [ -f "$file" ] || { jq -n --arg t "$tool" --arg e "$err" \
      '{tool: $t, ok: false, error: $e, windows: [], extra: null}'; return; }
    stale=$(age_of "$file")
  fi
  jq --arg tool "$tool" --arg e "$err" --argjson stale "$stale" \
    "($NORMALIZE) + {tool: \$tool, ok: true, error: (if \$e == \"\" then null else \$e end), stale_seconds: \$stale}" \
    "$file" 2>/dev/null \
    || jq -n --arg t "$tool" '{tool: $t, ok: false, error: "unexpected API response", windows: [], extra: null}'
}

TOOLS=()
case "$WHICH" in
  claude) TOOLS=(claude) ;;
  codex)  TOOLS=(codex) ;;
  all)    TOOLS=(claude codex) ;;
esac

# Add pace (where usage is heading) per window and a "switch tools" hint.
#   pace "over": at the current rate you hit 100% limit_in seconds from now, before the reset.
#   pace "ok":   you won't hit the limit before the reset.
#   pace is left out for the first 10% of a window, when the rate isn't meaningful yet.
RESULT=$(for t in "${TOOLS[@]}"; do tool_json "$t"; done | jq -s --argjson now "$NOW" '
  map(.windows |= map(
    if .resets_at == null then .
    else ((.resets_at - $now) | if . < 0 then 0 else . end) as $left
      | (.window_seconds - $left) as $elapsed
      | . + {resets_in: $left}
      + (if .used >= 100 then {pace: "limit"}
         elif $elapsed >= .window_seconds * 0.1 and .used > 0 then
           ((100 - .used) * $elapsed / .used) as $eta
           | if $eta < $left then {pace: "over", limit_in: ($eta | floor)} else {pace: "ok"} end
         else {} end)
    end))
  | . as $tools
  | def peak($t): [$tools[] | select(.tool == $t and .ok) | .windows[].used] | max;
    def title($t): if $t == "claude" then "Claude" else "Codex" end;
  { tools: $tools,
    hint: ([["claude", "codex"], ["codex", "claude"]]
           | map(. as [$a, $b] | select(peak($a) != null and peak($b) != null
                                         and peak($a) >= 80 and peak($b) < 50)
                 | "\(title($a)) is at \(peak($a) | floor)% but \(title($b)) is only at \(peak($b) | floor)%. Consider switching to \(title($b)).")
           | first) }')

if [ "$JSON" = true ]; then
  echo "$RESULT"
  exit 0
fi

echo "$RESULT" | jq -r '
  def dur: (. / 86400 | floor) as $d | (. % 86400 / 3600 | floor) as $h | (. % 3600 / 60 | floor) as $m
    | if $d > 0 then "\($d)d\($h)h"
      elif $h > 0 then "\($h)h" + ($m | tostring | if length < 2 then "0" + . else . end) + "m"
      else "\($m)m" end;
  def rpad($n): . + (" " * ([$n - length, 0] | max));
  def lpad($n): (" " * ([$n - length, 0] | max)) + .;

  (.tools | map(
    (if .tool == "claude" then "Claude" else "Codex" end)
    + (if .stale_seconds != null then "  (stale: cached \(.stale_seconds | dur) ago; \(.error))" else "" end),
    (if .ok | not then "  unavailable: \(.error)"
     else
       (.windows[] |
         "  " + (.name | rpad(10)) + ((.used | floor | tostring) + "%" | lpad(4))
         + (if .resets_at == null then "  (no active window)"
            else "  resets \(.resets_at | strflocaltime("%a %b %d %H:%M")) (in \(.resets_in | dur))" end)
         + (if .pace == "over" then "  ⚠ on pace to hit the limit in \(.limit_in | dur)"
            elif .pace == "limit" then "  ⛔ limit reached"
            elif .pace == "ok" then "  · pace ok"
            else "" end)),
       (.extra // empty | "  " + .)
     end),
    "") | .[]),
  (.hint // empty | "→ " + .)' | sed -e '${/^$/d;}'
