#!/usr/bin/env bash
# tests/_lib/test_full_workflow_fixture.bash
#
# Helper functions for test_full_workflow_e2e.bats.
# Sourced via load_lib test_full_workflow_fixture.
#
# v2 (real path): each invoke_* function calls REAL production code:
#   invoke_arch_stage    → skills/rdd-arch/scripts/write_arch_handoff_env
#                           (python3 -m, 12 DISCOVERED_* env vars, Oracle C1 safe)
#   invoke_arch_gate     → skills/rdd-arch/scripts/arch_done_gate.sh::check_arch_done_gate
#                           (real bash function, gates on ADR count + roadmap)
#   invoke_planner_stage → python3 -m _lib.planner_handoff
#                           (PROJECT_ROOT + PROPOSALS_* + FEATURES_ACTIVE + CURRENT_SPRINT)
#   invoke_builder_phases→ test_full_workflow_e2e_runner.sh (env-py shim for
#                           _lib.builder_handoff.write_builder_handoff)
#   invoke_archive_gate  → _lib/archive.sh::archive_gate_check (real function)
#                           gates on tasks.md ≥1 [x] (SKIP_VERIFIER_CONTRACT +
#                           SKIP_AC_VERIFICATION bypass non-task sub-gates)
#   invoke_archive_happy → openspec archive <name> --yes + mark_iteration_archived
#                           (real CLI + real Python via skills._lib.iteration)
#   assert_state         → jq field assertions on .rddf/state/*.json
#   assert_schema        → jsonschema.validate against _lib/schemas/*.json
#                           (defense-in-depth contract lock)
#
# Oracle C1 safety: all Python invocations use env-var passing; NEVER bash
# string interpolation into `python3 -c "...$VAR..."`. Python source
# uses only static content (heredocs) + env-var reading.

# Resolve REPO_ROOT once (set by test_helper.bash via load_lib)
: "${RDD_WORKFLOW_REPO:?RDD_WORKFLOW_REPO not set — load test_helper first}"

# ─── Fake project setup ─────────────────────────────────────────────────

# Setup: create fake project under $BATS_TEST_TMPDIR (or /tmp fallback)
# Returns: absolute path to fake project root via stdout
setup_fake_project() {
    local root
    root="${BATS_TEST_TMPDIR:-/tmp}/fake-project-$$-${RANDOM}"
    mkdir -p "$root"
    cd "$root" || return 1
    git init -q
    git config user.email "e2e@test.local"
    git config user.name "E2E Test"
    echo "fake project" > README.md
    echo '{"name":"fake-project","version":"0.0.1"}' > package.json
    git add README.md package.json
    git commit -q -m "init fake project"
    echo "$root"
}

# Write arch-stage fixture: 1 ADR + minimal roadmap
# Args: $1 = fake project root
write_arch_fixture() {
    local root="$1"
    mkdir -p "$root/docs/adr"
    cat > "$root/docs/adr/ADR-0001-test-arch.md" <<'EOF'
# ADR-0001: Test Architecture

**Status**: 已采纳 (2026-01-01)

## Context
E2E fixture for full-workflow E2E test.
EOF
    cat > "$root/roadmap.md" <<'EOF'
# Roadmap

**当前阶段**: phase-1

## Phase Skeleton
| Phase | Theme | Status |
|-------|-------|--------|
| phase-1 | e2e-fixture | active |
EOF
    git -C "$root" add docs/adr/ADR-0001-test-arch.md roadmap.md
    git -C "$root" commit -q -m "add arch fixture"
}

# Write proposal-stage fixture: skeleton proposal.md + tasks.md + design.md
# Args: $1 = fake project root, $2 = change name
write_proposal_fixture() {
    local root="$1" name="$2"
    mkdir -p "$root/openspec/changes/$name"
    cat > "$root/openspec/changes/$name/proposal.md" <<EOF
# $name Proposal

## Why
E2E fixture proposal.
EOF
    cat > "$root/openspec/changes/$name/tasks.md" <<EOF
# $name Tasks

- [ ] 1. Implement fixture
- [ ] 2. Run E2E test
EOF
    cat > "$root/openspec/changes/$name/design.md" <<EOF
# $name Design

## Approach
Direct implementation.
EOF
    git -C "$root" add "openspec/changes/$name"
    git -C "$root" commit -q -m "add $name change fixture"
}

# ─── Real stage invocation ──────────────────────────────────────────────

