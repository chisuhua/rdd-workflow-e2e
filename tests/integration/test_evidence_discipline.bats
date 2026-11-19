#!/usr/bin/env bash
# tests/integration/test_evidence_discipline.bats — **证据纪律**（零模型，默认进 CI）
#
# 由来：2026-11-19 的一次多 change 收口会话里，**真正出错的地方全部落在"记录与判据"层**，
# 而不是实现层。逐条复盘后，每一类错误都能被一条机械判据抓住 —— 本文件固化了 6 条：
#
#   C1 判据可机判      ：标了「逐字」的 AC 字面量必须真的能在仓里命中（否则该 AC 永远不成立）
#   C2 勾选要有证据    ：`- [x] AC…` 必须能在本 change 找到证据指针（"勾了没做"是最高频的腐败）
#   C3 勘误要自足      ：出现「勘误」时必须同时给出权威源 + 原文位置（否则勘误本身无法被复核）
#   C4 过期段要标注    ：观察报告里「未判定」与「已确认」并存时，旧段必须带取代标注
#   C5 活文档指针不悬空：`docs/adr/**` 与 `.rddf/improvements/**` 里的 `openspec/changes/<name>/` 必须存在
#   C6 commit 级归因要带命令：「未改 prompts/** / 只碰 …」这类**带提交语境**的断言必须给可复核命令
#
# 判别力要求（本仓纪律：判据必须能被反例打红）：
#   每条检查都配 **合成反例**（在 `$BATS_TEST_TMPDIR` 造一份"错的"样例 ⇒ 必须报出）+ **真实仓**用例（必须干净）。
#
# 被测目标：`$TARGET_REPO`（默认 `$HOME/.config/opencode`；与 `test_oracle_intent_gate.bats` 的 `SC_SRC` 同源）。
# **不依赖模型、不读用户级状态**。
#
# 范围（有意收窄 —— 每条都写清理由，避免"判据看着严、实际只能对历史存量判红"）：
#   - **生效日**：C2/C3/C4/C6 只检查 **2026-11-19 之后被改动过** 的文件（`git log -1 --format=%as`；
#     未跟踪/未提交 ⇒ 视为"新"，照样检查）。理由：这些约定自该日建立，历史存量的形态不同，
#     而本仓惯例是**历史记述不回改**（只追加勘误/指针）⇒ 对存量判红没有修复路径。
#   - C1 只看**标了「逐字」且不含占位符**（`<…>` / `…`）的 code span：描述性命令（`git log … -- <file>`）
#     本来就带占位符，逐字比对无意义；真正危险的是"声称逐字、实际不存在"（2026-11-19 的真实事故）。
#   - C4 只看 `*-observation.md`（结论面报告）；C5 只看活文档面（`docs/adr/**` + `.rddf/improvements/**`）。
#
# 用法：
#   bats tests/integration/test_evidence_discipline.bats
#   TARGET_REPO=/path/to/repo bats tests/integration/test_evidence_discipline.bats

load ../test_helper

TARGET_REPO="${TARGET_REPO:-$HOME/.config/opencode}"
EVIDENCE_EPOCH="${EVIDENCE_EPOCH:-2026-11-19}"
export TARGET_REPO EVIDENCE_EPOCH

_require_target() {
    [[ -d "$TARGET_REPO" ]] || {
        echo "TARGET_REPO 不存在：$TARGET_REPO" >&2
        return 1
    }
}

# 文件是否"自生效日起被动过"（未跟踪/未提交 ⇒ 视为新）
_touched_since_epoch() {
    local f="$1" last
    if ! git -C "$TARGET_REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        return 0   # 未跟踪 ⇒ 新
    fi
    if [[ -n "$(git -C "$TARGET_REPO" status --porcelain -- "$f" 2>/dev/null)" ]]; then
        return 0   # 工作树有改动 ⇒ 新
    fi
    last="$(git -C "$TARGET_REPO" log -1 --format=%as -- "$f" 2>/dev/null)"
    [[ -n "$last" && ! "$last" < "$EVIDENCE_EPOCH" ]]
}

