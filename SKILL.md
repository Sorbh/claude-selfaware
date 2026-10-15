---
name: selfaware
description: >
  Check your own usage limits and when they reset, for Claude (5-hour + 7-day windows)
  and Codex (5-hour + weekly windows). Use when the user asks about usage, limits, quota,
  capacity, or reset time, or before starting a large task to know how much budget is left.
---

# selfaware: usage + reset time

Run the bundled script (works from Claude Code and Codex):

```bash
~/.claude/skills/selfaware/scripts/usage.sh          # Claude + Codex
~/.claude/skills/selfaware/scripts/usage.sh claude   # just Claude
~/.claude/skills/selfaware/scripts/usage.sh codex    # just Codex
```

(If installed for Codex only, the path is `~/.codex/skills/selfaware/scripts/usage.sh`.)

Example output:

```
Claude
  5-hour     16%  resets Fri Oct 16 00:40 (in 3h04m)
  7-day      64%  resets Fri Oct 16 21:30 (in 23h54m)

Codex
  5-hour      0%  resets Fri Oct 16 00:30 (in 2h54m)
  weekly      0%  resets Thu Oct 22 14:20 (in 6d16h)
```

- If you are Claude, check `claude`. If you are Codex, check `codex`. Run it with no
  argument when the user asks about both.
- Report only what the script prints. Never guess numbers. If a line says
  `unavailable`, tell the user the reason it gives.
- The percentage is how much of that window is used. Times are local.
