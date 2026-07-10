---
description: Run the selfaware self-test — cross-check deps, hooks, usage API, Codex, launchd timer, and marathon
allowed-tools: Bash(~/.claude/skills/selfaware/scripts/selftest.sh*)
---
Run `~/.claude/skills/selfaware/scripts/selftest.sh` and report the results.

If the user passed `codex` or `--codex` in the arguments ($ARGUMENTS), run it as
`~/.claude/skills/selfaware/scripts/selftest.sh --codex` to also exercise a real
Codex delegation (~1 min).

Summarize: how many checks passed / warned / failed, then list any ✗ failures with the
exact fix, and any ⚠ warnings that correspond to features the user probably wants enabled
(hooks not installed, keep-alive timer off, codex probe false). If everything is green,
say so plainly.
