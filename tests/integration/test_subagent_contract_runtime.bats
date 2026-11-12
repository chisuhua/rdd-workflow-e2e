#!/usr/bin/env bats
# tests/integration/test_subagent_contract_runtime.bats
#
# subagent 输入契约门（~/.config/opencode/plugins/subagent-contract.ts）的**真实运行时**端到端测试。
#
# ── 门控 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 真正执行（需要真实模型 + 真实宿主）。
#
# ── 为什么默认全 skip ──────────────────────────────────────────────────────
#   L1/L2/L3 都发生在**真实 opencode 进程**里（插件钩子 + 父模型采样 + 子会话创建），
#   既跑不进 CI（无模型 secret），也不该在普通 `bats tests/` 时被触发。
#
# ── 手动运行方式 ───────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME=1 \
#   TMPDIR="$REPO_ROOT/.tmp-sc" \
#   bats tests/integration/test_subagent_contract_runtime.bats
#
#   父会话模型默认 opencode-go/deepseek-v4.1-flash（契约判定与模型无关）；
#   用 SC_PARENT_MODEL=... 覆盖，或 SC_PARENT_MODEL= 走 agent 自己的默认模型。
#
# ── 被测对象 ───────────────────────────────────────────────────────────────
#   $SC_SRC（默认 ~/.config/opencode）里的：
#     plugins/subagent-contract.ts   宿主接线（L3 注入 / L1 硬门 / L2 检出）
#     lib/subagent-contract-core.ts   规则真源（豁免语义、状态继承）
#     scripts/audit-subagent-prompts.ts  审计 CLI（L5）
#     subagent-contract.json          强度配置（warn / enforce / off）
#
# ── 隔离方式（hermetic HOME）────────────────────────────────────────────────
#   HOME 指到临时目录 ⇒ 契约配置、契约日志、会话 DB 全部隔离；
#   配置目录用**符号链接农场**指向真实 $SC_SRC ⇒ 测的是真实安装态的插件与内核，
#   但任何配置写入都落在临时副本里（subagent-contract.json 是真文件，其余是链接）。
#   凭据 auth.json / account.json 用链接带过来（否则 provider 401）。
#
# ── 断言优先级 ─────────────────────────────────────────────────────────────
#   ① 插件自己的日志文件（subagent-contract.log：gate / level / mode / exempted / violations）
#   ② NDJSON 事件流里的 tool_use 状态（completed / error + 错误文案）
#   ③ 隔离 DB 里的子会话是否被创建
#   不断言模型措辞 —— 只断言**结构性事实**（小节齐不齐 → 该放行还是该拒绝）。
#
# ── 用例清单 ───────────────────────────────────────────────────────────────
#   SC-1  L3 注入（每进程一条注入日志）
#   SC-2  L1 enforce：不合规被拒（可执行文案 + 不建子会话）
#   SC-3  L1 warn：不合规只记录不拦 + L2 兜底检出（enforceable=false）
#   SC-5  合规调用放行（无 violation 记录 + 子会话存在）
#   SC-6  豁免：任务陈述区含「复审」+ 缺 ≥4 小节 ⇒ enforce 下放行
#   SC-7  尾部关键词不算豁免（「复审」在 400 字符之后）⇒ enforce 下被拒
#   SC-8  继承需自证：第 1 轮复审豁免、第 2 轮新评审被拒（跨对象不继承）
#   SC-9  续接轮（sessionID 非空）不要求 7 字段
#   SC-10 逐 agent 覆盖：全局 warn + critic=enforce ⇒ critic 被拒、oracle（无契约）放行
#   SC-11 mode=off：不注入、不记录、不拦
#   SC-12 审计 CLI：--strict 有违规 exit 1 / 无违规 exit 0 / --json 形状
#
# ── 额度 / 挂起 ────────────────────────────────────────────────────────────
#   每个用例都真实调用模型。跑之前先做一次**额度预检**（整个文件跳过一次）：父模型
#   不可用（rate-limit / 认证）时整文件 skip，而不是 11 条用例各自失败。
#   单个用例里若 provider 报 rate-limit 或父会话超时且没产生任何 subagent 调用 ⇒ 该用例 skip
#   （显式标注"未判定"，绝不静默当通过）。

load ../test_helper

