#!/bin/bash
# ============================================================
# selftest.sh — End-to-end health check for selfaware.
#
# Cross-checks every layer WITHOUT needing a real usage spike:
#   deps, skill files, Keychain, live usage fetch, status-band
#   logic (seeded), hook injection, Codex probe/delegation,
#   launchd keep-alive timer, claude-m symlink, marathon daemon,
#   and installed hooks in settings.json.
#
#   selftest.sh            # fast, read-only (default)
#   selftest.sh --codex    # also run a REAL codex delegation (~1 min)
#   selftest.sh --quiet     # only print the summary + failures
#
# Exit code: 0 if no failures, 1 if any FAIL. macOS compatible.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILL_DIR="$CLAUDE_DIR/skills/selfaware"
PLIST_LABEL="com.claudeselfaware.keepalive"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
HOOK="$SCRIPT_DIR/usage-hook.sh"
LIB="$SCRIPT_DIR/usage-lib.sh"

DO_CODEX=false; QUIET=false
for a in "$@"; do
  case "$a" in
    --codex) DO_CODEX=true ;;
    --quiet|-q) QUIET=true ;;
  esac
done

# ---- pretty + counters ----
P=0; W=0; F=0
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=""; Y=""; R=""; B=""; Z=""; fi
pass() { P=$((P+1)); $QUIET || printf "  ${G}✓${Z} %s\n" "$1"; }
warn() { W=$((W+1)); printf "  ${Y}⚠${Z} %s\n" "$1"; }
fail() { F=$((F+1)); printf "  ${R}✗${Z} %s\n" "$1"; }
head() { $QUIET || printf "\n${B}%s${Z}\n" "$1"; }

printf "\n${B}🧠 selfaware — self-test${Z}\n"
printf "   script dir: %s\n" "$SCRIPT_DIR"

# ============================================================
head "1. Dependencies"
for t in jq bc python3 curl security; do
  command -v "$t" >/dev/null 2>&1 && pass "$t present" || fail "$t MISSING (required)"
done
for t in codex tmux; do
  command -v "$t" >/dev/null 2>&1 && pass "$t present (optional)" || warn "$t not found (optional — feature degrades)"
done

# ============================================================
head "2. Skill files"
for f in SKILL.md; do
  [ -f "$SKILL_DIR/$f" ] && pass "installed: $f" || warn "not installed at $SKILL_DIR/$f (run ./install.sh)"
done
for s in usage-lib.sh usage-check.sh usage-hook.sh usage-info.sh keepalive.sh codex-delegate.sh claude-m marathon-daemon.sh selftest.sh; do
  if [ -x "$SCRIPT_DIR/$s" ]; then pass "script executable: $s"
  elif [ -f "$SCRIPT_DIR/$s" ]; then warn "script present but not +x: $s"
  else fail "script MISSING: $s"; fi
done
[ -f "$CLAUDE_DIR/commands/selfaware-usage-info.md" ] && pass "slash command: /selfaware-usage-info" || warn "/selfaware-usage-info not installed"
[ -f "$CLAUDE_DIR/commands/selfaware-test.md" ] && pass "slash command: /selfaware-test" || warn "/selfaware-test not installed"
[ -f "$CLAUDE_DIR/commands/selfaware-task-update.md" ] && pass "slash command: /selfaware-task-update" || warn "/selfaware-task-update not installed"

# ============================================================
head "3. Keychain OAuth token"
if [ -f "$LIB" ]; then
  # shellcheck source=/dev/null
  source "$LIB"
  TOKEN=$(usage_get_token)
  [ -n "$TOKEN" ] && pass "OAuth token readable from Keychain" || fail "could not read token (log into Claude Code?)"
else
  fail "usage-lib.sh not found next to selftest.sh"
fi

