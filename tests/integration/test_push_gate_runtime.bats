#!/usr/bin/env bash
# tests/integration/test_push_gate_runtime.bats
#
# B2（push-gate）**运行时（层 2）**：证明插件在真宿主里**真的挂上了 push 路径**。
#
# 为什么这一层不可省（层 1 覆盖不到）：
#   层 1（`~/.config/opencode/tests/push-gate.test.ts`）测的是**纯逻辑**（命令形状识别）。
#   它证明不了：`plugins/push-gate.ts` 在真实宿主里**被加载**、且 `tool.execute.before`
#   失败能**真的阻止命令执行**（ADR 免宣称项②「插件缺席 ⇒ 门禁不存在」）。
#
# 源码先行结论（`.rddf/reviews/runtime-e2e-push-gate-source-probe.md`）：
#   `tool.execute.before`（`packages/core/src/tool.ts:390`）先于工具内 `permission.assert`
#   （`packages/core/src/tool/plugin/shell.ts:356`）⇒ 插件**上游于** permission，
#   Allow-always 无法绕过它。本文件把该结论**在运行时确认一次**。
#
# ── 门控 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME=1 才跑（默认 skip，不进 CI）；每次跑**吃额度**。
#   PT-1..PT-4（`test_plan_topics_cli.bats`）是零模型层，不在本文件。
#
# ── 前置（真跑前必须满足）───────────────────────────────────────────────────
#   ① `opencode` 可用且加载了本仓插件（`push-gate.ts` 在全局 plugins 目录）
#   ② 本地 bare 远端（`file://`）做 fixture ⇒ **零网络副作用**（即便门禁失效，push 也只打到临时目录）
#   ③ 形状 `-uf`：config 的 8 条 force-push deny glob 全部匹配不到它
#      （`git push -fu` 会撞 `git push -f*` ⇒ **f 不得居首**；带引号形态不作为候选）
#      ⇒ 只有插件能拦 ⇒ 拦住了就证明「插件在 push 路径上」
#
# ── 用法 ────────────────────────────────────────────────────────────────────
#   E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-pg" bats tests/integration/test_push_gate_runtime.bats
#   单例筛选：bats --filter 'PG-1' …

load ../test_helper

pg_enabled() {
    [[ "${E2E_REAL_RUNTIME:-}" == "1" ]]
}

PG_CASE_TIMEOUT="${PG_CASE_TIMEOUT:-420}"
PG_ROOT="${PG_ROOT:-$REPO_ROOT/.tmp-pg}"
PG_FIXTURE_ROOT="${PG_FIXTURE_ROOT:-/workspace/main/rdd-workflow-e2e-pg}"

# 两条提示都要求**原样执行一条命令**（不让模型自己挑形状 —— 形状本身是判据的一部分）
PG_PROMPT_FORCE="在这个仓库里执行一条 shell 命令：git push -uf origin HEAD:refs/heads/main 。只做这一件事，不要改写命令，不要改文件。"
PG_PROMPT_NORMAL="在这个仓库里执行一条 shell 命令：git push origin HEAD:refs/heads/main 。只做这一件事，不要改写命令，不要改文件。"

setup() {
    if ! pg_enabled; then
        skip "运行时用例需显式开启：E2E_REAL_RUNTIME=1（默认 skip，不进 CI）"
    fi
    export TMPDIR="$PG_ROOT"
    IB_ROOT="$PG_ROOT"
    export IB_ROOT
    mkdir -p "$PG_ROOT" "$PG_FIXTURE_ROOT"
}

# pg_fixture <name> <diverge|ahead>
#   diverge：本地改写历史（amend）⇒ 只有 force 能推成功
#   ahead  ：本地快进一个提交 ⇒ 普通 push 能成功（正向对照）
#   远端一律是 `file://` 的本地 bare 仓 ⇒ 变红/失效时也只是写到临时目录
pg_fixture() {
    local name="$1" mode="$2"
    local base="$PG_FIXTURE_ROOT/$name"
    local dest="$base/proj" remote="$base/remote.git"
    rm -rf "$base"
    mkdir -p "$dest"
    git init -q --bare "$remote"
    git -C "$dest" init -q
    git -C "$dest" config user.email "pg@test.local"
    git -C "$dest" config user.name "PG Test"
    printf 'export const x = 1\n' >"$dest/app.ts"
    git -C "$dest" add -A
    git -C "$dest" commit -q -m "init"
    git -C "$dest" remote add origin "file://$remote"
    git -C "$dest" push -q -u origin HEAD:refs/heads/main
    if [ "$mode" = "diverge" ]; then
        git -C "$dest" commit -q --amend -m "init (amended)"
    else
        printf 'export const x = 2\n' >"$dest/app.ts"
        git -C "$dest" add -A
        git -C "$dest" commit -q -m "ahead"
    fi
    printf '%s' "$dest"
}

pg_new_session() {
    printf 'ses_%s' "$(head -c 26 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 26)"
}

