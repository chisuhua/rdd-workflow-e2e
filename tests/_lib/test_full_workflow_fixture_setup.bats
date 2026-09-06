#!/usr/bin/env bats
# tests/_lib/test_full_workflow_fixture_setup.bats
# Verify setup_fake_project + write_arch_fixture behavior.

load ../test_helper
load_lib test_full_workflow_fixture

@test "setup_fake_project: returns git-initialized directory with package.json" {
    FAKE_ROOT=$(setup_fake_project)
    [ -d "$FAKE_ROOT" ]
    [ -d "$FAKE_ROOT/.git" ]
    [ -f "$FAKE_ROOT/package.json" ]
    [ -f "$FAKE_ROOT/README.md" ]
    rm -rf "$FAKE_ROOT"
}

@test "write_arch_fixture: creates docs/adr/ADR-0001 + roadmap.md" {
    FAKE_ROOT=$(setup_fake_project)
    write_arch_fixture "$FAKE_ROOT"
    [ -f "$FAKE_ROOT/docs/adr/ADR-0001-test-arch.md" ]
    [ -f "$FAKE_ROOT/roadmap.md" ]
    grep -q "phase-1" "$FAKE_ROOT/roadmap.md"
    rm -rf "$FAKE_ROOT"
}
