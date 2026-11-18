#!/usr/bin/env bats
# tests/integration/test_role_gate_runtime.bats
#
# 运行时 E2E：**角色感知写门 + 角色租约**（`openspec/changes/role-aware-permissions/`，
# 判据真源 `docs/adr/ADR-role-aware-permissions.md` D2/D6 + `ADR-role-session-identity.md` D1）。
#
# ── 门控 ────────────────────────────────────────────────
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 8 条用例真正执行（需要真实模型 + 真实宿主）：
#                             其中 RG-5 不驱动模型（纯 git worktree + role-switch.sh）。
#
# ── 手动运行 ──────────────────────────────────────────────
#   mkdir -p "$PWD/.tmp-rg"
#   E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-rg" \
#     bats tests/integration/test_role_gate_runtime.bats
#   单例筛选：bats --filter 'RG-1' …
#   换模型：RG_MAIN_MODEL=provider/model（默认用配置里的 build 模型）
#
# ── 被测契约（每条一句话）─────────────────────────────────────────
#   RG-1（AC18）主会话持 `builder` 租约 ⇒ 派 `role_class=builder` 后端**被拒**，错误指名持有者，不产生新槽位。
#   RG-2（AC19）主会话持 `architect` 租约 ⇒ 派 `role_class=verifier` 后端**放行**（异角色并行）。
#   RG-3（AC21）B 接管 builder 租约后，旧持有者 A 的写类调用**被拒**（指名 B）。
#   RG-4（AC1） 同一 worktree 两会话各读各分区：A=builder 写 `src/**` 成功；B=verifier 写同路径**被拒**。
#   RG-5（AC10）linked worktree 内切角色 ⇒ 写到**主仓** `stateRoot`，worktree 副本不存在。
#   RG-6（AC11）`architect` 主会话写 `src/**` ⇒ **真 Tool.Error**，文件未创建。
#   RG-7（AC17）真后端（`parentID != null`）**不受**门控：`role_class=builder` 后端写 scope 内文件成功。
#   RG-8（AC17）**非 build 主会话**（plan）不参与门控：同一份 edit 权限下写 `src/**` 不被角色门拦。
#
# ── 断言口径 ──────────────────────────────────────────────
#   只断言**结构化事实**：NDJSON 里 tool part 的 `state.error` 文本（本仓代码的错误文案，确定性）、
#   文件是否落盘、`role-claims.json` / `pair.json` 的字段。**不断言模型自然语言措辞**。
#
# ── 已知边界（不是缺陷）─────────────────────────────────────
#   - 用 `--auto` 免掉交互式 ask（脚本化必须）；⇒ 本文件**不证明** ask 档有效（那是层 1a 守卫的事）。
#   - RG-8 与「插件根本没加载」在**结果上**同形 ⇒ 必须与 RG-6 成对读（同配置下 RG-6 必红）。
#   - 插件按 D5⑥ 需宿主加载：本文件用 `--standalone` 让每次运行**自己**加载 `~/.config/opencode/plugins/`。

load ../test_helper

rg_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

RG_CASE_TIMEOUT="${RG_CASE_TIMEOUT:-420}"
RG_ROOT="${RG_ROOT:-$REPO_ROOT/.tmp-rg}"
RG_FIXTURE_ROOT="${RG_FIXTURE_ROOT:-/workspace/main/rdd-workflow-e2e-rg}"
# 被测配置根（插件 + role-switch.sh 都在这里）
OC_ROOT="${OC_ROOT:-$HOME/.config/opencode}"

setup() {
    if ! rg_enabled; then
        skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    export TMPDIR="$RG_ROOT"
    mkdir -p "$RG_ROOT" "$RG_FIXTURE_ROOT"
}

teardown() {
    :
}

