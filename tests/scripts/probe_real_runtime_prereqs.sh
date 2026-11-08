#!/usr/bin/env bash
# tests/scripts/probe_real_runtime_prereqs.sh
#
# 前置探针：确认「front agent session 驱动真实工程 session」的 L2 运行时测试
# 在本仓落地所需的 5 个前提条件。
#
#   P1  opencode 运行时是否把真实 session id 注入 OPENCODE_SESSION_ID
#   P2  opencode run 的 stdout 是否有稳定机器可读格式
#   P3  模型凭证从哪来、当前环境是否已有可用 provider
#   P4  单条真实委托的耗时（**两个口径**：整轮 elapsed / 事件流推导，见下）
#   P5  bats 的 BATS_TEST_TMPDIR 能否重定向到 /workspace 下
#
# P4 的两个口径（必须分别报告，只报一个会误导）：
#   口径 A｜整轮 elapsed：opencode run 进程的墙钟时间 —— 含模型重试与失败，
#           会被「模型重试循环」放大（病态样本实测 600s，被 timeout 掐断）。
#   口径 B｜事件流推导：从 stdout 的 NDJSON 事件流直读（part.state.time.start/end），
#           不受循环影响：prompt 注入→首次 delegate 发起（前置）、
#           单次 delegate 调用发起→完成（调用耗时）。
#           两者相加 = 一条「顺利」委托的耗时基线。
#
# 退出码语义：
#   0  全部探针结论为 PASS 或 SKIP（没有任何 FAIL）
#   1  至少一项探针结论为 FAIL
#   2  脚本自身无法执行（依赖缺失、工作目录不可写等）
#
# 失败不中断：每项探针独立判定，某项判 FAIL 后继续执行后续探针，
# 最后统一汇总并按上表返回退出码。
#
# 用法：
#   bash tests/scripts/probe_real_runtime_prereqs.sh                  # 只读探针（默认，不调模型）
#   bash tests/scripts/probe_real_runtime_prereqs.sh --with-real-run  # 额外执行 1 次真实 opencode run 委托
#   bash tests/scripts/probe_real_runtime_prereqs.sh --keep-workdir   # 保留探针产生的工作目录
#
# 环境变量：
#   PROBE_ROOT   探针工作目录（默认 /workspace/main/rdd-workflow-e2e-l2-probe）
#                必须在 front 的 external_directory 放行范围（/workspace/**）之内，
#                否则真实委托探针会被跳过。
#                必须在**仓库外**（否则 front 会读到仓库自己的 pair.json → busy 死循环）。
#                脚本只清理自己造出来、且带 .probe-owner 标记的子目录；
#                PROBE_ROOT 本身仅在清空后移除（rmdir 失败即保留）。
#   PROBE_STDOUT 复用一份已采集的 `opencode run --format json` stdout 做结构与耗时分析，
#                不触发真实委托、不消耗模型额度（配合 --with-real-run 之外的独立复盘用）。
#
# 只读保证（硬约束）：
#   - 不修改 ~/.config/opencode 下的任何文件（含 opencode.jsonc）
#   - 不执行 opencode service restart 或其它破坏性 opencode 操作
#   - 不写本仓受版本控制的文件；产物落在 $PROBE_ROOT
#   - **仓库内**只在 P5 的 gitignore 副作用探针里临时造 `.tmp-l2/p5-noise-probe/`（带
#     .probe-owner 标记），跑完只删自己造的那一个子目录，父目录仅在**空**时 rmdir
#   - 不打印任何凭证值；只报告凭证的存在性与来源变量名
#   - 单次调用最多执行 1 次真实 opencode run 委托（--with-real-run）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 探针工作目录默认放在**仓库外**、但仍在 /workspace 下：
#   - /workspace/** 在 front 的 external_directory 放行范围内（/tmp 不在，front 读不到）
#   - 仓库外 → front 不会把仓库根当成 project_dir，也不会弄脏本仓 git status
#   - /workspace 与 /workspace/main 虽是 root 属主，但带 sticky 位（o+w）→ 可创建新条目
PROBE_ROOT="${PROBE_ROOT:-/workspace/main/rdd-workflow-e2e-l2-probe}"
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"

WITH_REAL_RUN=0
KEEP_WORKDIR=0

# ── 参数 ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-real-run) WITH_REAL_RUN=1; shift ;;
        --keep-workdir)  KEEP_WORKDIR=1; shift ;;
        -h|--help)       sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── 结果累加器 ──────────────────────────────────────────────────────────────
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
declare -a SUMMARY_ROWS=()
EVIDENCE=()