# ─────────────────────────────────────────────────────────────
# C1 判据可机判：标了「逐字」的 AC 字面量必须能在 change 目录之外命中
# ─────────────────────────────────────────────────────────────
c1_bad_literals() {
    local root="$1" bad="" d props lit hits
    while IFS= read -r d; do
        props="$d/proposal.md"
        [[ -f "$props" ]] || continue
        # 有 AC 表就查（**不依赖是否已有勾选镜像** —— 2026-11-19 的坏判据恰好出现在
        # 「还没有镜像」的那个提交里；若以镜像为门，它就会漏过去）
        grep -qE '^## (验收标准|Acceptance)' "$props" || continue
        _touched_since_epoch "${props#"$root"/}" || continue
        while IFS= read -r row; do
            grep -q '逐字' <<<"$row" || continue
            # 语料由 AC 自己的措辞决定：说「测试源码 / 源码 / 代码」就该在代码文件里找，
            # 不能靠某份 .md 里的同名文字满足（2026-11-19 的真实事故正是这样"存在但不在声称的位置"）。
            local inc=(--include='*.md' --include='*.ts' --include='*.sh' --include='*.json' --include='*.jsonc')
            if grep -qE '测试源码|源码|代码文件|代码里' <<<"$row"; then
                inc=(--include='*.ts' --include='*.sh' --include='*.json' --include='*.jsonc')
            elif grep -qE '文档|报告|prompt' <<<"$row"; then
                inc=(--include='*.md')
            fi
            while IFS= read -r lit; do
                [[ -n "$lit" ]] || continue
                # 占位符形（描述性命令）不参与逐字比对
                grep -qE '<[^>]*>|…|\.\.\.' <<<"$lit" && continue
                # 命中面 = 全仓，但**排除该 change 自己的目录**（否则判据匹配到自身 ⇒ 假绿）
                hits="$(grep -rlF "${inc[@]}" -e "$lit" "$root" 2>/dev/null \
                          | grep -v "^$d/" | head -1)"
                if [[ -z "$hits" ]]; then
                    bad+="${props}: 「逐字」字面量在 change 目录之外（语料=${inc[*]}）找不到 → $lit"$'\n'
                fi
            done < <(grep -o '`[^`]*`' <<<"$row" | tr -d '`')
        done < <(grep -E '^\| \*{0,2}AC[0-9]+' "$props")
    done < <(find "$root/openspec/changes" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sort)
    printf '%s' "$bad"
}

@test "C1 反例：标「逐字」但仓里没有该字面量 ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c1"
    mkdir -p "$fake/openspec/changes/x" "$fake/tests"
    cat > "$fake/openspec/changes/x/proposal.md" <<'MD'
# x

## Acceptance（勾选镜像）

| AC | 判据 |
|---|---|
| AC1 | 源码含 `git log -1 --format=%H --`（逐字） |

- [x] AC1
MD
    printf '%s\n' 'const a = ["log", "-1", "--format=%H", "--", f]' > "$fake/tests/a.ts"
    local out; out="$(c1_bad_literals "$fake")"
    [ -n "$out" ] || { echo "C1 判别力不足：不存在的「逐字」字面量没有报出来" >&2; return 1; }
}

@test "C1 自匹配反例：字面量只在 change 自己的目录里 ⇒ 仍算找不到" {
    local fake="$BATS_TEST_TMPDIR/fake-c1b"
    mkdir -p "$fake/openspec/changes/x"
    cat > "$fake/openspec/changes/x/proposal.md" <<'MD'
# x

## Acceptance（勾选镜像）

| AC | 判据 |
|---|---|
| AC1 | 源码含 `git rev-parse --abbrev-ref HEAD`（逐字） |

- [x] AC1
MD
    local out; out="$(c1_bad_literals "$fake")"
    [ -n "$out" ] || { echo "C1 有自匹配漏洞：只在 change 目录内命中却判通过" >&2; return 1; }
}

@test "C1 占位符反例：带 <file> 的描述性命令 ⇒ 不参与逐字比对" {
    local fake="$BATS_TEST_TMPDIR/fake-c1c"
    mkdir -p "$fake/openspec/changes/x"
    cat > "$fake/openspec/changes/x/proposal.md" <<'MD'
# x

## Acceptance（勾选镜像）

| AC | 判据 |
|---|---|
| AC1 | 命令形态与归档 spec 逐字一致：`git log -1 --format=%H -- <file>` |

- [x] AC1
MD
    local out; out="$(c1_bad_literals "$fake")"
    [ -z "$out" ] || { echo "C1 误报：描述性命令（带占位符）被判违规：$out" >&2; return 1; }
}

