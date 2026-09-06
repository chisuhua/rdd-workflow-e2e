#!/usr/bin/env python3
"""Shim for invoke_builder_phases — env-var pattern (Oracle C1 safe).

Reads env vars (E2E_PROJECT_ROOT, E2E_CHANGE_NAME, E2E_BUILDER_*) and
calls _lib.builder_handoff.write_builder_handoff(). Mirrors the pattern
of skills/rdd-arch/scripts/write_arch_handoff_env.py.

Required env vars:
  E2E_PROJECT_ROOT    — absolute path to fake project root
  E2E_CHANGE_NAME     — OpenSpec change name

Optional env vars (with defaults matching builder_handoff signature):
  E2E_BUILDER_PHASE             (default: phase-2)
  E2E_BUILDER_APPROVAL_STATUS   (default: approved)
  E2E_BUILDER_EXECUTION_MODE    (default: lightweight)
  E2E_BUILDER_EXECUTION_STATUS  (default: completed)
  E2E_BUILDER_REVIEW_STATUS     (default: merge)
  E2E_BUILDER_ARCHIVE_STATUS    (default: pending)
  E2E_BUILDER_RETRY_COUNT       (default: 0)
  E2E_BUILDER_MAX_RETRIES       (default: 3)
  E2E_BUILDER_BRANCH            (default: openspec/<change>)
  E2E_BUILDER_WORKTREE_PATH     (default: empty — lightweight)

Returns: exit 0 on success, 1 on missing env vars.
"""
import os
import sys
from pathlib import Path

_repo_root = os.environ.get("PROJECT_ROOT") or os.environ.get("RDD_WORKFLOW_REPO") \
    or str(Path(__file__).resolve().parent.parent.parent)
# rdd-workflow-e2e sets PROJECT_ROOT to the installed rdd-workflow repo so this
# shim works both in-repo (rdd-workflow/tests) and externally (rdd-workflow-e2e/tests).
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

project_root = os.environ.get("E2E_PROJECT_ROOT")
change_name = os.environ.get("E2E_CHANGE_NAME")
if not project_root or not change_name:
    print("ERROR: E2E_PROJECT_ROOT and E2E_CHANGE_NAME required", file=sys.stderr)
    sys.exit(1)

from _lib.builder_handoff import write_builder_handoff  # noqa: E402

result = write_builder_handoff(
    project_root=project_root,
    change_name=change_name,
    current_phase=os.environ.get("E2E_BUILDER_PHASE", "phase-2"),
    approval_status=os.environ.get("E2E_BUILDER_APPROVAL_STATUS", "approved"),
    execution_mode_decision={
        "mode": os.environ.get("E2E_BUILDER_EXECUTION_MODE", "lightweight"),
        "reason": "e2e-fake-project-fixture",
        "decided_at": "2026-09-06T00:00:00Z",
        "decided_by": "test_full_workflow_e2e_runner",
    },
    worktree_path=os.environ.get("E2E_BUILDER_WORKTREE_PATH", ""),
    branch=os.environ.get("E2E_BUILDER_BRANCH", f"openspec/{change_name}"),
    execution_status=os.environ.get("E2E_BUILDER_EXECUTION_STATUS", "completed"),
    review_status=os.environ.get("E2E_BUILDER_REVIEW_STATUS", "merge"),
    archive_status=os.environ.get("E2E_BUILDER_ARCHIVE_STATUS", "pending"),
    retry_count=int(os.environ.get("E2E_BUILDER_RETRY_COUNT", "0")),
    max_retries=int(os.environ.get("E2E_BUILDER_MAX_RETRIES", "3")),
)

print(
    "✅ builder handoff written: "
    f".rddf/state/builder/{change_name}.json "
    f"(phase={result['current_phase']}, archive={result['archive_status']})"
)