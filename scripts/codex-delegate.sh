#!/bin/bash
# ============================================================
# codex-delegate.sh — Hand a task to the Codex CLI
# Claude calls this to offload work when usage is high (80%+),
# conserving Claude tokens by routing to Codex instead.
# ============================================================
#
# Usage:
#   codex-delegate.sh "task description" [working_dir]
#
# Returns Codex's output so Claude can review it.
# ============================================================

set -uo pipefail

TASK="${1:-}"
WORK_DIR="${2:-.}"

if [ -z "$TASK" ]; then
  echo "ERROR: No task provided."
  echo "Usage: codex-delegate.sh \"task description\" [working_dir]"
  exit 1
fi

# ---- Verify codex is available ----
if ! command -v codex >/dev/null 2>&1; then
  cat <<EOF
<codex_result>
  <status>UNAVAILABLE</status>
  <message>The 'codex' CLI is not installed or not in PATH. Cannot delegate. Handle this task yourself or ask the user to install Codex.</message>
</codex_result>
EOF
  exit 0
fi

cd "$WORK_DIR" || {
  echo "<codex_result><status>ERROR</status><message>Could not cd to $WORK_DIR</message></codex_result>"
  exit 1
}

# ---- Run codex in non-interactive/exec mode ----
# 'codex exec' runs a single task headlessly and exits.
# --sandbox workspace-write lets it read/write/run without prompting
# (replaces the deprecated --full-auto). </dev/null avoids a stdin hang.
START_TS=$(date '+%Y-%m-%d %H:%M:%S')

CODEX_OUTPUT=$(codex exec --sandbox workspace-write "$TASK" </dev/null 2>&1)
CODEX_EXIT=$?

END_TS=$(date '+%Y-%m-%d %H:%M:%S')

# ---- Wrap result in XML for Claude ----
# IMPORTANT: codex exec can exit 0 even when the API rejected the request
# (e.g. a 400 "model not supported"), so detect error markers in the output
# too — never report SUCCESS over a failed call.
if echo "$CODEX_OUTPUT" | grep -qE 'trusted directory|skip-git-repo-check'; then
  # Codex refuses to run in a dir that is neither a git repo nor a trusted
  # project, so its edits stay revertable. Give Claude an actionable message
  # instead of a bare "exit 1".
  STATUS="FAILED (working dir '${WORK_DIR}' is not a git repo or trusted Codex project — Codex won't edit it. Fix: run 'git init' there, delegate into an existing git repo, or add it to ~/.codex/config.toml as trusted. Or handle this task yourself.)"
elif echo "$CODEX_OUTPUT" | grep -qE '"type"[[:space:]]*:[[:space:]]*"error"|"status"[[:space:]]*:[[:space:]]*4[0-9][0-9]|not supported when using Codex'; then
  STATUS="FAILED (Codex API error — see output; check auth/model entitlement)"
elif [ "$CODEX_EXIT" -eq 0 ]; then
  STATUS="SUCCESS"
else
  STATUS="FAILED (exit ${CODEX_EXIT})"
fi

# Escape output for safe display (keep it readable, not JSON)
cat <<EOF
<codex_result>
  <status>${STATUS}</status>
  <task>${TASK}</task>
  <started>${START_TS}</started>
  <finished>${END_TS}</finished>
  <output>
${CODEX_OUTPUT}
  </output>
  <next_step>Review Codex's output above. Verify the work (run tests, check files). If correct, continue. If wrong, fix it yourself or re-delegate with clearer instructions.</next_step>
</codex_result>
EOF
