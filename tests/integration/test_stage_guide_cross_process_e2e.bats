#!/usr/bin/env bats
# tests/integration/test_stage_guide_cross_process_e2e.bats
#
# Cross-process end-to-end tests for feat-guide-orchestrator-session-event-bus.
# Validates the core architecture promise: multiple OpenCode windows observing
# each other via file polling on .rddf/state/events.jsonl.
#
# Each case spawns REAL Python child processes (NOT in-process mocks) so that
# fcntl.flock contention, last_seen_offset arithmetic, and hook entry/close
# lifecycle can be observed at the file-system level.
#
# Per feat-guide-orchestrator-session-event-bus review 2026-09-23: 6 cases
# addressing the "core architecture promise has 0 e2e coverage" gap.
#
# Self-contained: helper fixture at tests/_lib/test_stage_guide_cross_process_fixture.bash
# isolates to $BATS_TEST_TMPDIR (never touches $REPO_ROOT/.rddf/state/).

load ../test_helper
load_lib test_full_workflow_fixture
load_lib test_stage_guide_cross_process_fixture

setup() {
    FAKE_ROOT=$(setup_fake_project_cross)
    export FAKE_ROOT
}

teardown() {
    local old_fake_root="$FAKE_ROOT"

    # Kill any lingering child processes (defensive cleanup)
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

# ── AC-1: fcntl.flock 并发写 ──────────────────────────────────────────

@test "AC-1: two processes concurrently append_event — no row loss or duplication" {
    local pidfile_a="$FAKE_ROOT/.rddf/state/writer_a.pid"
    local pidfile_b="$FAKE_ROOT/.rddf/state/writer_b.pid"
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"

    # Spawn 2 writers, 50 events each, no rate limit (max contention)
    spawn_event_writer "OWNER_A" 50 0 "$pidfile_a" "$FAKE_ROOT"
    spawn_event_writer "OWNER_B" 50 0 "$pidfile_b" "$FAKE_ROOT"

    # Wait for both to finish
    wait $(cat "$pidfile_a") 2>/dev/null || true
    wait $(cat "$pidfile_b") 2>/dev/null || true
    wait_for_child "$(cat "$pidfile_a")" 15
    wait_for_child "$(cat "$pidfile_b")" 15

    # Total events should be exactly 100 (50 + 50)
    local total
    total=$(count_events "$events_file")
    [[ "$total" -eq 100 ]] || { echo "expected 100 events, got $total"; return 1; }

    # All event_ids must be unique (no duplication from race)
    local unique_count
    unique_count=$(collect_event_ids "$events_file" | wc -l)
    [[ "$unique_count" -eq 100 ]] || {
        echo "expected 100 unique event_ids, got $unique_count"
        return 1
    }
}

# ── AC-2: last_seen_offset 轮询时序 ───────────────────────────────────

@test "AC-2: poll read_since(offset) monotonically advances as events are written" {
    local pidfile="$FAKE_ROOT/.rddf/state/writer.pid"
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"

    # Writer A produces 20 events over 2 seconds (~10 Hz)
    spawn_event_writer "OWNER_A" 20 10 "$pidfile" "$FAKE_ROOT"

    # Poll events.jsonl 5 times during write window; track offset progression
    local snapshots=()
    for i in 1 2 3 4 5; do
        sleep 0.4
        local offset_so_far
        offset_so_far=$(count_events "$events_file")
        snapshots+=("$offset_so_far")
    done

    wait $(cat "$pidfile") 2>/dev/null || true
    wait_for_child "$(cat "$pidfile")" 15

    # Verify monotonic progression: each snapshot >= previous
    local prev=0
    for snap in "${snapshots[@]}"; do
        [[ "$snap" -ge "$prev" ]] || {
            echo "non-monotonic: $prev → $snap"
            return 1
        }
        prev=$snap
    done

    # Final count after writer completes should be 20
    local final
    final=$(count_events "$events_file")
    [[ "$final" -eq 20 ]] || { echo "expected 20 final events, got $final"; return 1; }
}

# ── AC-3: crash 残留恢复 ──────────────────────────────────────────────

@test "AC-3: kill -9 child leaves session active + events intact for recovery" {
    local pidfile="$FAKE_ROOT/.rddf/state/guide.pid"
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"

    # Child A creates stage_guide + writes 5 events then idles
    spawn_stage_guide_session "OWNER_CRASH" "$pidfile" "$FAKE_ROOT"
    sleep 1  # let it create session

    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import EventsLog
log = EventsLog(os.path.join('$FAKE_ROOT', '.rddf/state/events.jsonl'))
for i in range(5):
    log.append_event(
        event_type='test', severity='info', message=f'pre-crash-{i}',
        session_id=f'rds_{i}', kind='stage_arch',
        parent_session_id=None, owner_opencode_session_id='OWNER_CRASH',
    )
"

    # Verify pre-crash state: 5 events exist
    local pre_count
    pre_count=$(count_events "$events_file")
    [[ "$pre_count" -eq 5 ]] || { echo "expected 5 pre-crash events, got $pre_count"; return 1; }

    # kill -9 the child (simulating OpenCode crash)
    local child_pid
    child_pid=$(cat "$pidfile")
    kill -9 "$child_pid" 2>/dev/null || true
    sleep 1

    # Recovery read: B reads sessions.json + events.jsonl
    local active_count
    active_count=$(count_active_stage_guide_sessions "$sessions_file")
    [[ "$active_count" -eq 1 ]] || {
        echo "expected 1 active stage_guide after crash, got $active_count"
        return 1
    }

    local post_count
    post_count=$(count_events "$events_file")
    [[ "$post_count" -eq 5 ]] || {
        echo "expected 5 events after crash (intact), got $post_count"
        return 1
    }
}

# ── AC-4: H7 全局 stage_guide 单例 ───────────────────────────────────

@test "AC-4: second create_session(stage_guide) raises ConflictError (H7 singleton)" {
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"

    # First owner creates successfully
    local first_output
    first_output=$(spawn_stage_guide_with_exit "OWNER_A" "$FAKE_ROOT")
    [[ "$first_output" == ok:* ]] || {
        echo "first create failed unexpectedly: $first_output"
        return 1
    }

    # Second owner (different PID / owner_opencode_session_id) collides
    local second_output
    second_output=$(spawn_stage_guide_with_exit "OWNER_B" "$FAKE_ROOT" || true)
    [[ "$second_output" == conflict:* ]] || {
        echo "second create should have raised ConflictError, got: $second_output"
        return 1
    }

    # Verify only 1 active stage_guide session exists
    local active_count
    active_count=$(count_active_stage_guide_sessions "$sessions_file")
    [[ "$active_count" -eq 1 ]] || {
        echo "expected 1 active stage_guide (H7 singleton), got $active_count"
        return 1
    }
}

# ── AC-5: 自动归档触发 last_seen_offset 重置 ──────────────────────────

@test "AC-5: after archive_events, active stage_guide last_seen_offset reset to 0" {
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"

    # Create stage_guide with last_seen_offset=50 (simulate prior polling progress)
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys, json
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.rddf_session import RddfSessionCoordinator
coord = RddfSessionCoordinator(sessions_file=os.path.join('$FAKE_ROOT', '.rddf/state/sessions.json'))
sid = coord.create_session(
    kind='stage_guide', owner_opencode_session_id='OWNER_ARCHIVE',
    goal={'intent': 'guide-orchestrator', 'last_seen_offset': 50},
)
print(f'created:{sid}', flush=True)
"

    # Write 30 events to events.jsonl
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import EventsLog
log = EventsLog(os.path.join('$FAKE_ROOT', '.rddf/state/events.jsonl'))
for i in range(30):
    log.append_event(
        event_type='test', severity='info', message=f'pre-archive-{i}',
        session_id=f'rds_{i}', kind='stage_arch',
        parent_session_id=None, owner_opencode_session_id='OWNER_ARCHIVE',
    )
"

    # Pre-archive assertion: last_seen_offset=50
    assert_last_seen_offset "$sessions_file" "OWNER_ARCHIVE" 50

    # Trigger archive with keep=10 (forces archiving 20 oldest rows)
    trigger_archive "$events_file" "$sessions_file" 1

    # Post-archive assertion: last_seen_offset reset to 0
    assert_last_seen_offset "$sessions_file" "OWNER_ARCHIVE" 0
}

# ── AC-6: guide_entry 持久化 ──────────────────────────────────────────

@test "AC-6a: guide_entry in subshell + SIGTERM → stage_guide marked completed" {
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local guide_entry="$RDD_WORKFLOW_REPO/skills/guide/scripts/guide_entry.sh"

    # Source + call guide_entry in subshell. cd to FAKE_ROOT so guide_entry.sh's
    # `git rev-parse --show-toplevel` returns FAKE_ROOT (avoiding write to testbed).
    (
        set -e
        cd "$FAKE_ROOT"
        export RDDF_GUIDE_SESSION_ENABLED=yes
        source "$guide_entry"
        guide_entry --no-binding
        sleep 30
    ) &
    local sub_pid=$!

    sleep 3  # let guide_entry create stage_guide session

    # Verify session was created (active)
    local active_count
    active_count=$(count_active_stage_guide_sessions "$sessions_file")
    [[ "$active_count" -eq 1 ]] || {
        echo "expected 1 active stage_guide during subshell, got $active_count"
        kill -9 $sub_pid 2>/dev/null
        return 1
    }

    # Send SIGTERM (traps EXIT/INT/TERM → calls guide_close)
    kill -TERM $sub_pid 2>/dev/null || true
    wait $sub_pid 2>/dev/null || true

    # Session should now be completed (or marked terminal)
    local completed_count
    completed_count=$(python3 -c "
import json
d = json.load(open('$sessions_file'))
print(sum(1 for s in d.get('sessions', []) if s.get('kind')=='stage_guide' and s.get('state') in ('completed','failed','abandoned')))
")
    [[ "$completed_count" -ge 1 ]] || {
        echo "expected guide_close to mark session completed, got $completed_count terminal sessions"
        return 1
    }
}

@test "AC-6b: guide_entry in subshell + SIGKILL → stage_guide remains active" {
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local guide_entry="$RDD_WORKFLOW_REPO/skills/guide/scripts/guide_entry.sh"

    # Source + call guide_entry in subshell. cd to FAKE_ROOT for git rev-parse.
    (
        set -e
        cd "$FAKE_ROOT"
        export RDDF_GUIDE_SESSION_ENABLED=yes
        source "$guide_entry"
        guide_entry --no-binding
        sleep 30
    ) &
    local sub_pid=$!

    sleep 3  # let guide_entry create stage_guide session

    # SIGKILL (no trap can intercept)
    kill -9 $sub_pid 2>/dev/null || true
    wait $sub_pid 2>/dev/null || true

    # Session should STILL be active (crash leaves no chance for close)
    local active_count
    active_count=$(count_active_stage_guide_sessions "$sessions_file")
    [[ "$active_count" -eq 1 ]] || {
        echo "expected 1 active stage_guide after SIGKILL (crash), got $active_count"
        return 1
    }
}
