# 分类 D：可观测性与轨迹契约

## D1. OpenTelemetry GenAI / Agent spans

| 事实 | 内容 |
|---|---|
| 迁移 | 核心仓 `v1.42.0`（2026-06-12）把所有 `gen_ai.*` 与 MCP/OpenAI 定义**弃用并迁出**到 `open-telemetry/semantic-conventions-genai`；最新核心版 `v1.45.0`（2026-11-02） |
| 状态 | 新仓 README 的 Schema URL 仍是 `TODO`；**全部 GenAI 元素仍为 Development**，无 release/tag 可 pin |
| agent spans | `create_agent`(CLIENT)、`invoke_agent`(CLIENT/INTERNAL)、`execute_tool`(INTERNAL，`gen_ai.tool.name`)、`invoke_workflow`、`plan`、`retrieval`、`memory`；必填 `gen_ai.operation.name`（client 侧加 `gen_ai.provider.name`） |
| 评测事件 | `gen_ai.evaluation.result`：属性 `gen_ai.evaluation.name`(Required)、`gen_ai.evaluation.score.value`、`...score.label`、`...explanation`、`gen_ai.response.id` |
| 内容捕获 | 默认 **NO_CONTENT**（`OTEL_INSTRUMENTATION_GENAI_CAPTURE_CONTENT`） |
| 缺口 | **OTel 不含 seed / prompt hash / 模型快照 / 缓存策略** ⇒ 只靠 OTel 达不到「同快照必得同数」，必须自有快照字段 |

⇒ 结论：OTel 只做**对外互换层**，不做内部事实源。

## D2. 轨迹文件契约

### ATIF（Harbor RFC-0001，v1.8，2026-04）

- root：`schema_version`（如 `ATIF-v1.7`）、`session_id`（run-scoped，可选）、`trajectory_id`、`agent{name,version,model_name,tool_definitions,extra}`、`steps[]`、`final_metrics`、`continued_trajectory_ref`、`subagent_trajectories[]`、`extra`。
- `StepObject`：`step_id`（从 1 起）、`timestamp`(ISO 8601)、`source ∈ {system,user,agent}`、`model_name`、`reasoning_effort`、`reasoning_content`、`tool_calls[]`、`observation`、`metrics`、`llm_call_count`。
- `ObservationResultSchema.source_call_id` 关联 `tool_call_id`。
- **`llm_call_count = 0` + `source: "agent"` 表示「deterministic (non-LLM) dispatch … an eval harness that issued tool_calls without an LLM inference」** —— 这正是「同一快照重放」的语义位。

### Inspect AI（UK AISI）运行快照

- `EvalSpec` 字段：`eval_set_id / eval_id / run_id / created / task / task_id / task_version / task_file / task_args / task_args_passed / solver_args_passed / tags / dataset / sandbox / model / model_generate_config / model_base_url / model_args / model_roles / config / revision / packages / metadata / scorers / metrics / headline_metric / shards`。
- `recompute_metrics(log, trust_log=False)`：改分后可重建聚合指标（`trust_log=True` 会执行 log 里的 task 文件，风险自担）。
- 任务模型：**Task = Dataset + Solver + Scorer**；200+ 预置 eval（含 AgentDojo 移植）；`.eval` 为默认日志格式（v0.3.46 起）。

### 主流观测产品（字段参照）

| 产品 | 契约要点 |
|---|---|
| OpenAI Agents SDK tracing | Trace: `workflow_name` / `trace_id`(`trace_<32>`) / `group_id` / `metadata`；Span: `trace_id` / `parent_id` / `span_data`（`AgentSpanData`/`GenerationSpanData`/`FunctionSpanData`）；`RunConfig.trace_include_sensitive_data` 控制内容 |
| LangSmith / Langfuse / Phoenix / MLflow / Braintrust | 统一 span kind 分类（agent / chain / tool / llm / **score**）；Braintrust 把 `score` 做成 span 类型 ⇒ **指标即一等公民** |
| Claude Code OTel | 见 `01` §A2；span 不完全遵守 GenAI 约定（第三方核验） |
| Harbor | 每 trial 落 `trajectory.json` + `recording.cast` |

## D3. 评测框架里的「评分器不可达」契约

### Prime Intellect verifiers v1 + Environments Hub

- 环境 = Taskset + Task +（可选）Harness / Runtime / **Rubric**；**四条执行边界**：evaluator / agent sandbox / grading sandbox / task tools。
- 隔离评分 `ScoringConfig(mode="isolated")`：「starts a **fresh grading container** … giving graders a clean filesystem containing only **declared agent outputs** and private test assets」。
- 私有测试只在 `stage_verifier` 写入 ⇒「**so the agent cannot inspect them**」。
- `TaskData` 额外字段「**never injected into the agent's prompt**」；`TaskData.agent_user` 指定 agent 运行用户。
- Harness 是一等件（内置 Codex / Kimi Code / Terminus 2 / Mini-SWE-Agent，可自写）。

