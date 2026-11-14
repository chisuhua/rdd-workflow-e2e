#!/usr/bin/env bats
# tests/integration/test_class_scope_runtime.bats
#
# 运行时 E2E：能力面写集对齐（`class-write-scope-alignment`）+ verifier 取证不可用交回
# （`delegated-verifier-evidence-gap`）。
#
# ── 门控 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 4 条用例真正执行（需要真实模型 + 真实宿主）。
#
# ── 手动运行 ───────────────────────────────────────────────────────────────
#   mkdir -p "$PWD/.tmp-l2"
#   E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-l2" \
#     bats tests/integration/test_class_scope_runtime.bats
#
#   单例筛选：bats --filter 'CS-1' …
#   额度不足时：CS_PLAN_MODEL=provider/model（只影响本文件驱动的 plan 会话）
#
# ── 被测契约（每条用例一句话）──────────────────────────────────────────────
#   CS-1（AC3/AC4/AC12）verifier 类 + scope=[".rddf/reviews", ".rddf/state/verifier"]
#               ⇒ 派发**被接受**；后端**能**写 `.rddf/state/verifier/<name>.json`；
#               **不能**写 `.rddf/state/pair.json`（⇒ 上限不泄漏为授权）。
#   CS-2（AC4 后半）verifier 类 + scope=[".rddf/reviews"]（**不含**记账目录）
#               ⇒ 派发被接受，但写 `.rddf/state/verifier/<name>.json` 被**权限拒绝**
#               ⇒ 证明「类上限 ≠ 授权，授权只来自 scope」。
#   CS-3（AC7，delegated-verifier-evidence-gap）verifier 类的取证命令**失败**
#               ⇒ 交回（首行 `HANDOFF:`），**不产出 pass 结论**。
#   CS-4（AC2 前提，subagent-contract-critic-enforce）审计 CLI 的 `--json` 输出含
#               `rows[].timeCreated` / `messageIndex` / `evaluation{ok,exempted}`
#               ⇒ 四元组可算（**纯 CLI，不需模型**，但随 runtime 门控一起跑以免污染默认套件）。
#   CS-5（失败签名分类）修改文件上的测试失败 ⇒ `ac-fail` 而非 `blocked`。
#               ⚠ **验证状态：未验证**（2026-11-14 两次尝试均撞 Token Plan 429：10 次 retry 后
#               error、0 条文本、fixture 未被改 ⇒ 会话没拿到模型响应）。额度恢复后首次跑通即可。
#
# ── 断言优先级 ─────────────────────────────────────────────────────────────
#   ① 文件系统事实（文件是否存在 / 内容）
#   ② NDJSON 与 ledger 的结构化字段
#   ③ 不断言模型自然语言措辞；`HANDOFF:` 首行是**契约**（不是措辞），可断言。
#
# ── 前置（沿用 test_role_class_runtime.bats 的结论）────────────────────────
#   - fixture 落在**仓库外**且位于 /workspace 下（external_directory 放行面）
#   - fixture 的 .rddf/state/{pair,role}.json 必须是干净的（本文件每次重建 fixture）
#   - 每次真实运行带 `--session <new-id>`

load ../test_helper

cs_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

CS_CASE_TIMEOUT="${CS_CASE_TIMEOUT:-420}"
CS_ROOT="${CS_ROOT:-$REPO_ROOT/.tmp-l2}"
CS_FIXTURE_ROOT="${CS_FIXTURE_ROOT:-/workspace/main/rdd-workflow-e2e-cs}"

setup() {
    if ! cs_enabled; then
        skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    export TMPDIR="$CS_ROOT"
    mkdir -p "$CS_ROOT" "$CS_FIXTURE_ROOT"
}

teardown() {
    :
}

# ── fixture：最小工程 + 架构目录 + 改进草稿 ──────────────────────────────
cs_fixture() {
    local name="$1"
    local dest="$CS_FIXTURE_ROOT/$name"
    local marker="$CS_FIXTURE_ROOT/${name}.cs-owner"
    mkdir -p "$CS_FIXTURE_ROOT"
    if [ -d "$dest" ] && [ -f "$marker" ]; then
        rm -rf "$dest"
    elif [ -d "$dest" ]; then
        dest="$CS_FIXTURE_ROOT/${name}-$(date +%s)"
        marker="$dest.cs-owner"
    fi
    mkdir -p "$dest/docs/adr" "$dest/src" "$dest/.rddf/improvements" "$dest/.rddf/state"
    printf '# ADR-demo\n\nStatus: Draft\n\n## 决策\n\nD1: 初始决策。\n' > "$dest/docs/adr/ADR-demo.md"
    printf 'export const x = 1\n' > "$dest/src/app.ts"
    printf '# demo-change\n\n## Why\n\n演示用改进草稿。\n\n## What Changes\n\n无。\n\n## Acceptance\n\nAC1 演示。\n' \
        > "$dest/.rddf/improvements/demo-change.md"
    git -C "$dest" init -q
    git -C "$dest" config user.email "cs@test.local"
    git -C "$dest" config user.name "CS Test"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "cs fixture"
    printf 'cs-owned\n' > "$marker"
    printf '%s' "$dest"
}

