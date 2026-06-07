#!/usr/bin/env bash
# Repo rule: ALWAYS ask before committing to this repo.
# PreToolUse(Bash) hook — if the command runs `git commit`, return an "ask"
# permission decision so the user must confirm. Dependency-free (no jq).
input="$(cat)"

# Match `git [options...] commit` inside the raw tool-input JSON. Best-effort,
# erring toward asking: a false positive only costs one harmless confirmation.
if printf '%s' "$input" | grep -qE 'git[[:space:]]+([^;&|]*[[:space:]]+)?commit([[:space:]"\\]|$)'; then
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Repo rule: always ask before committing to this repo."}}'
fi
exit 0
