#!/usr/bin/env bats
# tests/integration/test_front_delegate_runtime.bats
#
# L2 运行时层测试：front agent session 驱动真实工程 session。
#
# ── 门控 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 8 条用例真正执行（需要真实模型 + 真实宿主）。
#
# ── 为什么默认全 skip ──────────────────────────────────────────────────────
#   L2 需要真实 `opencode run --agent front`（真实模型 + 真实宿主），
#   既跑不进 CI（无模型 secret），也不该在普通 `bats tests/` 时被触发。
#
# ── 手动运行方式 ───────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME=1 \
#   TMPDIR="$REPO_ROOT/.tmp-l2" \
#   bats tests/integration/test_front_delegate_runtime.bats
#
#   默认 front 模型额度耗尽时（provider.rate-limit 429），用 L2_FRONT_MODEL 覆盖：
#   E2E_REAL_RUNTIME=1 L2_FRONT_MODEL=commandcode/deepseek/deepseek-v4.1-flash \
#   bats tests/integration/test_front_delegate_runtime.bats
#   （只影响 front 自己；被委托的工程 session 仍用 build agent 配置的模型）
#
#   用例清单：L2-1…L2-8（v2.3 契约）+ L2-9…L2-14（v2.5 知识获取契约）。
#   L2-7（busy）在单进程下不可达：delegate 是同步调用，见该用例内的说明。
#
#   TMPDIR 必须先 mkdir -p 且指向 /workspace 下（探针 P5 结论）：
#     - bats 会用自己的 BATS_TEST_TMPDIR 覆盖同名环境变量，无效；
#     - BATS_TMPDIR / BATS_RUN_TMPDIR 同样被 bats 覆盖，无效；
#     - 只有 TMPDIR 生效（bats 内部 `BATS_TMPDIR="${TMPDIR:-/tmp}"`）），
#       且目标目录必须已存在且可写；
#     - /workspace 根目录非本用户可写 → 只能用仓库内 .tmp-l2/。
#
# ── 额度控制 ───────────────────────────────────────────────────────────────
#   每次真实委托都会烧模型额度，因此按**场景**缓存运行结果：
#     smoke 场景由 L2-3 与 L2-4 **共用**一次真实委托；
#     其余场景（scope / grants / busy / resume）各自一次。
#   单次真实委托有独立超时（$L2_CASE_TIMEOUT，默认 300s），超时判 FAIL。
#
# ── 断言优先级（探针 P2 结论）──────────────────────────────────────────────
#   ① 文件系统事实（工程文件内容、.rddf/state/pair.json、.rddf/state/role.json）
#   ② stdout 的 tool_use 事件（NDJSON，逐行解析）
#   ③ 不断言自然语言文本 —— 模型措辞不稳定，本文件不做任何文本措辞断言。
#
# ── 实测踩过的坑（docs/real-runtime-prereqs.md §8）──────────────────────────
#   - fixture 必须在**仓库外**（/workspace/main/…）：放仓库内时 front 会读到仓库
#     自己的 pair.json（里面登记着活的工程 session）→ 拿它当 resume_session →
#     拿到 busy → 无限重试（§8.3）。
#   - fixture 的 .rddf/state/{pair,role}.json 必须清掉（否则同上）。
#   - prompt 必须写死绝对路径 + 「只做这一件事」+「busy 直接汇报不要重试」
#     （§8.1/§8.2/§8.3）。
#   - 必须能区分三种失败形态：参数校验被拒（**无 session_id**）/ busy /
#     执行了但结果不符（**有 session_id** 但 outcome≠succeeded）。
#   - L2-4/L2-5 必须显式断言 canonical_root == fixture 根，否则「委托跑到
#     仓库根」会被伪装成通过（§8.2）。

load ../test_helper

# ── 门控 ────────────────────────────────────────────────────────────────────
l2_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

# 单条用例的独立超时上限（秒）。超时判 FAIL，绝不无限等待。
L2_CASE_TIMEOUT="${L2_CASE_TIMEOUT:-300}"

setup() {
    if ! l2_enabled; then
        skip "L2 运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    # 产物（stdout NDJSON / stderr / meta）落仓库内 .tmp-l2/（已被 .gitignore 覆盖）
    export L2_ROOT="${L2_ROOT:-$REPO_ROOT/.tmp-l2}"
    # fixture 落**仓库外**：仓库内会让 front 读到仓库自己的 pair.json → busy 死循环
    export L2_FIXTURE_ROOT="${L2_FIXTURE_ROOT:-/workspace/main/rdd-workflow-e2e-l2}"
    export TMPDIR="$L2_ROOT"
    mkdir -p "$L2_ROOT" "$L2_FIXTURE_ROOT"
}

teardown() {
    :
}

# ── fixture：复制工作树（排除 .git/.tmp-l2）+ git init + commit ────────────
# 约定来源：~/.config/opencode/docs/front-delegate-testing.md §5
#   1) 复制工作树，排除 .git（git 对象只读，复制后不可写 → EACCES）
#   2) 重新 git init + add -A + 一次 commit（需要可提交、可算 diff 的工程）
#   3) 副本必须落在 /workspace 下 —— front 的 external_directory 只放行
#      /workspace/** 与 ~/.config/opencode/**，bats 默认的 /tmp 前端读不到
#   4) 副本必须落在**仓库外** —— 否则 front 读到仓库自己的 pair.json → busy 死循环
#   5) 清掉 .rddf/state/{pair,role}.json —— 里面的旧登记会被 front 当 resume_session
l2_fixture_project() {
    local name="${1:-engproj}"
    local dest="$L2_FIXTURE_ROOT/$name"
    local marker="$L2_FIXTURE_ROOT/${name}.l2-owner"
    mkdir -p "$L2_FIXTURE_ROOT"
    # 只删**自己造过**的目录（旁边有 .l2-owner 标记）；没有标记 → 绝不删，改用带后缀的新目录
    if [ -d "$dest" ] && [ -f "$marker" ]; then
        rm -rf "$dest"
    elif [ -d "$dest" ]; then
        dest="$L2_FIXTURE_ROOT/${name}-$(date +%s)"
        marker="$L2_FIXTURE_ROOT/$(basename "$dest").l2-owner"
    fi
    mkdir -p "$dest"
    printf 'rdd-workflow-e2e L2 fixture\n' > "$marker"
    ( cd "$REPO_ROOT" && tar --exclude='./.git' --exclude='./.tmp-l2' -cf - . ) \
        | ( cd "$dest" && tar -xf - )
    # §8.3：登记文件必须清掉（只删这两个，保留 .rddf/state/ 的其余内容）
    rm -f "$dest/.rddf/state/pair.json" "$dest/.rddf/state/role.json"
    git -C "$dest" init -q
    git -C "$dest" config user.email "l2@test.local"
    git -C "$dest" config user.name "L2 Test"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "l2 fixture"
    printf '%s' "$dest"
}