# ============================================================
head "4. Live usage fetch (real API, read-only)"
if usage_snapshot; then
  case "$USAGE_STATUS" in
    OK|MODERATE|WARNING|CRITICAL|CRITICAL_BUFFER)
      pass "API reachable — status=$USAGE_STATUS, 5h=${USAGE_FIVE_PCT}%, 7d=${USAGE_SEVEN_PCT}%, resets in ${USAGE_MINS_TO_RESET}m" ;;
    *) fail "unexpected status: $USAGE_STATUS" ;;
  esac
else
  warn "usage fetch failed (${USAGE_ERROR:-unknown}) — skill fails open, but check token/network"
fi

# ============================================================
head "5. Status-band logic (seeded cache, no network)"
FAR=$(date -u -v+120M +%Y-%m-%dT%H:%M:%SZ)
NEAR=$(date -u -v+15M  +%Y-%m-%dT%H:%M:%SZ)
band() { # five seven resets want
  local dir; dir=$(mktemp -d)
  printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":%s,"resets_at":"%s"},"seven_day_opus":null}' \
    "$1" "$3" "$2" "$FAR" > "$dir/c.json"
  printf 'false' > "$dir/probe"
  local got
  got=$( export USAGE_CACHE="$dir/c.json" CODEX_PROBE_CACHE="$dir/probe" USAGE_POLL_INTERVAL=99999 CODEX_PROBE_TTL=99999
         source "$LIB"; usage_snapshot >/dev/null 2>&1; echo "$USAGE_STATUS" )
  rm -rf "$dir"
  if [ "$got" = "$4" ]; then pass "band ${1}/${2} → $got"; else fail "band ${1}/${2} → got=$got want=$4"; fi
}
band 10 10 "$FAR"  OK
band 65 10 "$FAR"  MODERATE
band 10 75 "$FAR"  MODERATE
band 80 10 "$FAR"  WARNING
band 90 10 "$FAR"  CRITICAL
band 95 10 "$NEAR" CRITICAL_BUFFER
band 95 95 "$NEAR" CRITICAL

# ============================================================
head "6. Hook injection plumbing"
if [ -x "$HOOK" ]; then
  # Silent when OK: push thresholds above 100 so any real usage bands to OK.
  out=$(echo '{"hook_event_name":"UserPromptSubmit"}' | \
        USAGE_MOD_FIVE=101 USAGE_MOD_SEVEN=101 USAGE_WARN_FIVE=101 USAGE_WARN_SEVEN=101 USAGE_CRIT_FIVE=101 USAGE_CRIT_SEVEN=101 \
        "$HOOK" 2>/dev/null)
  [ -z "$out" ] && pass "silent at OK (injects nothing)" || fail "expected no output at OK, got: ${out:0:60}…"
  # Injects when tripped: warn threshold at 1% forces WARNING+ on any usage.
  out=$(echo '{"hook_event_name":"UserPromptSubmit"}' | USAGE_WARN_FIVE=1 "$HOOK" 2>/dev/null)
  if echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["additionalContext"]' 2>/dev/null; then
    pass "injects valid additionalContext JSON when WARNING+"
  else
    fail "hook did not emit valid injection when tripped"
  fi
else
  fail "usage-hook.sh not executable"
fi

