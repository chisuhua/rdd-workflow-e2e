#!/usr/bin/env bats
# tests/integration/test_guide_polling_loop_e2e.bats
#
# Cross-process E2E for add-guide-polling-loop-implementation (v4.1).
# Validates the closed polling loop: Window A (guide) reads events written
# by Window B (rdd-arch/planner/builder/verifier/quick) via events.jsonl,
# advances goal.last_seen_offset monotonically, and re-reads from offset 0
# after archive_events resets it.
#
# AC-G1: guide in window A sees window B's events + offset advances to N
# AC-G2: multiple guide_entry calls advance offset monotonically (2→4→6)
# AC-G3: after archive_events, last_seen_offset resets to 0 and guide re-reads full
#
# Self-contained: uses existing setup_fake_project_cross fixture (isolates to
# $BATS_TEST_TMPDIR, never touches $REPO_ROOT/.rddf/state/). Real subprocesses
# only — no in-process mocks (same discipline as test_stage_guide_cross_process_e2e.bats).

load ../test_helper
load_lib test_full_workflow_fixture
load_lib test_stage_guide_cross_process_fixture

setup() {
    FAKE_ROOT=$(setup_fake_project_cross)
    export FAKE_ROOT
    # Symlink rdd-workflow skills into the fake root so guide_entry + hooks
    # resolve (guide_entry sources $SKILL_DIR/../rddf-session/scripts/...).
    mkdir -p "$FAKE_ROOT/skills"
    ln -sfn "$RDD_WORKFLOW_REPO/skills/rddf-session" "$FAKE_ROOT/skills/rddf-session"
    ln -sfn "$RDD_WORKFLOW_REPO/skills/guide" "$FAKE_ROOT/skills/guide"
}

teardown() {
    local old_fake_root="$FAKE_ROOT"
    for pidfile in "$FAKE_ROOT"/.rddf/state/*.pid; do
        [[ -f "$pidfile" ]] || continue
        local pid
        pid=$(cat "$pidfile" 2>/dev/null)
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    unset FAKE_ROOT
    cd "$REPO_ROOT"
    [[ -n "$old_fake_root" ]] && [[ -d "$old_fake_root" ]] && rm -rf "$old_fake_root"
}

# Write N events as window B (owner=OWNER_B) into the fake root's events.jsonl.
write_window_b_events() {
    local n="$1"
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import EventsLog
log = EventsLog(os.path.join('$FAKE_ROOT', '.rddf/state/events.jsonl'))
for i in range($n):
    log.append_event(
        event_type='phase_started', severity='info',
        message=f'window-B-event-{i}',
        session_id=f'rds_{i}', kind='stage_arch',
        parent_session_id=None, owner_opencode_session_id='OWNER_B',
    )
print(f'wrote:$n', flush=True)
"
}

# Create an active stage_guide session owned by $1 (window A's long-lived observer).
create_stage_guide_session() {
    local owner="$1"
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.rddf_session import RddfSessionCoordinator
coord = RddfSessionCoordinator(sessions_file=os.path.join('$FAKE_ROOT', '.rddf/state/sessions.json'))
sid = coord.create_session(
    kind='stage_guide', owner_opencode_session_id='$owner',
    goal={'intent': 'guide-orchestrator', 'last_seen_offset': 0},
)
print(f'created:{sid}', flush=True)
"
}

# Run the real rddf_session_hook_poll_events (window A's poll step).
run_poll_events() {
    local owner="$1"
    PROJECT_ROOT="$FAKE_ROOT" OPENCODE_SESSION_ID="$owner" \
    bash -c "
        source '$RDD_WORKFLOW_REPO/skills/rddf-session/scripts/rddf_session_hooks.sh'
        rddf_session_hook_poll_events
    "
}

# ── AC-G1: guide sees window B's events ────────────────────────────────

@test "AC-G1: guide_entry in window A reads events.jsonl from window B's writes" {
    create_stage_guide_session "OWNER_A"
    write_window_b_events 3

    local output
    output=$(run_poll_events "OWNER_A")

    echo "$output" | grep -q "📊 Child Sessions:" || {
        echo "expected '📊 Child Sessions:' marker, got: $output"
        return 1
    }
    echo "$output" | grep -q "window-B-event-0" || {
        echo "expected window-B-event-0 in output, got: $output"
        return 1
    }
    echo "$output" | grep -q "window-B-event-2" || {
        echo "expected window-B-event-2 in output, got: $output"
        return 1
    }

    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 3
}

# ── AC-G2: last_seen_offset 单调推进 ───────────────────────────────────

@test "AC-G2: multiple guide_entry calls advance offset monotonically" {
    create_stage_guide_session "OWNER_A"

    write_window_b_events 2
    run_poll_events "OWNER_A" >/dev/null
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 2

    write_window_b_events 2
    run_poll_events "OWNER_A" >/dev/null
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 4

    write_window_b_events 2
    run_poll_events "OWNER_A" >/dev/null
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 6
}

# ── AC-G3: archive 后 last_seen_offset 重置 ────────────────────────────

@test "AC-G3: after archive_events, guide re-reads from offset 0" {
    create_stage_guide_session "OWNER_A"
    write_window_b_events 30

    # Advance offset to 30 via one poll
    run_poll_events "OWNER_A" >/dev/null
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 30

    # Trigger archive keep=10 → moves 20 oldest rows, resets offset to 0
    trigger_archive "$FAKE_ROOT/.rddf/state/events.jsonl" \
                    "$FAKE_ROOT/.rddf/state/sessions.json" 1

    # Post-archive: only 10 events remain, offset reset to 0
    local remaining
    remaining=$(count_events "$FAKE_ROOT/.rddf/state/events.jsonl")
    [[ "$remaining" -eq 10 ]] || {
        echo "expected 10 events after archive, got $remaining"
        return 1
    }
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 0

    # Re-poll: guide re-reads all 10 fresh events and advances to 10
    local output
    output=$(run_poll_events "OWNER_A")
    echo "$output" | grep -q "window-B-event-20" || {
        echo "expected re-read of window-B-event-20, got: $output"
        return 1
    }
    assert_last_seen_offset "$FAKE_ROOT/.rddf/state/sessions.json" "OWNER_A" 10
}