# ── 真实 front 运行 ─────────────────────────────────────────────────────────
# 必须带 --session <new-id>：opencode run --agent X 会延续同 agent 的最近会话，
# 不隔离会复用上一轮上下文里的 id（验收报告 §四 运维事实）。
# 独立超时：timeout $L2_CASE_TIMEOUT，超时 = 退出码 124 → 判 FAIL。
l2_front_run() {
    local name="$1"; shift
    local prompt="$1"; shift
    local cwd="$1"; shift
    local sid
    sid="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
    local out="$L2_ROOT/${name}.json" err="$L2_ROOT/${name}.err"
    local start end rc
    start="$(date +%s.%N)"
    # L2_FRONT_MODEL 可选：给 front 覆盖模型（例如默认模型额度耗尽时换有额度的模型跑 E2E）
    local model_args=()
    [ -n "${L2_FRONT_MODEL:-}" ] && model_args=(--model "$L2_FRONT_MODEL")
    ( cd "$cwd" && timeout "$L2_CASE_TIMEOUT" opencode run --agent front \
        --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err"
    rc=$?
    end="$(date +%s.%N)"
    {
        printf 'requested_session_id=%s\n' "$sid"
        printf 'exit_code=%s\n' "$rc"
        printf 'elapsed=%s\n' "$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b-a}')"
        printf 'stdout=%s\n' "$out"
        printf 'stderr=%s\n' "$err"
        printf 'cwd=%s\n' "$cwd"
    } > "$L2_ROOT/${name}.meta"
    return $rc
}

# ── NDJSON 事件流解析 ───────────────────────────────────────────────────────
# stdout 是 NDJSON（每行一个 JSON 事件），必须逐行解析，不能 `jq .` 当单文档。
# 输出：delegate 工具调用列表（每行一个 JSON 对象），字段：
#   start_rel/end_rel  相对首事件的秒数
#   dur                调用发起→完成的秒数
#   outcome            delegate summary 的 outcome（succeeded/busy/failed/...）
#   session_id         delegate summary 的 session_id（**参数校验被拒时不存在**）
#   project_dir        委托入参 project_dir
#   scope              委托入参 scope
#   grants             委托入参 grants（用户预批的操作）
#   acceptance_type    委托入参 acceptance 的类型（str/list/...）
#   error              工具级错误信息（参数校验被拒时在这里）
l2_delegate_calls() {
    python3 - "$1" <<'PYEOF' 2>/dev/null || true
import json, sys

try:
    raw = open(sys.argv[1]).read()
except Exception:
    raise SystemExit

events = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        events.append(json.loads(line))
    except Exception:
        pass
if not events:
    raise SystemExit

t0 = events[0].get("timestamp") or 0
out = []
for ev in events:
    if ev.get("type") != "tool_use":
        continue
    part = ev.get("part") or {}
    if part.get("tool") != "delegate":
        continue
    st = part.get("state") or {}
    tm = st.get("time") or {}
    start, end = tm.get("start"), tm.get("end")
    inp = st.get("input") or {}
    summary = {}
    raw_out = st.get("output")
    if isinstance(raw_out, str):
        try:
            summary = json.loads(raw_out)
        except Exception:
            summary = {}
    elif isinstance(raw_out, dict):
        summary = raw_out
    err = st.get("error")
    rec = {
        "start_rel": round((start - t0) / 1000.0, 1) if start else None,
        "end_rel": round((end - t0) / 1000.0, 1) if end else None,
        "dur": round((end - start) / 1000.0, 2) if (start and end) else None,
        "outcome": summary.get("outcome"),
        "session_id": summary.get("session_id"),
        "project_dir": inp.get("project_dir"),
        "agent": inp.get("agent"),
        "scope": inp.get("scope"),
        "grants": inp.get("grants"),
        "resume_session": inp.get("resume_session"),
        "acceptance_type": type(inp.get("acceptance")).__name__,
        "status": st.get("status"),
        "error": err.get("message") if isinstance(err, dict) else None,
        "summary": summary,
    }
    out.append(json.dumps(rec, ensure_ascii=False))
print("\n".join(out))
PYEOF
}

# 事件流里的 front 会话 id（真实 ses_ id 的来源：stdout 事件自带的 sessionID）
l2_front_session_id() {
    python3 - "$1" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    raw = open(sys.argv[1]).read()
except Exception:
    raise SystemExit
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("sessionID"):
        print(ev["sessionID"])
        break
PYEOF
}

# 委托形态分类（把 §8 的三种失败形态变成可断言的结构化事实）：
#   succeeded        委托成功
#   rejected_param   参数校验被拒 → **无 session_id**（没有工程 session 被创建）
#   busy             目标工程 session 在跑 → outcome=busy + still_running=true
#   executed_mismatch 执行了但结果不符 → **有 session_id** 但 outcome≠succeeded
#   missing          事件流里根本没有 delegate 调用
l2_classify() {
    local calls="$1"
    if [[ -z "$calls" ]]; then echo "missing"; return; fi
    printf '%s\n' "$calls" | python3 -c '
import json, sys
recs = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
if any(r.get("outcome") == "succeeded" for r in recs):
    print("succeeded")
elif any(r.get("outcome") == "busy" for r in recs):
    print("busy")
elif any(r.get("session_id") for r in recs):
    print("executed_mismatch")
else:
    print("rejected_param")
'
}

# 取第一条 delegate 调用的某个字段
l2_first_field() {
    local calls="$1" field="$2"
    [[ -z "$calls" ]] && return 0
    printf '%s\n' "$calls" | head -1 | python3 -c "
import json, sys
line = sys.stdin.readline().strip()
if not line:
    raise SystemExit
r = json.loads(line)
v = r.get('$field')
if isinstance(v, (dict, list)):
    print(json.dumps(v, ensure_ascii=False))
elif v is None:
    print('')
else:
    print(v)
"
}

# ── subagent 调用解析（front 直调只读 agent 的运行时证据）────────────────────
# 输出：每行一个 JSON 对象 {agent, session_id, status, output_prefix}
l2_subagent_calls() {
    python3 - "$1" <<'PYEOF' 2>/dev/null || true
import json, re, sys

try:
    raw = open(sys.argv[1]).read()
except Exception:
    raise SystemExit

for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("type") != "tool_use":
        continue
    part = ev.get("part") or {}
    if part.get("tool") != "subagent":
        continue
    st = part.get("state") or {}
    inp = st.get("input") or {}
    out = st.get("output")
    if isinstance(out, (dict, list)):
        out = json.dumps(out, ensure_ascii=False)
    out = str(out or "")
    m = re.search(r'sessionID="?([A-Za-z0-9_]+)"?', out)
    err = st.get("error")
    if isinstance(err, dict):
        err = err.get("message") or json.dumps(err, ensure_ascii=False)
    print(json.dumps({
        "agent": inp.get("agent"),
        "session_id": m.group(1) if m else None,
        "status": st.get("status"),
        "error": err or "",
        "output_prefix": out[:300],
    }, ensure_ascii=False))
PYEOF
}

# 子 session 里是否出现过权限拒绝（硬证据：导出会话，解析 tool part 的 state.error）
l2_child_denial() {
    local sid="$1"
    [ -n "$sid" ] || { echo "no-session-id"; return 0; }
    opencode session export "$sid" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("export-failed")
    raise SystemExit
hits = 0
for m in (d.get("messages") or []):
    for p in (m.get("content") or []):
        if p.get("type") != "tool":
            continue
        err = (p.get("state") or {}).get("error") or {}
        if str(err.get("type", "")) == "permission.rejected" or "Permission denied" in str(err.get("message", "")):
            hits += 1
print("denied" if hits else "no-denial")
'
}

# 取某场景产物里第一条 subagent 调用的字段
l2_subagent_field() {
    local calls="$1" agent="$2" field="$3"
    printf '%s\n' "$calls" | python3 -c "
import json, sys
want = '$agent'
field = '$field'
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if r.get('agent') == want:
        print(r.get(field) or '')
        break
"
}

# 取 delegate 调用里满足某 agent 的记录数
l2_count_agent() {
    local calls="$1" agent="$2"
    [ -z "$calls" ] && { echo 0; return; }
    printf '%s\n' "$calls" | python3 -c "
import json, sys
n = 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    r = json.loads(line)
    if (r.get('agent') or 'build') == '$agent':
        n += 1
print(n)
"
}

# 取指定 agent 那条 delegate 记录的某个字段（取第一条匹配）
l2_first_field_for_agent() {
    local calls="$1" agent="$2" field="$3"
    [ -z "$calls" ] && return 0
    printf '%s\n' "$calls" | python3 -c "
import json, sys
agent = '$agent'
field = '$field'
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    r = json.loads(line)
    if (r.get('agent') or 'build') == agent:
        v = r.get(field)
        if isinstance(v, (dict, list)):
            print(json.dumps(v, ensure_ascii=False))
        else:
            print('' if v is None else v)
        break
"
}


# l2_run_scenario <scenario> —— 跑（或复用）一个场景的真实委托，产物落 $L2_ROOT：
#   run-<scenario>.json   stdout NDJSON
#   run-<scenario>.meta   退出码 / 耗时 / 传入的 session id
#   run-<scenario>.fixture  fixture 根的绝对路径
# ── debug agents（带重试：首次调用可能非 JSON / 空输出）────────────────────
l2_debug_agents() {
    local i out
    out=""
    for i in 1 2 3; do
        out="$(opencode debug agents 2>/dev/null || true)"
        if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
            printf '%s' "$out"
            return 0
        fi
        sleep 1
    done
    printf '%s' "$out"
    return 1
}

l2_run_scenario() {
    local scenario="$1"
    local name="run-$scenario"
    if [ -s "$L2_ROOT/$name.json" ] && [ -s "$L2_ROOT/$name.fixture" ]; then
        return 0
    fi
    local fixture
    fixture="$(l2_fixture_project "engproj-$scenario")"
    local prompt
    prompt="$(l2_scenario_prompt "$scenario" "$fixture")"
    l2_front_run "$name" "$prompt" "$fixture" || true
    printf '%s\n' "$fixture" > "$L2_ROOT/$name.fixture"

    # 超时（exit 124）必须被明确报出来 —— 超时判 FAIL，不允许无限等待后静默通过
    local rc elapsed
    rc="$(sed -n 's/^exit_code=//p' "$L2_ROOT/$name.meta" 2>/dev/null | head -1)"
    elapsed="$(sed -n 's/^elapsed=//p' "$L2_ROOT/$name.meta" 2>/dev/null | head -1)"
    if [[ "$rc" == "124" ]]; then
        echo "!! 场景 [$scenario] 的真实委托**超时**（timeout ${L2_CASE_TIMEOUT}s）→ 本用例判 FAIL" >&2
    else
        echo "场景 [$scenario] 真实委托结束：exit_code=${rc:-?} elapsed=${elapsed:-?}s" >&2
    fi
}

# 各场景的 prompt —— prompt 工程要求（docs §8.1/§8.2/§8.3）：
#   绝对路径写死 + 只做这一件事 + acceptance 是字符串 + busy 直接汇报别重试
l2_scenario_prompt() {
    local scenario="$1" fixture="$2"
    case "$scenario" in
    smoke)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具委托一次，让工程 session 在 ${fixture} 里新建 smoke.txt（内容 ok）。
delegate 的参数严格按下面填：
- project_dir: ${fixture}
- agent: build
- scope: ["smoke.txt"]
- acceptance: "文件 ${fixture}/smoke.txt 存在，内容去掉首尾空白后等于 ok"
注意：acceptance 必须写成字符串，不能写成数组；project_dir 必须就是 ${fixture} 这个绝对路径。
如果 delegate 返回 busy 或被拒绝，直接汇报结果即可，不要重复尝试、不要换参数再试。
PROMPT_EOF
        ;;
    scope)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具委托一次，让工程 session 在 ${fixture} 里新建两个文件：
