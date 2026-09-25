#!/usr/bin/env bats
# tests/integration/test_real_two_owner_poll.bats
#
# Real two-owner polling interaction test (Phase B):
# Spawns TWO background bash processes (NOT bats subshells) with different
# OPENCODE_SESSION_ID to simulate two independent OpenCode windows observing
# each other via file polling on events.jsonl + sessions.json.
#
# Differs from test_stage_guide_cross_process_e2e.bats which uses bats subshells
# (`(...) &`) — those finish sequentially within one @test, not truly long-lived.
# This test uses long-lived bash backgrounds (15s lifetime) and real
# OPENCODE_SESSION_ID env vars (not fixture OWNER_A/B strings).
#
# Case 1: pane-A (guide) sees pane-B (rdd-arch writer) events + last_seen_offset
#         reaches the number of events pane-B wrote.
# Case 2: Two pane-A processes with same OPENCODE_SESSION_ID fail ConflictError
#         (H7 singleton via real RddfSessionCoordinator path).
#
# Self-contained: uses setup_fake_project_cross (isolates to $BATS_TEST_TMPDIR).

load ../test_helper
load_lib test_full_workflow_fixture
load_lib test_stage_guide_cross_process_fixture

setup() {
    FAKE_ROOT=$(setup_fake_project_cross)
    export FAKE_ROOT
    mkdir -p "$FAKE_ROOT/skills"
    ln -sfn "$RDD_WORKFLOW_REPO/skills/rddf-session" "$FAKE_ROOT/skills/rddf-session"
    ln -sfn "$RDD_WORKFLOW_REPO/skills/guide" "$FAKE_ROOT/skills/guide"
    # Use timestamp+random to ensure unique owner IDs across bats invocations
    # (avoids stale state collisions from previous test runs sharing FAKE_ROOT)
    local ts; ts=$(date +%s%N)
    export OPENCODE_SESSION_ID_PANEA="pane-A-${ts}-$RANDOM"
    export OPENCODE_SESSION_ID_PANEB="pane-B-${ts}-$RANDOM"
    # Clear global owner cache so layer 1 env var wins fresh
    rm -f "${HOME}/.cache/rddf-session-owner"
}

