#!/usr/bin/env bash
# tests/_lib/test_full_workflow_e2e_runner.sh
# Bash wrapper for the builder handoff env-py shim.
# Mirrors skills/rdd-arch/scripts/write_arch_handoff.sh pattern (Oracle C1 safe).
#
# All values flow via env vars (NEVER bash string interpolation into python).
#
# Usage: bash test_full_workflow_e2e_runner.sh   # uses env vars set by caller

_runner_sh() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

    # All values flow via env vars (Oracle C1 safe)
    python3 "$script_dir/test_full_workflow_e2e_runner.env.py"
}

# If invoked (not sourced), run directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _runner_sh "$@"
fi

# Export the function so callers can `source` and invoke via the helper
export -f _runner_sh 2>/dev/null || true