- a.txt（内容 a）
- b.txt（内容 b）
delegate 的参数严格按下面填：
- project_dir: ${fixture}
- agent: build
- scope: ["a.txt"]
- acceptance: "文件 ${fixture}/a.txt 存在且内容为 a；文件 ${fixture}/b.txt 存在且内容为 b"
注意：scope 只含 a.txt，b.txt 超出 scope —— 权限层应当拒掉 b.txt 的写入。
acceptance 必须写成字符串，不能写成数组；project_dir 必须就是 ${fixture} 这个绝对路径。
如果 delegate 返回 busy 或被拒绝，直接汇报结果即可，不要重复尝试、不要换参数再试。
PROMPT_EOF
        ;;
    grants)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具发起一次委托，并且**故意**在 grants 里传一条不允许的操作：
grants: [{"action": "edit", "resource": "**"}]
其余参数按下面填：
- project_dir: ${fixture}
- agent: build
- scope: ["g.txt"]
- acceptance: "g.txt 存在"
注意：acceptance 必须写成字符串；这条委托是故意要失败的，请只发起一次，失败就直接汇报，不要重试。
PROMPT_EOF
        ;;
    resume)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具发起两次委托，目标是同一个工程 session：
- 第一次：project_dir 用 ${fixture}，scope 用 ["r.txt"]，新建 r.txt（内容 r）；
- 第二次：project_dir 仍然用 ${fixture}，并带上第一次的 resume_session（第一次的工程 session id 可以从 ${fixture}/.rddf/state/pair.json 读）。
两条的 acceptance 都写成字符串。
注意：第二次如果拿到 busy 就直接汇报结果，不要重试。
PROMPT_EOF
        ;;
    whitelist)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具发起一次委托，并且**故意**指定一个不在白名单里的 agent：
- project_dir: ${fixture}
- agent: general
- scope: ["w.txt"]
- acceptance: "w.txt 存在"
注意：这条委托是故意要失败的（agent 白名单不允许 general），请只发起一次，失败就直接汇报，不要重试、不要换 agent。
PROMPT_EOF
        ;;
    knowledge)
        cat <<PROMPT_EOF
只做这一件事：用 delegate 工具发起一次委托，让一个**只读**的 agent 回答一个问题：
- project_dir: ${fixture}
- agent: explore
- scope: []
- acceptance: "用 2 句话说明 ${fixture} 下的 README 讲了什么，并给出文件路径"
注意：这是知识会话，不要修改任何文件；project_dir 必须就是 ${fixture} 这个绝对路径。
如果 delegate 返回 busy 或被拒绝，直接汇报结果即可，不要重复尝试、不要换参数再试。
PROMPT_EOF
        ;;
    subagent-denied)
        cat <<PROMPT_EOF
