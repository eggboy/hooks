#!/bin/bash

# uv Enforcer Hook (optimized for speed)
# Blocks bare pip/python/pytest/ruff commands in favour of uv equivalents.
# Applied only to terminal/bash tool calls.
#
# Performance: single jq call for extraction, bash =~ for matching (zero forks).
#
# Environment variables:
#   SKIP_UV_ENFORCER - "true" to disable entirely

set -euo pipefail

[[ "${SKIP_UV_ENFORCER:-}" == "true" ]] && exit 0

INPUT=$(cat)

# ---------------------------------------------------------------------------
# Single jq call to extract tool_name + command (or grep fallback)
# ---------------------------------------------------------------------------
TOOL_NAME=""
CMD=""

if command -v jq &>/dev/null; then
  PAIR=$(printf '%s' "$INPUT" | jq -r '[
    (.tool_name // ""),
    (.tool_input.command // "")
  ] | join("\n")' 2>/dev/null) || PAIR=""
  if [[ -n "$PAIR" ]]; then
    TOOL_NAME="${PAIR%%$'\n'*}"
    CMD="${PAIR#*$'\n'}"
  fi
fi

if [[ -z "$TOOL_NAME" ]]; then
  TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"tool_name"\s*:\s*"//;s/"//')
fi

# Early exit for non-terminal tools
case "$TOOL_NAME" in
  *terminal*|*bash*|*Bash*|*Run*|*run_in_terminal*) ;;
  *) exit 0 ;;
esac

if [[ -z "$CMD" ]]; then
  TOOL_INPUT=$(printf '%s' "$INPUT" | grep -oE '"tool_input"\s*:\s*\{[^}]*\}' | head -1)
  CMD=$(printf '%s' "$TOOL_INPUT" | grep -oE '"command"\s*:\s*"[^"]*"' | head -1 | sed 's/"command"\s*:\s*"//;s/"$//')
fi

[[ -z "$CMD" ]] && exit 0

# ---------------------------------------------------------------------------
# Check patterns via bash =~ (zero forks)
# ---------------------------------------------------------------------------
shopt -s nocasematch
VIOLATIONS=()

PIP_RE='(^|[;&| ])pip3? install'
if [[ "$CMD" =~ $PIP_RE ]]; then
  VIOLATIONS+=("Use 'uv add <package>' instead of 'pip install'")
fi

PIPU_RE='(^|[;&| ])pip3? uninstall'
if [[ "$CMD" =~ $PIPU_RE ]]; then
  VIOLATIONS+=("Use 'uv remove <package>' instead of 'pip uninstall'")
fi

PY_RE='(^|[;&| ])python3? '
UV_PY='uv run python'
if [[ "$CMD" =~ $PY_RE ]] && [[ ! "$CMD" =~ $UV_PY ]]; then
  VIOLATIONS+=("Use 'uv run python ...' instead of bare 'python'")
fi

PT_RE='(^|[;&| ])pytest'
UV_PT='uv run pytest'
if [[ "$CMD" =~ $PT_RE ]] && [[ ! "$CMD" =~ $UV_PT ]]; then
  VIOLATIONS+=("Use 'uv run pytest' instead of bare 'pytest'")
fi

RF_RE='(^|[;&| ])ruff'
UV_RF='uv run ruff'
if [[ "$CMD" =~ $RF_RE ]] && [[ ! "$CMD" =~ $UV_RF ]]; then
  VIOLATIONS+=("Use 'uv run ruff' instead of bare 'ruff'")
fi

shopt -u nocasematch

[[ ${#VIOLATIONS[@]} -eq 0 ]] && exit 0

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
COUNT=${#VIOLATIONS[@]}

echo "" >&2
echo "🐍 uv Enforcer: ${COUNT} violation(s) detected" >&2
echo "" >&2
for v in "${VIOLATIONS[@]}"; do
  echo "  ⚠️  $v" >&2
done
echo "" >&2
echo "   Command: ${CMD}" >&2
echo "" >&2

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

REASON=$(printf 'BLOCKED: uv Enforcer detected %d violation(s). This is a uv-managed project — use uv commands instead. %s' "$COUNT" "${VIOLATIONS[0]}")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(json_escape "$REASON")"
exit 2