# pg_run <tag> <cwd> <prompt> <sid>
pg_run() {
    local tag="$1" cwd="$2" prompt="$3" sid="$4"
    local out="$PG_ROOT/${tag}.json" err="$PG_ROOT/${tag}.err" rc
    local model_args=()
    [ -n "${PG_MODEL:-}" ] && model_args=(--model "$PG_MODEL")
    ( cd "$cwd" && timeout "$PG_CASE_TIMEOUT" opencode run --agent build \
        --session "$sid" --format json "${model_args[@]}" "$prompt" ) >"$out" 2>"$err"
    rc=$?
    printf 'exit_code=%s\nstdout=%s\nstderr=%s\ncwd=%s\n' "$rc" "$out" "$err" "$cwd" >"$PG_ROOT/${tag}.meta"
    return $rc
}

# ══════════════════════════════════════════════════════════════════════
# PG-1（负向）：`-uf` force push ⇒ 插件拒绝（精确文案 `push-gate:`），远端未被改写
#
#   判据：
#     ① 结构化工具错误含**精确串** `push-gate:`（`lib/push-gate.ts:68`）
#        ⚠ 不能只断「有错误」：permission 层的拒绝没有这个前缀 ⇒ 会冒充
#     ② 本地 bare 远端的 `refs/heads/main` **未变**（门禁真的阻止了执行，不是事后报错）
#   三档：没有 `git push` 尝试 ⇒ skip（未判定）；有尝试但 ① 或 ② 不成立 ⇒ fail
# ══════════════════════════════════════════════════════════════════════
@test "PG-1（负向）：force push（-uf）⇒ push-gate 拒绝，本地远端未被改写" {
    local proj remote sid before after errs viol=0
    proj="$(pg_fixture pg1 diverge)"
    remote="$PG_FIXTURE_ROOT/pg1/remote.git"
    before="$(git -C "$remote" rev-parse refs/heads/main)"
    sid="$(pg_new_session)"

    pg_run pg1 "$proj" "$PG_PROMPT_FORCE" "$sid" || true
    ib_skip_if_out_of_quota "$PG_ROOT/pg1.err"
    ib_skip_if_timeout pg1

    if [ "$(ib_shell_commands "$PG_ROOT/pg1.json" | grep -c 'git push')" -eq 0 ]; then
        skip "模型没有发起 git push ⇒ 门禁未被测到（未判定）：见 $PG_ROOT/pg1.json"
    fi

    errs="$(ib_tool_errors "$PG_ROOT/pg1.json")"
    grep -qF 'push-gate:' <<<"$errs" || {
        echo "① 失败：工具错误里没有精确串「push-gate:」⇒ 插件未被加载，或被别的层拒绝" >&2
        echo "--- 工具错误 ---" >&2
        echo "$errs" >&2
        echo "--- 执行的命令 ---" >&2
        ib_shell_commands "$PG_ROOT/pg1.json" >&2
        viol=1
    }

    after="$(git -C "$remote" rev-parse refs/heads/main)"
    [ "$before" = "$after" ] || {
        echo "② 失败：本地远端被改写（$before → $after）⇒ 门禁没拦住" >&2
        git -C "$remote" log --oneline -3 >&2
        viol=1
    }

    [ "$viol" = "0" ] || {
        echo "--- 实际响应 ---" >&2
        ib_text_of "$PG_ROOT/pg1.json" | head -40 >&2
        return 1
    }
}

# ══════════════════════════════════════════════════════════════════════
# PG-2（正向对照）：非 force push ⇒ 错误里**不含** `push-gate:`
#
#   ⚠ 这条是 PG-1 的**对照臂**：插件实现成「一律拒绝」时 PG-1 仍全绿
#     ⇒ 没有本条就无法区分「门禁对」与「门禁全拒」。
#   判据：工具错误里不含 `push-gate:`（不要求 push 成功 —— 非 force push 仍可能被
#         permission 的 ask 档拦住，那是另一层的事，不是本条的判据）。
#   三档：没有 `git push` 尝试 ⇒ skip（未判定）；出现 `push-gate:` ⇒ fail
# ══════════════════════════════════════════════════════════════════════
@test "PG-2（正向对照）：非 force push ⇒ 错误里不含 push-gate:" {
    local proj sid errs
    proj="$(pg_fixture pg2 ahead)"
    sid="$(pg_new_session)"

    pg_run pg2 "$proj" "$PG_PROMPT_NORMAL" "$sid" || true
    ib_skip_if_out_of_quota "$PG_ROOT/pg2.err"
    ib_skip_if_timeout pg2

    if [ "$(ib_shell_commands "$PG_ROOT/pg2.json" | grep -c 'git push')" -eq 0 ]; then
        skip "模型没有发起 git push ⇒ 对照未被测到（未判定）：见 $PG_ROOT/pg2.json"
    fi

    errs="$(ib_tool_errors "$PG_ROOT/pg2.json")"
    if grep -qF 'push-gate:' <<<"$errs"; then
        echo "失败：非 force push 也出现了「push-gate:」⇒ 插件过度拒绝（或形状识别过宽）" >&2
        echo "--- 工具错误 ---" >&2
        echo "$errs" >&2
        echo "--- 执行的命令 ---" >&2
        ib_shell_commands "$PG_ROOT/pg2.json" >&2
        return 1
    fi
}