@test "C1 真实仓：标「逐字」的 AC 字面量都能在 change 目录之外命中" {
    _require_target
    local out; out="$(c1_bad_literals "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下 AC 声称「逐字」但字面量不存在（判据不可机判）：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C2 勾选要有证据
# ─────────────────────────────────────────────────────────────
c2_ticked_without_evidence() {
    local root="$1" bad="" d props name
    while IFS= read -r d; do
        props="$d/proposal.md"
        [[ -f "$props" ]] || continue
        grep -q '^## Acceptance（勾选镜像）' "$props" || continue
        grep -qE '^- \[x\] AC' "$props" || continue
        _touched_since_epoch "${props#"$root"/}" || continue
        name="$(basename "$d")"; name="${name#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
        grep -q '^> \*\*验收证据' "$props" && continue
        compgen -G "$root/.rddf/reviews/${name}*" >/dev/null 2>&1 && continue
        bad+="${props}: 有勾选但无证据指针（既无「> **验收证据**」注记，也无 .rddf/reviews/${name}*）"$'\n'
    done < <(find "$root/openspec/changes" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sort)
    printf '%s' "$bad"
}

@test "C2 反例：勾了 AC 但没有任何证据指针 ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c2"
    mkdir -p "$fake/openspec/changes/y" "$fake/.rddf/reviews"
    printf '%s\n\n## Acceptance（勾选镜像）\n\n- [x] AC1 某事已完成\n' "# y" > "$fake/openspec/changes/y/proposal.md"
    local out; out="$(c2_ticked_without_evidence "$fake")"
    [ -n "$out" ] || { echo "C2 判别力不足：无证据的勾选没被报出" >&2; return 1; }
}

@test "C2 正例：有「验收证据」注记 或 有同名 review 报告 ⇒ 不报" {
    local fake="$BATS_TEST_TMPDIR/fake-c2b"
    mkdir -p "$fake/openspec/changes/y" "$fake/openspec/changes/z" "$fake/.rddf/reviews"
    printf '%s\n\n## Acceptance（勾选镜像）\n\n- [x] AC1\n\n> **验收证据（x）**：见某报告\n' "# y" > "$fake/openspec/changes/y/proposal.md"
    printf '%s\n\n## Acceptance（勾选镜像）\n\n- [x] AC1\n' "# z" > "$fake/openspec/changes/z/proposal.md"
    : > "$fake/.rddf/reviews/z-verify.md"
    local out; out="$(c2_ticked_without_evidence "$fake")"
    [ -z "$out" ] || { echo "C2 误报（正例被判违规）：$out" >&2; return 1; }
}