# ============================================================
head "7. Installed hooks (settings.json)"
found_hooks=false
for S in "$CLAUDE_DIR/settings.json" "$PWD/.claude/settings.json"; do
  [ -f "$S" ] || continue
  if jq -e --arg c "usage-hook.sh" '
      [(.hooks.SessionStart//[]),(.hooks.UserPromptSubmit//[])]
      | flatten | map(.hooks//[]) | flatten | any(.command|test($c))' "$S" >/dev/null 2>&1; then
    pass "hooks wired in $S"; found_hooks=true
  fi
done
$found_hooks || warn "no SessionStart/UserPromptSubmit hooks reference usage-hook.sh (run ./install.sh, choose g/p)"

# ============================================================
head "8. Codex delegation"
if command -v codex >/dev/null 2>&1; then
  probe=$(cat /tmp/claude-codex-probe 2>/dev/null || echo "?")
  case "$probe" in
    true)  pass "codex probe cache = true (delegation enabled)" ;;
    false) warn "codex probe cache = false (installed but last probe failed — model/auth?)" ;;
    *)     warn "codex probe not cached yet (run: usage-check.sh --refresh-codex)" ;;
  esac
  if $DO_CODEX; then
    $QUIET || printf "    running a REAL delegation (may take ~1 min)…\n"
    wd=$(mktemp -d); git -C "$wd" init -q
    res=$("$SCRIPT_DIR/codex-delegate.sh" "Create a file named ok.txt containing exactly: ok" "$wd" 2>&1)
    if echo "$res" | grep -q '<status>SUCCESS' && [ "$(cat "$wd/ok.txt" 2>/dev/null)" = "ok" ]; then
      pass "real delegation SUCCESS (codex wrote the file)"
    else
      fail "real delegation failed — $(echo "$res" | grep -m1 '<status>' | tr -d ' ')"
    fi
    rm -rf "$wd"
    # non-git dir → should FAIL gracefully with the actionable message
    wd2=$(mktemp -d)
    res2=$("$SCRIPT_DIR/codex-delegate.sh" "touch x" "$wd2" 2>&1)
    if echo "$res2" | grep -q 'not a git repo or trusted'; then
      pass "non-git dir → graceful actionable FAILED (as designed)"
    else
      warn "non-git guard message not seen (codex may have trusted the temp dir)"
    fi
    rm -rf "$wd2"
  else
    $QUIET || printf "    (skipping real delegation — pass --codex to include it)\n"
  fi
else
  warn "codex not installed — delegation unavailable (skill still works, just no offload)"
fi

# ============================================================
head "9. launchd keep-alive timer"
if [ -f "$PLIST" ]; then
  pass "plist present: $PLIST"
  if launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
    pass "launchd agent LOADED (survives sleep/reboot)"
  else
    warn "plist exists but agent not loaded (launchctl bootstrap gui/\$(id -u) $PLIST)"
  fi
  hours=$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval" "$PLIST" 2>/dev/null | grep -A1 Hour | grep -oE '[0-9]+' | paste -sd, - 2>/dev/null)
  args=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST" 2>/dev/null | grep -oE 'keepalive.sh|--claude|--codex' | paste -sd' ' -)
  $QUIET || printf "    schedule hours: %s | args: %s\n" "${hours:-?}" "${args:-?}"
else
  warn "keep-alive not enabled (opt-in) — no plist at $PLIST"
fi

# ============================================================
head "10. claude-m marathon"
if command -v claude-m >/dev/null 2>&1; then
  pass "claude-m on PATH ($(command -v claude-m))"
else
  [ -L "$HOME/.local/bin/claude-m" ] && warn "claude-m symlink exists but ~/.local/bin not on PATH" || warn "claude-m not installed / not on PATH"
fi
[ -x "$SCRIPT_DIR/marathon-daemon.sh" ] && pass "marathon-daemon.sh present" || warn "marathon-daemon.sh missing"
dpid=$(cat /tmp/claude-marathon-daemon.pid 2>/dev/null || echo "")
if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
  pass "marathon daemon running (pid $dpid)"
else
  $QUIET || printf "    (marathon daemon not running — normal unless a claude-m session is active)\n"
fi

# ============================================================
printf "\n${B}Summary:${Z} ${G}%d passed${Z}, ${Y}%d warnings${Z}, ${R}%d failed${Z}\n\n" "$P" "$W" "$F"
if [ "$F" -gt 0 ]; then
  printf "${R}Self-test found failures — see ✗ above.${Z}\n\n"; exit 1
elif [ "$W" -gt 0 ]; then
  printf "${Y}Core healthy; warnings are optional/uninstalled features.${Z}\n\n"; exit 0
else
  printf "${G}All green — everything wired and working.${Z}\n\n"; exit 0
fi
