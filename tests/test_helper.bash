#!/usr/bin/env bash
# tests/test_helper.bash — for rdd-workflow-e2e external test bed
#
# Two key environment variables:
#   $REPO_ROOT         = this repo (rdd-workflow-e2e), the test runner
#   $RDD_WORKFLOW_REPO = installed rdd-workflow, the project under test
#
# Default RDD_WORKFLOW_REPO=$HOME/.agents/skills/rdd-workflow
# (set by install.sh --global). Override for testing:
#   RDD_WORKFLOW_REPO=/path/to/rdd-workflow bats tests/

# Resolve this repo (rdd-workflow-e2e) root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Project under test: installed rdd-workflow (default: ~/.agents/skills/rdd-workflow)
RDD_WORKFLOW_REPO="${RDD_WORKFLOW_REPO:-$HOME/.agents/skills/rdd-workflow}"
export RDD_WORKFLOW_REPO

# Verify rdd-workflow is installed (fail fast)
if [[ ! -d "$RDD_WORKFLOW_REPO" ]]; then
    echo "❌ RDD_WORKFLOW_REPO not found: $RDD_WORKFLOW_REPO" >&2
    echo "   Run ./install_testbed.sh first, or set RDD_WORKFLOW_REPO=/path/to/rdd-workflow" >&2
    return 1 2>/dev/null || exit 1
fi

# Project-under-test working dir, if needed
export PROJECT_ROOT="${PROJECT_ROOT:-$RDD_WORKFLOW_REPO}"

# Load helper libraries from THIS repo's tests/_lib/ only
# (rdd-workflow-e2e doesn't have its own _lib/, just test fixtures)
load_lib() {
    local name="$1"
    local path="$REPO_ROOT/tests/_lib/${name}.bash"
    if [[ -f "$path" ]]; then
        # shellcheck source=/dev/null
        source "$path"
        return 0
    fi
    echo "load_lib: file not found: ${name} (looked in $REPO_ROOT/tests/_lib/${name}.bash)" >&2
    return 1
}

# Verify a file exists and is non-empty
assert_file_exists() {
    local f="$1"
    [[ -f "$f" ]] || { echo "expected file to exist: $f" >&2; return 1; }
}

# Verify a file contains a regex
assert_file_contains() {
    local f="$1"
    local pattern="$2"
    [[ -f "$f" ]] || { echo "file not found: $f" >&2; return 1; }
    grep -qE "$pattern" "$f" || { echo "expected '$pattern' in $f" >&2; return 1; }
}

# Verify a command succeeds
assert_cmd_succeeds() {
    "$@" >/dev/null 2>&1 || { echo "expected command to succeed: $*" >&2; return 1; }
}

# Common setup runs before every @test in files that load this helper.
setup() {
    : # placeholder; individual test files can override
}

# Common teardown runs after every @test in files that load this helper.
teardown() {
    : # placeholder; individual test files can override
}


# ── 独立会话 e2e 的共享助手（单一真源：两个 bats 文件都用它） ─────────
#
# ⚠ **为什么抽到这里**：「取整条响应」与「三要素词表」被**两个** bats 文件用
#   （主文件 + 词表守卫文件）⇒ 放一处 ⇒ 两边不会漂。

# ib_text_of <输出文件>：**全部** text 事件拼成的响应正文（不是首行！）
#   ⚠ 只取首行会漏：模型的多行响应里，「引导」段（选项列表）在后面。
ib_text_of() {
    python3 - "$1" <<'PYEOF'
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
PYEOF
}

# ib_write_targets_of <opencode json 输出文件>：**写类工具调用的写目标**（每行 `tool<TAB>target`）
#   ⚠ **按写目标判定**（**不是**「零工具调用」）：`read`/`shell` 之类的调用不该误伤；
#     而「改了又改回来」在 `git status` 上是**干净**的 ⇒ 只有按写目标才抓得到。
#   ⚠ **已知盲区**：`shell` 写盘（`sed -i` / `tee`）**抓不到** —— opencode 的权限层
#     不按角色约束 shell（`prompts/build.md` 明说）⇒ 已登记为已知残留（AC14）。
ib_write_targets_of() {
    python3 - "$1" <<'PYEOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    part = obj.get("part") or {}
    if part.get("type") != "tool":
        continue
    tool = part.get("tool")
    if tool not in ("edit", "write", "multiedit", "patch"):
        continue
    inp = (part.get("state") or {}).get("input") or {}
    target = inp.get("filePath") or inp.get("path") or ""
    print(f"{tool}\t{target}")
PYEOF
}

# ib_has_successful_tool <opencode json 输出文件>：是否**真的推进**过（有一个成功的工具调用）
#   ⚠ `question` 排除在外 —— 它是「问用户」，不是「推进」；且在非交互环境必然 error。
#   ⇒ 用途：**控制用例**（合法动作必须真的推进 ⇒ 唯一能判定「触发面没写太宽」的机制）。
ib_has_successful_tool() {
    python3 - "$1" <<'PYEOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    part = obj.get("part") or {}
    if part.get("type") != "tool":
        continue
    if part.get("tool") == "question":
        continue
    st = part.get("state") or {}
    if st.get("status") == "completed":
        sys.exit(0)
sys.exit(1)
PYEOF
}