# Invoke rdd-arch stage: writes .arch-handoff.json via REAL write_arch_handoff
# Calls: python3 -m skills.rdd_arch.scripts.write_arch_handoff_env
# Args: $1 = fake project root
invoke_arch_stage() {
    local root="$1"
    cd "$root" || return 1

    # Real writer requires PROJECT_ROOT + DISCOVERED_* env vars (12 total)
    # Side-effect env vars disable reflect + planner feedback hooks
    PROJECT_ROOT="$root" \
    SKIP_WORKFLOW_REFLECTION=1 \
    SKIP_AUTO_PLANNER_FEEDBACK=1 \
    DISCOVERED_ADR_DIR=docs/adr \
    DISCOVERED_ADR_PATTERN='ADR-*.md' \
    DISCOVERED_ADR_DIR_FOUND=true \
    DISCOVERED_ROADMAP_FOUND=true \
    DISCOVERED_ARCH_FOUND=false \
    DISCOVERED_ADR_DIR_TRIED=3 \
    DISCOVERED_ROADMAP_TRIED=2 \
    DISCOVERED_ARCH_TRIED=3 \
    DISCOVERED_ROADMAP_PATH=roadmap.md \
    DISCOVERED_ARCHITECTURE_DIR=docs/architecture \
    ROADMAP_EXISTS_BOOL=true \
        python3 -m skills.rdd_arch.scripts.write_arch_handoff_env
}

# Invoke rdd-arch gate: real check_arch_done_gate (error path test)
# Sources skills/rdd-arch/scripts/arch_done_gate.sh, calls check_arch_done_gate
# Args: $1 = fake project root
invoke_arch_gate() {
    local root="$1"
    cd "$root" || return 1

    # Source the real arch gate function (Oracle C1 safe: pure bash, no Python)
    # shellcheck source=/dev/null
    source "$RDD_WORKFLOW_REPO/skills/rdd-arch/scripts/arch_done_gate.sh"

    # Real gate reads DISCOVERED_* env vars (set to point at fake project)
    PROJECT_ROOT="$root" \
    DISCOVERED_ADR_DIR=docs/adr \
    DISCOVERED_ADR_PATTERN='ADR-*.md' \
    DISCOVERED_ROADMAP_PATH=roadmap.md \
    check_arch_done_gate
}

# Invoke rdd-planner stage: writes .planner-handoff.json via REAL python module
# Calls: python3 -m _lib.planner_handoff
# Args: $1 = fake project root
invoke_planner_stage() {
    local root="$1"
    cd "$root" || return 1

    # Real writer reads PROJECT_ROOT + 4 env vars (per _lib/planner_handoff.py:48-57)
    PROJECT_ROOT="$root" \
    PROPOSALS_AUTHORED="add-e2e-fixture" \
    PROPOSALS_APPROVED_COUNT=1 \
    FEATURES_ACTIVE="feat-e2e-fixture" \
    CURRENT_SPRINT="sprint-2026-09" \
        python3 -m _lib.planner_handoff
}

# Invoke rdd-builder handoff: writes .rddf/state/builder/<change>.json via env-py shim
# Calls: test_full_workflow_e2e_runner.sh → .env.py → _lib.builder_handoff.write_builder_handoff
# Args: $1 = fake project root, $2 = change name
invoke_builder_phases() {
    local root="$1" name="$2"
    cd "$root" || return 1

    # Real writer via env-py shim (Oracle C1 safe)
    PROJECT_ROOT="$RDD_WORKFLOW_REPO" \
    E2E_PROJECT_ROOT="$root" \
    E2E_CHANGE_NAME="$name" \
    E2E_BUILDER_PHASE=phase-2 \
    E2E_BUILDER_APPROVAL_STATUS=approved \
    E2E_BUILDER_EXECUTION_MODE=lightweight \
    E2E_BUILDER_EXECUTION_STATUS=completed \
    E2E_BUILDER_REVIEW_STATUS=merge \
    E2E_BUILDER_ARCHIVE_STATUS=pending \
        bash "$REPO_ROOT/tests/_lib/test_full_workflow_e2e_runner.sh"

    # Touch commit per AGENTS.md "Worktree Commit Flow" (lightweight mode:
    # changes are made on main repo, not in worktree)
    echo "# E2E touch $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$root/openspec/changes/$name/touch.log"
    git -C "$root" add "openspec/changes/$name/touch.log"
    git -C "$root" commit -q -m "e2e: touch commit for lightweight mode"
}

# Invoke archive gate (real function from _lib/archive.sh)
# Used for ERROR PATH tests only — checks tasks.md completeness
# Calls: source _lib/archive.sh; archive_gate_check <name> <root>
# Args: $1 = fake project root, $2 = change name
invoke_archive_gate() {
    local root="$1" name="$2"
    cd "$root" || return 1

    # Source the real archive.sh (provides archive_gate_check function)
    # shellcheck source=/dev/null
    source "$RDD_WORKFLOW_REPO/_lib/archive.sh" 2>/dev/null || {
        echo "❌ cannot source _lib/archive.sh" >&2
        return 1
    }

    # Real gate: bypass non-task sub-gates (verifier + ac-verifier are Phase 2)
    SKIP_VERIFIER_CONTRACT=yes \
    SKIP_AC_VERIFICATION=yes \
    FORCE_ARCHIVE_INCOMPLETE=no \
        archive_gate_check "$name" "$root"
}