只做这一件事：调用一次 subagent 工具，并且**故意**指定一个不在白名单里的 agent：
- agent: general
- description: 故意触发权限拒绝
- prompt: 说一句话即可
注意：这条调用是故意要失败的（general 不在 front 的 subagent 白名单里），请只调用一次，
把错误信息原样返回，不要重试、不要换 agent。
PROMPT_EOF
        ;;
    subagent-guard)
        cat <<PROMPT_EOF
只做这一件事：调用两次 subagent 工具，不要调用 delegate：
1) agent=explore，任务：在 shell 里执行 bash -c 'touch /tmp/opencode/l2-bash-probe'，执行后把结果（包括任何错误原文）原样返回。
2) agent=librarian，任务：在 shell 里执行 curl -o /tmp/opencode/l2-curl-probe https://example.com，执行后把结果（包括任何错误原文）原样返回。
如果被权限层拒绝，原样汇报错误信息即可，不要换写法绕过、不要重试。
PROMPT_EOF
        ;;
    *)
        echo "unknown scenario: $scenario" >&2
        return 1
        ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-1：工具门控 —— delegate 只对 front 可见，其它 agent 看不到
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-1: 工具门控 —— delegate 只对 front 可见，其它 agent 看不到" {
    # 断言目标（结构化事实，来自 `opencode debug agents` 的权限矩阵）：
    #   - front 的权限列表里存在 effect=allow 的 delegate 规则；
    #   - 其它 agent 全部只有 effect=deny 的 delegate 规则，无 allow；
    #   - 真实运行侧：delegate 事件归属于 front 会话 id（真实 ses_ id）。
    local agents
    agents="$(l2_debug_agents)"
    [ -n "$agents" ] || { echo "opencode debug agents 无输出" >&2; return 1; }

    local matrix
    matrix="$(printf '%s' "$agents" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    data = [json.loads(l) for l in raw.splitlines() if l.strip()]
if isinstance(data, dict):
    data = [data]
for a in data:
    name = a.get("name")
    perms = a.get("permissions") or []
    rules = [p for p in perms if isinstance(p, dict) and p.get("action") == "delegate"]
    eff = ",".join(str(p.get("effect")) for p in rules)
    print("%s|%s" % (name, eff))
')"
    [ -n "$matrix" ] || { echo "权限矩阵解析失败" >&2; return 1; }

    # front 必须有 allow；其它 agent 必须没有 allow
    local front_eff others_eff
    front_eff="$(printf '%s\n' "$matrix" | awk -F'|' '$1=="front"{print $2}')"
    others_eff="$(printf '%s\n' "$matrix" | awk -F'|' '$1!="front"{print $1"="$2}')"
    [ -n "$front_eff" ] || { echo "权限矩阵里没有 front agent" >&2; return 1; }
    case ",$front_eff," in
        *,allow,*) : ;;
        *) echo "front 的 delegate 规则里没有 allow（实际：$front_eff）" >&2; return 1 ;;
    esac
    if printf '%s\n' "$others_eff" | grep -q '=.*allow'; then
        echo "有非 front agent 拿到了 delegate 的 allow：" >&2
        printf '%s\n' "$others_eff" | grep '=.*allow' >&2
        return 1
    fi

    # 真实运行侧（若已有 smoke 场景产物）：delegate 事件归属于 front 会话 id
    if [ -s "$L2_ROOT/run-smoke.json" ]; then
        local fsid
        fsid="$(l2_front_session_id "$L2_ROOT/run-smoke.json")"
        [ -n "$fsid" ] || { echo "事件流里读不到 front 会话 id" >&2; return 1; }
        case "$fsid" in ses_*) : ;; *) echo "front 会话 id 不是真实 ses_ id：$fsid" >&2; return 1 ;; esac
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-2：front 的 edit 被拒 —— front 不得直接改工程文件（edit: deny）
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-2: front 的 edit 被拒 —— front 不得直接改工程文件（edit: deny）" {
    # 断言目标：
    #   - front 的权限矩阵里 edit 只有 deny、没有 allow；
    #   - 文件系统事实：fixture 的受版本控制文件相对初始 commit 无非预期改动。
    local agents
    agents="$(l2_debug_agents)"
    [ -n "$agents" ] || { echo "opencode debug agents 无输出" >&2; return 1; }

    local front_perms
    front_perms="$(printf '%s' "$agents" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    data = [json.loads(l) for l in raw.splitlines() if l.strip()]
if isinstance(data, dict):
    data = [data]
for a in data:
    if a.get("name") != "front":
        continue
    for p in (a.get("permissions") or []):
        if not isinstance(p, dict):
            continue
        print("%s|%s|%s" % (p.get("action"), p.get("resource"), p.get("effect")))
')"
    [ -n "$front_perms" ] || { echo "front 权限条目为空" >&2; return 1; }

    # edit 必须只有 deny
    local edit_rules edit_allow
    edit_rules="$(printf '%s\n' "$front_perms" | awk -F'|' '$1=="edit"{print $3}' | tr '\n' ',')"
    edit_allow="$(printf '%s\n' "$front_perms" | awk -F'|' '$1=="edit" && $3=="allow"{print $2}')"
    case ",$edit_rules," in
        *,allow,*) echo "front 竟然有 edit 的 allow 规则：$edit_allow" >&2; return 1 ;;
    esac
    case ",$edit_rules," in
        *,deny,*) : ;;
        *) echo "front 的 edit 规则里没有 deny（实际：$edit_rules）" >&2; return 1 ;;
    esac

    # 文件系统事实：fixture 内不得出现 front 直接写出来的文件。
    # 允许的例外 = **委托产物**（smoke.txt）与 delegate 的登记产物
    # （.rddf/state/{pair,role}.json）—— 这些是工程 session 写的，不是 front 写的。
    local fixture
    fixture="$(cat "$L2_ROOT/run-smoke.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-smoke")"
    if [ -d "$fixture/.git" ]; then
        local dirty
        dirty="$(git -C "$fixture" status --porcelain --untracked-files=all 2>/dev/null \
                 | grep -v -e 'smoke.txt' -e '.rddf/state/pair.json' -e '.rddf/state/role.json' \
                          -e '.rddf/state/ledger.jsonl' || true)"
        if [ -n "$dirty" ]; then
            echo "fixture 相对初始 commit 出现了非预期改动：" >&2
            printf '%s\n' "$dirty" >&2
            return 1
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-3：真委托写文件 —— front 经 delegate 让工程 session 真的落文件
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-3: 真委托写文件 —— front 经 delegate 让工程 session 真的落文件" {
    l2_run_scenario smoke

    local calls classify
    calls="$(l2_delegate_calls "$L2_ROOT/run-smoke.json")"
    classify="$(l2_classify "$calls")"

    # ① 区分三种失败形态（§8.1/§8.3）：本用例要求的是 succeeded
    case "$classify" in
        succeeded) : ;;
        rejected_param)
            echo "委托被参数校验拒绝（无 session_id）：acceptance 类型 = $(l2_first_field "$calls" acceptance_type)" >&2
            echo "  → 工具级错误：$(l2_first_field "$calls" error)" >&2
            return 1 ;;
        busy)
            echo "委托拿到 busy（目标工程 session 在跑）—— 前置条件没满足，不是本用例要验证的成功路径" >&2
            return 1 ;;
        executed_mismatch)
            echo "委托执行了但结果不符（有 session_id，outcome=$(l2_first_field "$calls" outcome)）" >&2
            return 1 ;;
        *)
            echo "事件流里没有 delegate 调用（classify=$classify）" >&2
            return 1 ;;
    esac

    # ② 文件系统事实（最高优先级）：目标文件真的落盘且内容正确
    local fixture
    fixture="$(cat "$L2_ROOT/run-smoke.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-smoke")"
    [ -f "$fixture/smoke.txt" ] || { echo "fixture 里没有 smoke.txt（$fixture/smoke.txt）" >&2; return 1; }
    local content
    content="$(tr -d '[:space:]' < "$fixture/smoke.txt")"
    [ "$content" = "ok" ] || { echo "smoke.txt 内容不对：[$content]" >&2; return 1; }

    # ③ delegate summary 的结构化字段
    local sid changed
    sid="$(l2_first_field "$calls" session_id)"
    case "$sid" in
        ses_*) : ;;
        *) echo "delegate summary 的 session_id 不是真实 ses_ id：[$sid]" >&2; return 1 ;;
    esac
    changed="$(l2_first_field "$calls" summary | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print(""); raise SystemExit
