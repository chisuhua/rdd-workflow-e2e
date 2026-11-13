#!/usr/bin/env bats
# tests/integration/test_role_class_runtime.bats
#
# 运行时 E2E：派发能力类 `role_class` 的类边界（`ADR-backend-handoff-role-class` D3 修订：
# builder 上限 = `scope` − `archRoots`，两级规则）。
#
# ── 门控 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 4 条用例真正执行（需要真实模型 + 真实宿主）。
#
# ── 手动运行 ───────────────────────────────────────────────────────────────
#   mkdir -p "$PWD/.tmp-l2"
#   E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-l2" \
#     bats tests/integration/test_role_class_runtime.bats
#
#   单例筛选：bats --filter 'RC-1' …
#   额度不足时与 L2 同一手法：L2_FRONT_MODEL 不适用本文件（这里驱动的是 plan）；
#   如需换模型：RC_PLAN_MODEL=provider/model
#
# ── 被测契约（每条用例一句话）──────────────────────────────────────────────
#   RC-1（AC24）builder + scope **落在** arch 目录内 ⇒ 派发被拒，**不建 session**，ADR 不变。
#   RC-2（AC25）builder + scope 是 arch 祖先（`.`）⇒ 派发放行；后端写 ADR 被 **权限拒绝**，
#               ADR 保持不变、feedback 凭据落盘（交回），其余改动照常完成。
#   RC-3（AC21）同 RC-2 但 `rddf` 不可用 ⇒ 无 feedback 凭据（文本兜底），ADR 仍不变。
#   RC-4（AC14）architect 类 + oracle/critic 不可用 ⇒ **不得自审自批**：ADR 保持 `Status: Draft`
#               （不出现 Accepted），并以 feedback 凭据交回。
#
# ── 断言优先级（与 test_front_delegate_runtime.bats 同约定）──────────────────
#   ① 文件系统事实（工程文件内容 / pair.json / ledger.jsonl / improvement 的 Feedback 段）
#   ② NDJSON 的结构化字段（delegate 工具事件的 error / outcome / changed_files）
#   ③ **不断言模型自然语言措辞**（模型措辞不稳定）。RC-1 的 `scope 项落在架构文档目录内`
#      是本仓代码的**错误文案**（确定性），不属模型措辞。
#
# ── 前置（踩过的坑，沿用 L2 结论）──────────────────────────────────────────
#   - fixture 必须落在**仓库外**且位于 /workspace 下（external_directory 放行面）
#   - fixture 的 .rddf/state/{pair,role}.json 必须是干净的（本文件每次重建 fixture）
#   - 每次真实运行必须带 `--session <new-id>`（否则延续上一轮上下文）
#   - 需要环境隔离的用例（RC-3 / RC-4）用 `--standalone`：常驻 server 拿不到本次 export

load ../test_helper

rc_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

RC_CASE_TIMEOUT="${RC_CASE_TIMEOUT:-420}"
RC_ROOT="${RC_ROOT:-$REPO_ROOT/.tmp-l2}"
RC_FIXTURE_ROOT="${RC_FIXTURE_ROOT:-/workspace/main/rdd-workflow-e2e-rc}"

setup() {
    if ! rc_enabled; then
        skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    export TMPDIR="$RC_ROOT"
    mkdir -p "$RC_ROOT" "$RC_FIXTURE_ROOT"
}

teardown() {
    :
}

# ── fixture：与 rdd-workflow-e2e 无关的**最小独立工程**（不复制本仓）──────────
# 需要：docs/adr（arch root）+ src（非 arch 路径）+ .rddf/improvements（feedback 落点）
rc_fixture() {
    local name="$1"
    local dest="$RC_FIXTURE_ROOT/$name"
    local marker="$RC_FIXTURE_ROOT/${name}.rc-owner"
    mkdir -p "$RC_FIXTURE_ROOT"
    # 只删自己造过的目录（有 marker）；没有 marker 就换一个带时间戳的新目录
    if [ -d "$dest" ] && [ -f "$marker" ]; then
        rm -rf "$dest"
    elif [ -d "$dest" ]; then
        dest="$RC_FIXTURE_ROOT/${name}-$(date +%s)"
        marker="$dest.rc-owner"
    fi
    mkdir -p "$dest/docs/adr" "$dest/src" "$dest/.rddf/improvements"
    printf '# ADR-demo\n\nStatus: Draft\n\n## 决策\n\nD1: 初始决策。\n' > "$dest/docs/adr/ADR-demo.md"
    printf 'export const x = 1\n' > "$dest/src/app.ts"
    printf '# demo-change\n\n## Why\n\n演示用改进草稿。\n\n## What Changes\n\n无。\n\n## Acceptance\n\nAC1 演示。\n' \
        > "$dest/.rddf/improvements/demo-change.md"
    git -C "$dest" init -q
    git -C "$dest" config user.email "rc@test.local"
    git -C "$dest" config user.name "RC Test"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "rc fixture"
    printf 'rc-owned\n' > "$marker"
    printf '%s' "$dest"
}