# Invoke full archive happy path: real openspec CLI + real mark_iteration_archived
# Calls: openspec archive + skills._lib.iteration.post_archive.mark_iteration_archived
# Args: $1 = fake project root, $2 = change name
invoke_archive_happy() {
    local root="$1" name="$2"
    cd "$root" || return 1

    # Real archive CLI
    openspec archive "$name" --yes 2>&1 || {
        echo "❌ openspec archive failed" >&2
        return 1
    }

    # Auto-commit the archive file moves (mirrors _lib/archive.sh::commit_archive_moves)
    git -C "$root" add "openspec/changes/" 2>/dev/null || true
    git -C "$root" commit -q -m "archive($name): archive completed" 2>/dev/null || true

    # Real sync_iteration_after_archive via skills._lib.iteration
    # (Oracle C1 safe: env-var passing, inline heredoc has no bash $VAR inside)
    local archive_sha
    archive_sha=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)

    PROJECT_ROOT="$root" \
    CHANGE_NAME="$name" \
    ARCHIVE_COMMIT_SHA="$archive_sha" \
        python3 <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", "."))
try:
    from skills._lib.iteration.post_archive import sync_iteration_after_archive
    sync_iteration_after_archive(
        project_root=os.environ["PROJECT_ROOT"],
        change_name=os.environ["CHANGE_NAME"],
        archive_commit_sha=os.environ.get("ARCHIVE_COMMIT_SHA", "") or None,
    )
    print("✅ sync_iteration_after_archive complete")
except Exception as e:
    print(f"❌ sync_iteration_after_archive failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ─── State assertions ───────────────────────────────────────────────────

# Assert state file has expected schema fields
# Args: $1 = fake project root, $2 = state file (relative to .rddf/state/),
#       $3 = pipe-separated "key:val|key:val"
assert_state() {
    local root="$1" file="$2" fields="$3"
    local state_file="$root/.rddf/state/$file"
    [ -f "$state_file" ] || { echo "❌ assert_state: file missing: $state_file" >&2; return 1; }

    local IFS='|'
    local pair key expected actual
    for pair in $fields; do
        key="${pair%%:*}"
        expected="${pair#*:}"
        actual=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null)
        if [ "$actual" != "$expected" ]; then
            echo "❌ assert_state: $key expected '$expected' got '$actual'" >&2
            return 1
        fi
    done
}

# Validate state file against its real schema (jsonschema defense-in-depth)
# Args: $1 = fake project root, $2 = state file (relative to .rddf/state/),
#       $3 = (optional) schema filename under _lib/schemas/ (auto-derived if omitted)
assert_schema() {
    local root="$1" file="$2" schema="${3:-}"
    local state_file="$root/.rddf/state/$file"

    # Auto-derive schema filename if not provided
    case "$file" in
        .arch-handoff.json)     schema="${schema:-arch_handoff_schema.json}" ;;
        .planner-handoff.json)  schema="${schema:-planner_handoff_schema.json}" ;;
        builder/*.json)         schema="${schema:-builder_handoff_schema.json}" ;;
        iteration.json)         schema="${schema:-iteration_schema.json}" ;;
        *)
            echo "❌ assert_schema: unknown file $file" >&2
            return 1
            ;;
    esac

    local schema_file="$RDD_WORKFLOW_REPO/_lib/schemas/$schema"
    [ -f "$schema_file" ] || { echo "❌ schema missing: $schema_file" >&2; return 1; }
    [ -f "$state_file" ] || { echo "❌ state file missing: $state_file" >&2; return 1; }

    # Run jsonschema.validate via inline Python (Oracle C1 safe — env-var passing)
    REPO_ROOT="$RDD_WORKFLOW_REPO" \
    E2E_STATE_FILE="$state_file" \
    E2E_SCHEMA_FILE="$schema_file" \
        python3 <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", "."))
try:
    import jsonschema
except ImportError:
    print("⚠️ jsonschema not installed; skipping contract check", file=sys.stderr)
    sys.exit(0)
with open(os.environ["E2E_STATE_FILE"]) as f:
    payload = json.load(f)
with open(os.environ["E2E_SCHEMA_FILE"]) as f:
    schema = json.load(f)
try:
    jsonschema.validate(payload, schema)
    print("✅ schema validate OK")
except jsonschema.ValidationError as e:
    print(f"❌ schema validate FAIL: {e.message}", file=sys.stderr)
    sys.exit(1)
PYEOF
}