print(",".join(d.get("changed_files") or []))
')"
    case ",$changed," in
        *,smoke.txt,*) : ;;
        *) echo "summary.changed_files 里没有 smoke.txt（实际：$changed）" >&2; return 1 ;;
    esac

    # ④ 委托的 project_dir 必须就是 fixture 根（§8.2：防「委托跑到仓库根」伪装通过）
    local pdir expected
    pdir="$(l2_first_field "$calls" project_dir)"
    expected="$(cd "$fixture" && pwd -P)"
    [ "$pdir" = "$expected" ] || {
        echo "delegate 的 project_dir 不是 fixture 根：[$pdir] != [$expected]" >&2
        return 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-4：pair.json + role.json 登记 —— 工程 session 拿到 builder 分区
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-4: pair.json + role.json 登记 —— 工程 session 拿到 builder 分区" {
    l2_run_scenario smoke

    local calls classify
    calls="$(l2_delegate_calls "$L2_ROOT/run-smoke.json")"
    classify="$(l2_classify "$calls")"
    case "$classify" in
        succeeded) : ;;
        rejected_param) echo "委托被参数校验拒绝（无 session_id）" >&2; return 1 ;;
        busy)          echo "委托拿到 busy" >&2; return 1 ;;
        executed_mismatch) echo "委托执行了但结果不符" >&2; return 1 ;;
        *) echo "事件流里没有 delegate 调用" >&2; return 1 ;;
    esac

    local fixture eng_sid
    fixture="$(cat "$L2_ROOT/run-smoke.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-smoke")"
    eng_sid="$(l2_first_field "$calls" session_id)"
    [ -n "$eng_sid" ] || { echo "拿不到工程 session id" >&2; return 1; }

    # ① pair.json：登记在**被委托的工程根**下
    local pair="$fixture/.rddf/state/pair.json"
    [ -f "$pair" ] || { echo "fixture 下没有 pair.json（$pair）" >&2; return 1; }
    local version front_sid root
    version="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' "$pair")"
    [ "$version" = "pair-v2" ] || { echo "pair.json 的 version 不是 pair-v2：[$version]" >&2; return 1; }
    read -r front_sid root <<<"$(python3 - "$pair" "$eng_sid" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
e = d.get("pairs", {}).get(sys.argv[2], {})
print(e.get("front_session_id", ""), e.get("canonical_root", ""))
PYEOF
)"
    [ -n "$front_sid" ] || { echo "pair.json 里没有工程 session $eng_sid 的登记" >&2; return 1; }

    # ② front_session_id 必须是真实 ses_ id，且等于**事件流里观测到的** front 会话 id
    case "$front_sid" in
        ses_*) : ;;
        *) echo "front_session_id 不是真实 ses_ id：[$front_sid]" >&2; return 1 ;;
    esac
    local observed
    observed="$(l2_front_session_id "$L2_ROOT/run-smoke.json")"
    [ -n "$observed" ] || { echo "事件流里读不到 front 会话 id" >&2; return 1; }
    [ "$front_sid" = "$observed" ] || {
        echo "pair.json 的 front_session_id 与事件流观测到的 front 会话 id 不一致：" >&2
        echo "  pair.json = [$front_sid] / stdout 事件 = [$observed]" >&2
        return 1
    }

    # ③ canonical_root 必须 == fixture 根（§8.2：防「委托跑到仓库根」伪装通过）
    local expected
    expected="$(cd "$fixture" && pwd -P)"
    [ "$root" = "$expected" ] || {
        echo "canonical_root 不是 fixture 根：[$root] != [$expected]" >&2
        return 1
    }

    # ④ role.json：工程 session 在 sessions 分区里拿到 builder
    local role="$fixture/.rddf/state/role.json"
    [ -f "$role" ] || { echo "fixture 下没有 role.json（$role）" >&2; return 1; }
    local cur
    cur="$(python3 - "$role" "$eng_sid" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
s = (d.get("sessions") or {}).get(sys.argv[2]) or {}
print(s.get("current_role", ""))
PYEOF
)"
    [ "$cur" = "builder" ] || { echo "role.json 里工程 session 的 current_role 不是 builder：[$cur]" >&2; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-5：scope 越界被拒 —— scope 外的写入被权限层拒绝
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-5: scope 越界被拒 —— scope 外的写入被权限层拒绝" {
    # 断言目标（⚠ 口径必须**排除 shell 路径** —— 已知缺口 6：scope 只约束 edit 类目，
    #   shell 写越界检测不到；断言若覆盖 shell 路径就会写出永远失败的用例）：
    #   - 被委托的 scope 只含 a.txt 时，b.txt 要么没生成（edit 被权限层拒绝），
    #     要么出现在 out_of_scope_files 里（越界可见）——两者都不满足才算失败；
    #   - 并且 canonical_root == fixture 根（§8.2）。
    l2_run_scenario scope

    local calls classify
    calls="$(l2_delegate_calls "$L2_ROOT/run-scope.json")"
    classify="$(l2_classify "$calls")"
    case "$classify" in
        succeeded) : ;;
        rejected_param) echo "委托被参数校验拒绝（无 session_id）" >&2; return 1 ;;
        busy)          echo "委托拿到 busy" >&2; return 1 ;;
        executed_mismatch) echo "委托执行了但结果不符" >&2; return 1 ;;
        *) echo "事件流里没有 delegate 调用" >&2; return 1 ;;
    esac

    local fixture expected pdir
    fixture="$(cat "$L2_ROOT/run-scope.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-scope")"

    # ① canonical_root / project_dir == fixture 根
    expected="$(cd "$fixture" && pwd -P)"
    pdir="$(l2_first_field "$calls" project_dir)"
    [ "$pdir" = "$expected" ] || {
        echo "delegate 的 project_dir 不是 fixture 根：[$pdir] != [$expected]" >&2
        return 1
    }

    # ② scope 边界：真正关心的是**scope 外文件没有被写**。三种合法结局任一即通过：
    #    (a) b.txt 未生成 且 changed_files 不含 b.txt 且 summary 文本提到 b.txt
    #        → 越界写入被权限层拒绝 **或** 工程 session 自己遵守了 scope（两者都算边界生效）
    #    (b) b.txt 未生成 且 blocked_reason 非空 → 越界被权限层拒绝
    #    (c) b.txt 生成了 且 out_of_scope_files 非空 → 越界被检出（含 shell 写路径）
    #    三条都不成立 = 判据未触发（模型既没尝试越界、也没说明 b.txt 怎么处理）→ FAIL。
    #    ⚠ 不断言"必须出现权限拒绝"：模型遵守 scope 是合法结局，硬要求 denied 会写出假失败。
    local oos b_exists blocked text changed_has_b mentioned summary_json
    summary_json="$(l2_first_field "$calls" summary)"
    oos="$(printf '%s' "$summary_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print(""); raise SystemExit
