# 运行时用例的断言纪律

| 字段 | 值 |
|---|---|
| 日期 | 2026-11-15 |
| 适用 | 本仓 `tests/integration/` 里**需要真实运行时**（真实模型 / 真实宿主）的用例 |
| 配套 | [`real-runtime-prereqs.md`](./real-runtime-prereqs.md)（L2 落地前置与探针结论）、[`known-gaps-and-ownership.md`](./known-gaps-and-ownership.md)（跨仓缺口归属） |

---

## 0. 一句话

**运行时用例的断言只认「文件系统事实」与「结构化字段」，不断言模型的自然语言措辞。**

---

## 1. 三条纪律

### 纪律 1 —— 断言对象必须是**事实**，不是**措辞**

| ✔ 可断言 | ✘ 不可断言 |
|---|---|
| 文件是否存在、内容是什么（`grep -q '"demo"' file`） | 模型说了什么词（"没有出现 Permission denied"） |
| 工具层的结构化结果（NDJSON 里的 `part.state.error` / `part.state.status`） | 「模型有没有提到某个词」 |
| ledger 的结构化字段（`outcome` / `blocked_reason` / `changed_files`） | 输出文本里「有没有出现某串」 |

> ⚠ **反面教材（本仓真实发生过两次）**：
>
> | 用例 | 首版断言 | 为什么会假绿/假红 |
> |---|---|---|
> | CS-5 | `! grep -q "Permission denied" cs5.json` | 整份 JSON 里**包含模型的叙述**——它正好写了「没有出现 `Permission denied`」⇒ **命中自己** ⇒ 断言无意义 |
> | CS-6 | 同上 | 同上 |
>
> ⇒ 正确写法：**只查工具层 `state.error` 是否为空 + ledger 的 `blocked_reason` 是否含拒绝**。

### 纪律 2 —— 断言必须**可证伪**：前提本身要被验证

「断言 A 成立」不够 —— 还要保证**前提 P 真的成立**，否则断言可能恒真。

> **反面教材（CS-5 首版）**：断言「测试确实失败」—— 但 fixture **初始就失败**
> （`x = 1` vs 测试断言 `x === 2`）⇒ 无论改不改，断言都成立 ⇒ **空转**。
>
> 修法：① fixture 初始**绿**（`x = 2`，先跑一次确认通过）；② 由 **harness**（用例文件自己）
> 把源码改成 `x = 3`（⇒ 「文件相对 HEAD 已被改动」这个前提真的成立）；③ 再断言失败。
>
> 顺带一个**角色契约**事实：被派发后端是 `role_class=verifier` ⇒ 按契约**不得改 `src/**`**
> ⇒ 「让后端改坏源码」这个设计**不可达**（它会如实拒绝）。**前提要由 harness 造，不是由后端造。**

### 纪律 3 —— 每条用例配一次**变红演练**

用例「跑通」不等于「有判别力」。改坏一个受判据约束的要素 ⇒ 该用例**必须红**。

```bash
# 例：把一条「应当拦住」的路径写进 scope ⇒ CS-2 必须红
#     （改完还原，确认恢复绿）
```

⇒ **红 ⇒ 判据有判别力**；**仍绿 ⇒ 这条断言是空转的**（本仓已因此报废过一条断言）。

---

## 2. 本仓运行时用例索引（`tests/integration/test_class_scope_runtime.bats`）

| 用例 | 断言什么 | 依赖 |
|---|---|---|
| **CS-1** | `role_class=verifier` + `scope` 含 `.rddf/state/verifier` ⇒ 派发被接受；**能**写该目录；**不能**写 `.rddf/state/pair.json`（类上限不泄漏为授权） | 真实运行时（委托） |
| **CS-2** | `scope` **不含** `.rddf/state/verifier` ⇒ 写该目录**被权限拒**（证明「上限 ≠ 授权」，授权只来自 scope） | 真实运行时 |
| **CS-3** | 取证命令失败 ⇒ **交回**（首行 `HANDOFF:`）+ **不产出 pass 结论**；受阻记录由 verifier **自落** | 真实运行时 |
| **CS-4** | 审计 CLI 的 `--json` 含 `timeCreated` / `messageIndex` / `evaluation{ok,exempted}` ⇒ 四元组可算 | **纯 CLI**（不需模型） |
| **CS-5** | **被修改文件**上的测试失败 ⇒ 分类为 `ac-fail`（**判据信号**）而非 `blocked`（取证不可用） | 真实运行时 + 一次真实测试运行 |
| **CS-6** | 收拢后：verifier 类写 `.rddf/state/verifier/` 下的 verdict cache + audit log ⇒ **落盘成功**、无权限拒 | 真实运行时 |

> **CS-5 的判据形态**：失败签名必须是**判据信号**（bun 输出含 `Expected`/`Received`，不含
> `command not found`/`Cannot find module` 这类**环境信号**）⇒ 分类 `ac-fail`；且输出**不含**
> `HANDOFF: blocked`。

---

## 3. 怎么跑

```bash
cd <rdd-workflow-e2e 仓>

# 默认态：运行时用例**全部 skip**（不进 CI）
bats -r tests/

# 开启运行时（需要真实模型 + 真实宿主；**吃额度**）
mkdir -p "$PWD/.tmp-l2"
E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-l2" \
  bats --filter 'CS-5' tests/integration/test_class_scope_runtime.bats

# 额度不足时可换模型（只影响本文件驱动的 plan 会话）
E2E_REAL_RUNTIME=1 CS_PLAN_MODEL=provider/model bats --filter 'CS-1' …
```

⚠ **额度是持续态故障**：命中 Token Plan 429（`provider.rate-limit`）时**不要重试**——
重试只烧预算。记下证据（retry 次数 / 有无文本事件 / fixture 是否被改）即可。

---

## 4. 写新用例时的检查清单

- [ ] 断言对象是**文件系统事实**或**结构化字段**（纪律 1）？
- [ ] 前提**本身**被验证过（不是恒真）？（纪律 2）
- [ ] 做过**变红演练**（改坏 ⇒ 必须红）？（纪律 3）
- [ ] 用例**不依赖模型措辞**：模型换个说法不应让断言翻转；
- [ ] 失败时**能指出是哪一条判据**（断言信息里带文件/字段/路径）。
