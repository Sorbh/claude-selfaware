# 🧠 selfaware

A tiny skill that lets **Claude Code and Codex check their own usage** and see **when each limit resets**.

```
Claude
  5-hour     16%  resets Fri Oct 16 00:40 (in 3h04m)
  7-day      64%  resets Fri Oct 16 21:30 (in 23h54m)

Codex
  5-hour      0%  resets Fri Oct 16 00:30 (in 2h54m)
  weekly      0%  resets Thu Oct 22 14:20 (in 6d16h)
```

## Install

```bash
cd claude-selfaware
./install.sh
```

This copies the skill to `~/.claude/skills/selfaware/` and, if Codex is installed, to `~/.codex/skills/selfaware/` (skipped when `~/.codex/skills` already links to `~/.claude/skills`).

## Usage

Ask either agent something like "how much usage do I have left?" or "when does my limit reset?". You can also run the script yourself:

```bash
~/.claude/skills/selfaware/scripts/usage.sh          # both
~/.claude/skills/selfaware/scripts/usage.sh claude
~/.claude/skills/selfaware/scripts/usage.sh codex
```

## How it works

- **Claude**: reads the Claude Code OAuth token from the macOS Keychain and calls `api.anthropic.com/api/oauth/usage`.
- **Codex**: reads the ChatGPT login from `~/.codex/auth.json` and calls `chatgpt.com/backend-api/wham/usage`.

Both endpoints are **undocumented** and could change without notice. The script only makes read calls, using your own credentials on your own machine.

## Requirements

macOS, `curl`, `jq`. Claude Code signed in with a Pro/Max plan, and/or Codex signed in with ChatGPT.

## Uninstall

```bash
rm -rf ~/.claude/skills/selfaware ~/.codex/skills/selfaware
```

## License

MIT