# ── fixture：最小独立 git 工程（docs/adr + src + .rddf/state）────────────────
# ⚠ 落在**仓库外**且位于 /workspace 下（external_directory 放行面；沿用 L2 结论）。
rg_fixture() {
    local name="$1"
    local dest="$RG_FIXTURE_ROOT/$name"
    local marker="$RG_FIXTURE_ROOT/${name}.rg-owner"
    mkdir -p "$RG_FIXTURE_ROOT"
    if [ -d "$dest" ] && [ -f "$marker" ]; then
        rm -rf "$dest"
    elif [ -d "$dest" ]; then
        dest="$RG_FIXTURE_ROOT/${name}-$(date +%s)"
    fi
    mkdir -p "$dest/docs/adr" "$dest/src" "$dest/.rddf/state" "$dest/.rddf/improvements"
    printf '# ADR-demo\n\nStatus: Draft\n\n## 决策\n\nD1: 初始决策。\n' > "$dest/docs/adr/ADR-demo.md"
    printf 'export const x = 1\n' > "$dest/src/app.ts"
    printf '# demo-change\n\n## Why\n\n演示用改进草稿。\n\n## Acceptance\n\nAC1 演示。\n' \
        > "$dest/.rddf/improvements/demo-change.md"
    git -C "$dest" init -q
    git -C "$dest" config user.email "rg@test.local"
    git -C "$dest" config user.name "RG Test"
    # ⚠ 状态文件**不入库**：入库后 `git worktree add` 会把 role.json checkout 到 worktree
    #   ⇒ RG-5 的「worktree 无副本」判据会被**假阳性**（文件在不是因为写入，是因为 checkout）。
    printf '.rddf/state/\n' >> "$dest/.git/info/exclude"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "rg fixture"
    printf 'rg-owned\n' > "$marker"
    printf '%s' "$dest"
}

rg_sid() {
    printf 'ses_%s' "$(head -c 40 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
}

# ── 会话 id 引导 ────────────────────────────────────────────────────────────
# ⚠ `opencode run --session <自定义 id>` 不保证沿用该 id（实测本次生成 `ses_<12位>`）。
#   ⇒ 先跑一发**空转**拿真实 id，再把角色分区按真实 id 写进 role.json。
rg_new_session() {
    local proj="$1" agent="${2:-build}" tag
    tag="bootstrap-$(basename "$proj")"
    rg_run "$tag" "$proj" "ses_rgseed$(head -c 24 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)" \
        "$agent" "只回复两个字：OK。不要调用任何工具。" || true
    python3 - "$RG_ROOT/${tag}.json" <<'PY'
import json, sys
sids = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    sid = row.get("sessionID")
    if sid and sid not in sids:
        sids.append(sid)
assert sids, "空转运行未产出 sessionID ⇒ 无法定位真实会话"
print(sids[0])
PY
}

