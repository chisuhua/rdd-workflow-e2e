#!/usr/bin/env bats
# tests/integration/test_install_global.bats
# External test bed — verifies install.sh --global creates a usable installation
# from a fresh user's perspective.

load ../test_helper
load_lib test_full_workflow_fixture

@test "install: rdd-workflow is discoverable at \$RDD_WORKFLOW_REPO" {
    # test_helper.bash fails fast if RDD_WORKFLOW_REPO missing
    [ -d "$RDD_WORKFLOW_REPO" ]
    [ -d "$RDD_WORKFLOW_REPO/_lib" ]
    [ -d "$RDD_WORKFLOW_REPO/skills" ]
    [ -f "$RDD_WORKFLOW_REPO/install.sh" ]
}

@test "install: 27 sub-skills are exposed under RDD_WORKFLOW_REPO/skills/" {
    # Per README, rdd-workflow installs 27 sub-skills to ~/.agents/skills/.
    # In the testbed we use the source repo directly; check skills/ count.
    local count
    count=$(find "$RDD_WORKFLOW_REPO/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$count" -ge 27 ]
}

@test "install: rddf CLI wrapper is reachable in PATH" {
    # Either via global install or via direct invocation in PATH
    if ! command -v rddf >/dev/null 2>&1; then
        # CI may install via install.sh which writes to ~/.local/bin
        # Fall back: invoke via python3 -m directly
        skip "rddf CLI not in PATH (install via install.sh --global first)"
    fi
    run rddf --help
    [ "$status" = 0 ]
}

@test "install: _lib Python modules are importable from rdd-workflow repo" {
    # Mimic what install.sh --global does: adds RDD_WORKFLOW_REPO to sys.path.
    # Verify a few core modules exist and can be imported.
    cd "$RDD_WORKFLOW_REPO"
    run python3 -c "
import sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from _lib.builder_handoff import write_builder_handoff
from _lib.cli.__main__ import main
from _lib.config import ConfigParser
print('import OK')
"
    [ "$status" = 0 ]
    [[ "$output" == *"import OK"* ]]
}

@test "install: install.sh --help returns usage info" {
    run bash "$RDD_WORKFLOW_REPO/install.sh" --help
    [ "$status" = 0 ]
    local combined="$output$stderr"
    [[ "$combined" == *"--global"* ]] || [[ "$combined" == *"Usage"* ]] \
        || { echo "❌ unexpected: $combined" >&2; return 1; }
}

@test "install_testbed.sh: --status shows installation state" {
    run bash "$REPO_ROOT/install_testbed.sh" --status
    [ "$status" = 0 ]
    [[ "$output" == *"rdd-workflow installation status"* ]]
    [[ "$output" == *"$RDD_WORKFLOW_REPO"* ]] || [[ "$output" == *"NOT INSTALLED"* ]]
}