# ── 真实 plan 运行（delegate 的放行主体）──────────────────────────────────────
# rc_plan_run <tag> <prompt> <cwd> [extra opencode args...]
rc_plan_run() {
    local name="$1"; shift
    local prompt="$1"; shift
    local cwd="$1"; shift
    local sid out err rc
    sid="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
    out="$RC_ROOT/${name}.json"; err="$RC_ROOT/${name}.err"
    local model_args=()
    [ -n "${RC_PLAN_MODEL:-}" ] && model_args=(--model "$RC_PLAN_MODEL")
    ( cd "$cwd" && timeout "$RC_CASE_TIMEOUT" opencode run --agent plan \
        --session "$sid" --format json "${model_args[@]}" "$@" "$prompt" ) >"$out" 2>"$err"
    rc=$?
    printf 'exit_code=%s\nstdout=%s\nstderr=%s\ncwd=%s\n' "$rc" "$out" "$err" "$cwd" > "$RC_ROOT/${name}.meta"
    return $rc
}

# 委托指令：写死绝对路径 + 只做这一件事 + 参数逐字给（L2 §8.1/§8.2 的结论）
rc_prompt() {
    local project="$1" task="$2" goal="$3" scope="$4" acceptance="$5" role_class="$6"
    cat <<EOF
请只做一件事：调用 **delegate** 工具派发一个工程后端，参数严格如下（不要改写、不要追加、不要自行实现）：
- project_dir: $project
- agent: build
- task: $task
- goal: $goal
- scope: $scope
- acceptance: $acceptance
- role_class: $role_class
- plan_ref: $project/.rddf/improvements/demo-change.md
派发完成后，把 delegate 的返回值原样贴出（尤其 outcome / blocked_reason / changed_files）。
若 delegate 被拒，把错误原文贴出，不要改用 subagent 绕过，也不要重试。
EOF
}

# ── 观测：pair.json 里某字段 ────────────────────────────────────────────────
rc_pair_field() {
    local project="$1" field="$2"
    python3 - "$project/.rddf/state/pair.json" "$field" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for entry in (data.get("pairs") or {}).values():
    print(entry.get(sys.argv[2], ""))
    break
PY
}

