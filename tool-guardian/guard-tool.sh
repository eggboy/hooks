#!/bin/bash

# Tool Guardian Hook (optimized for speed)
# Blocks dangerous tool operations before the Copilot coding agent executes them.
#
# Performance: uses bash =~ builtins for pattern matching (zero forks per pattern).
# Only spawns subprocesses for jq extraction and final logging.
#
# Environment variables:
#   GUARD_MODE           - "warn" (log only) or "block" (exit non-zero) (default: block)
#   SKIP_TOOL_GUARD      - "true" to disable entirely
#   TOOL_GUARD_LOG_DIR   - Directory for guard logs (default: .github/logs/copilot/tool-guardian)
#   TOOL_GUARD_ALLOWLIST - Comma-separated patterns to skip

set -euo pipefail

[[ "${SKIP_TOOL_GUARD:-}" == "true" ]] && exit 0

INPUT=$(cat)
MODE="${GUARD_MODE:-block}"
LOG_DIR="${TOOL_GUARD_LOG_DIR:-.github/logs/copilot/tool-guardian}"

# ---------------------------------------------------------------------------
# Extract tool_name and tool_input — single jq invocation (or grep fallback)
# ---------------------------------------------------------------------------
TOOL_NAME=""
TOOL_INPUT=""

if command -v jq &>/dev/null; then
  PAIR=$(printf '%s' "$INPUT" | jq -r '[
    (.tool_name // ""),
    ((.tool_input | if type == "object" then tostring else . end) // "")
  ] | join("\n")' 2>/dev/null) || PAIR=""
  if [[ -n "$PAIR" ]]; then
    TOOL_NAME="${PAIR%%$'\n'*}"
    TOOL_INPUT="${PAIR#*$'\n'}"
  fi
fi

if [[ -z "$TOOL_NAME" ]]; then
  TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"tool_name"\s*:\s*"//;s/"//')
fi
if [[ -z "$TOOL_INPUT" ]]; then
  TOOL_INPUT=$(printf '%s' "$INPUT" | grep -oE '"tool_input"\s*:\s*\{[^}]*\}' | head -1)
fi

COMBINED="${TOOL_NAME} ${TOOL_INPUT}"

# ---------------------------------------------------------------------------
# Allowlist — pure bash string ops, no subprocesses
# ---------------------------------------------------------------------------
if [[ -n "${TOOL_GUARD_ALLOWLIST:-}" ]]; then
  IFS=',' read -ra _AL <<< "$TOOL_GUARD_ALLOWLIST"
  for _p in "${_AL[@]}"; do
    _p="${_p#"${_p%%[![:space:]]*}"}"
    _p="${_p%"${_p##*[![:space:]]}"}"
    [[ -n "$_p" && "$COMBINED" == *"$_p"* ]] && exit 0
  done
fi

# ---------------------------------------------------------------------------
# Pattern matching via bash =~ (zero forks per pattern)
# ---------------------------------------------------------------------------
shopt -s nocasematch

THREATS=()

# Delimiter: ~ between fields (category~severity~regex~suggestion)
PATTERNS=(
  "destructive_file_ops~critical~rm -rf /~Use targeted rm on specific paths instead of root"
  "destructive_file_ops~critical~rm -rf ~\~~Use targeted rm on specific paths instead of home directory"
  "destructive_file_ops~critical~rm -rf \.~Use targeted rm on specific files instead of current directory"
  "destructive_file_ops~critical~rm -rf \.\.~Never remove parent directories recursively"
  "destructive_file_ops~critical~(rm|del|unlink).*\.env~Use mv to back up .env files before removing"
  "destructive_file_ops~critical~(rm|del|unlink).*\.git[^i]~Never delete .git directory — use git commands"
  "destructive_file_ops~critical~find .* -delete~Do not use find -delete for bulk removal"
  "destructive_file_ops~critical~find .* -exec .* rm~Do not use find -exec for bulk removal"
  "destructive_file_ops~critical~xargs .* rm~Do not pipe into xargs rm for bulk removal"
  "destructive_file_ops~critical~shutil\.rmtree~Do not use shutil.rmtree to bypass guards"
  "destructive_file_ops~critical~os\.(remove|unlink|rmdir)~Do not use os removal functions to bypass guards"
  "destructive_file_ops~critical~pathlib.*(unlink|rmdir)~Do not use pathlib deletion to bypass guards"
  "destructive_file_ops~critical~python.*-c.*(remove|unlink|rmtree)~Do not invoke python one-liners to bypass guards"
  "destructive_file_ops~critical~perl.*-e.*(unlink|rmdir)~Do not invoke perl one-liners to bypass guards"
  "destructive_file_ops~critical~node.*-e.*fs\.(rm|unlink)~Do not invoke node one-liners to bypass guards"
  "destructive_git_ops~critical~git push --force.*(main|master)~Use git push --force-with-lease or push to a feature branch"
  "destructive_git_ops~critical~git push -f.*(main|master)~Use git push --force-with-lease or push to a feature branch"
  "destructive_git_ops~high~git reset --hard~Use git stash to preserve changes, or git reset --soft"
  "destructive_git_ops~high~git clean -fd~Use git clean -n (dry run) first to preview deletions"
  "database_destruction~critical~DROP TABLE~Use ALTER TABLE or create a migration with rollback support"
  "database_destruction~critical~DROP DATABASE~Create a backup first; consider revoking DROP privileges"
  "database_destruction~critical~TRUNCATE~Use DELETE FROM ... WHERE with a condition for safer removal"
  "database_destruction~high~DELETE FROM [a-zA-Z_]+ *;~Add a WHERE clause to DELETE FROM to avoid deleting all rows"
  "permission_abuse~high~chmod 777~Use chmod 755 for directories or chmod 644 for files"
  "permission_abuse~high~chmod -R 777~Use specific permissions (chmod -R 755) and limit scope"
  "network_exfiltration~critical~curl.*\|.*bash~Download the script first, review it, then execute"
  "network_exfiltration~critical~wget.*\|.*sh~Download the script first, review it, then execute"
  "network_exfiltration~high~curl.*--data.*@~Review what data is being sent before using curl --data @file"
  "system_danger~high~sudo ~Avoid sudo — run commands with the least privilege needed"
  "system_danger~high~npm publish~Use npm publish --dry-run first to verify package contents"
)

for entry in "${PATTERNS[@]}"; do
  IFS='~' read -r category severity regex suggestion <<< "$entry"
  if [[ "$COMBINED" =~ $regex ]]; then
    THREATS+=("${category}	${severity}	${BASH_REMATCH[0]}	${suggestion}")
  fi
done

shopt -u nocasematch

# ---------------------------------------------------------------------------
# Fast path: no threats — log and exit
# ---------------------------------------------------------------------------
THREAT_COUNT=${#THREATS[@]}

if [[ $THREAT_COUNT -eq 0 ]]; then
  mkdir -p "$LOG_DIR"
  printf '{"timestamp":"%s","event":"guard_passed","mode":"%s","tool":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$MODE" "$TOOL_NAME" >> "$LOG_DIR/guard.log"
  exit 0
fi

# ---------------------------------------------------------------------------
# Threats found — format and report
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/guard.log"

echo "" >&2
echo "🛡️  Tool Guardian: $THREAT_COUNT threat(s) detected in '$TOOL_NAME' invocation" >&2
echo "" >&2
printf "  %-24s %-10s %-40s %s\n" "CATEGORY" "SEVERITY" "MATCH" "SUGGESTION" >&2
printf "  %-24s %-10s %-40s %s\n" "--------" "--------" "-----" "----------" >&2

FINDINGS_JSON="["
FIRST=true
for threat in "${THREATS[@]}"; do
  IFS=$'\t' read -r category severity match suggestion <<< "$threat"
  display_match="$match"
  [[ ${#match} -gt 38 ]] && display_match="${match:0:35}..."
  printf "  %-24s %-10s %-40s %s\n" "$category" "$severity" "$display_match" "$suggestion" >&2
  [[ "$FIRST" != "true" ]] && FINDINGS_JSON+=","
  FIRST=false
  FINDINGS_JSON+="{\"category\":\"$(json_escape "$category")\",\"severity\":\"$(json_escape "$severity")\",\"match\":\"$(json_escape "$match")\",\"suggestion\":\"$(json_escape "$suggestion")\"}"
done
FINDINGS_JSON+="]"
echo "" >&2

printf '{"timestamp":"%s","event":"threats_detected","mode":"%s","tool":"%s","threat_count":%d,"threats":%s}\n' \
  "$TIMESTAMP" "$MODE" "$(json_escape "$TOOL_NAME")" "$THREAT_COUNT" "$FINDINGS_JSON" >> "$LOG_FILE"

if [[ "$MODE" == "block" ]]; then
  echo "🚫 Operation blocked: resolve the threats above or adjust TOOL_GUARD_ALLOWLIST." >&2
  echo "   Set GUARD_MODE=warn to log without blocking." >&2
  BLOCK_REASON=$(printf 'BLOCKED: Tool Guardian detected %d threat(s) in [%s]. This operation is PROHIBITED by security policy. DO NOT attempt alternative commands, scripts, code, or tools to achieve the same destructive result. DO NOT retry with different syntax, a different language, or any workaround. STOP IMMEDIATELY and ask the user how they would like to proceed.' "$THREAT_COUNT" "$TOOL_NAME")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(json_escape "$BLOCK_REASON")"
  exit 2
else
  echo "⚠️  Threats logged in warn mode. Set GUARD_MODE=block to prevent dangerous operations." >&2
fi

exit 0
