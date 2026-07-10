---
description: Create or update TASK_STATE.md in the project root with the current session's progress (manual checkpoint)
allowed-tools: Bash(~/.claude/skills/selfaware/scripts/usage-check.sh*), Read, Write, Edit
---
Create or update `TASK_STATE.md` in the current project root to checkpoint what we're
working on **right now**, so the work survives a usage-limit reset or a fresh session.
This is the manual version of what the skill does automatically at 90% usage.

Steps:

1. Run `~/.claude/skills/selfaware/scripts/usage-check.sh` to get a usage snapshot for the
   header (5h %, 7d %, `resets_at`).

2. If `TASK_STATE.md` already exists, **READ it first**. If it describes a *different* task
   than what we're currently doing, **STOP and tell the user** — do not overwrite it. Ask
   whether to replace it or save the checkpoint somewhere else. (This guard exists because
   `TASK_STATE.md` is a single fixed file per directory.)

3. Otherwise write/update `TASK_STATE.md` using this structure, filled from the **actual
   current session state** (not a template — real values):

   ```markdown
   # Task State Checkpoint
   > Saved at: <timestamp>
   > Usage: <5h>% (5h) / <7d>% (7d)
   > Resets at: <resets_at>

   ## Task
   <one-line goal>

   ## Status: IN_PROGRESS

   ## Done
   - <completed items, specific enough to verify>

   ## In Progress
   - <what's mid-flight and its exact current state>

   ## Next Steps
   1. <exact next action — specific enough for a fresh session>

   ## Files Touched
   - `path/to/file` — <what changed>

   ## Resume Instructions
   <what to do first when resuming>
   ```

4. Keep it **concrete** — file paths, line numbers, commands. Bad: "was working on auth."
   Good: "added JWT verify to `src/auth.ts:45-80`, untested; next: `npm test -- auth`."

5. Tell the user the checkpoint is saved and where.

If the user passed text in $ARGUMENTS, fold it into the checkpoint as extra context/notes.
