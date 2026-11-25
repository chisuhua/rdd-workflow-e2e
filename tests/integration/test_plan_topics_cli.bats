#!/usr/bin/env bash
# tests/integration/test_plan_topics_cli.bats
#
# 零模型层（不依赖模型 / 宿主）：plan-topics CLI 契约的**运行时**用例。
# 覆盖 ADR `plan-multi-session-collaboration` 的三条判据的**行为面**（L1 已有单测）：
#
#   PT-2（D9 取消语义）`cancel <node> --reason … --cascade`
#        ⇒ 目标节点与其**活跃下游**一并 `cancelled`；上游不受影响
#   PT-3（D10 在飞）`claim` 之后：该节点**不在** `ready` ∧ `ready --json` 的 `in_flight` 含它
#        ∧ `check --phase final` exit 0（在飞不是阻断项）
#   PT-4（锁无关）留一个**未释放**的 topic 写锁 ⇒ `check` 仍 `converged === true`
#        且 `graph.json` **逐字节不变**（读路径不碰锁、不写盘）
#
# ── 前置与门控（诚实口径）──────────────────────────────────────────────────
# 本文件**不是** `E2E_REAL_RUNTIME` 门控：它不需要模型。但它需要
#   ① `OC_ROOT`（默认 `$HOME/.config/opencode`）里的 `scripts/plan-topic-check.ts`
#   ② `bun`（CLI 以 bun 运行）
# 两者任一缺失 ⇒ **显式 skip 且给出原因**（不假装通过）。
#
# ⚠ **当前 e2e CI 不满足这两个前置**：`install_testbed.sh --clone` 只安装
#   `rdd-workflow`，没有 opencode 配置仓；CI 也没有装 bun。
#   ⇒ 本文件今天在 CI 里会 **skip**（= 零判别力），它的价值在**本地**
#     （改 `scripts/plan-topic-check.ts` 输出契约后本地能立刻发现）。
#   要让它在 CI 真跑，需在 `.github/workflows/test.yml` 增加
#   「clone opencode 配置仓 + 安装 bun」两步 —— 已登记为 L2 跟踪项
#   （见本仓 `.rddf/improvements/runtime-e2e-coverage-new-mechanisms.md`）。
#
# ── 手动运行 ───────────────────────────────────────────────────────────────
#   bats tests/integration/test_plan_topics_cli.bats
#   OC_ROOT=/path/to/opencode bats tests/integration/test_plan_topics_cli.bats
#   单例筛选：bats --filter 'PT-3' …

load ../test_helper

OC_ROOT="${OC_ROOT:-$HOME/.config/opencode}"
CLI="$OC_ROOT/scripts/plan-topic-check.ts"

# 在 fixture 仓里跑 CLI（repoRootOf 依赖 git 根 ⇒ 必须以仓库内 cwd 调用）
pt() { ( cd "$WORK" && bun "$CLI" "$@" ); }

# 从 graph.json 读一个字段：node_ids / cancelled_ids
graph_query() {
    bun -e '
const fs = require("node:fs")
const g = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const q = process.argv[2]
if (q === "cancelled_ids") console.log(g.nodes.filter((n) => n.cancelled).map((n) => n.id).sort().join(","))
else if (q === "cancelled_at") console.log(String(g.nodes.find((n) => n.id === process.argv[3])?.cancelled?.at ?? ""))
else if (q === "attempts") console.log(String(g.nodes.find((n) => n.id === process.argv[3])?.attempts?.length ?? -1))
else { console.error("unknown query: " + q); process.exit(2) }
' "$TOPIC/graph.json" "$@"
}

# 从 stdin 的 JSON 里取字段（用于断言 CLI 的 --json 输出）
json_query() {
    bun -e '
let raw = ""
process.stdin.on("data", (d) => (raw += d)).on("end", () => {
  const o = JSON.parse(raw)
  const q = process.argv[1]
  if (q === "ready_has") console.log(String(o.ready.includes(process.argv[2])))
  else if (q === "inflight_has") console.log(String(o.in_flight.some((x) => x.node === process.argv[2])))
  else if (q === "converged") console.log(String(o.converged))
  else { console.error("unknown query: " + q); process.exit(2) }
})
' "$@"
}

