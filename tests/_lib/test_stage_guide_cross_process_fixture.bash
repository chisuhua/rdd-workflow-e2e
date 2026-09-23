#!/usr/bin/env bash
# tests/_lib/test_stage_guide_cross_process_fixture.bash
#
# Helper functions for test_stage_guide_cross_process_e2e.bats.
# Sourced via load_lib test_stage_guide_cross_process_fixture.
#
# Cross-process test bed: spawns REAL Python child processes via bash &
# to validate fcntl.flock contention, last_seen_offset arithmetic, and
# hook entry/close lifecycle across PIDs.
#
# Owner identifier convention: "OWNER_<pid>" (string), derived from $BASHPID
# at spawn time. NOT a real OpenCode session ID, but a stable tag that
# travels with the child process and its sessions.json record.
#
# All Python invocations use env-var passing (Oracle C1 safety); NEVER
# bash string interpolation into python3 -c "...".

# Resolve REPO_ROOT once (set by test_helper.bash via load_lib)
: "${RDD_WORKFLOW_REPO:?RDD_WORKFLOW_REPO not set — load test_helper first}"

# ─── Fake project + rdd-workflow bootstrap ────────────────────────────

# Setup_fake_project_cross: extend setup_fake_project with .rddf/state/ dir.
# Required for child Python processes that call RddfSessionCoordinator.
setup_fake_project_cross() {
    local root
    root="$(setup_fake_project)"
    mkdir -p "$root/.rddf/state"
    echo "$root"
}

# ─── Child process spawning ─────────────────────────────────────────────

# Spawn a Python child that creates a stage_guide session as $1.
# Writes child PID to $2 (file path) so caller can wait/kill.
spawn_stage_guide_session() {
    local owner="$1"
    local pidfile="$2"
    local project_root="$3"

    RDDF_PROJECT_ROOT="$project_root" \
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    RDDF_GUIDE_SESSION_ENABLED=yes \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.rddf_session import RddfSessionCoordinator
coord = RddfSessionCoordinator(sessions_file=os.path.join('$project_root', '.rddf/state/sessions.json'))
sid = coord.create_session(
    kind='stage_guide',
    owner_opencode_session_id='$owner',
    goal={'intent': 'guide-orchestrator', 'last_seen_offset': 0},
)
print(f'spawned:{sid}', flush=True)
import time; time.sleep(60)
" > "$project_root/.rddf/state/spawn_${owner}.log" 2>&1 &
    echo $! > "$pidfile"
}

# Spawn a Python child that appends N events to events.jsonl as $1.
# $3 = rate in Hz (events per second); 0 = no delay.
spawn_event_writer() {
    local owner="$1"
    local count="$2"
    local rate_hz="$3"
    local pidfile="$4"
    local project_root="$5"

    local delay_arg=""
    if [[ "$rate_hz" != "0" && "$rate_hz" != "" ]]; then
        delay_arg="time.sleep(1.0/$rate_hz)"
    fi

    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys, time
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import EventsLog
log = EventsLog(os.path.join('$project_root', '.rddf/state/events.jsonl'))
for i in range($count):
    log.append_event(
        event_type='test', severity='info', message=f'event-{i}',
        session_id=f'rds_{i}', kind='stage_arch',
        parent_session_id=None, owner_opencode_session_id='$owner',
    )
    $delay_arg
print(f'wrote:$count', flush=True)
" > "$project_root/.rddf/state/writer_${owner}.log" 2>&1 &
    echo $! > "$pidfile"
}

# Spawn a child that creates stage_guide + returns its exit code.
# Used for AC-4 (H7 singleton collision test).
spawn_stage_guide_with_exit() {
    local owner="$1"
    local project_root="$2"

    RDDF_PROJECT_ROOT="$project_root" \
    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.rddf_session import RddfSessionCoordinator, ConflictError
coord = RddfSessionCoordinator(sessions_file=os.path.join('$project_root', '.rddf/state/sessions.json'))
try:
    sid = coord.create_session(
        kind='stage_guide', owner_opencode_session_id='$owner',
        goal={'intent': 'guide-orchestrator', 'last_seen_offset': 0},
    )
    print(f'ok:{sid}')
except ConflictError as e:
    print(f'conflict:{e}')
    sys.exit(2)
" 2>&1
}