cs_plan_run() {
    local name="$1"; shift
    local prompt="$1"; shift
    local cwd="$1"; shift
    local sid out err rc
    sid="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
    out="$CS_ROOT/${name}.json"; err="$CS_ROOT/${name}.err"
    local model_args=()
    [ -n "${CS_PLAN_MODEL:-}" ] && model_args=(--model "$CS_PLAN_MODEL")
    ( cd "$cwd" && timeout "$CS_CASE_TIMEOUT" opencode run --agent plan \
        --session "$sid" --format json "${model_args[@]}" "$@" "$prompt" ) >"$out" 2>"$err"
    rc=$?
    printf 'exit_code=%s\nstdout=%s\nstderr=%s\ncwd=%s\n' "$rc" "$out" "$err" "$cwd" > "$CS_ROOT/${name}.meta"
    return $rc
}

# 委托指令：只派发、不自行实现
cs_prompt() {
    local project="$1" task="$2" scope="$3" goal="$4"
    cat <<EOF
请只做一件事：调用 **delegate** 工具派发一个工程后端，参数严格如下（不要改写、不要追加、不要自行实现）：
- project_dir: $project
- agent: build
- task: $task
- goal: $goal
- scope: $scope
- acceptance: 完成后报告实际做了什么
- role_class: verifier
- plan_ref: $project/.rddf/improvements/demo-change.md
派发完成后，把 delegate 的返回值原样贴出（尤其 outcome / blocked_reason / changed_files）。
若 delegate 被拒，把错误原文贴出，不要改用 subagent 绕过，也不要重试。
EOF
}

cs_ledger_field() {
    local project="$1" field="$2"
    python3 - "$project/.rddf/state/ledger.jsonl" "$field" <<'PY' 2>/dev/null || true
import json, sys
try:
    rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
except Exception:
    raise SystemExit
if rows:
    value = rows[-1].get(sys.argv[2], "")
    print(json.dumps(value, ensure_ascii=False) if isinstance(value, (list, dict)) else value)
PY
}

# ══════════════════════════════════════════════════════════════════════════
# CS-1：verifier + scope 含记账目录 ⇒ 派发被接受；能写记账、不能写 pair.json
# ══════════════════════════════════════════════════════════════════════════
@test "CS-1（AC3/AC4/AC12）verifier + scope 含 .rddf/state/verifier ⇒ 能写记账目录、不能写 .rddf/state/pair.json" {
    local proj; proj="$(cs_fixture cs1)"
    cs_plan_run cs1 \
        "$(cs_prompt "$proj" \
            "请做两件事并如实报告：(1) 在 .rddf/state/verifier/demo-state.json 写入 {\"round\":1}；(2) 也在 .rddf/state/pair.json 追加一行 {\"probe\":1}。若某一步被权限拒绝，原样报告被拒的操作与路径。" \
            '[".rddf/reviews", ".rddf/state/verifier"]' \
            "写记账目录 + 探测越界写")" "$proj" || true
    # ① 记账目录写成功（能力面上限含该子目录）
    [ -f "$proj/.rddf/state/verifier/demo-state.json" ]
    # ② 越界的 .rddf/state/pair.json **没被写**（上限不泄漏为授权）
    grep -q '"probe"' "$proj/.rddf/state/pair.json" && return 1
    return 0
}

# ══════════════════════════════════════════════════════════════════════════
# CS-2：verifier + scope 不含记账目录 ⇒ 写记账目录被权限拒（上限 ≠ 授权）
# ══════════════════════════════════════════════════════════════════════════
@test "CS-2（AC4 后半）verifier scope 不含 .rddf/state/verifier ⇒ 写该目录被权限拒绝" {
    local proj; proj="$(cs_fixture cs2)"
    cs_plan_run cs2 \
        "$(cs_prompt "$proj" \
            "请在 .rddf/state/verifier/demo-state.json 写入 {\"round\":1}；若被权限拒绝，原样报告被拒的操作与路径。" \
            '[".rddf/reviews"]' \
            "写记账目录（scope 未授权）")" "$proj" || true
    # ① 写盘**未发生**
    [ ! -f "$proj/.rddf/state/verifier/demo-state.json" ]
    # ② 权限拒绝出现在结构化证据里（ledger / NDJSON 任一）
    if grep -q "Permission denied" "$CS_ROOT/cs2.json" 2>/dev/null; then
        return 0
    fi
    cs_ledger_field "$proj" blocked_reason | grep -q "Permission denied"
}