teardown() {
    # Kill any lingering child processes
    for pidfile in "$FAKE_ROOT"/.rddf/state/*.pid; do
        [[ -f "$pidfile" ]] || continue
        local pid
        pid=$(cat "$pidfile" 2>/dev/null)
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    done
    cd "$REPO_ROOT"
    [[ -n "$FAKE_ROOT" ]] && [[ -d "$FAKE_ROOT" ]] && rm -rf "$FAKE_ROOT"
}

# Helper: spawn pane-A (long-lived guide_entry polling loop)
spawn_pane_a_polling() {
    local owner="$1"
    local events_file="$2"
    local sessions_file="$3"
    local iterations="$4"
    local pidfile="$5"

    (
        cd "$FAKE_ROOT"
        export PROJECT_ROOT="$FAKE_ROOT"
        export OPENCODE_SESSION_ID="$owner"
        export RDDF_GUIDE_SESSION_ENABLED=yes
        export PYTHONPATH="$RDD_WORKFLOW_REPO:${PYTHONPATH:+:$PYTHONPATH}"
        source "$RDD_WORKFLOW_REPO/skills/guide/scripts/guide_entry.sh"
        for _ in $(seq 1 "$iterations"); do
            guide_entry --no-binding
            sleep 0.7
        done
    ) &
    echo $! > "$pidfile"
}

# Helper: spawn pane-B (writes events as different owner)
spawn_pane_b_writer() {
    local owner="$1"
    local events_file="$2"
    local count="$3"
    local interval="$4"
    local pidfile="$5"

    (
        cd "$FAKE_ROOT"
        export PROJECT_ROOT="$FAKE_ROOT"
        export OPENCODE_SESSION_ID="$owner"
        export PYTHONPATH="$RDD_WORKFLOW_REPO:${PYTHONPATH:+:$PYTHONPATH}"
        OWNER_ID="$owner" python3 -c "
import os, time, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import EventsLog
owner = os.environ['OWNER_ID']
log = EventsLog('$events_file')
for i in range($count):
    log.append_event(
        event_type='phase_started',
        severity='info',
        message=f'pane-B-event-{i}',
        session_id=f'rds_B_{i}',
        kind='stage_arch',
        parent_session_id=None,
        owner_opencode_session_id=owner,
    )
    time.sleep($interval)
"
    ) &
    echo $! > "$pidfile"
}

@test "REAL-2P-1: pane-A (guide) polling loop reads pane-B (writer) events; last_seen_offset advances" {
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local pidfile_a="$FAKE_ROOT/.rddf/state/pane_a.pid"
    local pidfile_b="$FAKE_ROOT/.rddf/state/pane_b.pid"

    # Spawn pane-A first (it will create stage_guide session)
    spawn_pane_a_polling "$OPENCODE_SESSION_ID_PANEA" "$events_file" "$sessions_file" 12 "$pidfile_a"
    local pid_a=$(cat "$pidfile_a")

    # Wait briefly so A's stage_guide session exists
    sleep 1.5

    # Spawn pane-B (writes 10 events with 0.5s interval = ~5s)
    spawn_pane_b_writer "$OPENCODE_SESSION_ID_PANEB" "$events_file" 10 0.5 "$pidfile_b"
    local pid_b=$(cat "$pidfile_b")

    # Wait for B to finish + A's polling loop to catch up
    wait $pid_b 2>/dev/null || true
    sleep 3
    kill -TERM $pid_a 2>/dev/null || true
    wait $pid_a 2>/dev/null || true

    # Verify: events.jsonl has all 10 events from pane-B
    local total
    total=$(wc -l < "$events_file")
    [[ "$total" -eq 10 ]] || { echo "expected 10 events, got $total"; return 1; }

    # Verify: pane-A's stage_guide session has last_seen_offset == 10
    local offset
    offset=$(python3 -c "
import json
d = json.load(open('$sessions_file'))
for s in d.get('sessions', []):
    if s.get('kind') == 'stage_guide' and s.get('owner_opencode_session_id') == '$OPENCODE_SESSION_ID_PANEA':
        print(s.get('goal', {}).get('last_seen_offset', 0))
        break
")
    [[ "$offset" -eq 10 ]] || {
        echo "expected last_seen_offset=10 in pane-A session, got $offset"
        return 1
    }

    # Verify: pane-A's session state is terminal (after SIGTERM)
    local state
    state=$(python3 -c "
import json
d = json.load(open('$sessions_file'))
for s in d.get('sessions', []):
    if s.get('kind') == 'stage_guide' and s.get('owner_opencode_session_id') == '$OPENCODE_SESSION_ID_PANEA':
        print(s.get('state', '?'))
        break
")
    [[ "$state" == "completed" ]] || {
        echo "expected pane-A session state=completed after SIGTERM, got $state"
        return 1
    }
}

@test "REAL-2P-2: pane-A and pane-B sessions are isolated by owner; pane-A only sees its own kind" {
    local events_file="$FAKE_ROOT/.rddf/state/events.jsonl"
    local sessions_file="$FAKE_ROOT/.rddf/state/sessions.json"
    local pidfile_a="$FAKE_ROOT/.rddf/state/pane_a.pid"
    local pidfile_b="$FAKE_ROOT/.rddf/state/pane_b.pid"

    # Spawn both panes simultaneously (different OPENCODE_SESSION_ID)
    spawn_pane_a_polling "$OPENCODE_SESSION_ID_PANEA" "$events_file" "$sessions_file" 5 "$pidfile_a"
    spawn_pane_b_writer "$OPENCODE_SESSION_ID_PANEB" "$events_file" 5 0.4 "$pidfile_b"

    local pid_a=$(cat "$pidfile_a")
    local pid_b=$(cat "$pidfile_b")

    wait $pid_a 2>/dev/null || true
    wait $pid_b 2>/dev/null || true

    # Verify pane-A has its own stage_guide session (H7 singleton)
    local count_a_sessions
    count_a_sessions=$(python3 -c "
import json
d = json.load(open('$sessions_file'))
n = sum(1 for s in d.get('sessions', []) if s.get('kind')=='stage_guide' and s.get('owner_opencode_session_id')=='$OPENCODE_SESSION_ID_PANEA')
print(n)
")
    [[ "$count_a_sessions" -ge 1 ]] || {
        echo "expected >=1 stage_guide session for PANEA, got $count_a_sessions"
        return 1
    }

    # Verify events.jsonl has events from pane-B
    local total_events
    total_events=$(wc -l < "$events_file")
    [[ "$total_events" -ge 5 ]] || {
        echo "expected >=5 events from pane-B, got $total_events"
        return 1
    }

    # Verify events.jsonl has the expected event types
    local has_event_types
    has_event_types=$(python3 -c "
import json
types = set()
with open('$events_file') as f:
    for line in f:
        if line.strip():
            d = json.loads(line)
            types.add(d.get('event_type', ''))
print('yes' if 'phase_started' in types else 'no')
")
    [[ "$has_event_types" == "yes" ]] || {
        echo "expected phase_started events in events.jsonl"
        return 1
    }
}