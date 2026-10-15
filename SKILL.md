---
name: selfaware
description: >
  Check your own usage limits and when they reset, for Claude (5-hour + 7-day windows)
  and Codex (5-hour + weekly windows), including whether you're on pace to hit a limit
  before it resets. Use when the user asks about usage, limits, quota, capacity, or reset
  time, or before starting a large task to know how much budget is left.
---

# selfaware: usage + reset time

Run the bundled script (works from Claude Code and Codex):

```bash
~/.claude/skills/selfaware/scripts/usage.sh          # Claude + Codex
~/.claude/skills/selfaware/scripts/usage.sh claude   # just Claude
~/.claude/skills/selfaware/scripts/usage.sh codex    # just Codex
~/.claude/skills/selfaware/scripts/usage.sh --json   # machine-readable
```

(If installed for Codex only, the path is `~/.codex/skills/selfaware/scripts/usage.sh`.)

Example output:

```
Claude
  5-hour     85%  resets Fri Oct 16 00:40 (in 1h21m)  ⚠ on pace to hit the limit in 38m
  7-day      67%  resets Fri Oct 16 21:30 (in 22h11m)  · pace ok

Codex
  5-hour      0%  resets Fri Oct 16 00:30 (in 1h11m)
  weekly      0%  resets Thu Oct 22 14:20 (in 6d15h)

→ Claude is at 85% but Codex is only at 0%. Consider switching to Codex.
```

- If you are Claude, check `claude`. If you are Codex, check `codex`. Run it with no
  argument when the user asks about both, or when deciding which tool should do a task.
- The percentage is how much of that window is used. Times are local.
- `⚠ on pace to hit the limit in X` means that at the current rate the limit arrives
  before the reset. Before starting a large task in that state, tell the user.
- A `→` line means one tool is nearly out and the other has room. Pass it on to the user.
- Report only what the script prints. Never guess numbers. If it says `unavailable`
  or `stale`, tell the user the reason it gives.