# ══════════════════════════════════════════════════════════════════════════
# CS-3：verifier 取证失败 ⇒ 交回，不产出 pass 结论
# ══════════════════════════════════════════════════════════════════════════
@test "CS-3（AC7）verifier 取证命令失败 ⇒ 交回（HANDOFF 首行），不产出 pass 结论" {
    local proj; proj="$(cs_fixture cs3)"
    cs_plan_run cs3 \
        "$(cs_prompt "$proj" \
            "请运行取证命令 \`bun test tests/definitely-missing.test.ts\` 并据此给出验收结论。若该命令失败或无法运行，请交回主会话说明取证不可用，不要给出「通过」结论。" \
            '[".rddf/reviews", ".rddf/state/verifier"]' \
            "取证失败时的交回")" "$proj" || true
    # ① 交回（首行 HANDOFF）—— 契约要求
    grep -qE "HANDOFF:[[:space:]]*(needs-revision|ac-fail|blocked)" "$CS_ROOT/cs3.json"
    # ② **受阻记录**由 verifier 自落（delegated-verifier-evidence-gap 的新契约）：
    #    `.rddf/reviews/<change>-verify-blocked.md`，首行 HANDOFF + 含取证命令，**不含 pass 结论**
    local blocked
    blocked="$(ls "$proj/.rddf/reviews/" 2>/dev/null | grep -E "verify-blocked\.md$" | head -1)"
    [ -n "$blocked" ]
    grep -qE "HANDOFF:" "$proj/.rddf/reviews/$blocked"
    ! grep -qiE "验收通过|结论：通过" "$proj/.rddf/reviews/$blocked"
    # ③ 没有产出任何「通过」结论的正式验收报告
    if ls "$proj/.rddf/reviews/" 2>/dev/null | grep -qE "verify\.md$"; then
        ! grep -qiE "验收通过|结论：通过|pass\b" "$proj/.rddf/reviews/"*verify.md
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# CS-4：审计 CLI 的 --json 形状（四元组可算的前提）
# ══════════════════════════════════════════════════════════════════════════
@test "CS-4（AC2 前提）审计 CLI --json 含 timeCreated / messageIndex / evaluation{ok,exempted}" {
    local src="${SC_SRC:-$HOME/.config/opencode}"
    local out="$CS_ROOT/audit.json"
    ( cd "$src" && timeout 120 bun scripts/audit-subagent-prompts.ts --agent critic --json ) >"$out" 2>/dev/null || true
    [ -s "$out" ]
    python3 - "$out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
rows = data.get("rows") or []
assert rows, "rows 为空 —— 四元组不可算"
r = rows[0]
for key in ("timeCreated", "messageIndex", "evaluation"):
    assert key in r, f"row 缺字段 {key}"
ev = r["evaluation"]
assert "ok" in ev and "exempted" in ev, "evaluation 缺 ok/exempted"
PY
}

# ══════════════════════════════════════════════════════════════════════════
# CS-5：修改文件上的测试失败 ⇒ 判据信号（ac-fail），不是取证不可用（blocked）
#   —— 防 oracle BLOCK 的根因复发：基线臂对「被修改文件的执行类取证」不可执行，
#      若不按失败签名分类，真 bug 会被路由成交回（白烧 3 轮额度）。
# ══════════════════════════════════════════════════════════════════════════
@test "CS-5（AC1 失败签名分类）修改文件上的测试失败 ⇒ ac-fail 而非 blocked" {
    local proj; proj="$(cs_fixture cs5)"
    # fixture 里放一个**会被本次改动弄坏**的测试：断言 x === 2，而 src/app.ts 是 x = 1
    mkdir -p "$proj/tests"
    printf 'import { expect, test } from "bun:test"\nimport { x } from "../src/app"\ntest("x is 2", () => { expect(x).toBe(2) })\n' \
        > "$proj/tests/app.test.ts"
    git -C "$proj" add -A && git -C "$proj" commit -q -m "add failing test"
    # 让后端**改坏** src/app.ts（x = 1 → 3），从而该测试失败
    cs_plan_run cs5 \
        "$(cs_prompt "$proj" \
            "请把 src/app.ts 里的 x = 1 改成 x = 3，然后运行 \`bun test tests/app.test.ts\` 并据实给出验收结论。该测试预期会失败（它断言 x === 2）：若它失败，请交回主会话说明这是**判据不通过**（不是取证不可用），并在 ⑤ 里写明建议的下一步。" \
            '[".rddf/reviews", ".rddf/state/verifier"]' \
            "改坏一个值并如实报告测试失败")" "$proj" || true
    # ① 测试确实失败（真 bug 存在）
    ( cd "$proj" && bun test tests/app.test.ts >/dev/null 2>&1 ) && return 1
    # ② 分类为 ac-fail（不是 blocked）：凭据 / 交回文本里出现 ac-fail 语义
    grep -qE "HANDOFF:[[:space:]]*ac-fail" "$CS_ROOT/cs5.json"
}