print(",".join(d.get("out_of_scope_files") or []))
')"
    blocked="$(printf '%s' "$summary_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print(""); raise SystemExit
print(d.get("blocked_reason") or "")
')"
    changed_has_b="$(printf '%s' "$summary_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("no"); raise SystemExit
print("yes" if "b.txt" in (d.get("changed_files") or []) else "no")
')"
    text="$(printf '%s' "$summary_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print(""); raise SystemExit
print(d.get("last_assistant_text") or "")
')"
    b_exists="no"
    [ -f "$fixture/b.txt" ] && b_exists="yes"
    mentioned="no"
    printf '%s' "$text" | grep -q 'b\.txt' && mentioned="yes"

    if [ "$b_exists" = "yes" ] && [ -n "$oos" ]; then
        echo "scope 外的 b.txt 生成了，但 out_of_scope_files 非空（越界被检出）—— 判定通过" >&2
        return 0
    fi
    if [ "$b_exists" = "no" ] && [ "$changed_has_b" = "no" ] && [ -n "$blocked" ]; then
        echo "b.txt 未生成 + changed_files 不含 b.txt + blocked_reason=[$blocked] —— 越界写入被权限层拒绝，判定通过" >&2
        return 0
    fi
    if [ "$b_exists" = "no" ] && [ "$changed_has_b" = "no" ] && [ "$mentioned" = "yes" ]; then
        echo "b.txt 未生成 + 工程 session 明确处理了 b.txt（遵守 scope）—— 边界生效，判定通过" >&2
        return 0
    fi
    echo "scope 越界判据未被触发：b_exists=$b_exists changed_has_b=$changed_has_b out_of_scope_files=[$oos] blocked_reason=[$blocked] mentioned_b=$mentioned" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-6：非法 grants 被拒 —— question/form/edit/write 永不可 grant
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-6: 非法 grants 被拒 —— question/form/edit/write 永不可 grant" {
    # 断言目标：delegate 的 grants 里出现 action=edit（永不可 grant 的类目）时，
    #   委托必须被**参数校验**拒绝 → **无 session_id**（没有工程 session 被创建），
    #   且工程根下没有新增 pair.json 登记。
    #   ⚠ 判定依据是「有没有 session_id」，不是错误文案措辞（模型/宿主文案不稳定）。
    l2_run_scenario grants

    local calls
    calls="$(l2_delegate_calls "$L2_ROOT/run-grants.json")"
    [ -n "$calls" ] || { echo "没有 delegate 调用产物" >&2; return 1; }

    # 找带非法 grants 的 delegate 调用
    local illegal
    illegal="$(printf '%s\n' "$calls" | python3 -c '
import json, sys
FORBIDDEN = {"question", "form", "edit", "write"}
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    r = json.loads(l)
    for g in (r.get("grants") or []):
        if isinstance(g, dict) and str(g.get("action", "")).lower() in FORBIDDEN:
            print(json.dumps(r, ensure_ascii=False))
            break
')"
    if [ -z "$illegal" ]; then
        echo "本次运行没有出现带非法 grants（question/form/edit/write）的 delegate 调用" >&2
        echo "  → 判据未被触发：要么模型没按要求构造非法 grants，要么 delegate 的 grants 校验没走到" >&2
        return 1
    fi

    # 非法 grants 的调用必须没有 session_id（参数校验阶段就拒了）
    local sid
    sid="$(printf '%s\n' "$illegal" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline()).get("session_id") or "")')"
    [ -z "$sid" ] || { echo "非法 grants 的委托竟然拿到了 session_id：[$sid]" >&2; return 1; }

    # 工程根下不得出现 pair.json 登记（没有工程 session 被创建）
    local fixture pair
    fixture="$(cat "$L2_ROOT/run-grants.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-grants")"
    pair="$fixture/.rddf/state/pair.json"
    if [ -f "$pair" ]; then
        local n
        n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("pairs",{})))' "$pair")"
        [ "$n" = "0" ] || { echo "非法 grants 被拒后仍然创建了 $n 条工程 session 登记" >&2; return 1; }
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-7：busy —— 目标工程 session 在跑时不排队
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-7: busy —— 目标工程 session 在跑时不排队（两进程）" {
    # 场景设计（实测结论）：delegate 是**同步**调用（prompt → wait → 返回），
    # 单个 front 运行内两次委托必然串行完成 → 造不出 in-flight（实测两次都 succeeded）。
    # 因此本用例用**两个进程**：
    #   ① 后台起一个 build session（执行 sleep 300），并写 pair 登记（模拟"上次委托还在跑"）；
    #   ② 另一个 front 运行用 resume_session 续接它 → 必须返回 busy 且不排队。
    # 断言口径：delegate summary 的结构化字段（outcome=busy、still_running=true），
    #           不断言自然语言。
    local fixture sid seed_out seed_err seed_pid
    fixture="$(l2_fixture_project "engproj-busy2")"
    sid="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
    seed_out="$L2_ROOT/busy-seed.json"
    seed_err="$L2_ROOT/busy-seed.err"

    # ① 后台长跑 session（build agent；模型可覆盖，默认跟随 L2_FRONT_MODEL）
    local build_model="${L2_BUILD_MODEL:-${L2_FRONT_MODEL:-}}"
    local build_args=()
    [ -n "$build_model" ] && build_args=(--model "$build_model")
    ( cd "$fixture" && timeout 420 opencode run --agent build --session "$sid" --format json \
        "${build_args[@]}" "只做这一件事：用 shell 执行 sleep 300，然后输出 done。不要做别的。" \
        >"$seed_out" 2>"$seed_err" ) &
    seed_pid=$!
    printf '%s\n' "$seed_pid" > "$L2_ROOT/busy-seed.pid"

    # ② 写 pair 登记（canonical_root 必须与 delegate 侧 canonicalRoot() 一致 → 用 git 取）
    mkdir -p "$fixture/.rddf/state"
    local canon
    canon="$(cd "$fixture" && git rev-parse --show-toplevel)"
    python3 - "$fixture" "$sid" "$canon" <<'PY'
