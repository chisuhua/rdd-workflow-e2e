#!/usr/bin/env bats
# tests/integration/test_full_workflow_e2e.bats
#
# Full-workflow E2E: fake project walks rdd-arch → rdd-planner →
# rdd-builder → archive lifecycle (lightweight mode).
#
# v2 (real path): invokes REAL production code per design v2 spec.
# Per docs/superpowers/specs/2026-09-06-rdd-workflow-full-e2e-design-v2.md
# 4 happy path cases + 3 error path cases.
#
# Self-contained: helper fixture at tests/_lib/test_full_workflow_fixture.bash
# isolates to $BATS_TEST_TMPDIR (never touches $REPO_ROOT/.rddf/state/).

load ../test_helper
load_lib test_full_workflow_fixture

setup() {
    FAKE_ROOT=$(setup_fake_project)
    export FAKE_ROOT
}

teardown() {
    # Capture FAKE_ROOT before unset (for cleanup)
    local old_fake_root="$FAKE_ROOT"

    # Unset all env vars set by invoke_* functions (prevent leak across tests)
    unset FAKE_ROOT PROJECT_ROOT \
          PROPOSALS_AUTHORED PROPOSALS_APPROVED_COUNT FEATURES_ACTIVE CURRENT_SPRINT \
          DISCOVERED_ADR_DIR DISCOVERED_ADR_PATTERN DISCOVERED_ADR_DIR_FOUND \
          DISCOVERED_ROADMAP_FOUND DISCOVERED_ARCH_FOUND DISCOVERED_ADR_DIR_TRIED \
          DISCOVERED_ROADMAP_TRIED DISCOVERED_ARCH_TRIED DISCOVERED_ROADMAP_PATH \
          DISCOVERED_ARCHITECTURE_DIR ROADMAP_EXISTS_BOOL \
          SKIP_WORKFLOW_REFLECTION SKIP_AUTO_PLANNER_FEEDBACK \
          E2E_PROJECT_ROOT E2E_CHANGE_NAME \
          E2E_BUILDER_PHASE E2E_BUILDER_APPROVAL_STATUS E2E_BUILDER_EXECUTION_MODE \
          E2E_BUILDER_EXECUTION_STATUS E2E_BUILDER_REVIEW_STATUS \
          E2E_BUILDER_ARCHIVE_STATUS E2E_BUILDER_RETRY_COUNT E2E_BUILDER_MAX_RETRIES \
          E2E_BUILDER_BRANCH E2E_BUILDER_WORKTREE_PATH \
          SKIP_VERIFIER_CONTRACT SKIP_AC_VERIFICATION FORCE_ARCHIVE_INCOMPLETE \
          ARCHIVE_COMMIT_SHA E2E_STATE_FILE E2E_SCHEMA_FILE \
          2>/dev/null || true

    # cd FIRST, then rm (per check_test_isolation.sh convention)
    cd "$REPO_ROOT"
    [ -n "$old_fake_root" ] && [ -d "$old_fake_root" ] && rm -rf "$old_fake_root"
}

# ── Happy Path (4 cases — REAL API invocation + jsonschema validate) ──

@test "full-workflow 1/7: arch stage emits valid .arch-handoff.json (v3 contract per ADR-0016)" {
    write_arch_fixture "$FAKE_ROOT"
    invoke_arch_stage "$FAKE_ROOT"

    # Real schema keys (version, NOT schema_version)
    assert_state "$FAKE_ROOT" ".arch-handoff.json" \
        "version:3|adr_dir:docs/adr|current_phase:phase-1"

    # Defense-in-depth: validate against real schema
    assert_schema "$FAKE_ROOT" ".arch-handoff.json"
}

@test "full-workflow 2/7: planner stage emits valid .planner-handoff.json (v1 contract per spec §3.3)" {
    write_arch_fixture "$FAKE_ROOT"
    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"

    # Real schema keys (schema/version/owner/current_sprint)
    assert_state "$FAKE_ROOT" ".planner-handoff.json" \
        "schema:planner-handoff-v1|version:1|owner:rdd-planner|current_sprint:sprint-2026-09"

    assert_schema "$FAKE_ROOT" ".planner-handoff.json"
}

@test "full-workflow 3/7: builder handoff + real archive moves change to openspec/changes/archive/" {
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"
    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"
    invoke_builder_phases "$FAKE_ROOT" "e2e-fixture"

    # Mark tasks complete (real gate requires ≥1 [x])
    sed -i 's/^- \[ \]/- [x]/g' "$FAKE_ROOT/openspec/changes/e2e-fixture/tasks.md"
    git -C "$FAKE_ROOT" add "openspec/changes/e2e-fixture/tasks.md" || true
    git -C "$FAKE_ROOT" commit -q -m "e2e: complete tasks for archive" || true

    invoke_archive_happy "$FAKE_ROOT" "e2e-fixture"

    # Real outcome: change moved by real openspec archive CLI.
    # Note: openspec prefixes archive dir with date (e.g. 2026-09-06-e2e-fixture).
    # Verify glob pattern + active dir absence.
    local archived_dir
    archived_dir=$(find "$FAKE_ROOT/openspec/changes/archive" -maxdepth 1 -type d -name "*-e2e-fixture" | head -1)
    [ -n "$archived_dir" ] && [ -d "$archived_dir" ]
    [ ! -d "$FAKE_ROOT/openspec/changes/e2e-fixture" ]

    # Builder handoff reflects real shape
    assert_state "$FAKE_ROOT" "builder/e2e-fixture.json" \
        "schema:builder-handoff-v1|change_name:e2e-fixture|owner:rdd-builder"

    assert_schema "$FAKE_ROOT" "builder/e2e-fixture.json"
}