node_json() { # node_json <id> <deps-json> [done]
    # ⚠ done 节点**必须**至少有一个真实存在的交付物（`deliverablesOk` 要求
    #   `length > 0` 且每个都非空）⇒ 否则派生永远是 pending（cache_ahead）。
    if [[ "${3:-}" == "done" ]]; then
        printf '{"id":"%s","title":"任务","deps":%s,"owner":"child","status":"done","progress":"complete","attempts":[],"deliverables":["nodes/%s/RESULT.md"]}' "$1" "${2:-[]}" "$1"
    else
        printf '{"id":"%s","title":"任务","deps":%s,"owner":"child","status":"pending","progress":"todo","attempts":[],"deliverables":[]}' "$1" "${2:-[]}"
    fi
}

write_graph() { printf '{"version":1,"topic":"demo","nodes":[%s]}\n' "$1" >"$TOPIC/graph.json"; }

write_brief() {
    mkdir -p "$TOPIC/nodes/$1"
    printf '# brief\n' >"$TOPIC/nodes/$1/BRIEF.md"
}

setup() {
    if [[ ! -f "$CLI" ]]; then
        skip "OC_ROOT 无 scripts/plan-topic-check.ts（$CLI）—— 本用例需要 opencode 配置仓"
    fi
    if ! command -v bun >/dev/null 2>&1; then
        skip "bun 不可用 —— plan-topic-check 以 bun 运行"
    fi
    WORK="$BATS_TEST_TMPDIR/repo"
    export WORK
    mkdir -p "$WORK/.rddf/plan-topics/demo/nodes"
    git -C "$WORK" init -q
    git -C "$WORK" config user.email t@example.com
    git -C "$WORK" config user.name t
    TOPIC="$WORK/.rddf/plan-topics/demo"
    export TOPIC
}

@test "PT-2（D9）cancel --cascade：目标与活跃下游一并 cancelled，上游不动" {
    write_graph "$(node_json a1),$(node_json a2 '["a1"]'),$(node_json a3 '["a2"]')"
    for n in a1 a2 a3; do write_brief "$n"; done

    run pt cancel "$TOPIC" a2 --reason "级联自 a1" --cascade
    [ "$status" -eq 0 ]

    # 活跃下游（a2 → a3）都被取消；上游 a1 不动
    run graph_query cancelled_ids
    [ "$output" = "a2,a3" ]

    # 取消**必须留理由**（D9 的 cancelled_unattributed 判据）：理由原样落盘
    run bun -e '
const fs = require("node:fs")
const g = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const n = g.nodes.find((x) => x.id === "a2")
console.log(JSON.stringify({ by: n.cancelled?.by, reason: n.cancelled?.reason }))
' "$TOPIC/graph.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"by":"parent"'
    echo "$output" | grep -q '"reason":"级联自 a1"'
}

@test "PT-3（D10）claim 后在飞：不在 ready ∧ in_flight 含它 ∧ check --phase final exit 0" {
    write_graph "$(node_json a1)"
    write_brief a1

    run pt claim "$TOPIC" a1
    [ "$status" -eq 0 ]

    run pt ready "$TOPIC" --json
    [ "$status" -eq 0 ]
    run json_query ready_has a1 <<<"$output"
    [ "$output" = "false" ]

    run pt ready "$TOPIC" --json
    run json_query inflight_has a1 <<<"$output"
    [ "$output" = "true" ]

    # 在飞不是阻断项 ⇒ final 阶段仍 exit 0
    run pt check "$TOPIC" --phase final
    [ "$status" -eq 0 ]
}

@test "PT-4（锁无关）未释放的写锁不影响 check：converged 且 graph.json 逐字节不变" {
    # 全终态 topic（done）⇒ converged 的前提成立
    write_graph "$(node_json a1 '[]' done)"
    mkdir -p "$TOPIC/nodes/a1"
    printf '# brief\n' >"$TOPIC/nodes/a1/BRIEF.md"
    printf -- '- [x] done\n' >"$TOPIC/nodes/a1/TODO.md"
    printf '# 结论\n\n正文。\n' >"$TOPIC/nodes/a1/RESULT.md"

    # 留一个**未释放**的写锁（fresh created_at ⇒ 不会被当成陈旧回收）
    LOCK="$WORK/.rddf/state/plan-topics/demo.graph.lock"
    mkdir -p "$LOCK"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$LOCK/created_at"
    printf 'test\n' >"$LOCK/owner"

    before="$(sha256sum "$TOPIC/graph.json" | cut -d' ' -f1)"

    run pt check "$TOPIC" --json
    [ "$status" -eq 0 ]
    run json_query converged <<<"$output"
    [ "$output" = "true" ]

    after="$(sha256sum "$TOPIC/graph.json" | cut -d' ' -f1)"
    [ "$before" = "$after" ]

    # check 是读路径：不得顺手删别人的锁
    [ -d "$LOCK" ]
}