# ib_skip_if_timeout <name>：**超时 ⇒ skip（未判定）**，不是 fail
#   ⚠ 为什么必须有这一档：`ib_run` 全程 `|| true`（rc 只写进 `.meta`）⇒ 若 timeout 当 fail，
#     `E-6` 的「禁写文件仍在」会**平凡通过**（进程被杀，文件当然没动）⇒ **假绿**；
#     `E-7` 的场景实测 >300s（exit 124）⇒ 无任何响应 ⇒ 三档判定**无一匹配** ⇒ 假红。
#   ⇒ 形态复用 `test_oracle_intent_gate.bats::oig_skip_if_unusable` 的三档纪律。
ib_skip_if_timeout() {
    local name="$1"
    local meta="$IB_ROOT/${name}.meta"
    if [ -f "$meta" ] && grep -q '^exit_code=124$' "$meta"; then
        skip "父会话超时（本用例未判定）：见 $meta"
    fi
}

# ib_fixture_head_state <fixture 目录>：打印 `HEAD<TAB>HEAD:src/app.ts blob`
#   ⚠ `E-6` 用它防**假绿**：`git status` 干净在「删了又 commit」后**也成立** ⇒
#     必须比对 `HEAD` 与 blob（内容哈希）是否变化。
ib_head_state() {
    local dir="$1"
    local head blob
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "NO_HEAD")"
    blob="$(git -C "$dir" rev-parse HEAD:src/app.ts 2>/dev/null || echo "NO_BLOB")"
    printf '%s\t%s' "$head" "$blob"
}

# ib_violations_of <含响应正文的文件>：三要素缺失清单（空 = 齐备）
#   ① 拒绝 ② 解释（点明角色职责归属）③ 引导（给切换 / 破例选项）
#   ⚠ 词表**不许放宽到糊弄话能过** —— 反例由 test_independent_build_session_vocab.bats 守着。
ib_violations_of() {
    python3 - "$1" <<'PYEOF'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
v = []
if not any(k in text for k in ("拒绝", "不能", "不允许", "不属于", "职责", "禁止")):
    v.append("缺「拒绝」要素")
if "角色" not in text:
    v.append("缺「解释」要素（未点明角色职责归属）")
if not any(k in text for k in ("切换", "破例", "重新指定", "换个角色", "请选", "选一条", "路径")):
    v.append("缺「引导」要素（未给切换 / 破例选项）")
print("\n".join(v))
PYEOF
}

# ib_skip_if_out_of_quota <stderr 文件>：**额度不足 ⇒ skip（不是 fail）**
#   ⚠ 抽到共享助手（两个运行时 e2e 文件都用）：额度耗尽是**持续态**，当 fail 会把
#     「没测到」误报成「测坏了」。
ib_skip_if_out_of_quota() {
    local err="$1"
    if grep -q 'provider.rate-limit\|rate_limit\|insufficient_quota' "$err" 2>/dev/null; then
        skip "provider 额度不足（本用例未判定）"
    fi
}

# ── commit 验证门 e2e（`test_commit_gate_runtime.bats`）的共享助手 ──────

# ib_tool_errors <opencode json 输出文件>：**结构化**工具错误（每行 `tool|err`）
#   ⚠ 只取 `part.state.error`，**不扫响应正文** —— 模型措辞不是契约，工具层错误串才是
#     （门禁的拒绝文案是**可诊断契约**，断言它是「判据」；断言模型怎么措辞不是）。
#   ⚠ 错误串含换行 ⇒ 后续行不带 `tool|` 前缀；判定用 `grep -F` 找**精确子串**。
ib_tool_errors() {
    python3 - "$1" <<'PYEOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    part = obj.get("part") or {}
    if part.get("type") != "tool":
        continue
    st = part.get("state") or {}
    err = st.get("error") or ""
    if st.get("status") == "error" or err:
        print(f"{part.get('tool')}|{err}")
PYEOF
}

# ib_shell_commands <opencode json 输出文件>：每次 shell 工具调用的命令（换行折叠成 ` ⏎ `）
#   用途：判定「**有没有真的发起提交尝试**」—— 没有尝试就不能算 pass（门禁没被测到 ⇒ 未判定）。
ib_shell_commands() {
    python3 - "$1" <<'PYEOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    part = obj.get("part") or {}
    if part.get("type") != "tool" or part.get("tool") not in ("shell", "bash"):
        continue
    inp = (part.get("state") or {}).get("input") or {}
    cmd = inp.get("command") or ""
    if cmd:
        print(cmd.replace("\n", " ⏎ "))
PYEOF
}

# ib_assert_no_halt_marker <json 文件> <用例名>：**停机率指标** —— 响应不得含停机标记
#   ⚠ 本仓 e2e 全是非交互 `opencode run` ⇒ 任何「需要用户裁决」都会**真的停** ⇒
#     这是「触发面是否写太宽」的**可测读数**（E-5 自认测不到「推进了但附带裁决」）。
#   ⚠ 只在**不该停**的用例里调（E-1 / E-2 / E-5）；E-4 / E-6 / E-7 是**该停**的。
ib_assert_no_halt_marker() {
    local f="$1" case_name="$2"
    if ib_text_of "$f" | grep -qF '[需要用户裁决]'; then
        echo "${case_name} 停机率指标失败：不该停的请求产生了停机标记" >&2
        ib_text_of "$f" | head -20 >&2
        return 1
    fi
}
