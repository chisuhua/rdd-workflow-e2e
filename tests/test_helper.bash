#!/usr/bin/env bash
# tests/test_helper.bash — for rdd-workflow-e2e external test bed
#
# Two key environment variables:
#   $REPO_ROOT         = this repo (rdd-workflow-e2e), the test runner
#   $RDD_WORKFLOW_REPO = installed rdd-workflow, the project under test
#
# Default RDD_WORKFLOW_REPO=$HOME/.agents/skills/rdd-workflow
# (set by install.sh --global). Override for testing:
#   RDD_WORKFLOW_REPO=/path/to/rdd-workflow bats tests/

# Resolve this repo (rdd-workflow-e2e) root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Project under test: installed rdd-workflow (default: ~/.agents/skills/rdd-workflow)
RDD_WORKFLOW_REPO="${RDD_WORKFLOW_REPO:-$HOME/.agents/skills/rdd-workflow}"
export RDD_WORKFLOW_REPO

# Verify rdd-workflow is installed (fail fast)
if [[ ! -d "$RDD_WORKFLOW_REPO" ]]; then
    echo "❌ RDD_WORKFLOW_REPO not found: $RDD_WORKFLOW_REPO" >&2
    echo "   Run ./install_testbed.sh first, or set RDD_WORKFLOW_REPO=/path/to/rdd-workflow" >&2
    return 1 2>/dev/null || exit 1
fi

# Project-under-test working dir, if needed
export PROJECT_ROOT="${PROJECT_ROOT:-$RDD_WORKFLOW_REPO}"

# Load helper libraries from THIS repo's tests/_lib/ only
# (rdd-workflow-e2e doesn't have its own _lib/, just test fixtures)
load_lib() {
    local name="$1"
    local path="$REPO_ROOT/tests/_lib/${name}.bash"
    if [[ -f "$path" ]]; then
        # shellcheck source=/dev/null
        source "$path"
        return 0
    fi
    echo "load_lib: file not found: ${name} (looked in $REPO_ROOT/tests/_lib/${name}.bash)" >&2
    return 1
}

# Verify a file exists and is non-empty
assert_file_exists() {
    local f="$1"
    [[ -f "$f" ]] || { echo "expected file to exist: $f" >&2; return 1; }
}

# Verify a file contains a regex
assert_file_contains() {
    local f="$1"
    local pattern="$2"
    [[ -f "$f" ]] || { echo "file not found: $f" >&2; return 1; }
    grep -qE "$pattern" "$f" || { echo "expected '$pattern' in $f" >&2; return 1; }
}

# Verify a command succeeds
assert_cmd_succeeds() {
    "$@" >/dev/null 2>&1 || { echo "expected command to succeed: $*" >&2; return 1; }
}

# Common setup runs before every @test in files that load this helper.
setup() {
    : # placeholder; individual test files can override
}

# Common teardown runs after every @test in files that load this helper.
teardown() {
    : # placeholder; individual test files can override
}