@test "full-workflow 4/7: lifecycle ends with iteration.json changes[].status='archived'" {
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"

    # Seed iteration.json so mark_iteration_archived has something to update
    mkdir -p "$FAKE_ROOT/.rddf/state"
    cat > "$FAKE_ROOT/.rddf/state/iteration.json" <<EOF
{
  "version": 7,
  "updated_at": "2026-09-06T00:00:00Z",
  "current_phase": "phase-1",
  "changes": [
    {"name": "e2e-fixture", "status": "in_worktree", "phase": "phase-1",
     "category": "general", "priority": "P1", "added_at": "2026-09-06T00:00:00Z"}
  ]
}
EOF
    git -C "$FAKE_ROOT" add ".rddf/state/iteration.json"
    git -C "$FAKE_ROOT" commit -q -m "seed iteration.json"

    invoke_arch_stage "$FAKE_ROOT"
    invoke_planner_stage "$FAKE_ROOT"
    invoke_builder_phases "$FAKE_ROOT" "e2e-fixture"

    sed -i 's/^- \[ \]/- [x]/g' "$FAKE_ROOT/openspec/changes/e2e-fixture/tasks.md"
    git -C "$FAKE_ROOT" add "openspec/changes/e2e-fixture/tasks.md" || true
    git -C "$FAKE_ROOT" commit -q -m "e2e: complete tasks" || true

    invoke_archive_happy "$FAKE_ROOT" "e2e-fixture"

    # Real schema: changes[].status (NOT sprints[-1].status)
    run jq -r '.changes[] | select(.name=="e2e-fixture") | .status' \
        "$FAKE_ROOT/.rddf/state/iteration.json"
    [ "$output" = "archived" ]

    # archived_at + archive_commit_sha + tasks_done set (per sync_iteration_after_archive)
    run jq -r '.changes[] | select(.name=="e2e-fixture") | .archived_at' \
        "$FAKE_ROOT/.rddf/state/iteration.json"
    [ "$output" != "null" ] && [ -n "$output" ]
    run jq -r '.changes[] | select(.name=="e2e-fixture") | .tasks_done' \
        "$FAKE_ROOT/.rddf/state/iteration.json"
    # tasks_done >= 1 (real archive_gate_check only requires ≥1 [x] task complete)
    [ "$output" -ge 1 ]

    # No active change (real openspec CLI moves it)
    [ ! -d "$FAKE_ROOT/openspec/changes/e2e-fixture" ]
}

# ── Error Paths (3 cases — all REAL gate failures) ─────────────────────

@test "full-workflow 5/7: arch gate blocks on missing ADR (real check_arch_done_gate)" {
    # INTENTIONALLY skip write_arch_fixture — no ADR

    run invoke_arch_gate "$FAKE_ROOT"
    [ "$status" -ne 0 ]
    # Real stderr from arch_done_gate.sh:47
    [[ "$output" == *"至少需要 1 个 ADR"* ]] || [[ "$stderr" == *"至少需要 1 个 ADR"* ]]
    [ ! -f "$FAKE_ROOT/.rddf/state/.arch-handoff.json" ]
}

@test "full-workflow 6/7: archive gate blocks on 0 completed tasks (real archive_gate_check)" {
    write_arch_fixture "$FAKE_ROOT"
    write_proposal_fixture "$FAKE_ROOT" "e2e-fixture"

    # All tasks unchecked → 0 [x] → real gate blocks
    run invoke_archive_gate "$FAKE_ROOT" "e2e-fixture"
    [ "$status" -ne 0 ]
    # Real stderr from _lib/archive.sh:393
    [[ "$output" == *"0 个完成任务"* ]] || [[ "$stderr" == *"0 个完成任务"* ]]
    [ -d "$FAKE_ROOT/openspec/changes/e2e-fixture" ]
}

@test "full-workflow 7/7: archive gate blocks on missing tasks.md (real archive_gate_check)" {
    write_arch_fixture "$FAKE_ROOT"
    mkdir -p "$FAKE_ROOT/openspec/changes/e2e-fixture"
    # INTENTIONALLY no tasks.md written

    run invoke_archive_gate "$FAKE_ROOT" "e2e-fixture"
    [ "$status" -ne 0 ]
    # Real stderr from _lib/archive.sh:384
    [[ "$output" == *"tasks.md 缺失"* ]] || [[ "$stderr" == *"tasks.md 缺失"* ]]
    [ -d "$FAKE_ROOT/openspec/changes/e2e-fixture" ]
}