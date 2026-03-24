#!/bin/bash
# =============================================================================
# uv Enforcer — Regression & False-Positive Test Suite
#
# Usage:  bash test-uv-enforcer.sh [--verbose]
#
# Tests every pattern in uv-enforcer.sh against:
#   1. True positives  — bare pip/python/pytest/ruff that MUST be blocked (exit 2)
#   2. False positives — safe commands that MUST be allowed (exit 0)
#
# Exit: 0 if all pass, 1 if any fail.
# =============================================================================

set -uo pipefail

ENFORCER="$(cd "$(dirname "$0")" && pwd)/uv-enforcer.sh"
VERBOSE="${1:-}"
PASS=0
FAIL=0
TOTAL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
DIM=$'\033[2m'
RESET=$'\033[0m'

run_test() {
  local label="$1" tool="$2" cmd="$3" expect="$4"
  ((TOTAL++))
  exit_code=$(printf '{"tool_name":"%s","tool_input":{"command":"%s"}}' "$tool" "$cmd" \
    | bash "$ENFORCER" 2>/dev/null; echo $?)
  exit_code="${exit_code##*$'\n'}"
  exit_code="${exit_code// /}"
  if [[ "$exit_code" == "$expect" ]]; then
    ((PASS++))
    [[ "$VERBOSE" == "--verbose" ]] && echo "${GREEN}PASS${RESET}  [$label]"
  else
    ((FAIL++))
    echo "${RED}FAIL${RESET}  [$label] exit=$exit_code (expected $expect)"
    [[ "$VERBOSE" == "--verbose" ]] && echo "       tool=$tool cmd=$cmd"
  fi
}

section() {
  echo ""
  echo "${DIM}--- $1 ---${RESET}"
}

# =============================================================================
# SECTION 1: TRUE POSITIVES — must block (exit 2)
# =============================================================================

section "pip install — true positives"

run_test "pip install requests"         run_in_terminal "pip install requests"                2
run_test "pip3 install requests"        run_in_terminal "pip3 install requests"               2
run_test "pip install -r requirements"  run_in_terminal "pip install -r requirements.txt"     2
run_test "pip install --upgrade pip"    run_in_terminal "pip install --upgrade pip"            2
run_test "chain: pip install after &&"  run_in_terminal "cd /project && pip install flask"    2
run_test "chain: pip install after ;"   run_in_terminal "echo ok; pip install flask"          2

section "pip uninstall — true positives"

run_test "pip uninstall requests"       run_in_terminal "pip uninstall requests"              2
run_test "pip3 uninstall requests"      run_in_terminal "pip3 uninstall requests"             2

section "bare python — true positives"

run_test "python script.py"             run_in_terminal "python script.py"                    2
run_test "python3 script.py"            run_in_terminal "python3 script.py"                   2
run_test "python -m http.server"        run_in_terminal "python -m http.server"               2
run_test "python3 -c print"             run_in_terminal "python3 -c 'print(1)'"               2
run_test "chain: python after &&"       run_in_terminal "cd /project && python main.py"       2
run_test "chain: python after ;"        run_in_terminal "echo ok; python main.py"             2
run_test "chain: python after &"        run_in_terminal "sleep 1 & python main.py"            2

section "bare pytest — true positives"

run_test "pytest"                       run_in_terminal "pytest"                              2
run_test "pytest tests/"                run_in_terminal "pytest tests/"                       2
run_test "pytest -v"                    run_in_terminal "pytest -v tests/"                    2
run_test "chain: pytest after &&"       run_in_terminal "cd /project && pytest"               2

section "bare ruff — true positives"

run_test "ruff check"                   run_in_terminal "ruff check ."                        2
run_test "ruff format"                  run_in_terminal "ruff format src/"                    2
run_test "chain: ruff after &&"         run_in_terminal "cd /project && ruff check"           2

# =============================================================================
# SECTION 2: FALSE POSITIVES — must allow (exit 0)
#
# These are safe commands that resemble dangerous patterns.
# If any of these fail, the enforcer is too aggressive.
# =============================================================================

section "piped python (utility, not standalone) — false positives"