# ledger 最后一行某字段
rc_ledger_field() {
    local project="$1" field="$2"
    python3 - "$project/.rddf/state/ledger.jsonl" "$field" <<'PY' 2>/dev/null || true
import json, sys
rows = []
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
# RC-1（AC24）：builder + scope 落在 arch 目录内 ⇒ 派发被拒（不建 session）
# ══════════════════════════════════════════════════════════════════════════
@test "RC-1（AC24）builder + scope 落在 docs/adr ⇒ 派发被拒、不建 session、ADR 不变" {
    local proj; proj="$(rc_fixture rc1)"
    rc_plan_run rc1 \
        "$(rc_prompt "$proj" "把 docs/adr/ADR-demo.md 的 D1 改成「新的决策」，再把 src/app.ts 的 x 改成 2。" \
            "改 ADR 再实现" '["docs/adr", "src"]' "src/app.ts 导出 x = 2" "builder")" "$proj" || true
    # ① 没有登记、没有台账 ⇒ 后端 session 根本没建
    [ ! -f "$proj/.rddf/state/pair.json" ]
    [ ! -f "$proj/.rddf/state/ledger.jsonl" ]
    # ② 拒绝来自本仓的类边界校验（确定性错误文案，不是模型措辞）
    grep -q "scope 项落在架构文档目录内" "$RC_ROOT/rc1.json"
    # ③ ADR 未被改动
    grep -q "D1: 初始决策。" "$proj/docs/adr/ADR-demo.md"
}

# ══════════════════════════════════════════════════════════════════════════
# RC-2（AC25）：builder + scope "."（宽目标）⇒ 放行，但 arch 路径被权限拒绝
# ══════════════════════════════════════════════════════════════════════════
@test "RC-2（AC25）builder + scope '.' ⇒ 派发放行；写 ADR 被拒、ADR 不变、feedback 落盘" {
    local proj; proj="$(rc_fixture rc2)"
    rc_plan_run rc2 \
        "$(rc_prompt "$proj" "请把 docs/adr/ADR-demo.md 的 D1 改成「新的决策」，然后把 src/app.ts 的 x 改成 2。" \
            "改 ADR 再实现（宽 scope）" '["."]' "src/app.ts 导出 x = 2" "builder")" "$proj" || true
    # ① 派发成功且登记类正确
    [ -f "$proj/.rddf/state/pair.json" ]
    [ "$(rc_pair_field "$proj" role_class)" = "builder" ]
    # ② ADR 未被改动（权限层 deny 生效）
    grep -q "D1: 初始决策。" "$proj/docs/adr/ADR-demo.md"
    # ③ 非 arch 路径的改动照常完成（证明不是「整个后端被卡死」）
    grep -q "x = 2" "$proj/src/app.ts"
    # ④ 交回凭据落盘（rddf 可用）
    grep -q "Feedback" "$proj/.rddf/improvements/demo-change.md"
    # ⑤ ledger 记录的是权限拒绝（结构化事实）
    rc_ledger_field "$proj" blocked_reason | grep -q "Permission denied"
}

# ══════════════════════════════════════════════════════════════════════════
# RC-3（AC21）：rddf 不可用 ⇒ 无凭据落盘（文本兜底），ADR 仍不变
# ══════════════════════════════════════════════════════════════════════════
@test "RC-3（AC21）rddf 不可用 ⇒ 无 feedback 凭据、ADR 仍不变（文本兜底不新造落点）" {
    local proj; proj="$(rc_fixture rc3)"
    # 只把 rddf 所在目录（~/.local/bin）踢出 PATH，保留 opencode 自身
    PATH="/home/ubuntu/.opencode/bin:/usr/bin:/bin" \
    rc_plan_run rc3 \
        "$(rc_prompt "$proj" "请把 docs/adr/ADR-demo.md 的 D1 改成「新的决策」，然后把 src/app.ts 的 x 改成 2。" \
            "改 ADR 再实现（rddf 不可用）" '["."]' "src/app.ts 导出 x = 2" "builder")" "$proj" --standalone || true
    # ① 派发仍成立
    [ -f "$proj/.rddf/state/pair.json" ]
    # ② ADR 仍未被改动（类边界不依赖 rddf）
    grep -q "D1: 初始决策。" "$proj/docs/adr/ADR-demo.md"
    # ③ **没有** feedback 段（rddf 写不进 ⇒ 不新造落点）
    ! grep -q "Feedback" "$proj/.rddf/improvements/demo-change.md"
    # ④ 权限拒绝仍是结构化证据
    rc_ledger_field "$proj" blocked_reason | grep -q "Permission denied"
}

# ══════════════════════════════════════════════════════════════════════════
# RC-4（AC14）：architect 类 + 审查者不可用 ⇒ 不得自审自批
# ══════════════════════════════════════════════════════════════════════════
@test "RC-4（AC14）architect + oracle/critic 不可用 ⇒ ADR 保持 Draft（不自审自批）+ 交回凭据" {
    local proj; proj="$(rc_fixture rc4)"
    # 把 oracle / critic 降为 primary ⇒ 内核拒绝它们作为 subagent（等价「审查者不可用」）
    local cfg="$RC_ROOT/rc4-no-reviewers.json"
    printf '{"agent":{"oracle":{"mode":"primary"},"critic":{"mode":"primary"}}}' > "$cfg"
    OPENCODE_CONFIG="$cfg" \
    rc_plan_run rc4 \
        "$(rc_prompt "$proj" "请起草一份 ADR（主题：demo 架构决策），跑 oracle 与 critic 审查，BLOCKER 全闭后把 Status 转 Accepted，并把审稿报告写到 .rddf/reviews/。" \
            "写 ADR 并跑 oracle→critic（审查者不可用）" '["docs/adr", ".rddf/reviews"]' \
            "ADR 含四要素、双审闭合、Status=Accepted、审稿报告落 .rddf/reviews/" "architect")" "$proj" --standalone || true
    # ① ADR 存在但**没有**被签成 Accepted（这是本用例的核心判据）
    #    两种元数据形态都要挡：YAML 头 `Status: Accepted` 与表格 `| Status | Accepted |`
    [ -f "$proj/docs/adr/ADR-demo.md" ]
    ! grep -qE "Status[[:space:]]*[:|][[:space:]]*\**[[:space:]]*Accepted" "$proj/docs/adr/ADR-demo.md"
    # ② 交回凭据落盘（rddf 可用 ⇒ 走 feedback 通道）
    grep -q "Feedback" "$proj/.rddf/improvements/demo-change.md"
    # ③ 登记类正确（architect）
    [ "$(rc_pair_field "$proj" role_class)" = "architect" ]
}
