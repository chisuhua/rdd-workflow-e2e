#!/usr/bin/env bash
# tests/integration/test_oracle_intent_gate.bats — 「oracle 意图闸门」的**行为层可观测性与取证**
#
# 背景（2026-11-16）：
#   v2.37 给 architect 审查链加了「oracle 调用前的意图检查点」，v2.38 补了**静态**守卫。
#   但静态判据只证明「文档写了」，证明不了「父模型真的把意图陈述带进 oracle 的输入」
#   「oracle 真的会因意图未定而拒发判定行」—— 本文件补这一层。
#
# 立项：`~/.config/opencode/openspec/changes/oracle-intent-gate-e2e/`
#   proposal AC1–AC8 / design D1–D10（**本文件只实现 PR-1**：AC1 探针 + AC6 门控 + AC8 报告 + AC7-①）
#
# 门控：
#   E2E_REAL_RUNTIME 未设置 → 全部用例 skip，bats 退出码 0（默认态，不进 CI）。
#   E2E_REAL_RUNTIME=1      → 真正执行（需要真实模型 + 真实宿主；**吃额度**）。
#
# 断言纪律（本仓 `docs/runtime-assertion-discipline.md`）：
#   ① 只认**文件系统事实**与**结构化字段**，不断言模型自然语言措辞；
#   ② 前提本身要被验证（否则恒真）；
#   ③ 每条用例配一次变红演练。
#
# 用法：
#   E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-oig" \
#   bats tests/integration/test_oracle_intent_gate.bats
#
# ⚠ **不用 `--standalone`**：本仓 `test_independent_build_session.bats`（2026-11-16 真跑通过）
#   已实证本机 `opencode run` 用不带 `--standalone` 的形态工作（该文件还记录了「传它会直接失败」，
#   虽然 `opencode run --help` 的 GLOBAL FLAGS 里**有**这个 flag ⇒ 两处说法冲突，本文件按**已跑通**的那一侧写）。
#
# ⚠ **通道选择**：E-B（PR-2）与 E-A（PR-3）都走**父会话 wrapper**
#   （`opencode run --agent build` ⇒ 用 `subagent` 工具调 `agent=oracle`），而不是 `--agent oracle` 直跑
#   （oracle 是 `mode: "subagent"`，能否被 `--agent` 直跑**未验证**）。同一条通道 ⇒ 少一个变量。

load ../test_helper

oig_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

OIG_CASE_TIMEOUT="${OIG_CASE_TIMEOUT:-300}"
OIG_ROOT="${OIG_ROOT:-$REPO_ROOT/.tmp-oig}"
OIG_SRC="${SC_SRC:-$HOME/.config/opencode}"
OIG_REPORT="${OIG_REPORT:-$REPO_ROOT/.rddf/reviews/oracle-intent-gate-e2e-observation.md}"
OIG_FIXTURE_ROOT="${OIG_FIXTURE_ROOT:-$REPO_ROOT/.tmp-oig-fixtures}"

# 主证据载体（design D2）：A = `part.state.output`；B = 落盘 `.rddf/reviews/<adr>.md`。
# ⚠ **未跑探针前保持 `pending`** ⇒ 依赖它的用例 **skip**（不许假设 A 可用）。
OIG_CARRIER="${OIG_CARRIER:-pending}"

setup() {
    # 路径变量必须在 skip 之前导出：setup 里 skip 时 teardown **仍然执行**，
    # 而 teardown 会调 oig_kill_processes —— 前缀为空时它会退化成匹配一切。
    export OIG_ROOT OIG_SRC OIG_REPORT
    mkdir -p "$OIG_ROOT" "$OIG_FIXTURE_ROOT" "$(dirname "$OIG_REPORT")"
}

# ⚠ **不**在 setup 里全局 skip：本文件含**零模型**用例（AC7-① 的两次变红演练），
#   它们应当**进 CI**。⇒ 需要真实运行时的用例在**用例开头**调本函数。
#   （惯例参照本仓 `test_independent_build_session_vocab.bats`：零额度判据不该被运行时门控一起跳过。）
oig_require_runtime() {
    oig_enabled || skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
}

teardown() {
    oig_kill_processes
}