import json, os, sys, time
root, sid, canon = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(root, ".rddf/state/pair.json")
d = {"version": "pair-v2", "pairs": {}}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {"version": "pair-v2", "pairs": {}}
now = time.strftime("%Y-%m-%dT%H:%M:%S")
d.setdefault("pairs", {})[sid] = {
    "front_session_id": None,
    "canonical_root": canon,
    "agent": "build",
    "kind": "engineering",
    "registered_at": now,
    "last_used_at": now,
}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY

    # 等 seed session 真的开始（出现 user 消息）再让 front 去 resume
    local i
    for i in $(seq 1 40); do
        if opencode session export "$sid" 2>/dev/null | grep -q '"type": "user"'; then
            break
        fi
        sleep 1
    done

    # ③ 另一个 front 运行：resume 它
    local prompt
    prompt="$(cat <<PROMPT_EOF
只做这一件事：用 delegate 工具发起一次委托，并带上 resume_session：
- project_dir: ${fixture}
- resume_session: ${sid}
- scope: ["busy.txt"]
- acceptance: "busy.txt 存在"
注意：这条委托预期会拿到 busy（目标工程 session 正在跑）。拿到 busy 就直接汇报结果，不要重试、不要换参数。
PROMPT_EOF
)"
    l2_front_run "run-busy2" "$prompt" "$fixture" || true
    kill "$seed_pid" 2>/dev/null || true

    local calls busy_rec still sid_out
    calls="$(l2_delegate_calls "$L2_ROOT/run-busy2.json")"
    [ -n "$calls" ] || { echo "没有 delegate 调用产物" >&2; return 1; }

    busy_rec="$(printf '%s\n' "$calls" | python3 -c '
import json, sys
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    r = json.loads(l)
    if r.get("outcome") == "busy":
        print(json.dumps(r, ensure_ascii=False))
        break
')"
    [ -n "$busy_rec" ] || {
        echo "本次运行没有出现 busy 的委托调用（判据未被触发）" >&2
        printf '%s\n' "$calls" >&2
        return 1
    }

    still="$(printf '%s\n' "$busy_rec" | python3 -c 'import json,sys;s=json.loads(sys.stdin.readline()).get("summary") or {};print("true" if s.get("still_running") is True else "false")')"
    [ "$still" = "true" ] || { echo "busy 的 summary 里 still_running 不是 true" >&2; return 1; }

    # busy 必须指向**被 resume 的那个** session（没有新建）
    sid_out="$(printf '%s\n' "$busy_rec" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline()).get("session_id") or "")')"
    [ "$sid_out" = "$sid" ] || { echo "busy 指向的 session 不是被 resume 的那个：[$sid_out] != [$sid]" >&2; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-8：续接不新建 —— resume 复用既有工程 session
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-8: 续接不新建 —— resume 复用既有工程 session" {
    # 断言目标：
    #   - 带 resume_session 再次委托后，session_id 与首次相同；
    #   - pair.json 里的工程 session 条目数不增（续接不新建）；
    #   - 负例：未在 pair.json 登记的 id 被拒（无 session_id）。
    l2_run_scenario resume

    local calls
    calls="$(l2_delegate_calls "$L2_ROOT/run-resume.json")"
    [ -n "$calls" ] || { echo "没有 delegate 调用产物" >&2; return 1; }

    # ① 事件流里出现过的 delegate 入参里必须带 resume_session
    local resumed
    resumed="$(printf '%s\n' "$calls" | python3 -c '
import json, sys
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    r = json.loads(l)
    if r.get("resume_session"):
        print(json.dumps(r, ensure_ascii=False))
        break
')"
    [ -n "$resumed" ] || { echo "本次运行没有带 resume_session 的委托调用（判据未被触发）" >&2; return 1; }

    # ② resume 前后的 session_id 必须一致
    local first_sid resumed_sid
    first_sid="$(l2_first_field "$calls" session_id)"
    resumed_sid="$(printf '%s\n' "$resumed" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline()).get("session_id") or "")')"
    [ -n "$resumed_sid" ] || { echo "resume 的委托没有 session_id" >&2; return 1; }
    [ "$first_sid" = "$resumed_sid" ] || {
        echo "resume 之后 session_id 变了（新建了 session）：[$first_sid] -> [$resumed_sid]" >&2
        return 1
    }

    # ③ pair.json 里该工程 session 仍然只有一条登记（续接不新建）
    local fixture pair count
    fixture="$(cat "$L2_ROOT/run-resume.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-resume")"
    pair="$fixture/.rddf/state/pair.json"
    [ -f "$pair" ] || { echo "fixture 下没有 pair.json" >&2; return 1; }
    count="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("pairs",{})))' "$pair")"
    [ "$count" = "1" ] || { echo "pair.json 里的工程 session 条目数不是 1（=$count）——resume 新建了 session" >&2; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-9：agent 白名单 —— delegate(agent=general) 在建 session 前被拒
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-9: agent 白名单 —— delegate(agent=general) 在建 session 前被拒" {
    # 断言目标（结构化事实）：
    #   - 事件流里确实出现 agent=general 的 delegate 调用（否则判据未触发）；
    #   - 该调用**没有 session_id**（参数校验阶段拒绝，没建工程 session）；
    #   - fixture 的 pair.json 没有新增登记。
    l2_run_scenario whitelist

    local calls n
    calls="$(l2_delegate_calls "$L2_ROOT/run-whitelist.json")"
    [ -n "$calls" ] || { echo "没有 delegate 调用产物" >&2; return 1; }

    n="$(l2_count_agent "$calls" general)"
    [ "${n:-0}" -ge 1 ] || {
        echo "本次运行没有出现 agent=general 的 delegate 调用（判据未被触发）" >&2
        return 1
    }

    local sid
    sid="$(l2_first_field_for_agent "$calls" general session_id)"
    [ -z "$sid" ] || { echo "白名单拒绝却拿到了 session_id：[$sid]" >&2; return 1; }

    local fixture pair count
    fixture="$(cat "$L2_ROOT/run-whitelist.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-whitelist")"
    pair="$fixture/.rddf/state/pair.json"
    if [ -f "$pair" ]; then
        count="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("pairs",{})))' "$pair")"
        [ "$count" = "0" ] || { echo "白名单拒绝后仍然登记了 $count 条 session" >&2; return 1; }
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-10：知识 session —— kind=knowledge、只登记 pair、不写 role 分区
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-10: 知识 session —— kind=knowledge、只登记 pair、不写 role 分区" {
    l2_run_scenario knowledge

    local calls sid summary kind
    calls="$(l2_delegate_calls "$L2_ROOT/run-knowledge.json")"
    [ -n "$calls" ] || { echo "没有 delegate 调用产物" >&2; return 1; }

    sid="$(l2_first_field_for_agent "$calls" explore session_id)"
    case "$sid" in
        ses_*) : ;;
        *) echo "没有拿到真实工程 session id：[$sid]（委托失败或判据未触发）" >&2; return 1 ;;
    esac

    summary="$(l2_first_field_for_agent "$calls" explore summary)"
    kind="$(printf '%s' "$summary" | python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read() or "{}").get("kind", ""))
except Exception:
    print("")
')"
    [ "$kind" = "knowledge" ] || { echo "summary.kind 不是 knowledge：[$kind]" >&2; return 1; }

    local fixture pair entry_kind
    fixture="$(cat "$L2_ROOT/run-knowledge.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-knowledge")"
    pair="$fixture/.rddf/state/pair.json"
    [ -f "$pair" ] || { echo "fixture 下没有 pair.json" >&2; return 1; }

    entry_kind="$(python3 - "$pair" "$sid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