# ── 写分区（role-v2 真实形状；`legacy` 保持无毫秒）──────────────────────────
# rg_role_json <proj> <sid>:<role> [<sid>:<role> ...]
rg_role_json() {
    local proj="$1"; shift
    python3 - "$proj/.rddf/state/role.json" "$@" <<'PY'
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
doc = {
    "current_role": "general",
    "updated_at": "2026-11-17T00:00:00.000Z",
    "updated_by": "user",
    "session_id": None,
    "auto_switch_window": None,
    "history": [],
    "schema_version": "role-v2",
    "sessions": {"legacy": {"current_role": "general", "auto_switch_window": None,
                            "auto_answer": None, "updated_at": "2026-11-05T16:01:58Z"}},
}
for p in pairs:
    sid, role = p.split(":", 1)
    doc["sessions"][sid] = {"current_role": role, "auto_switch_window": None,
                            "auto_answer": None, "updated_at": "2026-11-17T00:00:00.000Z"}
json.dump(doc, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
}

# ── 真实运行（NDJSON 落盘 + meta）──────────────────────────────────────────
# rg_run <tag> <cwd> <sid> <agent> <prompt>
rg_run() {
    local tag="$1" cwd="$2" sid="$3" agent="$4" prompt="$5"
    local out="$RG_ROOT/${tag}.json" err="$RG_ROOT/${tag}.err" rc
    local model_args=()
    [ -n "${RG_MAIN_MODEL:-}" ] && model_args=(--model "$RG_MAIN_MODEL")
    ( cd "$cwd" && timeout "$RG_CASE_TIMEOUT" opencode run --standalone --auto \
        --agent "$agent" --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err"
    rc=$?
    printf 'exit_code=%s\nstdout=%s\nstderr=%s\ncwd=%s\n' "$rc" "$out" "$err" "$cwd" > "$RG_ROOT/${tag}.meta"
    return $rc
}

# ── 工具层错误（结构化：只取 tool part 的 state.error）──────────────────────
rg_tool_errors() {
    python3 - "$1" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    part = row.get("part") or {}
    if part.get("type") != "tool":
        continue
    st = part.get("state") or {}
    err = st.get("error") or ""
    if st.get("status") == "error" or err:
        print(f"{part.get('tool')}|{err}")
PY
}

# ── claims 字段（`<workRoot>|<role>` 那条）──────────────────────────────────
rg_claim_field() {
    python3 - "$1/.rddf/state/role-claims.json" "$2" "$3" <<'PY'
import json, os, sys
path, work_root, field = sys.argv[1], os.path.realpath(sys.argv[2]), sys.argv[3]
try:
    doc = json.load(open(path))
except Exception:
    raise SystemExit
for key, c in (doc.get("claims") or {}).items():
    if key.startswith(work_root + "|"):
        print(c.get(field, ""))
PY
}

rg_with_claims() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys
path, work_root, sid, gen = sys.argv[1], os.path.realpath(sys.argv[2]), sys.argv[3], int(sys.argv[4])
try:
    doc = json.load(open(path))
except Exception:
    doc = {"schema_version": "role-claims-v1", "claims": {}, "holders": {}}
key = f"{work_root}|builder"
doc.setdefault("claims", {})[key] = {
    "work_root": work_root, "role": "builder", "session_id": sid, "kind": "main",
    "claim_gen": gen, "state": "active",
    "acquired_at": "2026-11-17T00:00:00.000Z", "heartbeat_at": "2026-11-17T00:00:00.000Z",
}
doc.setdefault("holders", {})[sid] = {"work_root": work_root, "role": "builder", "claim_gen": gen}
json.dump(doc, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
}

# ── 派发指令（只派发，不自行实现）──────────────────────────────────────────
rg_prompt() {
    local project="$1" role_class="$2" scope="${3:-[\"src\"]}"
    # ⚠ **单行短提示**：多行长提示会让驱动模型长时间无输出（层 2 实测 420s 超时），
    #   而本文件只需要它**照参数调用一次** delegate。
    printf '调用 delegate 工具一次，参数：project_dir=%s, agent=build, task=在 scope 内落一个文件, goal=验证角色租约与写门, scope=%s, acceptance=scope 内出现新文件, role_class=%s, base=%s, plan_ref=%s/.rddf/improvements/demo-change.md。把返回值或错误原文贴出，不要重试。' \
        "$project" "$scope" "$role_class" "$(git -C "$project" rev-parse HEAD)" "$project"
}

# ════════════════════════════════════════════════════════
# RG-1（AC18）：同角色派发被拒
# ════════════════════════════════════════════════════════
@test "RG-1（AC18）主会话持 verifier 租约 ⇒ 派 role_class=verifier 后端被拒 + 指名持有者" {
    local proj sid_main
    proj="$(rg_fixture rg1)"
    # ⚠ 驱动 agent 必须是 **plan**（`delegate` 只对 plan/front 开；build 是 deny）
    sid_main="$(rg_new_session "$proj" plan)"
    rg_role_json "$proj" "$sid_main:verifier"
    # harness 占租约（与「主会话切换角色」等价：同一 workRoot、kind=main）
    ( cd "$proj" && OPENCODE_SESSION_ID="$sid_main" bash "$OC_ROOT/scripts/role-switch.sh" verifier ) >/dev/null
    # 前置：租约真的落成了（否则下面的「被拒」不是租约造成的）
    [ "$(rg_claim_field "$proj" "$proj" state)" = "active" ]
    [ "$(rg_claim_field "$proj" "$proj" session_id)" = "$sid_main" ]

    rg_run rg1 "$proj" "$sid_main" plan "$(rg_prompt "$proj" verifier '[".rddf/reviews"]')" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg1.json")"
    printf '%s\n' "$errs"
    # ① 工具层报错，且是**租约**拒绝（本仓文案，确定性）
    printf '%s' "$errs" | grep -q 'delegate|'
    printf '%s' "$errs" | grep -q '角色租约冲突'
    # ② 指名持有者（诊断可用性：错误里必须有持有者 sid）
    printf '%s' "$errs" | grep -q "$sid_main"
    # ③ 未产生新槽位（拒绝发生在登记之前）
    local n; n="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get("pairs") or {}))' "$proj/.rddf/state/pair.json" 2>/dev/null || echo 0)"
    [ "$n" = "0" ]
}

# ════════════════════════════════════════════════════════
# RG-2（AC19）：异角色并行放行
# ════════════════════════════════════════════════════════
@test "RG-2（AC19）主会话持 architect 租约 ⇒ 派 role_class=verifier 后端放行" {
    local proj sid_main
    proj="$(rg_fixture rg2)"
    sid_main="$(rg_new_session "$proj" plan)"
    rg_role_json "$proj" "$sid_main:architect"
    ( cd "$proj" && OPENCODE_SESSION_ID="$sid_main" bash "$OC_ROOT/scripts/role-switch.sh" architect ) >/dev/null

    rg_run rg2 "$proj" "$sid_main" plan "$(rg_prompt "$proj" verifier '[".rddf/reviews"]')" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg2.json")"
    # ① 工具层无错误（不出现「角色租约冲突」）
    ! printf '%s' "$errs" | grep -q '角色租约冲突'
    # ② 登记真的发生了（放行 ⇒ 槽位被占；`role_class` 沿登记值）
    [ "$(rg_claim_field "$proj" "$proj" state 2>/dev/null | head -1)" != "active" ] || true
    python3 - "$proj/.rddf/state/pair.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
pairs = doc.get("pairs") or {}
assert pairs, "派发放行 ⇒ pair.json 必须有登记"
assert any(e.get("role_class") == "verifier" for e in pairs.values()), f"role_class 未沿登记值：{pairs}"
PY
}

# ════════════════════════════════════════════════════════
# RG-3（AC21）：接管后旧持有者的写类调用被拒
# ════════════════════════════════════════════════════════
@test "RG-3（AC21）B 接管 builder 租约后，A 的写类调用被拒（指名 B）" {
    local proj sid_a sid_b
    proj="$(rg_fixture rg3)"
    sid_a="$(rg_new_session "$proj" build)"
    sid_b="$(rg_new_session "$proj" build)"
    rg_role_json "$proj" "$sid_a:builder" "$sid_b:builder"
    # A 持旧租约（heartbeat 落在 2026-11-17T00:00:00Z ⇒ TTL 已过 ⇒ 允许接管）
    rg_with_claims "$proj/.rddf/state/role-claims.json" "$proj" "$sid_a" 1
    # B 经唯一写入口接管（探活缺席 ⇒ TTL 兜底判死 ⇒ 直接接管 + gen+1）
    ( cd "$proj" && OPENCODE_SESSION_ID="$sid_b" bash "$OC_ROOT/scripts/role-switch.sh" builder ) >/dev/null
    [ "$(rg_claim_field "$proj" "$proj" session_id)" = "$sid_b" ]
    [ "$(rg_claim_field "$proj" "$proj" claim_gen)" = "2" ]

    # A 仍以为自己在写 ⇒ 写类调用必须被围栏拒绝
    rg_run rg3 "$proj" "$sid_a" build "只用 write 工具创建 src/a.ts，内容一行：a。不要做别的事。" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg3.json")"
    printf '%s\n' "$errs"
    printf '%s' "$errs" | grep -q 'role-gate\|role-lease'
    printf '%s' "$errs" | grep -q "$sid_b"
    [ ! -f "$proj/src/a.ts" ]
}

# ════════════════════════════════════════════════════════
# RG-4（AC1）：两会话各读各分区
# ════════════════════════════════════════════════════════
@test "RG-4（AC1）同一 worktree 两会话各读各分区：builder 写成功 / verifier 写被拒" {
    local proj sid_a sid_b
    proj="$(rg_fixture rg4)"
    sid_a="$(rg_new_session "$proj" build)"
    sid_b="$(rg_new_session "$proj" build)"
    rg_role_json "$proj" "$sid_a:builder" "$sid_b:verifier"

    rg_run rg4a "$proj" "$sid_a" build "只用 write 工具创建 src/by-builder.ts，内容一行：ok。" || true
    [ -f "$proj/src/by-builder.ts" ]

    rg_run rg4b "$proj" "$sid_b" build "只用 write 工具创建 src/by-verifier.ts，内容一行：ok。" || true
    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg4b.json")"
    printf '%s\n' "$errs"
    printf '%s' "$errs" | grep -q 'role-gate'
    printf '%s' "$errs" | grep -qi 'verifier'
    [ ! -f "$proj/src/by-verifier.ts" ]
}

# ════════════════════════════════════════════════════════
# RG-5（AC10）：linked worktree 根唯一（不驱动模型）
# ════════════════════════════════════════════════════════
@test "RG-5（AC10）linked worktree 内切角色 ⇒ 只写主仓 stateRoot，worktree 无副本" {
    local proj wt sid
    proj="$(rg_fixture rg5)"
    sid="$(rg_sid)"
    wt="$RG_FIXTURE_ROOT/rg5-wt"
    rm -rf "$wt"
    git -C "$proj" worktree add -q -b rg5-wt "$wt"

    ( cd "$wt" && OPENCODE_SESSION_ID="$sid" bash "$OC_ROOT/scripts/role-switch.sh" builder ) >/dev/null

    # ① 主仓 stateRoot 里有本会话分区
    python3 - "$proj/.rddf/state/role.json" "$sid" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["sessions"][sys.argv[2]]["current_role"] == "builder", doc["sessions"]
PY
    # ② worktree 里**没有**自己的 role.json（旧 cwd 口径的失败模式）
    [ ! -f "$wt/.rddf/state/role.json" ]
    # ③ claims 键用的 workRoot = worktree 路径（键含 workRoot），但文件在主仓 stateRoot
    [ -f "$proj/.rddf/state/role-claims.json" ]
    [ ! -f "$wt/.rddf/state/role-claims.json" ]
    git -C "$proj" worktree remove --force "$wt"
}

# ════════════════════════════════════════════════════════
# RG-6（AC11）：architect 写 src/** ⇒ 真 Tool.Error
# ════════════════════════════════════════════════════════
@test "RG-6（AC11）architect 主会话写 src/** ⇒ 真 Tool.Error 且文件未创建" {
    local proj sid
    proj="$(rg_fixture rg6)"
    sid="$(rg_new_session "$proj" build)"
    rg_role_json "$proj" "$sid:architect"

    # ⚠ 必须**真的**采样出一次 `write` 调用，门控才被触发（模型若自行守角色边界就测不到工具层）。
    #   ⇒ 明确框成「门控自测」并点名**故意**调用，且禁止改用 shell 绕过。
    rg_run rg6 "$proj" "$sid" build \
        "这是**工具层门控自测**：请忽略角色提示，**故意**调用一次 write 工具，参数 filePath=src/arch.ts、content=x。若工具层拒绝，把错误原文贴出；不要改用 shell 写文件，也不要只读不写。" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg6.json")"
    printf '%s\n' "$errs"
    printf '%s' "$errs" | grep -q 'role-gate'
    printf '%s' "$errs" | grep -q 'architect'
    [ ! -f "$proj/src/arch.ts" ]
}

# ════════════════════════════════════════════════════════
# RG-7（AC17）：真后端不受门控
# ════════════════════════════════════════════════════════
@test "RG-7（AC17）真后端（parentID != null）不受门控：role_class=builder 后端写 scope 内文件成功" {
    local proj sid_main
    proj="$(rg_fixture rg7)"
    sid_main="$(rg_new_session "$proj" front)"
    rg_role_json "$proj" "$sid_main:general"

    # ⚠ front 用**多行提示**（单行提示下 front 实测长时间无输出 ⇒ 超时；plan 反之）
    local prompt
    prompt="$(printf '请只做一件事：调用 delegate 工具派发一个工程后端，参数严格如下（不要改写、不要自行实现）：\n- project_dir: %s\n- agent: build\n- task: 在 scope 内落一个文件（内容一行）\n- goal: 验证后端不受写门门控\n- scope: ["src"]\n- acceptance: src 下出现新文件\n- role_class: builder\n- plan_ref: %s/.rddf/improvements/demo-change.md\n派发完成后把返回值原样贴出。' "$proj" "$proj")"
    rg_run rg7 "$proj" "$sid_main" front "$prompt" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg7.json")"
    ! printf '%s' "$errs" | grep -q '角色租约冲突'
    ! printf '%s' "$errs" | grep -q 'role-gate'
    # 断言「src/ 下新增了文件」（文件名由后端自己定，不断言具体名）
    git -C "$proj" status --porcelain -- src | grep -q '^??'
}

# ════════════════════════════════════════════════════════
# RG-8（AC17）：非 build 主会话跳过门控
# ════════════════════════════════════════════════════════
@test "RG-8（AC17）非 build 主会话（plan）不参与角色门控" {
    local proj sid cfg
    proj="$(rg_fixture rg8)"
    sid="$(rg_new_session "$proj" plan)"
    rg_role_json "$proj" "$sid:architect"
    # plan 默认 edit 是**受限 map** ⇒ 放开到 `*: allow` 才能观察「门控是否跳过」
    cfg="$RG_ROOT/rg8-plan-edit.json"
    printf '{"agent":{"plan":{"permission":{"edit":{"*":"allow"}}}}}' > "$cfg"

    ( cd "$proj" && OPENCODE_CONFIG="$cfg" timeout "$RG_CASE_TIMEOUT" \
        opencode run --standalone --auto --agent plan --session "$sid" --format json \
        "这是**工具层门控自测**：请**故意**调用一次 write 工具，参数 filePath=src/by-plan.ts、content=ok。不要改用 shell。" ) \
        > "$RG_ROOT/rg8.json" 2> "$RG_ROOT/rg8.err" || true

    local errs; errs="$(rg_tool_errors "$RG_ROOT/rg8.json")"
    ! printf '%s' "$errs" | grep -q 'role-gate'
    [ -f "$proj/src/by-plan.ts" ]
}
