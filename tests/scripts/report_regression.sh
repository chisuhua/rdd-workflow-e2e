#!/usr/bin/env bash
# tests/scripts/report_regression.sh
#
# Compare current Bats failure set with tests/KNOWN_FAILURES.txt.
# Distinguishes 新增失败 (must fix) from 已知失败 (acceptable).
#
# Adapted from chisuhua/rdd-workflow/tests/scripts/report_regression.sh
# for the rdd-workflow-e2e external test bed:
#   - bats invocation requires RDD_WORKFLOW_REPO env var
#   - runs both tests/integration/ + tests/_lib/
#   - supports --no-color flag for CI log readability

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="$REPO_ROOT/tests/KNOWN_FAILURES.txt"
TMP_DIR="$(mktemp -d -t rdd-e2e-regression-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Parse args
USE_COLOR=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color) USE_COLOR=0; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--no-color]

Reports Bats regression status:
  已知失败    = baseline-listed failures (acceptable)
  新增失败    = new failures NOT in baseline (must fix; exit 1)
  基线已修复  = baseline entries no longer failing (consider refresh)

Env vars:
  RDD_WORKFLOW_REPO   path to installed rdd-workflow (default: ~/.agents/skills/rdd-workflow)

Exit codes:
  0  no new failures (regardless of bats status, when matches baseline)
  1  new failures detected, or bats infra error
  127 bats not installed
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Color helpers (ANSI; disabled when --no-color or non-TTY)
if [[ "$USE_COLOR" == 1 ]] && [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_RESET=""
fi

if ! command -v bats >/dev/null 2>&1; then
    printf '%s❌ bats-core is required to report regressions%s\n' "$C_RED" "$C_RESET" >&2
    exit 127
fi

if [[ ! -f "$BASELINE" ]]; then
    printf '%s❌ baseline file missing: %s%s\n' "$C_RED" "$BASELINE" "$C_RESET" >&2
    exit 1
fi

# Resolve rdd-workflow (testbed requirement)
RDD_WORKFLOW_REPO="${RDD_WORKFLOW_REPO:-$HOME/.agents/skills/rdd-workflow}"
export RDD_WORKFLOW_REPO

if [[ ! -d "$RDD_WORKFLOW_REPO" ]]; then
    printf '%s❌ RDD_WORKFLOW_REPO not found: %s%s\n' "$C_RED" "$RDD_WORKFLOW_REPO" "$C_RESET" >&2
    printf '   Run ./install_testbed.sh first.\n' >&2
    exit 1
fi

# Run bats (capture both stdout and stderr)
set +e
(cd "$REPO_ROOT" && bats tests/integration/ tests/_lib/) >"$TMP_DIR/bats-output" 2>&1
bats_status=$?
set -e

# Extract failure names from TAP output
# Lines like "not ok 1 full-workflow 4/7: lifecycle..." → just the test name part
sed -nE 's/^not ok [0-9]+[[:space:]]+(.*)$/\1/p' "$TMP_DIR/bats-output" \
    | sed -E 's/[[:space:]]+# (pre-existing|historical|reason)[^[:alnum:]].*$//' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | sed '/^[[:space:]]*$/d' \
    | sort -u >"$TMP_DIR/actual"

# Strip comment suffixes from baseline for matching
sed -E 's/[[:space:]]+#.*$//' "$BASELINE" \
    | sed '/^[[:space:]]*$/d' \
    | sed '/^#/d' \
    | sort -u >"$TMP_DIR/baseline"

known_count=$(comm -12 "$TMP_DIR/actual" "$TMP_DIR/baseline" | wc -l | tr -d ' ')
new_count=$(comm -23 "$TMP_DIR/actual" "$TMP_DIR/baseline" | wc -l | tr -d ' ')
stale_count=$(comm -13 "$TMP_DIR/actual" "$TMP_DIR/baseline" | wc -l | tr -d ' ')

printf 'Bats exit status: %s\n' "$bats_status"
if [[ "$known_count" -gt 0 ]]; then
    printf '%s已知失败: %s%s\n' "$C_YELLOW" "$known_count" "$C_RESET"
else
    printf '已知失败: %s\n' "$known_count"
fi
if [[ "$new_count" -gt 0 ]]; then
    printf '%s新增失败: %s%s\n' "$C_RED" "$new_count" "$C_RESET"
else
    printf '%s新增失败: %s%s\n' "$C_GREEN" "$new_count" "$C_RESET"
fi
if [[ "$stale_count" -gt 0 ]]; then
    printf '%s基线已修复: %s%s\n' "$C_YELLOW" "$stale_count" "$C_RESET"
else
    printf '基线已修复: %s\n' "$stale_count"
fi

# New failures = always fail CI
if [[ "$new_count" -gt 0 ]]; then
    printf '\n%s新增失败明细:%s\n' "$C_RED" "$C_RESET"
    comm -23 "$TMP_DIR/actual" "$TMP_DIR/baseline"
    exit 1
fi

# Bats infra error: non-zero exit but no TAP failures at all
if [[ "$bats_status" -ne 0 ]] \
    && [[ "$known_count" -eq 0 ]] \
    && [[ "$stale_count" -eq 0 ]] \
    && [[ ! -s "$TMP_DIR/actual" ]]; then
    printf '%s❌ Bats infra error (no TAP output):%s\n' "$C_RED" "$C_RESET" >&2
    tail -20 "$TMP_DIR/bats-output" >&2
    exit "$bats_status"
fi

if [[ "$stale_count" -gt 0 ]]; then
    printf '\n%s基线已修复明细 (考虑从 baseline 移除):%s\n' "$C_YELLOW" "$C_RESET"
    comm -13 "$TMP_DIR/actual" "$TMP_DIR/baseline"
fi

printf '\n%s✅ 0 新增失败%s\n' "$C_GREEN" "$C_RESET"
exit 0