#!/usr/bin/env bats
# tests/_lib/test_full_workflow_fixture_proposal.bats
# Verify write_proposal_fixture + invoke_arch_stage behavior.
# invoke_arch_stage calls REAL python3 -m skills.rdd_arch.scripts.write_arch_handoff_env
# with env-var passing (Oracle C1 safe, per AGENTS.md §20).

load ../test_helper
load_lib test_full_workflow_fixture

@test "write_proposal_fixture: creates openspec/changes/<name>/ with proposal.md + tasks.md + design.md" {
    FAKE_ROOT=$(setup_fake_project)
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"
    [ -f "$FAKE_ROOT/openspec/changes/e2e-fixture/proposal.md" ]
    [ -f "$FAKE_ROOT/openspec/changes/e2e-fixture/tasks.md" ]
    [ -f "$FAKE_ROOT/openspec/changes/e2e-fixture/design.md" ]
    grep -q "## Why" "$FAKE_ROOT/openspec/changes/e2e-fixture/proposal.md"
    grep -qE "^- \[[ x]\]" "$FAKE_ROOT/openspec/changes/e2e-fixture/tasks.md"
    rm -rf "$FAKE_ROOT"
}

@test "invoke_arch_stage: writes .arch-handoff.json with REAL contract keys (version=3 per ADR-0016)" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    invoke_arch_stage "$FAKE_ROOT"
    [ -f "$FAKE_ROOT/.rddf/state/.arch-handoff.json" ]

    # Real schema keys (NOT schema_version)
    run jq -r '.version' "$FAKE_ROOT/.rddf/state/.arch-handoff.json"
    [ "$output" = "3" ]
    run jq -r '.adr_dir' "$FAKE_ROOT/.rddf/state/.arch-handoff.json"
    [ "$output" = "docs/adr" ]
    run jq -r '.current_phase' "$FAKE_ROOT/.rddf/state/.arch-handoff.json"
    [ "$output" = "phase-1" ]
    run jq -r '.discovered.adr_dir.found' "$FAKE_ROOT/.rddf/state/.arch-handoff.json"
    [ "$output" = "true" ]
    run jq -r '.adr_count' "$FAKE_ROOT/.rddf/state/.arch-handoff.json"
    [ "$output" = "1" ]

    # jsonschema validate (defense-in-depth)
    assert_schema "$FAKE_ROOT" ".arch-handoff.json"

    rm -rf "$FAKE_ROOT"
}