# record <probe_id> <PASS|FAIL|SKIP> <一句话结论>
# 证据通过 EVIDENCE 数组传入（每行一条）。
record() {
    local id="$1" status="$2" headline="$3"
    SUMMARY_ROWS+=("${id}|${status}|${headline}")
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
    printf '\n[%s] %s —— %s\n' "$status" "$id" "$headline"
    if [[ ${#EVIDENCE[@]} -gt 0 ]]; then
        printf '%s\n' "${EVIDENCE[@]}" | sed 's/^/        | /'
    fi
    EVIDENCE=()
}

have() { command -v "$1" >/dev/null 2>&1; }

# ────────────────────────────────────────────────────────────────────────────
# P1 —— opencode 运行时是否把真实 session id 注入 OPENCODE_SESSION_ID
# ────────────────────────────────────────────────────────────────────────────
probe_p1() {
    local id="P1" static_hit="" runtime_sid="" verified="no" verify_note=""
    local bin=""
    bin="$(command -v opencode 2>/dev/null || true)"

    # (a) 静态证据：opencode 可执行文件里的注入点
    if [[ -n "$bin" && -f "$bin" ]]; then
        static_hit="$(grep -ao 'env\.OPENCODE_SESSION_ID=[A-Za-z0-9_.$]\{1,24\}' "$bin" 2>/dev/null | head -1 || true)"
    fi

    # (b) 运行时证据：脚本自身继承到的 OPENCODE_SESSION_ID
    runtime_sid="${OPENCODE_SESSION_ID:-}"

    # (c) 交叉验证：该 id 是否能被 opencode 自己认出来
    if [[ -n "$runtime_sid" ]] && have opencode; then
        local listing="" dir
        for dir in "$REPO_ROOT" "$PROBE_ROOT" "$PWD"; do
            [[ -d "$dir" ]] || continue
            listing="$(cd "$dir" 2>/dev/null && opencode session list --format json 2>/dev/null || true)"
            if [[ -n "$listing" ]] && printf '%s' "$listing" | grep -qF "$runtime_sid"; then
                verified="yes"
                verify_note="opencode session list（cwd=${dir}）中能查到该 id"
                break
            fi
        done
        if [[ "$verified" != "yes" ]]; then
            verify_note="未能通过 opencode session list 交叉验证（session 归属其它 project 目录时必然查不到）"
        fi
    fi

    if [[ -n "$static_hit" ]]; then
        EVIDENCE+=("静态：opencode 可执行文件内的注入点 → ${static_hit}")
        EVIDENCE+=("      含义：shell 工具每次调用时，把「发起该次工具调用的 session id」写进子进程环境变量")
        if [[ -n "$runtime_sid" ]]; then
            EVIDENCE+=("运行时：本脚本继承 OPENCODE_SESSION_ID=${runtime_sid}")
            EVIDENCE+=("      交叉验证：${verified} —— ${verify_note}")
        else
            EVIDENCE+=("运行时：本脚本不在 opencode 的 shell 工具内执行，OPENCODE_SESSION_ID 未设置")
            EVIDENCE+=("      → 运行时层需在 opencode 内执行本脚本补验（静态证据已成立）")
        fi
        record "$id" "PASS" "opencode 运行时确实注入 OPENCODE_SESSION_ID，值是真实 session id"
    else
        EVIDENCE+=("查找模式：env\.OPENCODE_SESSION_ID=…   可执行文件：${bin:-<未找到>}")
        record "$id" "FAIL" "未在 opencode 可执行文件中找到 OPENCODE_SESSION_ID 注入点"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# P2 —— opencode run 的 stdout 是否有稳定机器可读格式
# ────────────────────────────────────────────────────────────────────────────
probe_p2() {
    local id="P2"
    local help_out="" has_json="no" choice_line=""
    if have opencode; then
        help_out="$(opencode run --help 2>&1 || true)"
        if printf '%s' "$help_out" | grep -q -- '--format'; then
            has_json="yes"
            choice_line="$(printf '%s' "$help_out" | grep -- '--format' | head -1 | sed 's/^[[:space:]]*//')"
        fi
    fi

    if [[ "$has_json" != "yes" ]]; then
        EVIDENCE+=("opencode run --help 未出现 --format")
        record "$id" "FAIL" "opencode run 没有暴露 --format，stdout 无稳定机器可读格式"
        return
    fi

    EVIDENCE+=("静态：opencode run --help → ${choice_line}")

    if [[ -z "$RUN_STDOUT" || ! -f "$RUN_STDOUT" ]]; then
        EVIDENCE+=("运行时：未执行真实委托，--format json 的实际产物结构未采样")
        EVIDENCE+=("      → 采集方式：加 --with-real-run，或直接用 opencode run --format json 采样")
        record "$id" "PASS" "stdout 存在机器可读格式（--format json）；实际结构待真实运行采样"
        return
    fi

    # 采样真实产物结构：整体单文档 还是 NDJSON（每行一个事件）
    local raw_shape="unknown" shape="unknown" types="" nlines=""
    if have python3; then
        raw_shape="$(python3 - "$RUN_STDOUT" <<'PYEOF' 2>/dev/null || echo unknown
import json, sys
raw = open(sys.argv[1]).read()
lines = [l for l in raw.splitlines() if l.strip()]
ok = bad = 0
kinds = []
for l in lines:
    try:
        d = json.loads(l)
        ok += 1
        t = d.get("type") if isinstance(d, dict) else type(d).__name__
        if t not in kinds:
            kinds.append(t)
    except Exception:
        bad += 1
if bad == 0 and ok == 1:
    shape = "single-json"
elif bad == 0 and ok > 1:
    shape = "ndjson"
elif bad == 0:
    shape = "empty"
else:
    shape = "mixed"
print(shape + "|" + str(len(lines)) + "|" + ",".join(kinds))
PYEOF
)"
    fi
    shape="${raw_shape%%|*}"
    local rest="${raw_shape#*|}"
    nlines="${rest%%|*}"
    types="${rest#*|}"

    case "$shape" in
        ndjson)
            EVIDENCE+=("运行时：--format json 的 stdout 是 NDJSON —— 共 ${nlines} 行，每行一个 JSON 事件对象")
            EVIDENCE+=("      事件 type 取值：${types}")
            EVIDENCE+=("      → 断言口径：按行解析 + 按 type 过滤（tool_use 事件含 tool 名、input、state）")
            record "$id" "PASS" "stdout 存在机器可读格式（--format json，NDJSON 事件流），可按行断言"
            ;;
        single-json)
            EVIDENCE+=("运行时：--format json 的 stdout 是单个 JSON 文档（顶层 type 集合：${types}）")
            record "$id" "PASS" "stdout 存在机器可读格式（--format json，单 JSON 文档），可用 jq 断言"
            ;;
        *)
            EVIDENCE+=("运行时：--format json 的 stdout 结构无法归类（shape=${shape}）")
            EVIDENCE+=("      → 建议：断言只认文件系统事实 + pair.json/role.json，不解析 stdout")
            record "$id" "PASS" "stdout 暴露了 --format json，但本次采样结构异常；断言建议只认文件系统事实"
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────
# P3 —— 模型凭证来源与 provider 可用性（只报存在性，绝不打印凭证值）
# ────────────────────────────────────────────────────────────────────────────
probe_p3() {
    local id="P3"
    local cfg="$OPENCODE_CONFIG_DIR/opencode.jsonc"
    local model="" provider=""
    if [[ -f "$cfg" ]]; then
        model="$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null | head -1 | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
        provider="${model%%/*}"
    fi

    local auth="$HOME/.local/share/opencode/auth.json"
    local auth_hit="no" auth_fields="<无条目>"
    if [[ -f "$auth" ]] && [[ -n "$provider" ]] && have python3; then
        auth_hit="$(python3 - "$auth" "$provider" <<'PYEOF' 2>/dev/null || echo "no"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print("no"); raise SystemExit
for key in (sys.argv[2], sys.argv[2] + "-coding-plan"):
    v = d.get(key)
    if isinstance(v, dict) and v.get("key"):
        print("yes"); raise SystemExit
print("no")
PYEOF
)"
        auth_fields="$(python3 - "$auth" "$provider" <<'PYEOF' 2>/dev/null || echo "<无条目>"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print("<读取失败>"); raise SystemExit
for key in (sys.argv[2], sys.argv[2] + "-coding-plan"):
    v = d.get(key)
    if isinstance(v, dict):
        print(key + ": " + ",".join(sorted(v.keys())))
        raise SystemExit
print("<无条目>")
PYEOF
)"
    fi

    # ~/.config/opencode/.env 里的凭证变量名（只报名字，不报值）
    local envfile="$OPENCODE_CONFIG_DIR/.env"
    local env_names=""
    if [[ -f "$envfile" ]]; then
        env_names="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$envfile" 2>/dev/null | tr -d '=' | tr '\n' ',' | sed 's/,$//')"
    fi

    local models_ok="no" model_in_list="no" models_out=""
    if have opencode; then
        models_out="$(opencode models 2>/dev/null || true)"
        [[ -n "$models_out" ]] && models_ok="yes"
        if [[ -n "$model" ]] && printf '%s' "$models_out" | grep -qF "$model"; then
            model_in_list="yes"
        elif [[ -n "$provider" ]] && printf '%s' "$models_out" | grep -qF "$provider"; then
            model_in_list="yes"
        fi
    fi

    EVIDENCE+=("配置模型：${model:-<未读到>}（来源：${cfg}）")
    EVIDENCE+=("provider：${provider:-<未知>}")
    EVIDENCE+=("opencode models 可用：${models_ok}；配置模型在列表中：${model_in_list}")
    EVIDENCE+=("auth.json 命中 provider 条目：${auth_hit}（${auth_fields}；值不打印）")
    EVIDENCE+=("auth.json 路径：${auth}")
    if [[ -n "$env_names" ]]; then
        EVIDENCE+=("${envfile} 中的凭证变量名（只列名）：${env_names}")
    else
        EVIDENCE+=("${envfile}：不存在或无 KEY= 形式条目")
    fi

    if [[ "$models_ok" == "yes" && ( "$auth_hit" == "yes" || -n "$env_names" ) ]]; then
        record "$id" "PASS" "当前环境存在可用 provider 与凭证来源（L2 无需额外配 secret）"
    else
        record "$id" "FAIL" "未确认可用的模型凭证来源"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# 事件流分析：把 stdout 的 NDJSON 事件流折算成耗时口径（不额外消耗额度）
