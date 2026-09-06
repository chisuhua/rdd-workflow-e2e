#!/usr/bin/env bats
# tests/_lib/test_full_workflow_fixture_skeleton.bats
# Skeleton test: verify fixture helper is loadable + exports expected functions.

load ../test_helper

@test "fixture helper is loadable via load_lib" {
    run load_lib test_full_workflow_fixture
    [ "$status" -eq 0 ]
}

@test "fixture helper exports 10 expected functions" {
    load_lib test_full_workflow_fixture
    # v2 (real path): invoke_archive split into invoke_archive_gate (error path)
    # + invoke_archive_happy (happy path); added invoke_arch_gate for arch error case.
    for fn in setup_fake_project write_arch_fixture write_proposal_fixture \
              invoke_arch_stage invoke_arch_gate invoke_planner_stage \
              invoke_builder_phases invoke_archive_gate invoke_archive_happy \
              assert_state assert_schema; do
        run declare -F "$fn"
        [ "$status" -eq 0 ] || { echo "missing function: $fn"; return 1; }
    done
}
