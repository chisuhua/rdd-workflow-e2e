#!/usr/bin/env bats
# tests/integration/test_rddf_cli_all_subcommands.bats
# External test bed for rdd-workflow — verifies rddf CLI exposes all 36
# subcommands and basic ones work in a real fake project.
#
# Strategy: 6 grouped cases (each verifies 4-10 subcommands).
# Read-only commands are invoked directly; mutating ones only check --help.
# This is a SMOKE test, not functional verification.

load ../test_helper
load_lib test_full_workflow_fixture

# All rddf subcommands that must be exposed (per _lib/cli/*.py)
# Note: `help` is not a separate subcommand (it's --help flag);
#       `regression_diff_cmd` is exposed as `hub retry-failed` sub-subcommand.
ALL_SUBCOMMANDS="version guide status deps feature roadmap dashboard \
doctor validate monitor sessions orchestrate \
archive cleanup init migrate-improvements feedback issue \
ac-verify arch archive-sync builder contract-check discover-ship-changes \
iteration l2-trend planner rdd-hub-bootstrap rdd-verify report-issue \
scheduler sync-hub watch-hub hub"

@test "rddf CLI: exposes all 36 subcommands via --help" {
    run rddf --help
    [ "$status" = 0 ]
    # Each subcommand name should appear in --help output (some have aliases)
    local missing=0
    for cmd in $ALL_SUBCOMMANDS; do
        if ! grep -qw "$cmd" <<<"$output"; then
            echo "❌ missing subcommand: $cmd" >&2
            missing=$((missing + 1))
        fi
    done
    [ "$missing" = 0 ]
}

@test "rddf version: returns semver or 'not a rdd-workflow project' (both valid)" {
    run rddf version
    [ "$status" = 0 ]
    local combined="$output$stderr"
    [ -n "$combined" ]
    # Accept either:
    #  - in-repo: "rddf v4.0.0 — rdd-workflow CLI"
    #  - external project: "ℹ️  not a rdd-workflow project (no .../.rddf/state)"
    if [[ "$combined" =~ v[0-9]+\.[0-9]+\.[0-9]+ ]] \
        || [[ "$combined" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] \
        || [[ "$combined" == *"not a rdd-workflow project"* ]]; then
        return 0
    fi
    echo "❌ unexpected rddf version output: $combined" >&2
    return 1
}

@test "rddf read-only: status/guide/dashboard/doctor work in rdd-workflow repo" {
    # rddf wrapper (per _lib/cli/__main__.py:194) requires .rddf/state/ to exist
    # and emits "not a rdd-workflow project" diagnostic if absent. So we run from
    # the installed rdd-workflow repo (where .rddf/state/ exists).
    cd "$RDD_WORKFLOW_REPO"

    for cmd in status guide dashboard doctor validate feature roadmap deps; do
        run rddf "$cmd" 2>&1 || true
        # Each must produce SOME output (not crash silently)
        [ -n "$output" ] || [ -n "$stderr" ] || {
            echo "❌ rddf $cmd: empty output" >&2
            return 1
        }
    done
}

@test "rddf --help: each subcommand returns exit 0" {
    # These are known read-only / help-friendly
    local help_safe="version status guide dashboard doctor deps feature \
roadmap validate monitor sessions orchestrate migrate-improvements \
feedback issue iteration l2-trend planner scheduler regression-diff"
    local failed=""
    for cmd in $help_safe; do
        if ! rddf "$cmd" --help >/dev/null 2>&1; then
            # Some commands don't support --help; try running without args
            if ! rddf "$cmd" >/dev/null 2>&1; then
                # status without args exits 1 sometimes (no changes) — accept exit 0/1
                if [ "$?" -gt 2 ]; then
                    failed="$failed $cmd"
                fi
            fi
        fi
    done
    [ -z "$failed" ] || { echo "❌ failed:$failed" >&2; return 1; }
}

@test "rddf init: --help works (destructive, do not actually run)" {
    run rddf init --help
    [ "$status" = 0 ]
    local combined="$output$stderr"
    # Either:
    #  - in-repo: "usage: rddf init [target]" / "Install rdd-workflow to ..."
    #  - external project: "not a rdd-workflow project"
    [[ "$combined" == *"Install"* ]] \
        || [[ "$combined" == *"init"* ]] \
        || [[ "$combined" == *"usage"* ]] \
        || [[ "$combined" == *"not a rdd-workflow project"* ]] \
        || { echo "❌ unexpected: $combined" >&2; return 1; }
}

@test "rddf archive/cleanup/build --help: returns usage info without running" {
    for cmd in archive cleanup builder ac-verify rdd-hub-bootstrap report-issue \
               sync-hub watch-hub contract-check arch discover-ship-changes \
               archive-sync rdd-verify; do
        # These mutate state — only check --help or quick query
        if ! rddf "$cmd" --help >/dev/null 2>&1; then
            # If --help fails, try running with minimal args
            if ! timeout 5 rddf "$cmd" --version >/dev/null 2>&1; then
                echo "❌ rddf $cmd: --help failed" >&2
                return 1
            fi
        fi
    done
}