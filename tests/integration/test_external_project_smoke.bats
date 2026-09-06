#!/usr/bin/env bats
# tests/integration/test_external_project_smoke.bats
# External test bed — verifies that from a fresh third-party project
# perspective, rdd-workflow's sub-skills are well-formed and discoverable.

load ../test_helper

# Find all SKILL.md files (including skills/INSTALL.md at top level)
SKILL_FILES=$(find "$RDD_WORKFLOW_REPO/skills" -name SKILL.md -print0 | xargs -0 -n1)

@test "external: each sub-skill has valid YAML frontmatter (--- ... --- delimiters)" {
    local count=0 fail=0
    while IFS= read -r skill_md; do
        count=$((count + 1))
        # YAML frontmatter: must start with --- and end with --- on subsequent lines
        if ! head -1 "$skill_md" | grep -q '^---$'; then
            echo "❌ $skill_md: missing frontmatter delimiter" >&2
            fail=$((fail + 1))
            continue
        fi
        if ! sed -n '2,/^---$/p' "$skill_md" | grep -q '^---$'; then
            echo "❌ $skill_md: unclosed frontmatter" >&2
            fail=$((fail + 1))
        fi
    done <<<"$SKILL_FILES"
    [ "$fail" = 0 ]
    [ "$count" -ge 25 ] || { echo "❌ only $count SKILL.md found (need ≥25)" >&2; return 1; }
}

@test "external: each sub-skill frontmatter has name + description + license" {
    local count=0 fail=0
    while IFS= read -r skill_md; do
        count=$((count + 1))
        local body
        body=$(awk '/^---$/{c++; next} c==1' "$skill_md")
        if ! grep -q '^name:' <<<"$body"; then
            echo "❌ $skill_md: missing name:" >&2
            fail=$((fail + 1))
        fi
        if ! grep -q '^description:' <<<"$body"; then
            echo "❌ $skill_md: missing description:" >&2
            fail=$((fail + 1))
        fi
        if ! grep -q '^license:' <<<"$body"; then
            echo "❌ $skill_md: missing license:" >&2
            fail=$((fail + 1))
        fi
    done <<<"$SKILL_FILES"
    [ "$fail" = 0 ]
    [ "$count" -ge 25 ]
}

@test "external: each sub-skill metadata has semver version (X.Y or X.Y.Z)" {
    local count=0 fail=0
    while IFS= read -r skill_md; do
        count=$((count + 1))
        # Extract version line within frontmatter (between first --- pair)
        local version_line
        version_line=$(awk '/^---$/{c++; next} c==1 && /^  version:/' "$skill_md")
        # Accept both `version: "2.0"` (quoted) and `version: 2.0` (bare)
        if ! grep -qE '^  version: *"*[0-9]+\.[0-9]+' <<<"$version_line"; then
            echo "❌ $skill_md: missing/invalid metadata.version (got: $version_line)" >&2
            fail=$((fail + 1))
        fi
    done <<<"$SKILL_FILES"
    [ "$fail" = 0 ]
    [ "$count" -ge 25 ]
}

@test "external: openspec CLI is on PATH (required by rdd-workflow)" {
    if ! command -v openspec >/dev/null 2>&1; then
        echo "❌ openspec CLI not found in PATH" >&2
        echo "   Install via: https://github.com/insight-hub/openspec" >&2
        return 1
    fi
    run openspec --help
    [ "$status" = 0 ]
}

@test "external: bats-core ≥1.10 available (required test runner)" {
    if ! command -v bats >/dev/null 2>&1; then
        echo "❌ bats not found in PATH" >&2
        return 1
    fi
    local version
    version=$(bats --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [[ -n "$version" ]] || { echo "❌ cannot parse bats version" >&2; return 1; }
    # 1.10+ check via awk
    awk -v v="$version" 'BEGIN{ split(v,a,"."); if (a[1]<1 || (a[1]==1 && a[2]<10)) exit 1 }' \
        || { echo "❌ bats $version < 1.10" >&2; return 1; }
    echo "bats $version OK"
}