# ── 进程清理（照 `test_subagent_contract_runtime.bats` 的 `sc_kill_sc_processes`）──
# 背景服务继承 OPENCODE_DB 但不随父进程退出 ⇒ 临时目录被占住（rm: Device or resource busy）。
oig_kill_processes() {
    [ -n "${OIG_ROOT:-}" ] || return 0
    case "$OIG_ROOT" in /*) ;; *) return 0 ;; esac
    local pid db
    for pid in $(pgrep -f "opencode" 2>/dev/null || true); do
        [ -r "/proc/$pid/environ" ] || continue
        db="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^OPENCODE_DB=//p')"
        case "$db" in
            "$OIG_ROOT"/*) kill -9 "$pid" 2>/dev/null || true ;;
        esac
    done
}

# ── 真源派生（**唯一真源 = $OIG_SRC/prompts/oracle.md**，不手抄词表）───────────

# 判定行正则（**其他审查**那一套：`判定: APPROVE | REJECT`）
#   ⚠ 本文件的审查对象是项目 `docs/adr/**` ⇒ **不属治理面**（build.md 治理面作用域表右列）
#     ⇒ 不接受「治理面判定:」那一套（design D4）。
oig_verdict_pattern() {
    python3 - "$OIG_SRC/prompts/oracle.md" <<'PY'
import re, sys
path = sys.argv[1]
try:
    md = open(path, encoding="utf-8", errors="replace").read()
except OSError as e:
    sys.exit(f"读不到真源 {path}: {e}")
m = re.search(r"^## 模式\s*$(.*?)^## ", md, re.M | re.S)
if not m:
    sys.exit(f"真源 {path} 缺「## 模式」段")
seg = m.group(1)
v = re.search(r"其他审查\s*=\s*`判定:\s*([A-Za-z_ |]+)`", seg)
if not v:
    sys.exit("真源「模式」段缺「其他审查 = `判定: …`」词表（判据派生锚点失效）")
vals = [x.strip() for x in v.group(1).split("|") if x.strip()]
if not vals:
    sys.exit("真源「判定:」词表为空 ⇒ 派生锚点失效")
# 允许 markdown 粗体包裹（实测 oracle 会写 `**判定: REJECT**`；行首语义不变）
# ⚠ **v2.40 起还要容忍「前置标注 + 判定行同一行」**：第 4 层（审查域未声明）要求 oracle 写
#   `**审查域=未声明（默认其他审查）** — 判定: APPROVE` ⇒ 判定行**不在行首** ⇒
#   纯行首锚会**假阴性**（2026-11-17 实测：态①被误判为「无判定行」⇒ 两态差分结论反了）。
#   ⇒ 前缀只容忍「**标注** + 分隔符」这一种形态（不匹配正文里的任意引用 ⇒ 不引入假绿）。
print(r"^\s*(?:\*\*[^*]+\*\*\s*[—–\-]\s*)?\*{0,2}判定:\s*(" + "|".join(vals) + r")\b")
PY
}

# 意图陈述的组成词（从意图前提表首行派生：`意图已定（要解决的问题 + 范围边界都给了）`）
oig_intent_terms() {
    python3 - "$OIG_SRC/prompts/oracle.md" <<'PY'
import re, sys
path = sys.argv[1]
try:
    md = open(path, encoding="utf-8", errors="replace").read()
except OSError as e:
    sys.exit(f"读不到真源 {path}: {e}")
m = re.search(r"意图已定（(.+?)都给了）", md)
if not m:
    sys.exit("真源缺「意图已定（…都给了）」⇒ 术语派生锚点失效（意图前提段被删/被改写？）")
terms = [t.strip() for t in m.group(1).split("+") if t.strip()]
if len(terms) < 2:
    sys.exit(f"意图陈述的组成词只派生出 {len(terms)} 项 ⇒ 派生锚点失效")
print("\n".join(terms))
PY
}

# ── fixture（design D5）─────────────────────────────────────────────────────
# 最小 git 工程 + `docs/adr/`（**必须存在**：判定三态第 3 态是「一个都不存在 ⇒ 只讨论不落文档」）
# + `role.json`（role-v2 全集，current_role=architect）。
oig_fixture() {
    local name="$1"
    local dest="$OIG_FIXTURE_ROOT/$name"
    local marker="$OIG_FIXTURE_ROOT/${name}.oig-owner"
    mkdir -p "$OIG_FIXTURE_ROOT"
    if [ -d "$dest" ] && [ -f "$marker" ]; then
        rm -rf "$dest"
    elif [ -d "$dest" ]; then
        dest="$OIG_FIXTURE_ROOT/${name}-$(date +%s)"
        marker="$dest.oig-owner"
    fi
    mkdir -p "$dest/src" "$dest/docs/adr" "$dest/.rddf/state"
    printf 'export const x = 1\n' > "$dest/src/app.ts"
    cat > "$dest/docs/adr/ADR-001.md" <<'ADR'
# ADR-001 读路径缓存

- Status: Accepted
- Date: 2026-01-01

## 背景与问题

读接口 p95 延迟偏高。

## 决策

在读路径加一层进程内缓存。

## 后果 / 代价

- 正面：p95 下降。
- 负面：写路径的一致性变复杂 ⇒ 本期不动写路径。
ADR
    cat > "$dest/.rddf/state/role.json" <<'JSON'
{"current_role":"architect","updated_at":"2026-01-01T00:00:00.000Z","updated_by":"user","session_id":"oig-fixture","auto_switch_window":null,"history":[],"sessions":{"oig-fixture":{"current_role":"architect","auto_switch_window":null,"auto_answer":null,"updated_at":"2026-01-01T00:00:00.000Z"}},"schema_version":"role-v2"}
JSON
    cat > "$dest/docs/adr/draft-002.md" <<'ADR2'
# draft-002 读路径缓存选型（待审）

- Status: Draft
- Date: 2026-01-02

## 决策

读路径使用进程内 LRU 缓存，写时失效。

## 后果 / 代价

- 正面：读 p95 预期显著下降。
- 负面：多进程部署时各进程缓存独立。
ADR2
    git -C "$dest" init -q
    git -C "$dest" config user.email "oig@test.local"
    git -C "$dest" config user.name "OIG Test"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "oig fixture"
    printf 'oig-owned\n' > "$marker"
    printf '%s' "$dest"
}

oig_new_session() {
    printf 'ses_%s' "$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
}

# ── 跑一次父会话（照 IBS 的 ib_run：**不带 `--standalone`**）──────────────────
# $1 = 名字  $2 = 工程目录  $3 = prompt  $4 = session id
oig_run_parent() {
    local name="$1" cwd="$2" prompt="$3" sid="$4"
    local out="$OIG_ROOT/${name}.json" err="$OIG_ROOT/${name}.err" rc=0
    local model_args=()
    [ -n "${OIG_MODEL:-}" ] && model_args=(--model "$OIG_MODEL")
    ( cd "$cwd" && timeout "$OIG_CASE_TIMEOUT" opencode run --agent build \
        --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err" || rc=$?
    printf '%s' "$rc" > "$OIG_ROOT/${name}.rc"
    printf 'exit_code=%s\nstdout=%s\nstderr=%s\n' "$rc" "$out" "$err" > "$OIG_ROOT/${name}.meta"
    oig_skip_if_unusable "$name" "$out" "$err" "$rc"
    return 0
}

# ── skip 纪律（design D7 三档；**一律不得当绿**）────────────────────────────────
oig_skip_if_unusable() {
    local name="$1" out="$2" err="$3" rc="$4"
    if grep -q 'provider.rate-limit\|rate_limit\|insufficient_quota' "$out" "$err" 2>/dev/null; then
        skip "provider 额度不足（本用例未判定）：见 $out / $err"
    fi
    if [ "$rc" -eq 124 ]; then
        skip "父会话超时（本用例未判定）：见 $out"
    fi
    # 没有任何 oracle 调用 ⇒ 前提未成立（不是契约回归）
    if ! grep -q '"tool":"subagent"' "$out" 2>/dev/null; then
        skip "父会话未产生 subagent 调用（本用例未判定）：见 $out"
    fi
}

# ── 从 NDJSON 里取 subagent 调用（含 **output 通道** —— AC1 探针要的就是它）──────
# 输出每行：{"i":..,"status":..,"agent":..,"prompt_len":N,"output_len":N,"output_head":".."}
oig_subagent_calls() {
    python3 - "$1" <<'PY'
import json, sys
try:
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError as e:
    sys.exit(f"读不到 NDJSON: {e}")
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
    out = st.get("output")
    out_s = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False) if out is not None else ""
    idx += 1
    print(json.dumps({
        "i": idx,
        "status": st.get("status"),
        "agent": inp.get("agent"),
        "prompt_len": len(prompt),
        "output_len": len(out_s),
        "output_head": out_s[:200].replace("\n", "\\n"),
        "error": (st.get("error") if isinstance(st.get("error"), str) else ""),
    }, ensure_ascii=False, separators=(",", ":")))
PY
}

# 全部 text 事件拼成的正文（父会话的最终响应）
oig_text_of() {
    python3 - "$1" <<'PY'
import json, sys
texts = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    part = obj.get("part") or {}
    if part.get("type") == "text" and part.get("text"):
        texts.append(part["text"])
print("\n".join(texts))
PY
}

# ── 报告（AC8：固定 9 列）──────────────────────────────────────────────────
oig_report_init() {
    if [ -f "$OIG_REPORT" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$OIG_REPORT")"
    cat > "$OIG_REPORT" <<'MD'
# oracle-intent-gate-e2e 观察报告

> 判据真源：`~/.config/opencode/openspec/changes/oracle-intent-gate-e2e/proposal.md`（AC1–AC8）
> 本文件由 `tests/integration/test_oracle_intent_gate.bats` 追加；**固定 9 列**（AC8）。

## 1. 探针结论（AC1）

- 主证据载体：**pending**（探针未跑 / 或跑完由用例回填 A / B）
- `part.state.output` 通道：未验证

## 2. 记录表

| 用例 | 模型 id | 日期 | 请求指纹 | 尝试次数 | 全部调用序号 | 结论 | 证据路径 | SC_SRC 路径 + HEAD |
|---|---|---|---|---|---|---|---|---|
MD
}

oig_report_row() {
    local case_name="$1" model="$2" fingerprint="$3" attempts="$4" calls="$5" verdict="$6" evidence="$7"
    local src_head
    src_head="$(git -C "$OIG_SRC" rev-parse --short HEAD 2>/dev/null || echo "no-git")"
    # 规则真源有未提交改动 ⇒ 标 `+dirty`（否则 HEAD 会让人误以为跑的是已提交文本）
    if [ -n "$(git -C "$OIG_SRC" status --porcelain -- prompts/oracle.md prompts/build.md 2>/dev/null)" ]; then
        src_head="$src_head+dirty"
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s (%s) |\n' \
        "$case_name" "${model:-default}" "$(date -u +%Y-%m-%d)" "$fingerprint" "$attempts" "$calls" \
        "$verdict" "$evidence" "$OIG_SRC" "$src_head" >> "$OIG_REPORT"
}

# ══════════════════════════════════════════════════════════════════════════
# AC7-① 变红演练：真源缺判定行词表 ⇒ 派生必须**红**（**零模型**）
#   ⚠ 方向必须对：删的是**判定行词表**（删「意图前提段」不会让 E-A 红 —— 那是两组独立 bullet，
#     删闸门只会让 oracle 不再拒发、判定行照样出现 ⇒ 见 design D8）。
# ══════════════════════════════════════════════════════════════════════════
@test "AC7-①（零模型）：删掉真源的判定行词表 ⇒ 派生必须失败（不得静默返回空正则）" {
    local src="$OIG_ROOT/src-no-verdict"
    mkdir -p "$src/prompts"
    python3 - "$OIG_SRC/prompts/oracle.md" "$src/prompts/oracle.md" <<'PY'
import re, sys
md = open(sys.argv[1], encoding="utf-8").read()
# 删掉「其他审查 = `判定: …`」片段（模拟真源缺词表 —— v2.40 起词表在**定义行**里，不再单独成行）
out = md.replace("；其他审查 = `判定: APPROVE | REJECT`", "")
if out == md:
    sys.exit("注入失败：真源里没找到「其他审查 = 判定: …」片段 ⇒ 本演练的锚点已变")
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    local pat rc=0
    pat="$(OIG_SRC="$src" oig_verdict_pattern 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || { echo "❌ 真源缺词表时派生**没有**失败（返回：$pat）⇒ 判据会静默变绿/空转" >&2; return 1; }
    echo "$pat" | grep -q "缺「其他审查" || { echo "❌ 失败信息没指出缺哪一段：$pat" >&2; return 1; }
    echo "✅ 演练通过：真源缺判定行词表 ⇒ 派生失败，信息：$pat"
}

@test "AC7-①b（零模型）：删掉真源的意图前提段 ⇒ 术语派生必须失败（而不是返回空列表）" {
    local src="$OIG_ROOT/src-no-premise"
    mkdir -p "$src/prompts"
    python3 - "$OIG_SRC/prompts/oracle.md" "$src/prompts/oracle.md" <<'PY'
import re, sys
md = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(r"意图已定（(.+?)都给了）", "意图已定（已删）", md)
if out == md:
    sys.exit("注入失败：真源里没找到「意图已定（…都给了）」⇒ 本演练的锚点已变")
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    local terms rc=0
    terms="$(OIG_SRC="$src" oig_intent_terms 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || { echo "❌ 真源缺意图前提段时术语派生**没有**失败（返回：$terms）" >&2; return 1; }
    echo "$terms" | grep -q "意图已定" || { echo "❌ 失败信息没指出锚点：$terms" >&2; return 1; }
    echo "✅ 演练通过：术语派生失败，信息：$terms"
}

# ══════════════════════════════════════════════════════════════════════════
# AC1 探针：`subagent` 的 `part.state.output` 通道**是否存在全文**
#   这是 E-A/E-B 主证据载体的**前置**（design D2）⇒ 必须先跑它，再定 OIG_CARRIER。
# ══════════════════════════════════════════════════════════════════════════
@test "AC1 探针：subagent 的 state.output 通道（打印长度 + 首 200 字符）" {
    oig_require_runtime
    local proj sid
    proj="$(oig_fixture probe)"
    sid="$(oig_new_session)"
    oig_report_init

    local prompt="只做一件事：用 subagent 工具调用一次，agent 必须是 oracle，description 填 oig-probe，prompt 参数必须是下面这段原文（不要改写、不要补充）：
请给一句话结论：读路径加缓存有什么风险？"
    oig_run_parent probe "$proj" "$prompt" "$sid"

    local calls
    calls="$(oig_subagent_calls "$OIG_ROOT/probe.json")"
    [ -n "$calls" ] || { echo "❌ 没有解析到 subagent 调用：$(head -c 400 "$OIG_ROOT/probe.json")" >&2; return 1; }

    local oracle_calls
    oracle_calls="$(echo "$calls" | grep '"agent":"oracle"' || true)"
    [ -n "$oracle_calls" ] || { echo "❌ 没有 agent=oracle 的调用（实际：$calls）" >&2; return 1; }

    local first status out_len out_head
    first="$(echo "$oracle_calls" | head -1)"
    status="$(echo "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
    out_len="$(echo "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["output_len"])')"
    out_head="$(echo "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["output_head"])')"

    echo "── 探针结果 ──"
    echo "status=$status output_len=$out_len"
    echo "output_head=$out_head"

    # 载体判定（**写进报告**，供 E-A / E-B 使用）
    local carrier="B"
    if [ "$status" = "completed" ] && [ "${out_len:-0}" -gt 0 ]; then
        carrier="A"
    fi
    {
        echo ""
        echo "### AC1 探针实测（$(date -u +%Y-%m-%dT%H:%M:%SZ)）"
        echo ""
        echo "- status: \`$status\`"
        echo "- \`part.state.output\` 长度: **$out_len**"
        echo "- 首 200 字符: \`${out_head:-<空>}\`"
        echo "- **载体判定: $carrier**（A = \`state.output\` 有全文；B = 退到落盘 \`.rddf/reviews/<adr>.md\`）"
        echo "- ⚠ 后续用例须以 \`OIG_CARRIER=$carrier\` 运行（不许假设 A 可用 —— design D2）"
    } >> "$OIG_REPORT"

    oig_report_row "AC1 探针" "${OIG_MODEL:-default}" "prompt_len=${#prompt}" "1" "1" "carrier=$carrier" "$OIG_ROOT/probe.json"

    [ -n "$out_head" ] || { echo "⚠ state.output 为空 ⇒ 载体退 B（见报告）"; }
}

# ══════════════════════════════════════════════════════════════════════════
# 载体 A 的落地细节（**探针实测 2026-11-16**）：
#   `part.state.output` 是 `<subagent sessionID="…" state="completed">正文</subagent>` 包装 ⇒
#   ① 必须 **unwrap** 再断言；② 判定行正则需要 **多行匹配**（整串以 `<subagent …>` 开头，
#   单行锚 `^判定:` 永远不命中）。
# ══════════════════════════════════════════════════════════════════════════

# 把每次 `agent=oracle` 调用的**完整 output（已 unwrap）**写成 `$prefix.call<N>.txt`
oig_dump_outputs() {
    python3 - "$1" "$2" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
prefix = sys.argv[2]
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
    if (st.get("input") or {}).get("agent") != "oracle":
        continue
    idx += 1
    out = st.get("output") or ""
    if not isinstance(out, str):
        out = json.dumps(out, ensure_ascii=False)
    m = re.search(r"<subagent\b[^>]*>(.*)</subagent>", out, re.S)
    body = m.group(1) if m else out
    path = f"{prefix}.call{idx}.txt"
    open(path, "w", encoding="utf-8").write(body)
    print(f"{path}\tstatus={st.get('status')}\tlen={len(body)}")
PY
}

# 判定行是否出现（**多行**匹配；正则从真源派生）。exit 0 = 有，1 = 无，2 = 派生失败
oig_has_verdict() {
    local text_file="$1" pat
    pat="$(oig_verdict_pattern)" || return 2
    python3 - "$text_file" "$pat" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.exit(0 if re.search(sys.argv[2], s, re.M) else 1)
PY
}

# ══════════════════════════════════════════════════════════════════════════
# AC5 E-B 两态差分（**观察项：不 fail** —— 用户裁决；design D3）
#   态① 带意图陈述 / 态② = **harness** 删掉意图段（不是让模型删）
#   判据 = **两态是否可分辨**（① 有判定行、② 无）：
#     可分辨   ⇒ 闸门生效；
#     不可分辨 ⇒ 记「软约束被违反 / 失效」并**如实登记**（模型的真相，不是测试缺陷）。
#   ⚠ 一次父会话里发起**两次** subagent 调用（省一次父会话轮次；SC-10 有同类先例）。
# ══════════════════════════════════════════════════════════════════════════
@test "AC5 E-B 两态差分（观察项，不 fail）：带意图 vs 删意图 ⇒ 判定行是否可分辨" {
    oig_require_runtime
    [ "$OIG_CARRIER" = "A" ] || skip "OIG_CARRIER=$OIG_CARRIER：E-B 需 state.output 载体（先跑 AC1 探针，design D2）"

    local proj sid
    proj="$(oig_fixture eb)"
    sid="$(oig_new_session)"
    oig_report_init

    # 态① / 态② —— **只差意图那一行**（harness 侧构造，可复现）
    local p1 p2
    p1='请以审查模式审查 docs/adr/ADR-001.md 这个决策。
意图陈述：要解决的问题是读接口 p95 延迟偏高；范围边界是只动读路径、不动写路径。
判据：与既有 ADR 是否冲突。'
    p2='请以审查模式审查 docs/adr/ADR-001.md 这个决策。
判据：与既有 ADR 是否冲突。'

    local prompt="只做一件事，按顺序发起两次 subagent 工具调用，不要做别的。
第 1 次：agent 必须是 oracle，description 填 oig-eb-with-intent，prompt 参数必须逐字是：
---
$p1
---
第 2 次：agent 必须是 oracle，description 填 oig-eb-no-intent，prompt 参数必须逐字是：
---
$p2
---"
    oig_run_parent eb "$proj" "$prompt" "$sid"

    local dumped
    dumped="$(oig_dump_outputs "$OIG_ROOT/eb.json" "$OIG_ROOT/eb")"
    local n
    n="$(printf '%s\n' "$dumped" | grep -c . || true)"
    [ "$n" -ge 2 ] || { echo "❌ 只解析到 $n 次 oracle 调用（期望 2）：$dumped" >&2; return 1; }

    # 状态门控（D7）：任一次未完成 ⇒ skip 未判定
    if printf '%s\n' "$dumped" | grep -v 'status=completed' >/dev/null; then
        skip "存在未完成的 oracle 调用（本用例未判定）：$dumped"
    fi

    local f1="$OIG_ROOT/eb.call1.txt" f2="$OIG_ROOT/eb.call2.txt"
    local h1=1 h2=1
    oig_has_verdict "$f1" && h1=0
    oig_has_verdict "$f2" && h2=0

    local verdict
    if [ "$h1" -eq 0 ] && [ "$h2" -ne 0 ]; then
        verdict="可分辨（①有判定行 / ②无 ⇒ 闸门生效）"
    elif [ "$h1" -ne 0 ] && [ "$h2" -ne 0 ]; then
        verdict="不可分辨（两态都无判定行 ⇒ 可能一律拒发，需人工判读）"
    elif [ "$h1" -eq 0 ] && [ "$h2" -eq 0 ]; then
        verdict="**两态不可分辨**（都有判定行）—— ⚠ 存在**未排除的替代解释**：产物本身可能内嵌意图线索（见报告 caveat），故不得直接判「软约束被违反」"
    else
        verdict="不可分辨（①无 ②有 ⇒ 反直觉）"
    fi

    echo "── E-B 两态差分 ──"
    echo "态①（带意图）: $( [ "$h1" -eq 0 ] && echo 有判定行 || echo 无判定行 )"
    echo "态②（删意图）: $( [ "$h2" -eq 0 ] && echo 有判定行 || echo 无判定行 )"
    echo "结论: $verdict"
    echo "（态②正文前 200 字符：$(head -c 200 "$f2" | tr '\n' ' ')）"

    {
        echo ""
        echo "### AC5 E-B 两态差分（$(date -u +%Y-%m-%dT%H:%M:%SZ)）"
        echo ""
        echo "- 态①（带意图）：$( [ "$h1" -eq 0 ] && echo '**有**判定行' || echo '无判定行' ) —— \`$f1\`"
        echo "- 态②（harness 删意图）：$( [ "$h2" -eq 0 ] && echo '**有**判定行' || echo '无判定行' ) —— \`$f2\`"
        echo "- **结论：$verdict**"
        echo "- ⚠ 观察项，**不 fail**（用户裁决）：不合规是**模型的真相**，升级为硬门禁须另立 change"
        echo "- ⚠ 本用例走**父会话 wrapper** ⇒ 多带一个「父模型转述」变量（已知边界）"
    } >> "$OIG_REPORT"

    oig_report_row "AC5 E-B" "${OIG_MODEL:-default}" "state1+state2" "1" "2" "$verdict" "$OIG_ROOT/eb.json"
    # **不 fail**：观察项（用户裁决）。
}

# ══════════════════════════════════════════════════════════════════════════
# AC4 观察：把 `agent=oracle` 调用的**入参 prompt 原文**逐字落文件（**不判红**）
#   输出：`$prefix.prompt<N>.txt`；同时打印每条的 agent 与长度。
# ══════════════════════════════════════════════════════════════════════════
oig_dump_prompts() {
    python3 - "$1" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
prefix = sys.argv[2]
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
    if inp.get("agent") != "oracle":
        continue
    idx += 1
    prompt = inp.get("prompt") if isinstance(inp.get("prompt"), str) else ""
    open(f"{prefix}.prompt{idx}.txt", "w", encoding="utf-8").write(prompt)
    print(f"{prefix}.prompt{idx}.txt\tlen={len(prompt)}")
PY
}

# 入参里「含 / 不含」真源派生的意图陈述组成词（**观察，不判红**）
#   exit 0 = 全部含；1 = 缺若干；2 = 派生失败
oig_prompt_term_report() {
    local prompt_file="$1" terms
    terms="$(oig_intent_terms)" || return 2
    python3 - "$prompt_file" "$terms" <<'PY'
import sys
prompt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
terms = [t for t in sys.argv[2].split("\n") if t.strip()]
missing = [t for t in terms if t not in prompt]
if not missing:
    print("含全部组成词：" + " / ".join(terms))
    sys.exit(0)
print("缺组成词：" + " / ".join(missing))
sys.exit(1)
PY
}

# ══════════════════════════════════════════════════════════════════════════
# AC2 / AC3 / AC4 E-A：architect 角色 + 明确**审查**请求
#   AC3 前提（守）：确有 `agent=oracle` 调用；未发生 ⇒ **skip 未判定**（不得当绿）
#   AC2 门禁（硬）：**最后一次** oracle 调用的返回含 `^判定: (APPROVE|REJECT)`
#   AC4 观察（不判红）：入参 prompt 原文落报告 + 标注「含 / 不含」组成词
# ══════════════════════════════════════════════════════════════════════════
@test "AC2/AC3/AC4 E-A（硬门禁）：architect 审查 ⇒ oracle 返回含判定行；入参原文落报告" {
    oig_require_runtime
    [ "$OIG_CARRIER" = "A" ] || skip "OIG_CARRIER=$OIG_CARRIER：E-A 需 state.output 载体（design D2）"

    local proj sid
    proj="$(oig_fixture ea)"
    sid="$(oig_new_session)"
    oig_report_init

    # 意图**以叙述嵌入**（给内容不给槽位名 —— design D5），并要求**审查**（产物 + 判据）
    local prompt='我们打算给**读接口**单独加一层进程内缓存：读 p95 现在约 480ms，目标是压到 120ms 以下。
范围边界：**只动读路径**；写路径的强一致这期完全不动，也不引入外部缓存组件。
审查域: 其他审查
请以**审查模式**审查 `docs/adr/draft-002.md` 这个决策，判据是「与既有决策 / 契约是否冲突」。'
    oig_run_parent ea "$proj" "$prompt" "$sid"

    # ── AC3 前提：确有 oracle 调用（未发生 ⇒ skip，不得当绿）──
    local dumped n
    dumped="$(oig_dump_outputs "$OIG_ROOT/ea.json" "$OIG_ROOT/ea")"
    n="$(printf '%s\n' "$dumped" | grep -c . || true)"
    if [ "$n" -lt 1 ]; then
        skip "父模型未调 oracle（前提未成立，本用例未判定）—— subagent 调用：$(grep -o '"agent":"[a-z]*"' "$OIG_ROOT/ea.json" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    fi

    # 登记 metis 是否插入（其输出会作**材料**进 oracle 输入 ⇒ AC4 数据失真）
    local metis_seen="否"
    grep -q '"agent":"metis"' "$OIG_ROOT/ea.json" 2>/dev/null && metis_seen="是"

    # ── 状态门控（D7）：取**最后一次**，未完成 ⇒ skip ──
    local last="$OIG_ROOT/ea.call$n.txt" lastline
    lastline="$(printf '%s\n' "$dumped" | tail -1)"
    printf '%s\n' "$lastline" | grep -q 'status=completed' \
        || skip "最后一次 oracle 调用未完成（本用例未判定）：$lastline"

    # ── AC4 观察（不判红）：入参原文 + 组成词标注 ──
    local pdumped plen term_report term_rc=0
    pdumped="$(oig_dump_prompts "$OIG_ROOT/ea.json" "$OIG_ROOT/ea")"
    plen="$(printf '%s\n' "$pdumped" | tail -1 | sed -n 's/.*len=//p')"
    term_report="$(oig_prompt_term_report "$OIG_ROOT/ea.prompt$n.txt")" || term_rc=$?

    echo "── E-A 结果 ──"
    echo "oracle 调用次数: $n（metis 插入: $metis_seen）"
    echo "最后一次入参长度: ${plen:-?}"
    echo "入参组成词: $term_report"

    # ── AC2 门禁（硬）：判定行 ──
    local has=1
    oig_has_verdict "$last" && has=0

    # 观察（不判红）：**任一**判定行（治理面档 or 其他审查档）⇒ 区分两种失败态：
    #   ① 审查根本没发生（无任何判定行）② 审查发生了但**词表选错**（用了治理面档）。
    local any_verdict="无"
    local gov_line
    gov_line="$(grep -oE '^\*{0,2}治理面判定:[[:space:]]*[A-Z-]+' "$last" | head -1 || true)"
    if [ "$has" -eq 0 ]; then
        any_verdict="有（其他审查档：判定: …）"
    elif [ -n "$gov_line" ]; then
        any_verdict="有但**词表选错**（$gov_line —— 被审对象是项目 docs/adr/**，**不属**治理面）"
    fi
    echo "任一判定行: $any_verdict"

    {
        echo ""
        echo "### AC2/AC3/AC4 E-A（$(date -u +%Y-%m-%dT%H:%M:%SZ)）"
        echo ""
        echo "- oracle 调用次数：**$n**；\`agent=metis\` 是否插入：**$metis_seen**"
        echo "- 最后一次入参长度：\`${plen:-?}\`"
        echo "- 入参组成词（AC4 观察，**不判红**）：$term_report"
        echo "- 最后一次返回是否含**契约判定行**（\`判定: APPROVE|REJECT\`）：**$( [ "$has" -eq 0 ] && echo 是 || echo 否 )**"
        echo "- 任一判定行（观察，区分两种失败态）：$any_verdict"
        echo "- 入参原文：\`$OIG_ROOT/ea.prompt$n.txt\`；返回正文：\`$last\`"
        echo "- ⚠ 若 metis=是 ⇒ 入参里的组成词可能来自 **metis 转述** ⇒ AC4 数据不可用于判父侧"
        echo "- ⚠ 实验设计残余：被审产物 \`draft-002.md\` 自身可能含意图线索 ⇒ 与 E-B 同类的替代解释"
    } >> "$OIG_REPORT"

    local verdict_txt
    verdict_txt="$( [ "$has" -eq 0 ] && echo "判定行=有" || echo "判定行=无" )"
    oig_report_row "AC2/AC3/AC4 E-A" "${OIG_MODEL:-default}" "prompt_len=${#prompt}" "1" "$n" \
        "$verdict_txt / metis=$metis_seen" "$OIG_ROOT/ea.json"

    [ "$has" -eq 0 ] || {
        echo "❌ AC2 门禁失败：最后一次 oracle 返回**没有**契约判定行（期望 \`^判定: (APPROVE|REJECT)\`）" >&2
        echo "   任一判定行：$any_verdict" >&2
        echo "   返回正文前 400 字符：$(head -c 400 "$last" | tr '\n' ' ')" >&2
        echo "   ⚠ 先看 AC4 观察：若父模型没带意图陈述 ⇒ oracle 拒发是**规则生效**（不是缺陷）；" >&2
        echo "     若带了意图仍无判定行 ⇒ 两种可能：(a) 审查没发生 (b) **词表选错**（见上面「任一判定行」）；" >&2
        echo "     后者是**规则/模型的实际行为**，不是测试缺陷 ⇒ 记观察报告 + 另立 change，不在本 change 改判据。" >&2
        return 1
    }
}

# oracle 输出用的词表：`gov`（治理面判定:）/ `other`（判定:）/ `none`（无判定行）
oig_word_table() {
    local f="$1"
    if grep -qE '^\*{0,2}治理面判定:' "$f" 2>/dev/null; then printf 'gov'; return 0; fi
    if oig_has_verdict "$f"; then printf 'other'; return 0; fi
    printf 'none'
}

# ══════════════════════════════════════════════════════════════════════════
# AC5b 审查域两态差分（**观察项：不 fail** —— N=1 不排除采样噪声）
#   态① 带声明 `审查域: 其他审查` / 态② **harness** 删掉该行（不是让模型删）
#   判据 = **词表是否改变**（① `判定:` / ② `治理面判定:`）：
#     改变   ⇒ 声明生效（本 change 的机制在真实行为上成立）；
#     不改变 ⇒ 如实登记（可能是模型按路径自行判断 —— 那是**正确行为**，不是测试缺陷）。
#   ⚠ 一次父会话发起两次 subagent 调用（同 E-B；省一轮父会话）。
# ══════════════════════════════════════════════════════════════════════════
@test "AC5b 审查域两态差分（观察项，不 fail）：带声明 vs 删声明 ⇒ 词表是否改变" {
    oig_require_runtime
    [ "$OIG_CARRIER" = "A" ] || skip "OIG_CARRIER=$OIG_CARRIER：需 state.output 载体（design D2）"

    local proj sid
    proj="$(oig_fixture ea2)"
    sid="$(oig_new_session)"
    oig_report_init

    local body1='我们打算给**读接口**单独加一层进程内缓存：读 p95 现在约 480ms，目标是压到 120ms 以下。
范围边界：**只动读路径**；写路径的强一致这期完全不动，也不引入外部缓存组件。
审查域: 其他审查
请以**审查模式**审查 `docs/adr/draft-002.md` 这个决策，判据是「与既有决策 / 契约是否冲突」。'
    local body2='我们打算给**读接口**单独加一层进程内缓存：读 p95 现在约 480ms，目标是压到 120ms 以下。
范围边界：**只动读路径**；写路径的强一致这期完全不动，也不引入外部缓存组件。
请以**审查模式**审查 `docs/adr/draft-002.md` 这个决策，判据是「与既有决策 / 契约是否冲突」。'

    local prompt="只做一件事，按顺序发起两次 subagent 工具调用，不要做别的。
第 1 次：agent 必须是 oracle，description 填 oig-ac5-with-decl，prompt 参数必须逐字是：
---
$body1
---
第 2 次：agent 必须是 oracle，description 填 oig-ac5-no-decl，prompt 参数必须逐字是：
---
$body2
---"
    oig_run_parent ea2 "$proj" "$prompt" "$sid"

    local dumped n
    dumped="$(oig_dump_outputs "$OIG_ROOT/ea2.json" "$OIG_ROOT/ea2")"
    n="$(printf '%s\n' "$dumped" | grep -c . || true)"
    [ "$n" -ge 2 ] || { echo "❌ 只解析到 $n 次 oracle 调用（期望 2）：$dumped" >&2; return 1; }
    if printf '%s\n' "$dumped" | grep -v 'status=completed' >/dev/null; then
        skip "存在未完成的 oracle 调用（本用例未判定）：$dumped"
    fi

    local f1="$OIG_ROOT/ea2.call1.txt" f2="$OIG_ROOT/ea2.call2.txt"
    local k1 k2 m1 m2
    k1="$(oig_word_table "$f1")"
    k2="$(oig_word_table "$f2")"
    # 第 4 层标注是否出现（结构化事实，不读自然语言措辞）
    m1="no"; grep -q "审查域=未声明（默认其他审查）" "$f1" && m1="yes"
    m2="no"; grep -q "审查域=未声明（默认其他审查）" "$f2" && m2="yes"

    local verdict
    if [ "$k1" != "$k2" ]; then
        verdict="**词表改变**（①=$k1 / ②=$k2 ⇒ 声明生效）"
    elif [ "$m1" = "no" ] && [ "$m2" = "yes" ]; then
        verdict="词表未改变（两态都 $k1），但第 4 层标注只在态②出现 ⇒ 声明被识别（默认层同为 other，故词表不变）"
    else
        verdict="词表未改变（两态都 $k1；第 4 层标注 ①=$m1 / ②=$m2）⇒ 不可归因"
    fi

    echo "── AC5b 审查域两态 ──"
    echo "态①（带声明）: 词表=$k1 / 第4层标注=$m1"
    echo "态②（删声明）: 词表=$k2 / 第4层标注=$m2"
    echo "结论: $verdict"

    {
        echo ""
        echo "### AC5b 审查域两态差分（$(date -u +%Y-%m-%dT%H:%M:%SZ)）"
        echo ""
        echo "- 态①（带 \`审查域: 其他审查\`）：词表 **$k1** / 第 4 层标注 **$m1** —— \`$f1\`"
        echo "- 态②（harness 删声明）：词表 **$k2** / 第 4 层标注 **$m2** —— \`$f2\`"
        echo "- **结论：$verdict**"
        echo "- ⚠ 观察项，**不 fail**；N=1 不排除采样噪声（与上游 E-B 同型）"
    } >> "$OIG_REPORT"

    oig_report_row "AC5b 审查域两态" "${OIG_MODEL:-default}" "state1+state2" "1" "2" "$verdict" "$OIG_ROOT/ea2.json"
}
