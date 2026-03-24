#!/bin/bash

# Doc File Warning Hook (PreToolUse - file write tools)
# Warns about non-standard documentation files.
# Exit code 0 always (warns only, never blocks).
#
# Performance: single jq call for extraction, bash =~ for matching (zero forks).
#
# Environment variables:
#   SKIP_DOC_FILE_WARNING - "true" to disable entirely

set -euo pipefail

[[ "${SKIP_DOC_FILE_WARNING:-}" == "true" ]] && exit 0

INPUT=$(cat)

# ---------------------------------------------------------------------------
# Extract tool_name + file_path via jq (or grep fallback)
# ---------------------------------------------------------------------------
TOOL_NAME=""
FILE_PATH=""

if command -v jq &>/dev/null; then
  PAIR=$(printf '%s' "$INPUT" | jq -r '[
    (.tool_name // ""),
    (.tool_input.file_path // .tool_input.filePath // "")
  ] | join("\n")' 2>/dev/null) || PAIR=""
  if [[ -n "$PAIR" ]]; then
    TOOL_NAME="${PAIR%%$'\n'*}"
    FILE_PATH="${PAIR#*$'\n'}"
  fi
fi

if [[ -z "$TOOL_NAME" ]]; then
  TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"tool_name"\s*:\s*"//;s/"//')
fi

# Only inspect file-authoring tools
case "$TOOL_NAME" in
  create_file|replace_string_in_file|multi_replace_string_in_file|edit_notebook_file) ;;
  *) exit 0 ;;
esac

if [[ -z "$FILE_PATH" ]]; then
  FILE_PATH=$(printf '%s' "$INPUT" | grep -oE '"(file_path|filePath)"\s*:\s*"[^"]*"' | head -1 | sed 's/.*:\s*"//;s/"$//')
fi

[[ -z "$FILE_PATH" ]] && exit 0

# ---------------------------------------------------------------------------
# Normalize path separators
# ---------------------------------------------------------------------------
NORMALIZED="${FILE_PATH//\\//}"
BASENAME="${NORMALIZED##*/}"

# ---------------------------------------------------------------------------
# Check if the file is a doc/text file at all
# ---------------------------------------------------------------------------
shopt -s nocasematch

DOC_EXT_RE='\.(md|txt)$'
[[ ! "$BASENAME" =~ $DOC_EXT_RE ]] && exit 0

# ---------------------------------------------------------------------------
# Allowed standard documentation files and paths
# ---------------------------------------------------------------------------

# Well-known root-level doc files
KNOWN_ROOT_RE='^(README|CONTRIBUTING|CHANGELOG|LICENSE|CODE_OF_CONDUCT|SECURITY|AUTHORS|HISTORY|AGENTS|SKILL|MEMORY|WORKLOG)\.md$'
[[ "$BASENAME" =~ $KNOWN_ROOT_RE ]] && exit 0

# Copilot / agent customization paths
COPILOT_PATH_RE='\.copilot/(commands|plans|projects|hooks|skills)/'
[[ "$NORMALIZED" =~ $COPILOT_PATH_RE ]] && exit 0

# GitHub special directories
GITHUB_PATH_RE='\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE|workflows)/'
[[ "$NORMALIZED" =~ $GITHUB_PATH_RE ]] && exit 0

# Standard documentation directories
DOC_DIR_RE='(^|/)(docs|documentation|wiki|skills|\.history|memory|notes)/'
[[ "$NORMALIZED" =~ $DOC_DIR_RE ]] && exit 0

# .instructions.md / .prompt.md / .agent.md customization files
CUSTOM_RE='\.(instructions|prompt|agent)\.md$'
[[ "$BASENAME" =~ $CUSTOM_RE ]] && exit 0

# Plan files (*.plan.md)
PLAN_RE='\.plan\.md$'
[[ "$BASENAME" =~ $PLAN_RE ]] && exit 0

# copilot-instructions.md anywhere
[[ "$BASENAME" == "copilot-instructions.md" ]] && exit 0

# ---------------------------------------------------------------------------
# Not in any allowed category — warn (but never block)
# ---------------------------------------------------------------------------
echo "[Hook] WARNING: Non-standard documentation file detected" >&2
echo "[Hook] File: ${FILE_PATH}" >&2
echo "[Hook] Consider consolidating into README.md or a docs/ directory" >&2

exit 0