# ── 门控 ────────────────────────────────────────────────────────────────────
sc_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

SC_CASE_TIMEOUT="${SC_CASE_TIMEOUT:-180}"
# 父会话模型：契约判定与模型无关，默认按候选顺序自动挑一个**当前有额度**的
# （各 provider 的 Token Plan 额度会被前面的真实跑打满；build 默认的 minimax-cn 最先满）。
# 显式设置 SC_PARENT_MODEL=... 则跳过自动挑选，只用指定模型。
SC_PARENT_MODEL_CANDIDATES="${SC_PARENT_MODEL_CANDIDATES:-commandcode/deepseek/deepseek-v4.1-flash opencode-go/deepseek-v4.1-flash minimax-cn/MiniMax-M3.1-Flash}"

# ── 进程清理 ────────────────────────────────────────────────────────────────
# `opencode run --standalone` 会额外拉起 `opencode serve --stdio` 与
# `opencode-pty daemon`，它们继承 OPENCODE_DB 但不随父进程退出 ⇒ 临时 HOME 里的
# 文件被占住（rm: Device or resource busy），下一个用例的 setup 直接失败。
# 这里按 /proc/<pid>/environ 里的 OPENCODE_DB 前缀精确清理（不误杀本机真实服务）。
sc_kill_sc_processes() {
    # SC_ROOT 未设定时匹配式会退化成 "^OPENCODE_DB=/"（命中一切绝对路径 DB）⇒ 拒绝执行。
    # SC_ROOT 必须是绝对路径，否则前缀判定不可靠。
    [ -n "${SC_ROOT:-}" ] || return 0
    case "$SC_ROOT" in /*) ;; *) return 0 ;; esac
    local pid db
    for pid in $(pgrep -f "opencode" 2>/dev/null || true); do
        [ -r "/proc/$pid/environ" ] || continue
        # 取 OPENCODE_DB 的值本身做前缀判定（glob 前缀是字面量，不受正则元字符干扰）
        db="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^OPENCODE_DB=//p')"
        case "$db" in
            "$SC_ROOT"/*) kill -9 "$pid" 2>/dev/null || true ;;
        esac
    done
}

setup() {
    # 路径变量必须在 skip 之前导出：setup 里 skip 时 teardown **仍然执行**，
    # 而 teardown 会调 sc_kill_sc_processes —— SC_ROOT 为空时该函数会退化成
    # 匹配一切 OPENCODE_DB 绝对路径，把本机真实 opencode 服务一起 kill 掉。
    export SC_ROOT="${SC_ROOT:-$REPO_ROOT/.tmp-sc}"
    export SC_HOME="$SC_ROOT/home"
    export SC_WORK="$SC_ROOT/work"
    export SC_SRC="${SC_SRC:-$HOME/.config/opencode}"
    export SC_LOG="$SC_ROOT/contract.log"
    export SC_DB="$SC_HOME/.local/share/opencode/opencode.db"

    if ! sc_enabled; then
        skip "SC 运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi

    sc_kill_sc_processes
    rm -rf "$SC_HOME" "$SC_WORK" 2>/dev/null || true
    mkdir -p "$SC_HOME/.config/opencode" "$SC_HOME/.local/share/opencode" \
             "$SC_HOME/.rddf/state" "$SC_WORK/.rddf/state"
    : > "$SC_LOG"

    # 配置目录：符号链接农场（真实安装态），契约配置除外（可写）
    local f b
    for f in "$SC_SRC"/* "$SC_SRC"/.[!.]*; do
        b="$(basename "$f")"
        case "$b" in
            .git|subagent-contract.json) continue ;;
        esac
        [ -e "$f" ] || continue
        ln -sfn "$f" "$SC_HOME/.config/opencode/$b"
    done

    # 凭据：链接真实 auth（provider 认证）
    for f in auth.json account.json; do
        [ -f "$HOME/.local/share/opencode/$f" ] && \
            ln -sfn "$HOME/.local/share/opencode/$f" "$SC_HOME/.local/share/opencode/$f"
    done

    # 角色文件：让父 agent 开场就能读到角色，不至于因权限被拒而报错
    cat > "$SC_HOME/.rddf/state/role.json" <<'ROLEEOF'
{"schema_version":"role-v2","current_role":"builder","updated_at":"2026-11-12T00:00:00.000Z","updated_by":"user","session_id":"ses_sc_e2e","auto_switch_window":null,"history":[]}
ROLEEOF
    cp "$SC_HOME/.rddf/state/role.json" "$SC_WORK/.rddf/state/role.json"

    # 父会话模型：显式指定 → 预检一次；未指定 → 按候选顺序挑第一个可用的（每次运行挑一次）
    if [ -z "${SC_PARENT_MODEL:-}" ]; then
        if [ -f "$SC_ROOT/.parent-model-$$" ]; then
            export SC_PARENT_MODEL="$(cat "$SC_ROOT/.parent-model-$$")"
        else
            local cand chosen="" ok=1
            for cand in $SC_PARENT_MODEL_CANDIDATES; do
                export SC_PARENT_MODEL="$cand"
                if sc_preflight; then chosen="$cand"; ok=0; break; fi
                unset SC_PARENT_MODEL
            done
            [ "$ok" -eq 0 ] || skip "没有可用的父会话模型（额度/认证）：$SC_PARENT_MODEL_CANDIDATES"
            printf '%s' "$chosen" > "$SC_ROOT/.parent-model-$$"
        fi
    elif [ ! -f "$SC_ROOT/.preflight-ok-$$" ]; then
        if ! sc_preflight; then
            skip "父会话模型不可用（额度/认证）：$SC_PARENT_MODEL —— 见 $SC_ROOT/preflight.ndjson"
        fi
        : > "$SC_ROOT/.preflight-ok-$$"
    fi
}

teardown() {
    sc_stop_server
}

# ── 契约配置 ────────────────────────────────────────────────────────────────
# $1 = JSON 片段（不含 log 字段，log 由本文件注入到隔离路径）
sc_contract_config() {
    python3 - "$SC_HOME/.config/opencode/subagent-contract.json" "$SC_LOG" "$1" <<'PY'
import json, sys
out, log, frag = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.loads(frag)
cfg["log"] = log
with open(out, "w") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
PY
}

# ── 额度预检 ────────────────────────────────────────────────────────────────
# 真实模型会被额度打满（provider.rate-limit / Model unavailable）。额度不可用时，
# 11 个用例会各自失败，噪音盖住真正的契约回归 ⇒ 整个文件跑之前先探一次，不通就 skip。
# 结果按运行进程缓存（$SC_ROOT/.preflight-ok-$$），一套跑只探一次。
sc_preflight() {
    local sid="ses_sc_preflight_$$_$RANDOM" out="$SC_ROOT/preflight.ndjson"
    local model_args=() rc=0
    if [ -n "${SC_PARENT_MODEL:-}" ]; then model_args=(--model "$SC_PARENT_MODEL"); fi
    ( cd "$SC_WORK" && env -u OPENCODE_SERVER_URL \
        HOME="$SC_HOME" OPENCODE_DB="$SC_DB" \
        timeout 90 opencode run --standalone --agent build --session "$sid" \
            --format json "${model_args[@]}" "只回答：OK" ) >"$out" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && grep -q '"type":"text"' "$out"
}

# ── 真实父会话运行 ──────────────────────────────────────────────────────────
# $1 = 场景名；$2 = prompt；可选 $3 = 复用的 session id
sc_run_parent() {
    local name="$1" prompt="$2" sid="${3:-}"
    local out="$SC_ROOT/${name}.ndjson" err="$SC_ROOT/${name}.err"
    if [ -z "$sid" ]; then
        sid="ses_sc_$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')_$$_$RANDOM"
    fi
    printf '%s' "$sid" > "$SC_ROOT/${name}.sid"
    local model_args=() rc=0
    if [ -n "${SC_PARENT_MODEL:-}" ]; then model_args=(--model "$SC_PARENT_MODEL"); fi
    ( cd "$SC_WORK" && env -u OPENCODE_SERVER_URL \
        HOME="$SC_HOME" OPENCODE_DB="$SC_DB" \
        timeout "$SC_CASE_TIMEOUT" opencode run --standalone --agent build \
            --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err" || rc=$?

    # 超时（124）重试一次：真实 provider 偶发挂起，不能把偶发当契约回归
    if [ "$rc" -eq 124 ]; then
        rc=0
        sid="ses_sc_$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')_retry_$$_$RANDOM"
        printf '%s' "$sid" > "$SC_ROOT/${name}.sid"
        ( cd "$SC_WORK" && env -u OPENCODE_SERVER_URL \
            HOME="$SC_HOME" OPENCODE_DB="$SC_DB" \
            timeout "$SC_CASE_TIMEOUT" opencode run --standalone --agent build \
                --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err" || rc=$?
    fi
    printf '%s' "$rc" > "$SC_ROOT/${name}.rc"

    # 额度 / 挂起：本用例没跑起来，不能算契约回归（也不许静默放过 —— 用 skip 显式标注）
    if grep -q 'provider.rate-limit' "$out" 2>/dev/null; then
        skip "provider 额度不足（本用例未判定）：见 $out"
    fi
    if [ "$rc" -eq 124 ] && ! grep -q '"tool":"subagent"' "$out" 2>/dev/null; then
        skip "父会话超时且未产生 subagent 调用（provider 挂起，本用例未判定）：见 $out"
    fi
    return 0
}

# ── 共享 server（需要"跨轮保留状态"时用）────────────────────────────────────
# 继承语义的状态是**进程内 Map**（key = parentSessionID + agent）：两次 `opencode run
# --standalone` 是两个进程 ⇒ 状态丢失。要验证"第 2 轮不继承第 1 轮"必须让两轮跑在
# 同一个 server 上（这也更接近真实会话）。
sc_start_server() {
    local port=$((20000 + RANDOM % 20000))
    export SC_SERVER_PORT="$port"
    export SC_SERVER_URL="http://127.0.0.1:${port}"
    export SC_SERVER_PASSWORD="${SC_SERVER_PASSWORD:-sc-e2e-$$-$RANDOM}"
    ( cd "$SC_WORK" && env -u OPENCODE_SERVER_URL \
        HOME="$SC_HOME" OPENCODE_DB="$SC_DB" OPENCODE_SERVER_PASSWORD="$SC_SERVER_PASSWORD" \
        opencode serve --hostname 127.0.0.1 --port "$port" ) >"$SC_ROOT/server.log" 2>&1 &
    echo $! > "$SC_ROOT/server.pid"
    local i
    for i in $(seq 1 60); do
        if curl -s -o /dev/null --max-time 1 "${SC_SERVER_URL}/health"; then return 0; fi
        sleep 1
    done
    return 1
}

sc_stop_server() {
    [ -n "${SC_ROOT:-}" ] || return 0
    if [ -f "$SC_ROOT/server.pid" ]; then
        kill -9 "$(cat "$SC_ROOT/server.pid")" 2>/dev/null || true
        rm -f "$SC_ROOT/server.pid"
    fi
    sc_kill_sc_processes
}

# 走共享 server 的父会话（状态跨轮保留）
# $1 = 场景名；$2 = prompt；$3 = session id
sc_run_parent_via_server() {
    local name="$1" prompt="$2" sid="$3"
    local out="$SC_ROOT/${name}.ndjson" err="$SC_ROOT/${name}.err" rc=0
    printf '%s' "$sid" > "$SC_ROOT/${name}.sid"
    local model_args=()
    if [ -n "${SC_PARENT_MODEL:-}" ]; then model_args=(--model "$SC_PARENT_MODEL"); fi
    ( cd "$SC_WORK" && env -u OPENCODE_SERVER_URL \
        HOME="$SC_HOME" OPENCODE_DB="$SC_DB" OPENCODE_SERVER_PASSWORD="$SC_SERVER_PASSWORD" \
        timeout "$SC_CASE_TIMEOUT" opencode run --server "$SC_SERVER_URL" --agent build \
            --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err" || rc=$?
    printf '%s' "$rc" > "$SC_ROOT/${name}.rc"
    if grep -q 'provider.rate-limit' "$out" 2>/dev/null; then
        skip "provider 额度不足（本用例未判定）：见 $out"
    fi
    return 0
}

# ── NDJSON 里的 subagent 工具调用 ───────────────────────────────────────────
# 输出每行一条：{"i":序号,"status":"completed|error","agent":..,"sessionID":..,
#                "prompt_len":N,"missing":[..],"error":".."}
sc_subagent_calls() {
    python3 - "$1" <<'PY'
import json, re, sys

SECTIONS = ["changes_summary", "intent", "focus", "review_profile",
            "diff_or_paths", "context", "expected_format"]

def missing_sections(prompt):
    out = []
    for s in SECTIONS:
        pat = r"^(#{1,6}\s*(?:\d+[.)]\s*)?" + s + r"\b|\*\*" + s + r"\*\*)"
        if not re.search(pat, prompt, re.M | re.I):
            out.append(s)
    return out

try:
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    raise SystemExit(0)

idx = 0
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
    prompt = inp.get("prompt") if isinstance(inp.get("prompt"), str) else ""
    idx += 1
    err = st.get("error")
    print(json.dumps({
        "i": idx,
        "status": st.get("status"),
        "agent": inp.get("agent"),
        "sessionID": inp.get("sessionID"),
        "prompt_len": len(prompt),
        "missing": missing_sections(prompt),
        "error": (err if isinstance(err, str) else json.dumps(err, ensure_ascii=False)) if err else "",
    }, ensure_ascii=False, separators=(",", ":")))
PY
}

# 第一条 subagent prompt 里关键词「复审」的字符位置（-1 = 不出现）
sc_keyword_pos() {
    python3 - "$1" <<'PY'
import json, sys
pos = -1
try:
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        part = ev.get("part") or {}
        if ev.get("type") != "tool_use" or part.get("tool") != "subagent":
            continue
        prompt = (part.get("state") or {}).get("input", {}).get("prompt") or ""
        pos = prompt.find("复审")
        break
except Exception:
    pass
print(pos)
PY
}

# ── 契约日志记录 ────────────────────────────────────────────────────────────
# 可选 $1 = gate 过滤（L1 / L2 / L3）
sc_log_records() {
    local gate="${1:-}"
    python3 - "$SC_LOG" "$gate" <<'PY'
import json, sys
path, gate = sys.argv[1], sys.argv[2]
try:
    raw = open(path, encoding="utf-8", errors="replace").read()
except Exception:
    raise SystemExit(0)
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if gate and rec.get("gate") != gate:
        continue
    print(json.dumps(rec, ensure_ascii=False, separators=(",", ":")))
PY
}

# ── 隔离 DB 里的子会话 ──────────────────────────────────────────────────────
sc_child_sessions() {
    python3 - "$SC_DB" "$1" <<'PY'
import sqlite3, sys
db_path, parent = sys.argv[1], sys.argv[2]
try:
    db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    rows = db.execute(
        "select id, agent, title from session_v2 where parent_id = ?", (parent,)
    ).fetchall()
    for r in rows:
        print("%s\t%s\t%s" % r)
except Exception as exc:
    print("DB_ERROR\t%s" % exc)
PY
}

# ── 常用 prompt 片段 ───────────────────────────────────────────────────────
# 不合规：只有一句话（长度也不够）
SC_PROMPT_NONCOMPLIANT="审查一下这个改动。只回答「收到」即可；不要读任何文件、不要运行任何命令。"
# 合规：7 个小节齐备
SC_PROMPT_COMPLIANT="请审查以下改动。
## changes_summary
- src/foo.cpp: 修掉崩溃
## intent
修复空指针崩溃
## focus
1. 契约兼容
2. 失败模式
## review_profile
build
## diff_or_paths
diff --git a/src/foo.cpp b/src/foo.cpp
## context
- 相关测试 tests/foo.test.ts
## expected_format
4 段式 + mergeable / scope_exceeded
只做形式确认：回复「收到」即可；不要读任何文件、不要运行任何命令、不要修改任何文件。"

# ─────────────────────────────────────────────────────────────────────────────
# 用例
# ─────────────────────────────────────────────────────────────────────────────

@test "SC-1: L3 注入 —— 契约写进 subagent 工具描述（每进程一条注入日志）" {
    sc_contract_config '{"mode":"warn"}'
    sc_run_parent "sc1" "只回答：OK"

    run sc_log_records "L3"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    echo "$output" | grep -q '"event":"injected"'
    echo "$output" | grep -q '"agent":"critic"'
}

@test "SC-2: L1 enforce —— 不合规 prompt 被拒（可执行文案 + 不建子会话）" {
    sc_contract_config '{"mode":"enforce"}'
    sc_run_parent "sc2" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    run sc_subagent_calls "$SC_ROOT/sc2.ndjson"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '"i":1')" -eq 1 ]
    printf '%s\n' "$output" | grep -q '"status":"error"'
    # 错误文案必须可执行：说清缺什么 + 明确不要原样重试
    printf '%s\n' "$output" | grep -q '缺少小节'
    printf '%s\n' "$output" | grep -q '不要原样重试'

    # 日志：L1 violation，mode=enforce，未豁免
    run sc_log_records "L1"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"mode":"enforce"'
    printf '%s\n' "$output" | grep -q '"exempted":false'

    # 被拒 ⇒ 不应创建子会话
    sid="$(cat "$SC_ROOT/sc2.sid")"
    run sc_child_sessions "$sid"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "SC-3: L1 warn 只记录不拦 + L2 兜底检出（enforceable=false）" {
    sc_contract_config '{"mode":"warn"}'
    sc_run_parent "sc3" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    # 放行：工具调用完成
    run sc_subagent_calls "$SC_ROOT/sc3.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"completed"'

    # L1：只记录
    run sc_log_records "L1"
    printf '%s\n' "$output" | grep -q '"mode":"warn"'
    printf '%s\n' "$output" | grep -q '"exempted":false'

    # L2：子会话落库前的兜底检出（session 域钩子不可失败 ⇒ 只能检出）
    run sc_log_records "L2"
    printf '%s\n' "$output" | grep -q '"enforceable":false'
    printf '%s\n' "$output" | grep -q '"mode":"warn"'

    # 放行 ⇒ 子会话真的建出来了
    sid="$(cat "$SC_ROOT/sc3.sid")"
    run sc_child_sessions "$sid"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "SC-5: 合规调用放行 —— 无 violation 记录 + 子会话存在" {
    sc_contract_config '{"mode":"warn"}'
    sc_run_parent "sc5" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要删减任何小节）：
${SC_PROMPT_COMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    run sc_subagent_calls "$SC_ROOT/sc5.ndjson"
    [ "$status" -eq 0 ]
    # 模型必须逐字复制模板，否则本用例失去意义（明确报错而不是静默放过）
    printf '%s\n' "$output" | grep -q '"missing":\[\]'
    printf '%s\n' "$output" | grep -q '"status":"completed"'

    run sc_log_records "L1"
    [ -z "$output" ]
    run sc_log_records "L2"
    [ -z "$output" ]

    sid="$(cat "$SC_ROOT/sc5.sid")"
    run sc_child_sessions "$sid"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "SC-6: 豁免 —— 任务陈述区含「复审」且缺 ≥4 小节 ⇒ enforce 下放行" {
    sc_contract_config '{"mode":"enforce"}'
    sc_run_parent "sc6" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
这是复审（第 2 轮），只判定上一轮 BLOCK 是否闭合。本轮只看闭合证据，不要重审全文，不要重复上一轮已经列过的 SHOULD_FIX 与 NITS；请逐条核对作者声明的修复是否真的落在代码里，并指出仍然没有闭合的条目。闭合判定必须给出文件与行号证据，仍缺证据的条目按未闭合处理；若某条 finding 超出本轮范围请标注 scope_exceeded，不得要求返工。（只回复「收到」即可，不要读任何文件、不要运行任何命令。）
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    run sc_subagent_calls "$SC_ROOT/sc6.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"completed"'

    run sc_log_records "L1"
    printf '%s\n' "$output" | grep -q '"level":"exempted"'
    printf '%s\n' "$output" | grep -q '"exemption":"re-review-round"'
    printf '%s\n' "$output" | grep -q '"mode":"enforce"'
}

@test "SC-7: 尾部关键词不算豁免 —— 「复审」只出现在 400 字符之后 ⇒ enforce 下被拒" {
    sc_contract_config '{"mode":"enforce"}'
    sc_run_parent "sc7" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
请审查下面这份调研产物，它是本轮新写的研究文档，读者是实现团队。
核对要求如下：
1. 每一条结论都必须能在源码里找到对应实现，给不出文件与行号的一律标注「未验证」；
2. 引用外部资料时必须给出可访问的链接，二手转述不算证据；
3. 时序图必须与实现里的状态机逐步对齐，任何一步对不上都要指出；
4. 实现对照表必须覆盖全部字段，缺字段要单列出来，不许合并同类项蒙混过关；
5. 性能数字必须标注测量环境与口径，没有测量环境的数字一律视为传闻；
6. 结论分三档输出：阻断开仓、应当修复但可延后、可选优化。
文档路径见 /workspace/project/CppTLM/docs/research/，共 4 个文件。请重点看协议栈描述、时序图与实现对照表，若与源码不符请直接给出具体行号与正确说法。请逐条核对实现与文档的一致性，标注证据所在文件与行号；不确定的地方不要猜，宁可标注「未验证」。请按严重程度分三档输出：阻断开仓的问题、应当修复但可延后的问题、可选优化；每条都要给出可复现的判据，不接受「看起来不对」这种没有证据的结论。若发现文档与源码大范围漂移，请直接指出漂移面并给出一份最小核对清单。这不是复审代码（这是 research 文档，不入 openspec 契约），也不要修改调研文档本身——只给报告。调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    # 自校验：模型可能改写 prompt —— 关键词若被挪进 400 窗口，本用例就不成立
    pos="$(sc_keyword_pos "$SC_ROOT/sc7.ndjson")"
    if [ "$pos" -ge 0 ] && [ "$pos" -lt 400 ]; then
        skip "模型改写了 prompt（「复审」落在 ${pos} 字符 < 400），本用例未判定"
    fi

    run sc_subagent_calls "$SC_ROOT/sc7.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"error"'
    printf '%s\n' "$output" | grep -q '缺少小节'

    run sc_log_records "L1"
    printf '%s\n' "$output" | grep -q '"exempted":false'
}

@test "SC-8: 继承需自证 —— 第 1 轮复审豁免、第 2 轮新评审被拒（跨对象不继承）" {
    sc_contract_config '{"mode":"enforce"}'
    sc_start_server || skip "共享 server 未起来（见 $SC_ROOT/server.log，本用例未判定）"
    local sid="ses_sc_sc8_$$_$RANDOM"

    # 第 1 轮：复审 prompt（缺全部小节，但关键词在任务陈述区 ⇒ 豁免放行）
    sc_run_parent_via_server "sc8a" "只做一件事：用 subagent 工具调用 agent=critic，description 填 first，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
这是复审（第 2 轮），只判定上一轮 BLOCK 是否闭合。本轮只看闭合证据，不要重审全文，也不要求复审上一轮没提的部分，不要重复已经列过的 SHOULD_FIX 与 NITS；请逐条核对作者声明的修复是否真的落在代码里，并指出仍然没有闭合的条目。闭合判定必须给出文件与行号证据，仍缺证据的条目按未闭合处理；若某条 finding 超出本轮范围请标注 scope_exceeded，不得要求返工。（只回复「收到」即可，不要读任何文件、不要运行任何命令。）
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。" "$sid"

    # 第 2 轮：同一父会话里的**新评审**（不引用上一轮）⇒ 不得继承第 1 轮的复审模式
    sc_run_parent_via_server "sc8b" "只做一件事：用 subagent 工具调用 agent=critic，description 填 second，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
请审另一份 ADR 草案的技术正确性，这是本轮新起草的文档，读者是实现团队，请核对决策陈述与代价是否自洽、是否与既有契约冲突、是否把未决问题写成了已决。

调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。" "$sid"

    sc_stop_server

    run sc_subagent_calls "$SC_ROOT/sc8a.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"completed"'

    run sc_subagent_calls "$SC_ROOT/sc8b.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"error"'
    printf '%s\n' "$output" | grep -q '缺少小节'

    run sc_log_records "L1"
    # 一条豁免（level=exempted）+ 一条违规（level=violation）
    printf '%s\n' "$output" | grep -q '"level":"exempted"'
    printf '%s\n' "$output" | grep -q '"level":"violation"'
}

@test "SC-9: 续接轮（sessionID 非空）不要求 7 字段" {
    # 第 1 步：warn 模式建出子会话（enforce 下首轮会被拒，就没有可续接的对象）
    sc_contract_config '{"mode":"warn"}'
    sc_run_parent "sc9a" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"
    sid="$(cat "$SC_ROOT/sc9a.sid")"
    child="$(sc_child_sessions "$sid" | head -1 | cut -f1)"
    [ -n "$child" ]

    # 第 2 步：切 enforce，续接该子会话 ⇒ 续接只是补充说明，不要求 7 字段
    sc_contract_config '{"mode":"enforce"}'
    local before
    before="$(wc -l < "$SC_LOG" 2>/dev/null || echo 0)"
    sc_run_parent "sc9b" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，sessionID 参数必须填 ${child}，prompt 参数必须是下面这段原文（不要改写）：
补充：再确认一下上一条。只回复「收到」即可。
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。" "$sid"

    run sc_subagent_calls "$SC_ROOT/sc9b.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"completed"'
    printf '%s\n' "$output" | grep -q "\"sessionID\":\"${child}\""

    # 续接不要求 7 字段 ⇒ 续接这一轮不应出现"缺小节"违规记录
    # （sc9a 那一轮的违规记录是预期内的，所以只看 sc9b 之后新增的行）
    new_lines="$(tail -n +"$((before + 1))" "$SC_LOG" 2>/dev/null || true)"
    ! printf '%s' "$new_lines" | grep -q '缺少小节'
}

@test "SC-10: 逐 agent 覆盖 —— 全局 warn + critic=enforce ⇒ critic 被拒、oracle 放行" {
    sc_contract_config '{"mode":"warn","agents":{"critic":{"mode":"enforce"}}}'
    sc_run_parent "sc10" "只做一件事，按顺序发起两次 subagent 工具调用，不要做别的：
第一次 agent=oracle，description 填 sc-probe，prompt 必须是：只回答「收到」即可，不要读任何文件、不要运行任何命令、不要修改任何文件。
第二次 agent=critic，description 填 sc-probe，prompt 必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
两次调用完成后不要再做任何事。"

    run sc_subagent_calls "$SC_ROOT/sc10.ndjson"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '"i":')" -eq 2 ]
    # oracle：无契约 ⇒ 放行
    printf '%s\n' "$output" | grep '"i":1' | grep -q '"status":"completed"'
    # critic：agent 级 enforce ⇒ 被拒
    printf '%s\n' "$output" | grep '"i":2' | grep -q '"status":"error"'

    run sc_log_records "L1"
    printf '%s\n' "$output" | grep -q '"mode":"enforce"'
}

@test "SC-11: mode=off —— 不注入、不记录、不拦" {
    sc_contract_config '{"mode":"off"}'
    sc_run_parent "sc11" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    run sc_subagent_calls "$SC_ROOT/sc11.ndjson"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '"status":"completed"'

    # 日志里一条记录都不该有（L1 / L2 / L3 全无）
    run sc_log_records
    [ -z "$output" ]
}

@test "SC-12: 审计 CLI —— --strict 有违规 exit 1 / 无违规 exit 0 / --json 形状" {
    sc_contract_config '{"mode":"warn"}'
    sc_run_parent "sc12" "只做一件事：用 subagent 工具调用 agent=critic，description 填 sc-probe，prompt 参数必须是下面这段原文（不要改写、不要补充、不要加任何小节）：
${SC_PROMPT_NONCOMPLIANT}
调用之后不要再做任何事；如果工具报错就停止，不要重试、不要改写后再发。"

    # critic 有违规 ⇒ --strict exit 1
    run env HOME="$SC_HOME" bash -c "cd '$SC_SRC' && bun scripts/audit-subagent-prompts.ts --db '$SC_DB' --agent critic --strict"
    [ "$status" -eq 1 ]

    # explore 无契约 ⇒ 无违规 ⇒ exit 0
    run env HOME="$SC_HOME" bash -c "cd '$SC_SRC' && bun scripts/audit-subagent-prompts.ts --db '$SC_DB' --agent explore --strict"
    [ "$status" -eq 0 ]

    # --json 形状
    run env HOME="$SC_HOME" bash -c "cd '$SC_SRC' && bun scripts/audit-subagent-prompts.ts --db '$SC_DB' --agent critic --json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'summary' in d and 'rows' in d, d.keys()
c = d['summary']['critic']
assert c['violations'] >= 1, c
assert c['total'] >= 1, c
"
}
