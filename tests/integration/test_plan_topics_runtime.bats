#!/usr/bin/env bash
# tests/integration/test_plan_topics_runtime.bats
#
# PT-1（B1 真宿主层）：**plan agent 的权限 / shell 白名单 / 工具接线**在真宿主里
# 允许协议命令（`claim` / `close` / `check`）被执行。
#
# ── 它存在的唯一理由 ────────────────────────────────────────────────────────
# 零模型层（`test_plan_topics_cli.bats`）已经证明**CLI 契约**对；它证明不了的是：
# 真 `plan` 会话里，宿主的 permission / shell 白名单**允不允许**这些命令跑。
# ⇒ 本条只覆盖这一格，**不**重复协议逻辑（那是 L1）。
#
# ── 形态（一次性 + 变更触发）────────────────────────────────────────────────
# 用户裁决（2026-11-26）：**一次性首跑 + 变更触发**，不是「每批收尾都跑」。
#   - 首跑：本条落地时跑一次（证据落 `.rddf/reviews/plan-topics-pt1-runtime.md`）。
#   - 变更触发：只在「plan agent 权限 / shell 白名单 / 工具接线」变更的批重跑；
#     本仓 `scripts/e2e-runtime.sh` 的触发表已把 `prompts/plan*.md` 映射到本文件。
#   - 默认 skip（`E2E_REAL_RUNTIME=1` 才跑）；每次真跑吃 1 次模型会话。
#
# ── 三档判定 ────────────────────────────────────────────────────────────────
#   没有 shell 调用 ⇒ **skip（未判定）**（模型没动手，不是插件的错）
#   出现 permission 拒绝 / claim-close 未完成 ⇒ **fail**
#   全绿 ⇒ pass

load ../test_helper

pt1_enabled() { [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]; }
PT1_CASE_TIMEOUT="${PT1_CASE_TIMEOUT:-420}"
PT1_ROOT="${PT1_ROOT:-$REPO_ROOT/.tmp-pt1}"
OC_ROOT="${OC_ROOT:-$HOME/.config/opencode}"
CLI="$OC_ROOT/scripts/plan-topic-check.ts"

setup() {
    if ! pt1_enabled; then
        skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    export TMPDIR="$PT1_ROOT"
    IB_ROOT="$PT1_ROOT"
    export IB_ROOT
    mkdir -p "$PT1_ROOT"
}

# 造 fixture：一个 topic（单节点 a1，带一个交付物）+ 真 git 仓
pt1_fixture() {
    local dest="$PT1_ROOT/proj"
    rm -rf "$dest"
    mkdir -p "$dest/.rddf/plan-topics/demo/nodes/a1"
    git -C "$dest" init -q
    git -C "$dest" config user.email "pt1@test.local"
    git -C "$dest" config user.name "PT1 Test"
    printf '# brief\n' >"$dest/.rddf/plan-topics/demo/nodes/a1/BRIEF.md"
    cat >"$dest/.rddf/plan-topics/demo/graph.json" <<'JSON'
{"version":1,"topic":"demo","nodes":[{"id":"a1","title":"任务","deps":[],"owner":"child","status":"pending","progress":"todo","attempts":[],"deliverables":["nodes/a1/RESULT.md"]}]}
JSON
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "pt1 fixture"
    printf '%s' "$dest"
}

@test "PT-1（真宿主）：plan agent 能 claim → 写产物 → close → check 收敛" {
    local proj sid topic
    proj="$(pt1_fixture)"
    topic="$proj/.rddf/plan-topics/demo"
    sid="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"

    # 提示里给**逐字命令**（不让模型自选路径/自选写法）——
    # 本条只证明「宿主放行」，不测模型创造力。
    local prompt
    prompt="在这个仓库里依次执行下面四条 shell 命令，只做这一件事，命令原样执行（不要改写路径、不要用 edit 工具）：
1) bun $CLI claim $topic a1
2) printf -- '- [x] done\n' > $topic/nodes/a1/TODO.md
3) printf '# 结论\n\n正文。\n' > $topic/nodes/a1/RESULT.md
4) bun $CLI close $topic a1
最后再执行：bun $CLI check $topic --phase final --json 并把输出贴出来。"

    ( cd "$proj" && timeout "$PT1_CASE_TIMEOUT" opencode run --agent plan \
        --session "$sid" --format json "$prompt" ) >"$PT1_ROOT/pt1.json" 2>"$PT1_ROOT/pt1.err"
    local rc=$?
    printf 'exit_code=%s\n' "$rc" >"$PT1_ROOT/pt1.meta"
    ib_skip_if_out_of_quota "$PT1_ROOT/pt1.err"
    ib_skip_if_timeout pt1

    local cmds
    cmds="$(ib_shell_commands "$PT1_ROOT/pt1.json")"
    if [ -z "$cmds" ]; then
        skip "模型没有发起任何 shell 调用 ⇒ 宿主接线未被测到（未判定）：见 $PT1_ROOT/pt1.json"
    fi

    # ① 协议命令真的被执行（不是只被"看到"）
    grep -qF "plan-topic-check.ts claim" <<<"$cmds" || {
        echo "① 失败：没有执行 claim ⇒ plan 的 shell 白名单可能不放行协议命令" >&2
        echo "$cmds" >&2
        return 1
    }
    grep -qF "plan-topic-check.ts close" <<<"$cmds" || {
        echo "① 失败：没有执行 close" >&2
        echo "$cmds" >&2
        return 1
    }

    # ② 没有被 permission 拒绝（否则说明「宿主放行」不成立）
    local errs; errs="$(ib_tool_errors "$PT1_ROOT/pt1.json")"
    if grep -qiE "cannot ask the user for permission|permission denied|not permitted|EACCES" <<<"$errs"; then
        echo "② 失败：协议命令被 permission 拒绝 ⇒ plan 的 shell 白名单不放行" >&2
        echo "$errs" >&2
        return 1
    fi

    # ③ 状态真的推进了：attempt 已闭合 + 节点派生 done + 收敛
    python3 - "$topic" <<'PY'
import json, sys, os
topic = sys.argv[1]
g = json.load(open(os.path.join(topic, "graph.json")))
n = [x for x in g["nodes"] if x["id"] == "a1"][0]
att = n.get("attempts") or []
assert len(att) == 1, f"attempt 数应为 1，实际 {len(att)}"
assert att[0].get("finished_at"), "attempt 未闭合（close 没生效）"
assert att[0].get("input"), "attempt 缺 input 快照"
PY
    [ $? -eq 0 ] || return 1

    # ④ 收敛（harness 侧独立复算，不采信模型的自然语言）
    run bun "$CLI" check "$topic" --phase final --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"converged":true'
}
