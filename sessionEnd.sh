#!/bin/bash
# sessionEnd hook — reminds users to prefer uv commands in Python projects.
# Only activates when a Python project is detected (pyproject.toml, setup.py,
# requirements.txt, or Pipfile in the working directory).

set -euo pipefail

# ---------------------------------------------------------------------------
# Python project detection — exit early for non-Python workspaces
# ---------------------------------------------------------------------------
is_python_project() {
  local markers=("pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile" "tox.ini")
  for marker in "${markers[@]}"; do
    if [[ -f "$marker" ]]; then
      return 0
    fi
  done
  return 1
}

if ! is_python_project; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Read session data from stdin
# ---------------------------------------------------------------------------
INPUT=$(cat)

# ---------------------------------------------------------------------------
# Extract commands that were run during the session
# ---------------------------------------------------------------------------
COMMANDS=""
if command -v jq &>/dev/null; then
  # Try to extract commands from session data — adapt to the actual schema
  # sessionEnd receives JSON with tool invocations from the session
  COMMANDS=$(printf '%s' "$INPUT" | jq -r '
    .. | objects |
    select(.tool == "Bash" or .tool == "Run") |
    .parameters.command // empty
  ' 2>/dev/null || echo "")

  # Fallback: try flat command field
  if [[ -z "$COMMANDS" ]]; then
    COMMANDS=$(printf '%s' "$INPUT" | jq -r '
      .commands[]? // empty
    ' 2>/dev/null || echo "")
  fi
fi

# Fallback: grep for command-like patterns in raw input
if [[ -z "$COMMANDS" ]]; then
  COMMANDS=$(printf '%s' "$INPUT" | grep -oE '"command"\s*:\s*"[^"]*"' | sed 's/"command"\s*:\s*"//;s/"$//' || true)
fi

if [[ -z "$COMMANDS" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Pattern definitions: old_pattern -> uv replacement
# Uses parallel arrays for bash 3.2 compatibility (no associative arrays)
# ---------------------------------------------------------------------------
OLD_PATTERNS=(
  "pip install"
  "pip3 install"
  "python "
  "python3 "
  "pytest"
  "ruff"
)
NEW_PATTERNS=(
  "uv add"
  "uv add"
  "uv run"
  "uv run"
  "uv run pytest"
  "uv run ruff"
)

# ---------------------------------------------------------------------------
# Scan commands for problematic patterns
# ---------------------------------------------------------------------------
FOUND=0
SUGGESTIONS=""

while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  i=0
  while [[ $i -lt ${#OLD_PATTERNS[@]} ]]; do
    old="${OLD_PATTERNS[$i]}"
    new="${NEW_PATTERNS[$i]}"
    if [[ "$cmd" == *"$old"* ]]; then
      # Skip if the command already uses uv
      if [[ "$cmd" == *"uv run"* || "$cmd" == *"uv add"* ]]; then
        i=$((i + 1))
        continue
      fi
      FOUND=$((FOUND + 1))
      SUGGESTIONS+="  ⚠️  Detected '${old}' → use '${new}' instead"$'\n'
      SUGGESTIONS+="     Command: ${cmd}"$'\n'
    fi
    i=$((i + 1))
  done
done <<< "$COMMANDS"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ $FOUND -gt 0 ]]; then
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "🐍 uv Session Summary: ${FOUND} suggestion(s)" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
  printf '%s' "$SUGGESTIONS" >&2
  echo "" >&2
  echo "💡 This is a uv project. Prefer 'uv run' and 'uv add'" >&2
  echo "   for consistent dependency management." >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
fi

exit 0
