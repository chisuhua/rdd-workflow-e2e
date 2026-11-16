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
