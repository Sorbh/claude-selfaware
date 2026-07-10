---
name: selfaware
description: >
  Makes Claude aware of its own API usage limits and able to manage them intelligently.
  Usage is checked automatically by hooks (SessionStart + UserPromptSubmit) that inject a
  directive when usage gets high; Claude delegates suitable tasks to a Codex sub-agent to
  conserve tokens, checkpoints work before limits hit, and resumes after resets. Use this
  skill for: long coding sessions, multi-file refactors, agentic tasks, marathon sessions,
  or any work where hitting a usage limit mid-task would be disruptive. Also trigger when
  the user mentions usage, limits, capacity, quota, token conservation, Codex delegation,
  or the claude-m marathon command. If a TASK_STATE.md exists in the project root, this
  skill is relevant — read it before doing anything.
---

# Claude Selfaware

You have real-time awareness of your own API usage and manage it intelligently —
including offloading work to Codex when you're running low. Usage is checked
**automatically** by hooks; your job is to **act on what they inject**.

## How checks reach you (hooks)

Two hooks run `usage-hook.sh` for you — you don't call them:

- **`SessionStart`** — at session start, surfaces any `TASK_STATE.md` checkpoint to resume.
- **`UserPromptSubmit`** — before every reply, re-checks usage.

They stay **silent at OK/MODERATE** and only inject a `<usage_status>` directive once you
reach **WARNING (80%)** or above. So: if you see no usage note, you have plenty of capacity —
just work. When a directive appears, follow it (delegate / checkpoint / push through).

## Manual check

You can still read usage on demand (the hooks use the same script):

```bash
~/.claude/skills/selfaware/scripts/usage-check.sh
```

Outputs:

```xml
<usage_status>
  <five_hour>
    <utilization>42%</utilization>
    <resets_at>2026-06-24T18:30:00Z</resets_at>
    <minutes_to_reset>87</minutes_to_reset>
  </five_hour>
  <seven_day>
    <utilization>67%</utilization>
    <resets_at>2026-06-29T12:00:00Z</resets_at>
  </seven_day>
  <opus_seven_day>
    <utilization>23%</utilization>
  </opus_seven_day>
  <codex_available>true</codex_available>
  <reset_soon>false</reset_soon>
  <status>OK | MODERATE | WARNING | CRITICAL | CRITICAL_BUFFER | UNKNOWN</status>
  <directive>...</directive>
</usage_status>
```

## When you might check manually

The hooks cover the routine cadence. Run `usage-check.sh` yourself only when you want a
reading mid-task that the hook hasn't surfaced — e.g. **before starting something large**
(know your budget first), or **when the user asks** about usage. The script caches for 2
minutes, so an occasional manual check is cheap.

## How To Act By Status

### OK (under 60%)
Full speed. Don't mention usage to the user.

### MODERATE (60-79%)
Work normally, stay efficient. No need to mention usage.

### WARNING (80-89%) — DELEGATE TO CODEX

This is the key behavior. When you cross 80%:

1. **Check `<codex_available>`.**
   - If `true`: **Automatically delegate suitable tasks to Codex** to conserve Claude tokens.
     You decide which tasks — no need to ask the user (they pre-approved auto-delegation).
   - If `false`: Can't offload. Just wrap up efficiently and prepare to checkpoint.