e = (d.get("pairs") or {}).get(sys.argv[2]) or {}
print(e.get("kind", ""))
PY
)"
    [ "$entry_kind" = "knowledge" ] || { echo "pair 条目的 kind 不是 knowledge：[$entry_kind]" >&2; return 1; }

    local role has
    role="$fixture/.rddf/state/role.json"
    if [ -f "$role" ]; then
        has="$(python3 - "$role" "$sid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in (d.get("sessions") or {}) else "no")
PY
)"
        [ "$has" = "no" ] || { echo "知识 session 被写进了 role.json 的 sessions 分区" >&2; return 1; }
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-11：ledger —— 恰好一行、字段齐全、已脱敏
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-11: ledger —— 恰好一行、字段齐全、已脱敏" {
    l2_run_scenario knowledge

    local fixture ledger n
    fixture="$(cat "$L2_ROOT/run-knowledge.fixture" 2>/dev/null || echo "$L2_FIXTURE_ROOT/engproj-knowledge")"
    ledger="$fixture/.rddf/state/ledger.jsonl"
    [ -f "$ledger" ] || { echo "没有 ledger.jsonl（$ledger）" >&2; return 1; }
    n="$(wc -l < "$ledger" | tr -d ' ')"
    [ "$n" = "1" ] || { echo "ledger 行数不是 1：$n" >&2; return 1; }

    python3 - "$ledger" <<'PY'
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = rows[0]
for k in ("recorded_at", "kind", "backend_session_id", "outcome", "front_session_id"):
    assert k in r, "ledger 缺字段: " + k
assert r["kind"] == "knowledge", "kind 不是 knowledge: %r" % r["kind"]
txt = r.get("last_assistant_text") or ""
assert not re.search(r"oc_sk_[A-Za-z0-9]{8,}", txt), "ledger 含疑似凭证"
print("ok")
PY
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-12：subagent 加固 —— explore 的 shell 写入被权限层拒
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-12: subagent 加固 —— explore 的 shell 写入被权限层拒" {
    rm -f /tmp/opencode/l2-bash-probe
    l2_run_scenario subagent-guard

    local subs sid verdict
    subs="$(l2_subagent_calls "$L2_ROOT/run-subagent-guard.json")"
    [ -n "$subs" ] || { echo "没有 subagent 调用产物（判据未触发）" >&2; return 1; }

    sid="$(l2_subagent_field "$subs" explore session_id)"
    case "$sid" in
        ses_*) : ;;
        *) echo "explore 的 subagent 调用没有子 session id" >&2; return 1 ;;
    esac

    verdict="$(l2_child_denial "$sid")"
    [ "$verdict" = "denied" ] || { echo "explore 子 session 没有出现 permission.rejected（$verdict）" >&2; return 1; }
    [ ! -e /tmp/opencode/l2-bash-probe ] || { echo "bash 写入竟然落盘了" >&2; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-13：librarian 网络守卫 —— curl -o 落盘被拒
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-13: librarian 网络守卫 —— curl -o 落盘被拒" {
    rm -f /tmp/opencode/l2-curl-probe
    l2_run_scenario subagent-guard

    local subs sid verdict
    subs="$(l2_subagent_calls "$L2_ROOT/run-subagent-guard.json")"
    [ -n "$subs" ] || { echo "没有 subagent 调用产物（判据未触发）" >&2; return 1; }

    sid="$(l2_subagent_field "$subs" librarian session_id)"
    case "$sid" in
        ses_*) : ;;
        *) echo "librarian 的 subagent 调用没有子 session id" >&2; return 1 ;;
    esac

    verdict="$(l2_child_denial "$sid")"
    [ "$verdict" = "denied" ] || { echo "librarian 子 session 没有出现 permission.rejected（$verdict）" >&2; return 1; }
    [ ! -e /tmp/opencode/l2-curl-probe ] || { echo "curl -o 竟然落盘了" >&2; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-14：front 的 subagent 门控 —— 只 allow 五个只读 agent
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-14: front 的 subagent 门控 —— 只 allow 五个只读 agent" {
    # 纯配置判据（不烧模型额度）：front 的 subagent 规则必须恰好是
    #   五个只读 agent allow + 末尾 "*": deny，且不得出现 general/plan/build。
    local agents
    agents="$(l2_debug_agents)" || { echo "opencode debug agents 无有效输出" >&2; return 1; }

    printf '%s' "$agents" | python3 -c '
import json, sys

data = json.load(sys.stdin)
front = next((a for a in data if a.get("name") == "front"), None)
assert front is not None, "没有 front agent"
rules = [p for p in (front.get("permissions") or []) if p.get("action") == "subagent"]
allow = sorted(p.get("resource") for p in rules if p.get("effect") == "allow")
deny_wild = any(p.get("resource") == "*" and p.get("effect") == "deny" for p in rules)
assert allow == ["critic", "explore", "librarian", "metis", "oracle"], "allow 集合不符: %r" % allow
assert deny_wild, "缺少 *: deny 兜底"
for bad in ("general", "plan", "build"):
    assert bad not in allow, "危险 agent 被放行: " + bad
print("ok")
'
}

# ═══════════════════════════════════════════════════════════════════════════
# L2-15：逐 agent 门控 —— front 召 general 必须被**权限层**拒绝
#   （v2.5 修正的配套：subagent 规则顺序改为 "*": deny 第一条后，工具可见，
#    必须同时证明"可见"没有带来"可调任意 agent"的旁路）
# ═══════════════════════════════════════════════════════════════════════════
@test "L2-15: 逐 agent 门控 —— front 召 general 被权限层拒绝" {
    l2_run_scenario subagent-denied

    local calls rec
    calls="$(l2_subagent_calls "$L2_ROOT/run-subagent-denied.json")"
    [ -n "$calls" ] || { echo "没有 subagent 调用产物（判据未触发：模型没调用）" >&2; return 1; }

    # 找到 agent=general 的那次调用
    rec="$(printf '%s\n' "$calls" | python3 -c '
import json, sys
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    r = json.loads(l)
    if r.get("agent") == "general":
        print(json.dumps(r, ensure_ascii=False))
        break
')"
    [ -n "$rec" ] || { echo "没有 agent=general 的 subagent 调用（判据未触发）" >&2; return 1; }

    # 必须以 error 状态结束，且错误来自权限层
    local status denied
    status="$(printf '%s\n' "$rec" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline()).get("status") or "")')"
    [ "$status" = "error" ] || {
        echo "agent=general 的 subagent 调用没有以 error 结束（status=$status）—— 白名单没生效" >&2
        printf '%s\n' "$rec" >&2
        return 1
    }
    denied="$(printf '%s\n' "$rec" | python3 -c '
import json, sys
r = json.loads(sys.stdin.readline())
out = (r.get("output_prefix") or "") + " " + (r.get("error") or "")
print("yes" if ("Permission denied" in out or "permission.rejected" in out) else "no")
')"
    [ "$denied" = "yes" ] || {
        echo "agent=general 的调用报错里没有权限拒绝痕迹：" >&2
        printf '%s\n' "$rec" >&2
        return 1
    }
}
