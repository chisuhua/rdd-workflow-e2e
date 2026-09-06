#!/usr/bin/env bats
# tests/_lib/test_full_workflow_fixture_archive.bats
# Verify invoke_archive_gate (error path) + invoke_archive_happy (happy path)
# + assert_state + assert_schema behavior. Both invoke REAL production APIs.

load ../test_helper
load_lib test_full_workflow_fixture

@test "invoke_archive_gate (REAL archive_gate_check from _lib/archive.sh): blocks when 0 tasks [x]" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"
    # Tasks are all unchecked → 0 [x] → real gate blocks
    run invoke_archive_gate "$FAKE_ROOT" "e2e-fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0 个完成任务"* ]] || [[ "$stderr" == *"0 个完成任务"* ]]
    rm -rf "$FAKE_ROOT"
}

@test "invoke_archive_gate (REAL archive_gate_check): blocks on missing tasks.md" {
    FAKE_ROOT=$(setup_fake_project)
    mkdir -p "$FAKE_ROOT/openspec/changes/e2e-fixture"
    # INTENTIONALLY no tasks.md written
    run invoke_archive_gate "$FAKE_ROOT" "e2e-fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tasks.md 缺失"* ]] || [[ "$stderr" == *"tasks.md 缺失"* ]]
    rm -rf "$FAKE_ROOT"
}

@test "invoke_archive_happy (REAL openspec CLI): moves change to archive/ + updates iteration.json" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"
    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"
    invoke_builder_phases "$FAKE_ROOT" "e2e-fixture"
    sed -i 's/^- \[ \]/- [x]/g' "$FAKE_ROOT/openspec/changes/e2e-fixture/tasks.md"
    git -C "$FAKE_ROOT" add "openspec/changes/e2e-fixture/tasks.md" || true
    git -C "$FAKE_ROOT" commit -q -m "complete tasks" || true

    # Seed iteration.json so sync_iteration_after_archive has something to update
    mkdir -p "$FAKE_ROOT/.rddf/state"
    cat > "$FAKE_ROOT/.rddf/state/iteration.json" <<EOF
{"version": 7, "updated_at": "2026-09-06T00:00:00Z", "current_phase": "phase-1",
 "changes": [{"name": "e2e-fixture", "status": "in_worktree",
             "phase": "phase-1", "category": "general", "priority": "P1",
             "added_at": "2026-09-06T00:00:00Z"}]}
EOF
    git -C "$FAKE_ROOT" add ".rddf/state/iteration.json"
    git -C "$FAKE_ROOT" commit -q -m "seed iter"

    invoke_archive_happy "$FAKE_ROOT" "e2e-fixture"

    # Real outcome: change moved by real openspec archive CLI (date prefix)
    local archived_dir
    archived_dir=$(find "$FAKE_ROOT/openspec/changes/archive" -maxdepth 1 -type d -name "*-e2e-fixture" | head -1)
    [ -n "$archived_dir" ] && [ -d "$archived_dir" ]
    [ ! -d "$FAKE_ROOT/openspec/changes/e2e-fixture" ]

    # iteration.json updated to archived by sync_iteration_after_archive
    run jq -r '.changes[] | select(.name=="e2e-fixture") | .status' \
        "$FAKE_ROOT/.rddf/state/iteration.json"
    [ "$output" = "archived" ]
    run jq -r '.changes[] | select(.name=="e2e-fixture") | .archived_at' \
        "$FAKE_ROOT/.rddf/state/iteration.json"
    [ "$output" != "null" ] && [ -n "$output" ]

    rm -rf "$FAKE_ROOT"
}

@test "assert_schema() validates against _lib/schemas/* (jsonschema defense-in-depth)" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    invoke_arch_stage "$FAKE_ROOT"
    # Auto-derives schema from filename
    assert_schema "$FAKE_ROOT" ".arch-handoff.json"
    rm -rf "$FAKE_ROOT"
}