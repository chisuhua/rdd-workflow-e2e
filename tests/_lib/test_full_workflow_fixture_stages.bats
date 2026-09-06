#!/usr/bin/env bats
# tests/_lib/test_full_workflow_fixture_stages.bats
# Verify invoke_planner_stage + invoke_builder_phases behavior.
# Both invoke REAL production APIs (env-var safe, Oracle C1 compliant).

load ../test_helper
load_lib test_full_workflow_fixture

@test "invoke_planner_stage: writes .planner-handoff.json with REAL v1 schema" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"
    [ -f "$FAKE_ROOT/.rddf/state/.planner-handoff.json" ]

    # Real schema keys (NOT schema_version)
    run jq -r '.schema' "$FAKE_ROOT/.rddf/state/.planner-handoff.json"
    [ "$output" = "planner-handoff-v1" ]
    run jq -r '.version' "$FAKE_ROOT/.rddf/state/.planner-handoff.json"
    [ "$output" = "1" ]
    run jq -r '.owner' "$FAKE_ROOT/.rddf/state/.planner-handoff.json"
    [ "$output" = "rdd-planner" ]
    run jq -r '.current_sprint' "$FAKE_ROOT/.rddf/state/.planner-handoff.json"
    [ "$output" = "sprint-2026-09" ]

    assert_schema "$FAKE_ROOT" ".planner-handoff.json"

    rm -rf "$FAKE_ROOT"
}

@test "invoke_builder_phases: writes .rddf/state/builder/<change>.json with REAL v1 schema" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"
    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"
    invoke_builder_phases "$FAKE_ROOT" "e2e-fixture"
    [ -f "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json" ]

    # Real schema keys (NOT 'change')
    run jq -r '.schema' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "builder-handoff-v1" ]
    run jq -r '.version' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "1" ]
    run jq -r '.change_name' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "e2e-fixture" ]
    run jq -r '.owner' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "rdd-builder" ]
    run jq -r '.current_phase' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "phase-2" ]
    run jq -r '.execution_mode_decision.mode' "$FAKE_ROOT/.rddf/state/builder/e2e-fixture.json"
    [ "$output" = "lightweight" ]

    assert_schema "$FAKE_ROOT" "builder/e2e-fixture.json"

    rm -rf "$FAKE_ROOT"
}