# ────────────────────────────────────────────────────────────────────────────
# 输出 KEY=VALUE 行，供 probe_p4 读取：
#   EVENT_LINES            事件行数
#   EVENT_SPAN_SEC         事件流跨度（首事件 → 末事件）
#   FRONT_SESSION_ID       事件流里的 session id（front 侧真实 id）
#   DELEGATE_CALLS         delegate 工具调用次数
#   DELEGATE_OK            outcome=succeeded 的次数
#   DELEGATE_BUSY          outcome=busy 的次数
#   DELEGATE_NO_SESSION    没有 session_id 的次数（= 参数校验被拒，未建 session）
#   DELEGATE_REJECTED      状态为 error / 带 error message 的次数
#   FIRST_DELEGATE_PRE_SEC prompt 注入 → 首次 delegate **发起**
#   FIRST_DELEGATE_CALL_SEC 首次 delegate 调用发起→完成
#   FIRST_OK_CALL_SEC      首次 outcome=succeeded 的 delegate 调用发起→完成
#   CALL_MIN_SEC / CALL_MED_SEC / CALL_MAX_SEC  全部 delegate 调用耗时分布
#   RETRY_GAP_MED_SEC      相邻两次 delegate 发起间隔的中位数（模型一轮的思考成本）
#   DELEGATE_PROJECT_DIR / DELEGATE_RESUME_SESSION  首次 delegate 的入参
EV_ANALYSIS=""
ev_val() {
    local v
    v="$(printf '%s\n' "$EV_ANALYSIS" | sed -n "s/^$1=//p" | head -1)"
    [[ -z "$v" ]] && v="NA"
    printf '%s' "$v"
}
analyze_event_stream() {
    EV_ANALYSIS="$(python3 - "$1" <<'PYEOF' 2>/dev/null || true
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
front_sid = ""
for ev in events:
    if ev.get("sessionID"):
        front_sid = ev["sessionID"]
        break

calls = []
for ev in events:
    if ev.get("type") != "tool_use":
        continue
    part = ev.get("part") or {}
    if part.get("tool") != "delegate":
        continue
    st = part.get("state") or {}
    tm = st.get("time") or {}
    start, end = tm.get("start"), tm.get("end")
    dur = round((end - start) / 1000.0, 2) if (start and end) else None
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
    err_msg = err.get("message") if isinstance(err, dict) else None
    calls.append({
        "start_rel": round((start - t0) / 1000.0, 1) if start else None,
        "end_rel": round((end - t0) / 1000.0, 1) if end else None,
        "dur": dur,
        "outcome": summary.get("outcome"),
        "session_id": summary.get("session_id"),
        "project_dir": inp.get("project_dir"),
        "resume_session": inp.get("resume_session"),
        "scope": inp.get("scope"),
        "acceptance_type": type(inp.get("acceptance")).__name__,
        "status": st.get("status"),
        "error": err_msg,
    })

def med(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else round((xs[n // 2 - 1] + xs[n // 2]) / 2.0, 2)

durs = [c["dur"] for c in calls if c["dur"] is not None]
ok_durs = [c["dur"] for c in calls if c["outcome"] == "succeeded" and c["dur"] is not None]
starts = [c["start_rel"] for c in calls if c["start_rel"] is not None]
gaps = [round(starts[i + 1] - starts[i], 1) for i in range(len(starts) - 1)]

out = []
out.append("EVENT_LINES=%d" % len(events))
out.append("EVENT_SPAN_SEC=%.1f" % (((events[-1].get("timestamp") or t0) - t0) / 1000.0))
out.append("FRONT_SESSION_ID=%s" % front_sid)
out.append("DELEGATE_CALLS=%d" % len(calls))
out.append("DELEGATE_OK=%d" % sum(1 for c in calls if c["outcome"] == "succeeded"))
out.append("DELEGATE_BUSY=%d" % sum(1 for c in calls if c["outcome"] == "busy"))
out.append("DELEGATE_NO_SESSION=%d" % sum(1 for c in calls if not c.get("session_id")))
out.append("DELEGATE_REJECTED=%d" % sum(1 for c in calls if c.get("error") or c.get("status") == "error"))
out.append("FIRST_DELEGATE_PRE_SEC=%s" % (starts[0] if starts else "NA"))
out.append("FIRST_DELEGATE_CALL_SEC=%s" % (durs[0] if durs else "NA"))
out.append("FIRST_OK_CALL_SEC=%s" % (ok_durs[0] if ok_durs else "NA"))
out.append("CALL_MIN_SEC=%s" % (min(durs) if durs else "NA"))
out.append("CALL_MED_SEC=%s" % (med(durs) if durs else "NA"))
out.append("CALL_MAX_SEC=%s" % (max(durs) if durs else "NA"))
out.append("RETRY_GAP_MED_SEC=%s" % (med(gaps) if gaps else "NA"))
out.append("DELEGATE_PROJECT_DIR=%s" % (calls[0]["project_dir"] if calls else "NA"))
out.append("DELEGATE_RESUME_SESSION=%s" % (calls[0]["resume_session"] if calls else "NA"))
for line in out:
    print(line)
PYEOF
)"
}

# ────────────────────────────────────────────────────────────────────────────
# P4 —— 单条真实委托耗时（两个口径：整轮 elapsed / 事件流推导）
# ────────────────────────────────────────────────────────────────────────────
# 口径 A（整轮 elapsed）：opencode run 进程的墙钟时间 —— 含模型重试与失败，
#         会被「模型重试循环」放大，不能当成「一条委托的耗时」。
# 口径 B（事件流推导）：从 NDJSON 事件流直读，不受循环影响：
#         - prompt 注入 → 首次 delegate **发起**（前置耗时）
#         - 单次 delegate 调用发起→完成（调用耗时）
#         → 相加 = 一条「顺利」委托的耗时基线。
# 两个口径必须分别报告：只报口径 A 会把病态循环当成常态。
probe_p4() {
    local id="P4"
    if [[ -z "$RUN_STDOUT" || ! -f "$RUN_STDOUT" ]]; then
        EVIDENCE+=("采集方式：bash tests/scripts/probe_real_runtime_prereqs.sh --with-real-run")
        record "$id" "SKIP" "未执行真实委托，无耗时数据（默认只读模式）"
        return
    fi

    analyze_event_stream "$RUN_STDOUT"

    local span calls ok_cnt busy_cnt nosid rej_cnt
    span="$(ev_val EVENT_SPAN_SEC)"; calls="$(ev_val DELEGATE_CALLS)"
    ok_cnt="$(ev_val DELEGATE_OK)"; busy_cnt="$(ev_val DELEGATE_BUSY)"
    nosid="$(ev_val DELEGATE_NO_SESSION)"; rej_cnt="$(ev_val DELEGATE_REJECTED)"

    # ── 口径 A：整轮 elapsed ────────────────────────────────────────────────
    local whole="N/A" per8_a="N/A"
    if [[ -n "$RUN_ELAPSED" ]]; then
        whole="$RUN_ELAPSED"
        per8_a="$(awk -v s="$whole" 'BEGIN{printf "%.0f", s*8}')"
    fi
    if [[ -n "$RUN_ELAPSED" ]]; then
        EVIDENCE+=("【口径 A｜整轮 elapsed】opencode run 进程墙钟 = ${whole}s")
    else
        EVIDENCE+=("【口径 A｜整轮 elapsed】N/A（本次只复用了已采集的 stdout，没有本轮进程墙钟）")
    fi
    EVIDENCE+=("      来源：$RUN_STDOUT 的运行耗时（进程级），含模型重试与失败")
    EVIDENCE+=("      8 条外推（病态：每条都撞上同样的循环并被 timeout 掐断）= ${per8_a}s")
    EVIDENCE+=("      事件流跨度（首事件→末事件）= ${span}s；delegate 调用次数 = ${calls}")

    # ── 口径 B：事件流推导 ────────────────────────────────────────────────
    local pre call ok_call total per8_b
    pre="$(ev_val FIRST_DELEGATE_PRE_SEC)"
    call="$(ev_val FIRST_DELEGATE_CALL_SEC)"
    ok_call="$(ev_val FIRST_OK_CALL_SEC)"
    total="NA"; per8_b="NA"
    if [[ "$pre" != "NA" && "$call" != "NA" ]]; then
        total="$(awk -v a="$pre" -v b="$call" 'BEGIN{printf "%.1f", a+b}')"
        per8_b="$(awk -v a="$total" 'BEGIN{printf "%.0f", a*8}')"
    fi
    EVIDENCE+=("【口径 B｜事件流推导】prompt 注入→首次 delegate 发起 = ${pre}s")
    EVIDENCE+=("      单次 delegate 调用发起→完成 = ${call}s（中位 $(ev_val CALL_MED_SEC)s / 区间 $(ev_val CALL_MIN_SEC)s~$(ev_val CALL_MAX_SEC)s）")
    if [[ "$ok_call" != "NA" ]]; then
        EVIDENCE+=("      首次 **成功** 委托（outcome=succeeded）调用耗时 = ${ok_call}s")
        EVIDENCE+=("      单条「顺利」委托 = ${pre}s + ${ok_call}s = $(awk -v a="$pre" -v b="$ok_call" 'BEGIN{printf "%.1f", a+b}')s")
        EVIDENCE+=("      8 条外推（顺利：每条一次成功委托、不重试）= ${per8_b}s")
    else
        EVIDENCE+=("      ⚠ 本次事件流里 **没有** outcome=succeeded 的 delegate（成功 ${ok_cnt} 次 / busy ${busy_cnt} 次 / 无 session_id ${nosid} 次 / 被拒 ${rej_cnt} 次）")
        EVIDENCE+=("      → 「成功委托耗时」本次无实测样本；下面的顺利外推是用 **busy 路径的调用耗时** 代替，属**上界不成立**的估计")
        EVIDENCE+=("      8 条外推（顺利：前置换 ${pre}s + 调用耗时按实测中位 $(ev_val CALL_MED_SEC)s 代）= ${per8_b}s")
    fi
    EVIDENCE+=("      相邻两次 delegate 发起间隔中位 = $(ev_val RETRY_GAP_MED_SEC)s（模型一轮的思考成本，重试时叠加）")
    EVIDENCE+=("      front 会话 id（事件流直读）= $(ev_val FRONT_SESSION_ID)")
    EVIDENCE+=("      首次 delegate 入参：project_dir=$(ev_val DELEGATE_PROJECT_DIR) resume_session=$(ev_val DELEGATE_RESUME_SESSION)")

    EVIDENCE+=("会话 id（opencode run --session 传入值）：${RUN_SESSION_ID:-<无>}")
    [[ -n "$RUN_FILE_CHECK" ]] && EVIDENCE+=("产物校验：${RUN_FILE_CHECK}")
    record "$id" "PASS" "真实委托耗时已采集（口径A 整轮 ${whole}s / 口径B 事件流推导 单条 ${total}s）"
}

# ────────────────────────────────────────────────────────────────────────────
# P5 —— bats 的 BATS_TEST_TMPDIR 能否重定向到 /workspace 下
# ────────────────────────────────────────────────────────────────────────────
probe_p5() {
    local id="P5"
    if ! have bats; then
        EVIDENCE+=("command -v bats → <未找到>")
        record "$id" "SKIP" "未安装 bats，无法实测重定向行为"
        return
    fi

    local sandbox="$PROBE_ROOT/p5-sandbox"
    mkdir -p "$sandbox" 2>/dev/null
    printf 'rdd-workflow-e2e probe\n' > "$sandbox/.probe-owner" 2>/dev/null || true
    local probe_file="$sandbox/p5.bats"
    cat > "$probe_file" <<'BATS_EOF'
@test "p5" {
  echo "BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR" >> "$P5_OUT"
  echo "BATS_RUN_TMPDIR=$BATS_RUN_TMPDIR" >> "$P5_OUT"
  echo "BATS_TMPDIR=${BATS_TMPDIR:-<unset>}" >> "$P5_OUT"
}
BATS_EOF

    local out="$sandbox/observed.txt"
    : > "$out"
    local knob_ok="none" knob_desc=""

    # 逐个试各种重定向旋钮，看哪个真的把 BATS_TEST_TMPDIR 挪走
    local entry name value observed
    for entry in \
        "BATS_TEST_TMPDIR:$sandbox/direct" \
        "BATS_TMPDIR:$sandbox/viaBatsTmp" \
        "BATS_RUN_TMPDIR:$sandbox/viaRunTmp" \
        "TMPDIR:$sandbox/viaTmpdir"; do
        name="${entry%%:*}"; value="${entry#*:}"
        : > "$out"
        # bats 要求 TMPDIR 目标目录已存在且可写，否则直接报错退出
        mkdir -p "$value" 2>/dev/null
        ( cd "$sandbox" && env "$name=$value" P5_OUT="$out" bats "$probe_file" >/dev/null 2>&1 )
        observed="$(grep '^BATS_TEST_TMPDIR=' "$out" 2>/dev/null | head -1 | cut -d= -f2-)"
        if [[ -n "$observed" && "$observed" == "$sandbox"* ]]; then
            knob_ok="$name"
            knob_desc="${name}=${value} → BATS_TEST_TMPDIR=${observed}"
            break
        fi
    done

    # --tmpdir CLI 旗标（部分 bats 版本支持）
    local cli_ok="no"
    if bats --help 2>&1 | grep -q -- '--tmpdir'; then cli_ok="yes"; fi

    # 可写性候选
    local ws_root="no" ws_main="no" repo_tmp="no"
    ( mkdir -p /workspace/.p5-write-probe 2>/dev/null && rmdir /workspace/.p5-write-probe 2>/dev/null ) && ws_root="yes"
    ( mkdir -p /workspace/main/.p5-write-probe 2>/dev/null && rmdir /workspace/main/.p5-write-probe 2>/dev/null ) && ws_main="yes"
    # ⚠ F3：探针在**仓库内**造出来的目录必须自己清掉，且只删自己造的（带 .probe-owner 标记）。
    # 探针子目录固定为 .tmp-l2/p5-noise-probe/；父目录 .tmp-l2/ 只有在**空**时才 rmdir（不碰别人的内容）。
    local repo_tmp_target="$REPO_ROOT/.tmp-l2"
    local repo_tmp_probe="$repo_tmp_target/p5-noise-probe"
    if mkdir -p "$repo_tmp_probe" 2>/dev/null; then
        repo_tmp="yes"
        printf 'rdd-workflow-e2e probe\n' > "$repo_tmp_probe/.probe-owner" 2>/dev/null || true
    fi

    # git status 副作用：把 bats 临时目录放进**仓库内**会不会脏 git
    local git_noise="unknown"
    if have git && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local probe_rel=".tmp-l2/p5-noise-probe/probe.txt"
        : > "$repo_tmp_probe/probe.txt" 2>/dev/null
        if git -C "$REPO_ROOT" status --porcelain --untracked-files=all 2>/dev/null | grep -qF "$probe_rel"; then
            git_noise="yes（${probe_rel} 以 untracked 形式出现在 git status）"
        else
            git_noise="no（该路径已被 .gitignore 覆盖或不在仓库内）"
        fi
    fi
    # 清理探针自己造的那一个子目录（标记校验），再尝试清掉空的父目录
    if [[ -f "$repo_tmp_probe/.probe-owner" ]]; then
        rm -rf "$repo_tmp_probe"
    fi
    rmdir "$repo_tmp_target" 2>/dev/null || true

    EVIDENCE+=("bats 版本：$(bats --version 2>&1 | head -1)")
    EVIDENCE+=("生效的重定向旋钮：${knob_ok} —— ${knob_desc:-<无>}")
    EVIDENCE+=("bats --tmpdir 旗标存在：${cli_ok}")
    EVIDENCE+=("BATS_TEST_TMPDIR / BATS_TMPDIR / BATS_RUN_TMPDIR 三个环境变量均被 bats 自身覆盖，无效")
    EVIDENCE+=("/workspace 根目录可写：${ws_root}（root 属主 drwxr-xr-x，非 root 用户不可写）")
    EVIDENCE+=("/workspace/main 可写：${ws_main}（drwxrwxrwt sticky，可创建新条目）→ 推荐把 fixture 放这里，仓库外")
    EVIDENCE+=("仓库内 .tmp-l2 可写：${repo_tmp}（${repo_tmp_target}）→ 可用但会脏 git status")
    EVIDENCE+=("把 bats 临时目录放进仓库内是否脏 git status：${git_noise}")

    if [[ "$knob_ok" != "none" ]]; then
        record "$id" "PASS" "可用 ${knob_ok} 把 BATS_TEST_TMPDIR 重定向到 /workspace 下（推荐 /workspace/main/，仓库外）"
    else
        record "$id" "FAIL" "没有找到能重定向 BATS_TEST_TMPDIR 的受支持旋钮"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# 真实委托（--with-real-run）：单次调用最多 1 次
# ────────────────────────────────────────────────────────────────────────────
RUN_STDOUT=""; RUN_ELAPSED=""; RUN_SESSION_ID=""; RUN_FILE_CHECK=""; RUN_WORKDIR=""

build_fixture() {
    local dest="$1"
    mkdir -p "$dest" || return 1
    # 复制工作树（排除 .git —— git 对象文件只读，复制后会 EACCES）
    ( cd "$REPO_ROOT" && tar --exclude='./.git' --exclude='./.tmp-l2' -cf - . ) \
        | ( cd "$dest" && tar -xf - ) || return 1
    # ⚠️ 必须清掉**登记文件**：拷贝过来的 pair.json / role.json 里带着**别的** session 登记，
    #    front 读到后会把它当 resume_session 传给 delegate → delegate 去续接那个 session →
    #    拿到 busy → front 反复重试（实测会退化成 10 分钟的重试循环，见 docs §8.3）。
    #    只删这两个登记文件，保留 .rddf/state/ 的其余内容（registerSession 会自己 mkdir -p）。
    rm -f "$dest/.rddf/state/pair.json" "$dest/.rddf/state/role.json"
    git -C "$dest" init -q || return 1
    git -C "$dest" config user.email "l2-probe@test.local"
    git -C "$dest" config user.name "L2 Probe"
    git -C "$dest" add -A || return 1
    git -C "$dest" commit -q -m "l2 probe fixture" || return 1
    return 0
}

run_real_delegate() {
    if ! have opencode; then
        echo "!! opencode 不在 PATH，跳过真实委托" >&2
        return 1
    fi
    if [[ "$PROBE_ROOT" != /workspace/* ]]; then
        echo "!! PROBE_ROOT 不在 /workspace 下（front 的 external_directory 放行不到），跳过真实委托" >&2
        return 1
    fi
    # ⚠️ fixture 必须在**仓库外**：放在仓库内时 front 会读到仓库自己的 pair.json
    #    （里面登记着活的工程 session）→ 拿它当 resume_session → 拿到 busy → 无限重试（docs §8.3）。
    case "$PROBE_ROOT/" in
        "$REPO_ROOT"/*) echo "!! PROBE_ROOT 在仓库内（$REPO_ROOT），真实委托会被仓库的 pair.json 污染，跳过" >&2; return 1 ;;
    esac

    RUN_WORKDIR="$PROBE_ROOT/real-run"
    local fixture="$RUN_WORKDIR/engproj"
    mkdir -p "$RUN_WORKDIR" || return 1
    printf 'rdd-workflow-e2e probe\n' > "$RUN_WORKDIR/.probe-owner" 2>/dev/null || true
    if [[ -d "$fixture" ]]; then
        find "$fixture" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    fi
    build_fixture "$fixture" || { echo "!! fixture 构建失败" >&2; return 1; }

    # 隔离会话：opencode run --agent X 会延续同 agent 的最近会话
    RUN_SESSION_ID="ses_$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
    # prompt 工程（docs §8.1/§8.2/§8.3 实测踩坑后的要求）：
    #   - 只做这一件事           → 防止 front 顺手探查/跑偏
    #   - 绝对路径写死           → 防止 front 自选 project_dir 漂到别处
    #   - acceptance 明确是字符串 → 防止模型传成数组被参数校验拒（无 session_id）
    #   - busy/被拒直接汇报      → 防止模型陷入重试循环（实测 8 次 busy）
    local prompt
    prompt="$(cat <<PROMPT_EOF
只做这一件事：用 delegate 工具委托一次，让工程 session 在 ${fixture} 里新建 smoke.txt（内容 ok）。
delegate 的参数严格按下面填：
- project_dir: ${fixture}
- agent: build
- scope: ["smoke.txt"]
- acceptance: "文件 ${fixture}/smoke.txt 存在，内容去掉首尾空白后等于 ok"
注意：acceptance 必须写成字符串，不能写成数组；project_dir 必须就是 ${fixture} 这个绝对路径。
如果 delegate 返回 busy 或被拒绝，直接汇报结果即可，不要重复尝试、不要换参数再试。
PROMPT_EOF
)"
    local out="$RUN_WORKDIR/stdout.json" err="$RUN_WORKDIR/stderr.log"

    echo ">> 真实委托（唯一一次）：opencode run --agent front --session ${RUN_SESSION_ID}" >&2
    local start end rc
    start="$(date +%s.%N)"
    ( cd "$RUN_WORKDIR" && timeout 600 opencode run --agent front --session "$RUN_SESSION_ID" \
        --format json "$prompt" ) >"$out" 2>"$err"
    rc=$?
    end="$(date +%s.%N)"
    RUN_ELAPSED="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b-a}')"
    RUN_STDOUT="$out"

    echo ">> 退出码=${rc} 耗时=${RUN_ELAPSED}s" >&2
    if [[ -f "$fixture/smoke.txt" ]]; then
        RUN_FILE_CHECK="smoke.txt 已生成（内容：$(head -c 60 "$fixture/smoke.txt" | tr '\n' ' ')）"
    else
        RUN_FILE_CHECK="smoke.txt 未生成（见 ${err}）"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────────────────────
printf '════ front+delegate L2 运行时前置探针 ════\n'
printf 'repo        : %s\n' "$REPO_ROOT"
printf 'probe root  : %s\n' "$PROBE_ROOT"
printf 'opencode    : %s\n' "$(command -v opencode 2>/dev/null || echo '<未找到>')"
printf 'mode        : %s\n' "$([[ $WITH_REAL_RUN -eq 1 ]] && echo '含 1 次真实委托' || echo '只读（不调模型）')"

if ! mkdir -p "$PROBE_ROOT" 2>/dev/null; then
    echo "❌ 无法创建探针工作目录：$PROBE_ROOT" >&2
    exit 2
fi
# 标记目录归本脚本所有：清理时只删带标记的目录，避免误删用户自定路径
printf 'rdd-workflow-e2e probe\n' > "$PROBE_ROOT/.probe-owner" 2>/dev/null || true

if [[ $WITH_REAL_RUN -eq 1 ]]; then
    run_real_delegate || true
fi

# 复用已采集的 stdout 做结构分析（不消耗模型额度）
if [[ -n "${PROBE_STDOUT:-}" && -f "${PROBE_STDOUT}" ]]; then
    RUN_STDOUT="$PROBE_STDOUT"
    printf '复用 stdout  : %s（未触发真实委托）\n' "$RUN_STDOUT"
fi

probe_p1
probe_p2
probe_p3
probe_p4
probe_p5

# ── 汇总 ────────────────────────────────────────────────────────────────────
printf '\n════ 探针汇总 ════\n'
for row in "${SUMMARY_ROWS[@]}"; do
    printf '%s\n' "$row" | awk -F'|' '{printf "  %-6s %-4s %s\n", $1, $2, $3}'
done
printf '\nPASS=%s  FAIL=%s  SKIP=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ $KEEP_WORKDIR -eq 0 ]]; then
    # 只清理本脚本自己造出来的子目录（各自带 .probe-owner 标记）；
    # PROBE_ROOT 本身仅在空时移除（rmdir 失败即保留）
    d=""
    for d in "$PROBE_ROOT/real-run" "$PROBE_ROOT/p5-sandbox"; do
        if [[ -f "$d/.probe-owner" ]]; then
            rm -rf "$d"
        fi
    done
    rm -f "$PROBE_ROOT/.probe-owner"
    rmdir "$PROBE_ROOT" 2>/dev/null || true
else
    printf '工作目录保留：%s\n' "$PROBE_ROOT"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
