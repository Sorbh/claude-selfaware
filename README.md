# 🧠 selfaware

A tiny skill that lets **Claude Code and Codex check their own usage**, see **when each limit resets**, and tell whether you're **on pace to run out** before it does.

```
Claude
  5-hour     85%  resets Fri Oct 16 00:40 (in 1h21m)  ⚠ on pace to hit the limit in 38m
  7-day      67%  resets Fri Oct 16 21:30 (in 22h11m)  · pace ok

Codex
  5-hour      0%  resets Fri Oct 16 00:30 (in 1h11m)
  weekly      0%  resets Thu Oct 22 14:20 (in 6d15h)

→ Claude is at 85% but Codex is only at 0%. Consider switching to Codex.
```

## Install

```bash
cd claude-selfaware
./install.sh
```

This copies the skill to `~/.claude/skills/selfaware/` and, if Codex is installed, to `~/.codex/skills/selfaware/` (skipped when `~/.codex/skills` already links to `~/.claude/skills`). If you have no Claude Code status line yet, it sets one up; if you do, it leaves yours alone and shows what to add.

## Usage

Ask either agent something like "how much usage do I have left?" or "when does my limit reset?". You can also run the script yourself:

```bash
~/.claude/skills/selfaware/scripts/usage.sh            # both
~/.claude/skills/selfaware/scripts/usage.sh claude
~/.claude/skills/selfaware/scripts/usage.sh codex
~/.claude/skills/selfaware/scripts/usage.sh --json     # for scripts
```

- **Pace**: compares how much of a limit is used with how much of the window has passed. `⚠ on pace to hit the limit in 38m` means the current rate runs out before the reset. Shown once at least 10% of the window has passed.
- **Switch hint**: when one tool is at 80%+ and the other is under 50%, a `→` line suggests switching.
- **Extra usage**: paid extra usage (Claude) or credits (Codex) are shown when enabled.

### Status line

`scripts/statusline.sh` prints a compact Claude summary for the Claude Code status line:

```
5h 40% ↻1h21m · 7d 67%
5h 85% ↻1h20m ⚠38m · 7d 68%
```

`⚠38m` next to a limit means you're on pace to hit it in 38 minutes, before it resets; `⛔` means it's already reached. If you already have a status line script, append its output, e.g.:

```sh
usage=$(~/.claude/skills/selfaware/scripts/statusline.sh </dev/null)
printf '%s | %s' "$your_existing_line" "$usage"
```

## How it works

- **Claude**: reads the Claude Code login from the macOS Keychain (or `~/.claude/.credentials.json` on Linux) and calls `api.anthropic.com/api/oauth/usage`.
- **Codex**: reads the ChatGPT login from `~/.codex/auth.json` and calls `chatgpt.com/backend-api/wham/usage`.
- Responses are cached for 60 seconds (`SELFAWARE_TTL` to change) so the status line doesn't hit rate limits. If an API call fails, the last cached result is shown and marked `stale`.

Both endpoints are **undocumented** and could change without notice. The script only makes read calls, using your own credentials on your own machine.

## Requirements

macOS or Linux, `bash`, `curl`, `jq` 1.6+. Claude Code signed in with a Pro/Max plan, and/or Codex signed in with ChatGPT.

## Uninstall

```bash
rm -rf ~/.claude/skills/selfaware ~/.codex/skills/selfaware
```

Then remove the status line entry from `~/.claude/settings.json` (or your status line script) if you added one.

## License

MIT