run_test "az | python3 -c (JSON parse)"     run_in_terminal "az containerapp show -n app -g rg -o json 2>&1 | python3 -c 'import json,sys; print(json.load(sys.stdin))'" 0
run_test "curl | python3 -m json.tool"       run_in_terminal "curl -s https://api.example.com | python3 -m json.tool"     0
run_test "cat | python3 -c"                  run_in_terminal "cat data.json | python3 -c 'import json,sys; print(json.load(sys.stdin))'" 0
run_test "echo | python3 -c"                 run_in_terminal "echo '{\"a\":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin))'" 0
run_test "grep | python3 -c"                 run_in_terminal "grep -r TODO . | python3 -c 'import sys; print(len(sys.stdin.readlines()))'" 0
run_test "kubectl | python3 -c"              run_in_terminal "kubectl get pods -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d[\"items\"]))'" 0
run_test "docker | python3 (parse)"          run_in_terminal "docker inspect myapp | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"State\"])'" 0
run_test "az | python -c (no 3)"             run_in_terminal "az vm list -o json | python -c 'import json,sys; print(len(json.load(sys.stdin)))'" 0

section "uv run python (correct usage) — false positives"

run_test "uv run python script.py"       run_in_terminal "uv run python script.py"            0
run_test "uv run python -m pytest"       run_in_terminal "uv run python -m pytest"             0
run_test "uv run python -c print"        run_in_terminal "uv run python -c 'print(1)'"         0
run_test "uv run python3 script.py"      run_in_terminal "uv run python3 script.py"            0

section "uv run pytest (correct usage) — false positives"

run_test "uv run pytest"                 run_in_terminal "uv run pytest"                       0
run_test "uv run pytest -v"              run_in_terminal "uv run pytest -v tests/"              0
run_test "uv run pytest tests/"          run_in_terminal "uv run pytest tests/"                 0

section "uv run ruff (correct usage) — false positives"

run_test "uv run ruff check"             run_in_terminal "uv run ruff check ."                 0
run_test "uv run ruff format"            run_in_terminal "uv run ruff format src/"              0

section "uv native commands — false positives"

run_test "uv add requests"               run_in_terminal "uv add requests"                     0
run_test "uv remove flask"               run_in_terminal "uv remove flask"                     0
run_test "uv sync"                       run_in_terminal "uv sync"                             0
run_test "uv lock"                       run_in_terminal "uv lock"                             0
run_test "uv pip install (uv prefix)"    run_in_terminal "uv pip install requests"             0

section "non-terminal tools — false positives (early exit)"

run_test "create_file python content"    create_file     "python main.py"                      0
run_test "read_file with python path"    read_file       "python script.py"                    0
run_test "semantic_search python"        semantic_search "import pytest"                        0

section "unrelated commands — false positives"

run_test "ls -la"                        run_in_terminal "ls -la"                              0
run_test "cat file"                      run_in_terminal "cat README.md"                       0
run_test "git status"                    run_in_terminal "git status"                          0
run_test "docker build"                  run_in_terminal "docker build -t myapp ."             0
run_test "npm install"                   run_in_terminal "npm install"                         0
run_test "az login"                      run_in_terminal "az login"                            0
run_test "echo hello"                    run_in_terminal "echo hello"                          0

section "words containing python/pip/ruff — false positives"

run_test "cpython reference"             run_in_terminal "echo cpython is great"               0
run_test "pipx install"                  run_in_terminal "pipx install black"                  0

section "SKIP_UV_ENFORCER — false positive"

# Special test: SKIP_UV_ENFORCER=true should exit 0 even for violations
((TOTAL++))
exit_code=$(printf '{"tool_name":"run_in_terminal","tool_input":{"command":"python main.py"}}' \
  | SKIP_UV_ENFORCER=true bash "$ENFORCER" 2>/dev/null; echo $?)
exit_code="${exit_code##*$'\n'}"
exit_code="${exit_code// /}"
if [[ "$exit_code" == "0" ]]; then
  ((PASS++))
  [[ "$VERBOSE" == "--verbose" ]] && echo "${GREEN}PASS${RESET}  [SKIP_UV_ENFORCER=true]"
else
  ((FAIL++))
  echo "${RED}FAIL${RESET}  [SKIP_UV_ENFORCER=true] exit=$exit_code (expected 0)"
fi

# =============================================================================
# RESULTS
# =============================================================================
echo ""
echo "==========================================="
if [[ $FAIL -eq 0 ]]; then
  echo "${GREEN}ALL $TOTAL TESTS PASSED${RESET} ($PASS passed, 0 failed)"
else
  echo "${RED}$FAIL FAILED${RESET} out of $TOTAL ($PASS passed)"
fi
echo "==========================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