# ─── File reading + assertion helpers ──────────────────────────────────

# Count total lines in events.jsonl (excludes blank lines).
count_events() {
    local events_file="$1"
    if [[ ! -f "$events_file" ]]; then echo 0; return; fi
    grep -c '^{' "$events_file" 2>/dev/null || echo 0
}

# Collect unique event_ids from events.jsonl.
collect_event_ids() {
    local events_file="$1"
    if [[ ! -f "$events_file" ]]; then return; fi
    python3 -c "
import json, sys
ids = set()
with open('$events_file') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: ids.add(json.loads(line)['event_id'])
        except: pass
for i in sorted(ids): print(i)
"
}

# Read sessions.json and return number of active stage_guide sessions.
count_active_stage_guide_sessions() {
    local sessions_file="$1"
    if [[ ! -f "$sessions_file" ]]; then echo 0; return; fi
    python3 -c "
import json
d = json.load(open('$sessions_file'))
print(sum(1 for s in d.get('sessions', []) if s.get('kind')=='stage_guide' and s.get('state')=='active'))
"
}

# Assert that a stage_guide session owned by $1 has goal.last_seen_offset == $2.
assert_last_seen_offset() {
    local sessions_file="$1"
    local owner="$2"
    local expected="$3"

    local actual
    actual=$(python3 -c "
import json
d = json.load(open('$sessions_file'))
for s in d.get('sessions', []):
    if s.get('kind')=='stage_guide' and s.get('owner_opencode_session_id')=='$owner':
        print(s.get('goal', {}).get('last_seen_offset', -1))
        break
")
    if [[ "$actual" != "$expected" ]]; then
        echo "❌ last_seen_offset: expected $expected, got $actual for owner=$owner" >&2
        return 1
    fi
}

# Read events.jsonl and return count of rows at line_no >= $1.
poll_events_since() {
    local events_file="$1"
    local offset="$2"
    if [[ ! -f "$events_file" ]]; then echo 0; return; fi
    python3 -c "
import json
n = 0
with open('$events_file') as f:
    for line_no, line in enumerate(f, 0):
        if line_no < $offset: continue
        line = line.strip()
        if not line: continue
        try:
            json.loads(line); n += 1
        except: pass
print(n)
"
}

# Trigger archive via Python API (test helper for AC-5).
trigger_archive() {
    local events_file="$1"
    local sessions_file="$2"
    local max_size_mb="${3:-1}"

    PYTHONPATH="$RDD_WORKFLOW_REPO:$PYTHONPATH" \
    python3 -c "
import os, sys
sys.path.insert(0, '$RDD_WORKFLOW_REPO')
from skills.rddf_session.scripts.events_log import archive_events
n = archive_events('$events_file', keep=10, sessions_file='$sessions_file')
print(f'archived:{n}', flush=True)
"
}

# Wait for a child PID to exit (max 30s).
wait_for_child() {
    local pid="$1"
    local max_wait="${2:-30}"
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt $max_wait ]]; do
        sleep 1
        i=$((i+1))
    done
}

# Wait for events.jsonl to have at least N lines (for polling tests).
wait_for_event_count() {
    local events_file="$1"
    local target="$2"
    local max_wait="${3:-10}"
    local i=0
    while [[ $i -lt $max_wait ]]; do
        local n
        n=$(count_events "$events_file")
        if [[ "$n" -ge "$target" ]]; then
            echo "$n"
            return 0
        fi
        sleep 1
        i=$((i+1))
    done
    count_events "$events_file"
    return 1
}