### Inspect AI 沙箱契约

- 自动生成的 compose 强制 **`network_mode: none`**；**禁止任何可写 host mount**（防「改写 compose.yml 给后续样本提权」），只允许 `:ro`；逃生阀显式 `unsafe_allow_writable_host_mounts: true`。
- 警告：「**Don't count on a non-root container user to contain an adversarial model**」。

### PaperBench

三容器：rollout（ubuntu 容器）→ reproduction（**全新第二容器**，GPU）→ grading（**第三容器**跑 judge）；judge 自身被 `JudgeEval` 评测；`blacklist.txt` 禁 agent 访问原论文代码库。

## D4. Prompt / 规则版本化契约（Langfuse）

| 事实 | 内容 |
|---|---|
| 版本 | 每次 create 自动递增 `version` |
| 标签 | `labels`（production / staging / tenant / experiment）即「部署」；取不到 label ⇒ **404，绝不静默回退** |
| 回滚 | 把 `production` 标签移回旧版本（**版本+标签的原子切换**，不是文件 diff 回滚） |
| 权限 | `protected labels` + RBAC：viewer/member 不能改 production 标签 |
| API | `GET /api/public/v2/prompts/{name}?label=|version=`（两者互斥，同时传 400） |

## D5. 可直接抄的三个契约（综合 §C1 / §C2 / §D2 / §D3）

### 契约 1：能力声明 + 强制拒绝（srt 形状）

```json
{"network":{"allowedDomains":[],"deniedDomains":[],"allowUnixSockets":[],"allowLocalBinding":false},
 "filesystem":{"denyRead":["<评分器目录>","<rubric 目录>"],"allowRead":[],
               "allowWrite":["proposals/"],"denyWrite":["<安全核 glob 展开>"]}}
```

规则三条：**deny > allow 不对称**；**强制 deny 清单**（能改变后续行为的文件：`.git/hooks`、`.git/config`、`.claude/commands`、`.claude/agents`、`.mcp.json`、CI 配置、判据与 rubric 文件本身）；**fail-closed**（配置存在但无效 ⇒ 报错退出，不回落更宽松默认）。

拒绝留痕字段（OWASP）：`{actor, agent_id, policy_version, action_class, tool, normalized_args, decision, reason, approval_id, ts}`；权限决策同时作为 metric/event（Claude Code 的 `code_edit_tool.decision` / `tool_decision`）。

### 契约 2：「评分器不可达」的环境契约

1. 评分器跑在**另一个容器**，只在 agent 结束后启动；输入只有**显式声明的 artifacts**；
2. 私有测试走 `stage_verifier`（只在评分容器、artifact 恢复后写入），**永不出现在 agent 沙箱**；
3. 任务元数据（gold / rubric 路径）放 `TaskData` 扩展字段，**明确不注入 agent prompt**；
4. agent 以专用非 root 用户运行，**但不把「非 root」当隔离**；
5. 网络 `network_mode: none`；host 挂载只允许 `:ro`；
6. 评测环境声明复用 `task.toml` 形状：`[environment] allow_internet=false, cpus, memory_mb`、`[agent] timeout_sec`、`[verifier] timeout_sec`。

### 契约 3：轨迹 + 运行快照双文件

- **轨迹**（每 trial 一份，可回放）：`schema_version` / `agent{name,version,model_name}` / `steps[{step_id, timestamp, source∈{system,user,agent}, model_name, reasoning_content, tool_calls[{tool_call_id,name,arguments}], observation[{source_call_id,content}], metrics{prompt/completion/cached tokens}, llm_call_count}]` / `final_metrics` / `extra`；用 `llm_call_count=0` 标注「非 LLM 的确定性步骤」，让重放能区分模型抖动与 harness 行为。
- **运行快照**（每次 run 一份，用于复算）：抄 `EvalSpec` 的字段选择 —— `run_id`、`created`、`task_version`、`task_args` 与 `task_args_passed` 分开存、`model` + `model_generate_config`（含 seed/temperature）、`sandbox` 规格、`revision`(git sha)、`packages`（版本字典）、`config`、`scorers` + `headline_metric`。
- **复算模式**：log 是唯一事实源，聚合分数可离线重算；结果另以 `gen_ai.evaluation.result` 导出 OTel 接外部看板。
- **join key 必须进 manifest**：`tool_use_id` / `trace_id` / `session.id` —— 否则报告与 DB 无法对齐复算。
- **脱敏默认 + 显式开关 + 内容截断上限**（照 60 KB 量级）。