@test "C2 真实仓：生效日之后的 change 勾选都有证据指针" {
    _require_target
    local out; out="$(c2_ticked_without_evidence "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下 change 勾了 AC 但没有证据指针：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C3 勘误要自足
# ─────────────────────────────────────────────────────────────
c3_insufficient_errata() {
    local root="$1" bad="" f start block
    while IFS= read -r f; do
        _touched_since_epoch "${f#"$root"/}" || continue
        while IFS= read -r start; do
            block="$(sed -n "${start},$((start + 10))p" "$f")"
            grep -qE '权威|真源' <<<"$block" || bad+="${f}:${start}: 勘误缺少「权威源」"$'\n'
            grep -qE '原文|上文|上条|本条|上表|原句|第 [0-9]+ 行' <<<"$block" \
                || bad+="${f}:${start}: 勘误缺少「原文位置」"$'\n'
        done < <(grep -n '勘误（' "$f" | cut -d: -f1)
    done < <(find "$root" -type f -name '*.md' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
    printf '%s' "$bad"
}

@test "C3 反例：勘误只写「此处有误」⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c3"
    mkdir -p "$fake/docs"
    printf '%s\n' '# log' '' '> ⑥ 门控 N 112 → 326（≥150 已到）。' '' '> ⚠ **勘误（2026-11-19）**：本条有误。' \
        > "$fake/docs/CHANGELOG.md"
    local out; out="$(c3_insufficient_errata "$fake")"
    [ -n "$out" ] || { echo "C3 判别力不足：残缺勘误未报出" >&2; return 1; }
}

@test "C3 正例：勘误含权威源 + 原文位置 ⇒ 不报" {
    local fake="$BATS_TEST_TMPDIR/fake-c3b"
    mkdir -p "$fake/docs"
    printf '%s\n' '# log' '' '> ⑥ N 112 → 326（≥150 已到）。' '' \
        '> ⚠ **勘误（2026-11-19）**：上条「326」有误 —— 权威数据为 `N = 112`（观察报告 §2）。' \
        > "$fake/docs/CHANGELOG.md"
    local out; out="$(c3_insufficient_errata "$fake")"
    [ -z "$out" ] || { echo "C3 误报（自足勘误被判违规）：$out" >&2; return 1; }
}

@test "C3 真实仓：生效日之后改动过的勘误都自足" {
    _require_target
    local out; out="$(c3_insufficient_errata "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下勘误不可复核（缺权威源或原文位置）：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C4 过期段要标注（观察报告）
# ─────────────────────────────────────────────────────────────
c4_unmarked_stale() {
    local root="$1" bad="" f
    while IFS= read -r f; do
        _touched_since_epoch "${f#"$root"/}" || continue
        grep -qE 'pending|未判定' "$f" || continue
        grep -qE '✅|已确认|载体判定: A|通过' "$f" || continue
        grep -qE '已被后续|已被取代|superseded|状态更新|过期' "$f" && continue
        bad+="${f}: 同时存在「未判定/pending」与「已确认/通过」，但没有任何取代标注"$'\n'
    done < <(find "$root/.rddf/reviews" -maxdepth 1 -type f -name '*observation.md' 2>/dev/null | sort)
    printf '%s' "$bad"
}

@test "C4 反例：观察报告同时写 pending 与 ✅ 且无取代标注 ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c4"
    mkdir -p "$fake/.rddf/reviews"
    printf '%s\n' '# xxx 观察报告' '' '- 主证据载体：pending' '' '| AC1 | ✅ 通过 |' \
        > "$fake/.rddf/reviews/x-observation.md"
    local out; out="$(c4_unmarked_stale "$fake")"
    [ -n "$out" ] || { echo "C4 判别力不足：未标注的过期段没被报出" >&2; return 1; }
}

@test "C4 正例：有「已被后续实测取代」标注 ⇒ 不报" {
    local fake="$BATS_TEST_TMPDIR/fake-c4b"
    mkdir -p "$fake/.rddf/reviews"
    printf '%s\n' '# xxx 观察报告' '' '> ⚠ **本节已被后续实测取代**' '' '- 主证据载体：pending' '' '| AC1 | ✅ 通过 |' \
        > "$fake/.rddf/reviews/x-observation.md"
    local out; out="$(c4_unmarked_stale "$fake")"
    [ -z "$out" ] || { echo "C4 误报：已标注的过期段仍被判违规：$out" >&2; return 1; }
}

@test "C4 真实仓：生效日之后的观察报告没有未标注的过期段" {
    _require_target
    local out; out="$(c4_unmarked_stale "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下报告的过期段没有标注（会被误读为最新结论）：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C5 活文档指针不悬空
# ─────────────────────────────────────────────────────────────
c5_dangling_pointers() {
    local root="$1" bad="" f p name arch
    while IFS= read -r f; do
        while IFS= read -r p; do
            name="$(sed -E 's#^openspec/changes/([^/]+)/.*#\1#' <<<"$p")"
            arch="$(ls "$root/openspec/changes/archive" 2>/dev/null | grep -E -- "-${name}$" | head -1)"
            [[ -d "$root/openspec/changes/$name" ]] && continue
            [[ -n "$arch" && -d "$root/openspec/changes/archive/$arch" ]] && continue
            if grep -qE "openspec/changes/archive/[0-9-]+-${name}/" "$f"; then continue; fi
            if grep -qE '已归档|archive/' "$f" && grep -q -- "$name" "$f"; then continue; fi
            bad+="${f}: 悬空指针 → $p"$'\n'
        done < <(grep -ohE 'openspec/changes/[^/` )]+/' "$f" | sort -u)
    done < <(find "$root/docs/adr" -type f -name '*.md' 2>/dev/null; find "$root/.rddf/improvements" -type f -name '*.md' 2>/dev/null)
    printf '%s' "$bad"
}

@test "C5 反例：活文档指向不存在的 change ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c5"
    mkdir -p "$fake/docs/adr" "$fake/.rddf/improvements"
    printf '%s\n' '# ADR' '' '| 关联 change | `openspec/changes/ghost/proposal.md` |' > "$fake/docs/adr/ADR-x.md"
    local out; out="$(c5_dangling_pointers "$fake")"
    [ -n "$out" ] || { echo "C5 判别力不足：悬空指针没被报出" >&2; return 1; }
}

@test "C5 真实仓：ADR / improvement 的 change 指针不悬空" {
    _require_target
    local out; out="$(c5_dangling_pointers "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下活文档指针悬空（归档后未同步）：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C6 **commit 级**归因要带命令
# ─────────────────────────────────────────────────────────────
# 事故形态：verify 报告写「`git log` 可见本 change 的提交只碰 openspec/docs/.rddf」——
# 那个 commit **混装了** v2.43 收尾（含 `prompts/build.md`）⇒ commit 级 diff 在混装提交上没有归因力。
# 因此只检查**带提交语境**（提交/commit/git log/sha）的否定性归因；单纯的性质句（"只改 tests/"）不在此列。
c6_unbacked_negative_claim() {
    local root="$1" bad="" f lineno line
    while IFS= read -r f; do
        while IFS= read -r hit; do
            lineno="${hit%%:*}"
            line="${hit#*:}"
            grep -qE '(未改|未碰|只碰|只改)' <<<"$line" || continue
            # 文件名 `commit-gate.json` 含 `commit`，但它不是**提交语境** ⇒ 先剔除再判
            # （同口径：本仓 tests/verify_record_discipline.sh 的 check_c6）。
            # 该误报首次命中守卫自己的验收报告（"配置文件的 verify_commands 未改"）。
            local ctx="${line//commit-gate/__cfg__}"
            grep -qE '(提交|commit|git log|sha)' <<<"$ctx" || continue
            # ⚠ **不接受 `git log` 作为归因手段**：它能列提交，但证明不了某个提交改了哪些文件
            #   ⇒ 混装提交上恒真。归因必须用 `git show --stat` / `git diff --stat` / 按文件归属。
            sed -n "${lineno},$((lineno + 3))p" "$f" | grep -qE '`[^`]*(git (show|diff)|按文件归属)' && continue
            grep -qE '按文件归属' <<<"$line" && continue
            bad+="${f}:${lineno}: commit 级否定性归因缺少可复核命令"$'\n'
        done < <(grep -nE '(未改|未碰|只碰|只改).*(prompts/|tests/|lib/)' "$f")
    done < <(find "$root/openspec/changes" -name 'proposal.md' 2>/dev/null; find "$root/.rddf/reviews" -name '*-verify.md' 2>/dev/null)
    printf '%s' "$bad"
}

@test "C6 反例：用 commit 级证据说「只碰 X」但无命令 ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c6"
    mkdir -p "$fake/openspec/changes/x"
    printf '%s\n' '# x' '' '`git log` 可见本 change 的提交只碰 openspec/ 与 .rddf/，未改 prompts/**。' \
        > "$fake/openspec/changes/x/proposal.md"
    local out; out="$(c6_unbacked_negative_claim "$fake")"
    [ -n "$out" ] || { echo "C6 判别力不足：无命令的 commit 级归因没被报出" >&2; return 1; }
}

@test "C6 正例：同段给出「按文件归属」或命令 ⇒ 不报" {
    local fake="$BATS_TEST_TMPDIR/fake-c6b"
    mkdir -p "$fake/openspec/changes/x"
    printf '%s\n' '# x' '' '`git log` 可见本 change 的提交只碰 openspec/，未改 prompts/**（**按文件归属核对**：产出只有本目录三份文档）。' \
        > "$fake/openspec/changes/x/proposal.md"
    local out; out="$(c6_unbacked_negative_claim "$fake")"
    [ -z "$out" ] || { echo "C6 误报：已给手段的断言仍被判违规：$out" >&2; return 1; }
}

@test "C6 正例：配置文件名 commit-gate.json 的「未改」不构成提交语境" {
    local fake="$BATS_TEST_TMPDIR/fake-c6d"
    mkdir -p "$fake/openspec/changes/x"
    printf '%s\n' '# x' '' '`.rddf/commit-gate.json` 的 `verify_commands` **未改**（仍是 `bun test tests/`）。' \
        > "$fake/openspec/changes/x/proposal.md"
    local out; out="$(c6_unbacked_negative_claim "$fake")"
    [ -z "$out" ] || { echo "C6 误报：配置文件名被当成提交语境：$out" >&2; return 1; }
}

@test "C6 性质句反例：不带提交语境的「只改 tests/」不参与判定" {
    local fake="$BATS_TEST_TMPDIR/fake-c6c"
    mkdir -p "$fake/openspec/changes/x"
    printf '%s\n' '# x' '' '> 性质：**只改测试**（`tests/foo.test.ts`）⇒ 运行时零影响。' \
        > "$fake/openspec/changes/x/proposal.md"
    local out; out="$(c6_unbacked_negative_claim "$fake")"
    [ -z "$out" ] || { echo "C6 误报：性质句被判违规：$out" >&2; return 1; }
}

@test "C6 真实仓：commit 级否定性归因都带可复核手段" {
    _require_target
    local out; out="$(c6_unbacked_negative_claim "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下断言不可复核（混装 commit 不能作归因证据）：" >&2
        echo "$out" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# C7 门槛达标类断言必须带取数指针
# ─────────────────────────────────────────────────────────────
# 事故形态：`docs/CHANGELOG.md` 写「门控 N 112 → 326（≥150 **已到**）」——
# 而权威数据是 `N = 112`（未涨）。错误活下来的原因是**那句话没有任何取数指针**：
# 读者无法复核，也就没人发现它与观察报告矛盾。⇒ 凡「门槛已到 / 已达标」类断言，必须给可追的指针。
c7_unbacked_gate_claim() {
    local root="$1" bad="" f hit lineno line
    while IFS= read -r f; do
        while IFS= read -r hit; do
            lineno="${hit%%:*}"
            line="${hit#*:}"
            # 取数指针必须与断言**同一条 bullet**（列表项续行也算；下一条 bullet 不算 ——
            # 否则"隔壁 bullet 提到某文件"会被当成这条断言的证据）。
            local win="$line" n2 cur
            n2=$((lineno + 1))
            while (( n2 <= lineno + 2 )); do
                cur="$(sed -n "${n2}p" "$f")"
                [[ "$cur" == ">"* ]] || break            # 不在同一 blockquote 里 ⇒ 停
                [[ "$cur" =~ ^\>[[:space:]]*[①-⑳] ]] && break   # 下一条 bullet ⇒ 停
                win+=$'\n'"$cur"
                n2=$((n2 + 1))
            done
            grep -qE '`[^`]*(/|\.md|\.json|§)[^`]*`|（见 |观察报告|ndjson' <<<"$win" && continue
            # 引用性语境（勘误引原文 / 「待 N ≥ 150」这类**未到**的表述）不算
            sed -n "$((lineno > 2 ? lineno - 2 : 1)),$((lineno + 2))p" "$f" \
                | grep -qE '勘误|有误|是错的|superseded|已被取代' && continue
            # 「样本不足」语境（`N = 112 < 150` 落在第三支）不算"门槛已到"
            grep -qE '< ?150|样本不足|未涨' <<<"$line" && continue
            bad+="${f}:${lineno}: 「门槛已到」类断言缺少取数指针（无法复核）"$'\n'
        done < <(grep -nE '((已到|已达标).*150|150.*(已到|已达标))' "$f")
    done < <(find "$root" -type f -name '*.md' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
    printf '%s' "$bad"
}

@test "C7 反例：声称「N ≥150 已到」但无任何取数指针 ⇒ 必须报违规" {
    local fake="$BATS_TEST_TMPDIR/fake-c7"
    mkdir -p "$fake/docs"
    printf '%s\n' '# log' '' '> ⑥ 门控 **N 112 → 326**（≥150 **已到**），时间门未到。' > "$fake/docs/CHANGELOG.md"
    local out; out="$(c7_unbacked_gate_claim "$fake")"
    [ -n "$out" ] || { echo "C7 判别力不足：无指针的门槛断言没被报出" >&2; return 1; }
}

@test "C7 正例：断言带观察报告指针 ⇒ 不报" {
    local fake="$BATS_TEST_TMPDIR/fake-c7b"
    mkdir -p "$fake/docs"
    printf '%s\n' '# log' '' '> ⑥ 门控 N ≥ 150 已到（见 `.rddf/reviews/x-observation.md` §2）。' > "$fake/docs/CHANGELOG.md"
    local out; out="$(c7_unbacked_gate_claim "$fake")"
    [ -z "$out" ] || { echo "C7 误报：带指针的断言被判违规：$out" >&2; return 1; }
}

@test "C7 真实仓：所有「门槛已到」类断言都带取数指针" {
    _require_target
    local out; out="$(c7_unbacked_gate_claim "$TARGET_REPO")"
    if [[ -n "$out" ]]; then
        echo "以下断言声称门槛已到但没有取数指针：" >&2
        echo "$out" >&2
        return 1
    fi
}
