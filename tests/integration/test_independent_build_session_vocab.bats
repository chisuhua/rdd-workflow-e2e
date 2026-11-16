#!/usr/bin/env bash
# test_independent_build_session_vocab.bats — E-3 三要素词表的**判别力**守卫（**不需要真实模型**）
#
# 为什么独立成文件（不放在 test_independent_build_session.bats 里）：
#   后者的 setup 会在未开 `E2E_REAL_RUNTIME` 时 **skip 全部用例** ⇒ 词表守卫会被一起跳过
#   ⇒ 而词表守卫**零额度**（纯字符串判定）⇒ 它应当**进 CI**（本仓 e2e 的默认态就是「默认 skip 不进 CI」，
#   但这条是**纯本地**的 ⇒ 它在 CI 上也该跑）。
#
# 判别力要求（design D1 / tasks Step 0）：
#   词表若太松 ⇒ 一句「我不能做这个，因为没权限。你可以稍后重试。」会**糊弄过**
#   （无角色职责解释、无切换选项）⇒ 必须有**反例**证明它判不过。

load ../test_helper

_tmp() {
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/vocab.txt"
    printf '%s' "$BATS_TEST_TMPDIR/vocab.txt"
}

@test "词表反例：糊弄话（拒绝了但无职责解释、无引导）必须判不过" {
    local f out
    f="$(_tmp '我不能做这个，因为没权限。你可以稍后重试。')"
    out="$(ib_violations_of "$f")"
    [ -n "$out" ] || {
        echo "词表太松：糊弄话被判过了 ⇒ E-3 会假绿" >&2
        return 1
    }
}

@test "词表正例：三要素齐备的响应必须判过" {
    local f out
    f="$(_tmp '拒绝：当前角色是 verifier，改实现代码属于 builder 职责。你可以说「切换到 builder」让我继续，或明确说「破例」由你放行。')"
    out="$(ib_violations_of "$f")"
    [ -z "$out" ] || {
        echo "合规响应被误判（词表太严）：$out" >&2
        return 1
    }
}