2. **Pick the RIGHT tasks for Codex.** Good candidates are independent, well-specified,
   and verifiable:
   - Boilerplate generation (CRUD, config files, type definitions)
   - Writing tests for already-written code
   - Repetitive edits across files (rename, format, mechanical refactors)
   - Self-contained functions with clear specs
   - Documentation generation

   **Keep for yourself** (don't delegate) tasks that are:
   - Architectural or design decisions
   - Anything needing context from this conversation Codex won't have
   - Security-sensitive logic
   - Tasks where verifying Codex's output costs as much as doing it yourself

3. **Delegate with:**
   ```bash
   ~/.claude/skills/selfaware/scripts/codex-delegate.sh "clear, complete task description" /path/to/project
   ```
   Give Codex a *complete, self-contained* prompt — it doesn't see this conversation.
   Include file paths, requirements, and what "done" looks like.

4. **Review what Codex returns.** Verify it (run tests, read the diff). If good, continue.
   If wrong, fix it yourself or re-delegate with clearer instructions.

5. **Tell the user once:** "Usage at X% — I've handed [task] to Codex to conserve tokens."

### CRITICAL (90%+) — STOP WITH BUFFER

1. **Mostly stop.** Don't start new work. Keep a buffer of remaining capacity.
2. **Write TASK_STATE.md immediately** (template below).
3. **Tell the user:** what's done, what remains, when it resets, how to resume.
4. **Stop** after saving state.

### CRITICAL_BUFFER (90%+ but 5h resets in ≤30 min) — PUSH THROUGH

Special case: if the 5-hour window is over 90% **but resets within 30 minutes** AND the
weekly window is still healthy, the script returns `CRITICAL_BUFFER`. This means:

- **You MAY keep working carefully** through the remaining buffer, since the window
  refreshes shortly anyway.
- **Still keep a TASK_STATE.md ready** in case you hit a hard wall.
- **Don't start large new operations** — finish what's in flight.
- This only applies when `reset_soon=true` and weekly usage is NOT critical.

### UNKNOWN
Script couldn't fetch data. Work normally, check again at next milestone. If repeated,
tell the user the usage check isn't working.

## TASK_STATE.md

Write to **project root** when checkpointing:

```markdown
# Task State Checkpoint
> Saved at: [timestamp]
> Usage: [five_hour]% (5h) / [seven_day]% (7d)
> Resets at: [resets_at]

## Task
[One-line goal]

## Status: IN_PROGRESS

## Done
- [Completed item, with enough detail to verify]

## In Progress
- [What was being worked on and its current state]

## Delegated to Codex
- [Any tasks handed to Codex and their status]

## Next Steps
1. [Exact next action — specific enough for a fresh session]
2. [...]

## Files Touched
- `path/to/file` — [what changed]

## Resume Instructions
[What to do first when resuming]
```

**Quality matters.** Bad: "Was working on auth." Good: "Added JWT verify to
`src/auth.ts:45-80`. Refresh logic written, untested. Next: `npm test -- --grep auth`."

## Session Start Protocol

The `SessionStart` hook already checks usage and, if a `TASK_STATE.md` exists, injects a
note telling you to resume. When you see that note: read `TASK_STATE.md`, tell the user
what you're resuming, verify the recorded state, and continue from its Next Steps. If no
note appears, just proceed with the user's request.

## Marathon sessions (`claude-m`)

The user can launch a long unattended run with `claude-m` — it opens you inside a tagged
tmux session watched by a shared background daemon. When usage hits the 5-hour limit the
daemon sends you a wrap-up message: **checkpoint to `TASK_STATE.md` and stop**. After the
window resets it sends a resume nudge. So in a marathon, treat any "checkpoint and pause"
message as a hard signal to save state immediately — that's your only chance before the wall.

## The Keep-Alive (background, not your concern)

A separate `keepalive.sh` runs via a **launchd** agent (surviving sleep and reboot) to ping
Claude — and Codex if enabled and working — every 5 hours with a tiny dummy prompt, keeping
the rolling windows warm. It skips when usage is already above 70%. You don't invoke this —
it runs independently. Just know it exists if the user asks why their session stays active.

## Weekly Limit Awareness

If `seven_day` is above 80% even when `five_hour` is low:
- Tell the user: "Weekly usage is at X%. Capacity now but we should prioritize."
- Lean harder on Codex delegation to stretch the weekly budget.
- Avoid Opus-heavy operations if `opus_seven_day` is also high.

## Rules

- **Never fabricate usage numbers.** Only report what the script returns.
- **Don't mention usage when OK/MODERATE.** One mention at WARNING, clear comms at CRITICAL.
- **At 80%+, delegate to Codex automatically** when available — that's the whole point.
- **Give Codex complete, self-contained prompts** — it has zero conversation context.
- **Always verify Codex output** before building on it.
- **Respect the 30-min buffer rule** — CRITICAL_BUFFER means keep going, plain CRITICAL means stop.
- **Always be ready to checkpoint** — usage can jump 10%+ in one heavy operation.
- **Delete TASK_STATE.md when a resumed task completes.**
