# 分类 G：可下载性矩阵（本环境实测，2026-11-20）

| 字段 | 值 |
|---|---|
| 方法 | librarian 通过 **hf-mirror.com API** 与 **aliyun PyPI 镜像**逐条核实；本地实测下载两个文件 |
| 结论 | **编程任务数据「可下但多数不可跑」**；真正能在本环境端到端跑的是**规则/判据类**数据 + `agentdojo`（PyPI） |

## G0. 本环境网络事实（决定一切）

| 通道 | 状态 | 说明 |
|---|---|---|
| `huggingface.co` | ❌ 不可达（curl 000） | 必须走镜像 |
| **`hf-mirror.com`** | ✅ 200 | `HF_ENDPOINT=https://hf-mirror.com`；API `/api/datasets/<id>`，文件 `/datasets/<id>/resolve/main/<path>` |
| `github.com` | ❌ 不可达（`git ls-remote` 无输出） | **所有 GitHub-only 数据集/仓库在本环境不可用** |
| `pypi.org` | ❌ 不可达 | 但 `PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/` ✅ |
| Docker daemon | ❌ 无（containerd 管理的 ECI） | SWE-* / Terminal-Bench 的容器执行不可行；但可用 ECI 沙箱替代（见 ADR-0006） |

## G1. 编程任务（可执行类）

| 数据集 | HF id | 体积 | 许可 | gated | 自带测试 | 本环境可执行？ |
|---|---|---|---|---|---|---|
| SWE-bench | `princeton-nlp/SWE-bench` | ≈120 MB（dev 1.4MB / test 12MB / train 107MB） | 卡上无 license（上游 MIT） | false | ✅ FAIL_TO_PASS / PASS_TO_PASS | ❌ 需 GitHub clone + Docker |
| **SWE-bench Verified** | `princeton-nlp/SWE-bench_Verified` | **2.1 MB**（500 条） | 同上 | false | ✅ | ❌ 同上（**已本地实测下载**：500 行，字段含 `patch` / `test_patch` / `FAIL_TO_PASS` / `PASS_TO_PASS` / `difficulty`） |
| SWE-smith（任务工厂） | `SWE-bench/SWE-smith` | ≈277 MB（11 parquet） | **MIT** | false | ✅ | ❌ 需 GitHub + Docker |
| SWE-Gym | `SWE-Gym/SWE-Gym` | 43.6 MB | MIT | false | ✅ | ❌ 同上 |
| R2E-Gym Subset | `R2E-Gym/R2E-Gym-Subset` | ≈943 MB（8 shard） | Apache-2.0 | false | ✅ | ❌ 同上 |
| SWE-rebench | `nebius/SWE-rebench` | ≈245 MB | CC-BY-4.0 | false | ✅ | ❌ 同上 |
| Multi-SWE-bench | `ByteDance-Seed/Multi-SWE-bench` | python 31 MB；9 语言合计 ≈200–300 MB | `other` | false | ✅ | ❌ 同上 |
| SWE-bench-Live | `SWE-bench-Live/SWE-bench-Live` | ≈60 MB（23 月分片） | MIT | false | ✅ | ❌ 同上 |
| LiveCodeBench | `livecodebench/code_generation_lite` | **4.5 GB** | `cc` | false | 私有测试随数据 | ⚠️ 数据可跑；沙箱 harness 在 GitHub |
| BigCodeBench | `bigcode/bigcodebench` | ≈2.3 MB/版本 | Apache-2.0 | false | ✅（执行需 Docker） | ❌ Docker |
| RepoBench（Python） | `tianyang/repobench_python_v1.1` | MB 级 | `cc` | false | 静态补全 | ✅ 可本地评测 |
| SWE-PolyBench | — | — | — | — | — | ❌ **GitHub-only** |

## G2. agent harness / 交互式任务

| 数据集 / 工具 | 通道 | 体积 | 许可 | 备注 |
|---|---|---|---|---|
| **Terminal-Bench** | HF `harborframework/terminal-bench` | 66 个任务目录（小） | Apache-2.0 | task 目录含容器定义 ⇒ **需 Docker**（可用 ECI 沙箱替代） |
| **AgentDojo** | **PyPI `agentdojo==0.1.9`** | wheel 数百 KB~MB | MIT | ✅ **pip 可装**，benchmark 数据随包（tool-policy + 注入用例） |
| **swebench**（评测 harness 本体） | **PyPI `swebench==5.0.2`** | — | MIT | ✅ 可装；不含目标仓库 |
| Agent-SafetyBench | HF `thu-coai/Agent-SafetyBench` | 2.88 MB（单文件） | MIT | 静态样本 + 判定；10 种 failure mode |
| AgentGym / AgentEval | HF `AgentGym/AgentEval` | 28.6 MB | **无 license tag** | 官方环境需 GitHub/Docker |
| τ-bench / τ²-bench / τ³-bench | **GitHub-only**（HF/PyPI 均 404） | — | — | ❌ 不可达；但可自建同形态 policy + pass^k |
| DevAI / Agent-as-a-Judge | **GitHub-only** | — | — | ❌ 不可达 |
| AgentBench（官方） | GitHub-only | — | — | ❌ 不可达（镜像 `iFurySt/AgentBench` 许可不明） |
| SWE-agent-trajectories | HF `nebius/SWE-agent-trajectories` | **1.1 GB**（12 shard） | CC-BY-4.0 | 轨迹 + patch + 测试结果；无环境 |
| SWE-rebench-openhands-trajectories | HF `nebius/SWE-rebench-openhands-trajectories` | **2.08 GB** | CC-BY-4.0 | 轨迹 parquet |
| Nemotron-SWE-v1 | HF `nvidia/Nemotron-SWE-v1` | **11.1 GB** | CC-BY-4.0 | 训练数据（r2e_gym），非评测 |
| Nemotron-Agentic-v1 | HF `nvidia/Nemotron-Agentic-v1` | **5.79 GB** | CC-BY-4.0 | `interactive_agent` / `tool_calling` 两 config |

## G3. 判据 / 规则遵循类

| 数据集 | HF id | 体积 | 许可 | gated | 备注 |
|---|---|---|---|---|---|
| **IFEval** | `google/IFEval` | **207 KB** | Apache-2.0 | false | **已本地实测下载**（207,111 B） |
| **IH-Challenge** | `openai/ih-challenge` | ≈157 MB（4 jsonl，最大 122 MB） | Apache-2.0 | false | system > user > tool > third-party 层级冲突 |
| FollowBench | `YuxinJiang/FollowBench` | 小 | Apache-2.0 | false | 5 类约束 × 1–5 级 |
| InFoBench | `kqsong/InFoBench` | 小 | MIT | false | DRFR（分解需求满足率） |
| ComplexBench | 官方 404；`liyyy/ComplexBench-Edit` | — | — | **`gated:"auto"`** | 需登录同意 |
| JudgeBench | `ScalerLab/JudgeBench` | 小 | MIT | false | judge 误判率锚点 |
| RewardBench | `allenai/reward-bench` | ≈13.5 MB | ODC-BY | false | 偏好对 |
| AutoIF / LLMBar / FLASK | — | — | — | — | **GitHub-only** |

## G4. 现在就能下的 Top 5（按「体量 × 判据完备度」）

| # | 数据集 | 体积 | 命令 |
|---|---|---|---|
| 1 | `princeton-nlp/SWE-bench_Verified` | 2.1 MB | `HF_ENDPOINT=https://hf-mirror.com hf download princeton-nlp/SWE-bench_Verified --repo-type dataset` |
| 2 | `SWE-bench/SWE-smith` | 277 MB | `hf download SWE-bench/SWE-smith --repo-type dataset` |
| 3 | `SWE-Gym/SWE-Gym` | 43.6 MB | `hf download SWE-Gym/SWE-Gym --repo-type dataset` |
| 4 | `nebius/SWE-rebench` | 245 MB | `hf download nebius/SWE-rebench --repo-type dataset` |
| 5 | `openai/ih-challenge` + `google/IFEval` | 157 MB + 207 KB | `hf download openai/ih-challenge --repo-type dataset`；`hf download google/IFEval --repo-type dataset` |

**唯一「安装即用」的交互式评测**：`pip install -i https://mirrors.aliyun.com/pypi/simple/ agentdojo==0.1.9`（另可装 `swebench==5.0.2` 拿到评测代码，但不含目标仓库）。

## G5. 明确不可下载（本环境）

`BugsInPy` · `Defects4J` · `Codeflaws` · `SWE-PolyBench` · `Aider-polyglot` · `τ-bench/τ²-bench/τ³-bench` · `DevAI` · `Agent-as-a-Judge` · `AutoIF` · `LLMBar` · `FLASK` · `AgentBench(官方)` —— **全部 GitHub-only**。

## G6. 对我们项目的判断（比本地 session DB 更「多样」吗？）

**分两类看：**

| 用途 | 公开数据能否补足多样性 | 判断 |
|---|---|---|
| **多智能体配置行为**（角色矩阵、委托、审查配对、权限门） | ❌ 几乎没有公开集覆盖「多 agent 配置」本身 | 本地 1,828 条 session 仍是**主数据源**；公开集只能提供「任务环境」而非「配置行为样本」 |
| **任务类型多样性**（编程任务 / 规则遵循 / 工具策略） | ✅ 明显更广 | 用 IFEval/IH-Challenge/AgentDojo/Agent-SafetyBench 做**判据模板与对抗用例**；SWE-* 作**任务语料** |
| **可执行性** | ⚠️ 受限 | SWE-* 全部需要 GitHub + Docker；本环境两者都缺 ⇒ **只能先缓存数据，不能执行** |
| **轨迹语料** | ✅ 大（1.1–11 GB） | 但域不匹配（单 agent 写代码），只用于失败分类学与基线，不当我们的 case 源 |

**结论**：
1. 公开数据能补的是**任务类型与判据模板**，补不了**多智能体配置行为**——所以不能替代本地 session DB，只能作为补充。
2. 本环境**现在就可用**的是：IFEval、IH-Challenge、Agent-SafetyBench（静态）、`agentdojo`（pip）、RepoBench（静态）；SWE-bench Verified 可下但不可跑。
3. 若要把 SWE-* 跑起来，需先解决两个缺口：**GitHub 可达** 与 **容器执行**（前者本环境不可达；后者可用 ECI 沙箱替代 Docker，但仓库仍需 GitHub）。

## G7. 建议的下载清单（< 30 MB，先做，不占资源）

```bash
export HF_ENDPOINT=https://hf-mirror.com
# 判据/规则类（可直接用）
hf download google/IFEval --repo-type dataset
hf download scalerlab/JudgeBench --repo-type dataset
hf download allenai/reward-bench --repo-type dataset
hf download YuxinJiang/FollowBench --repo-type dataset
hf download kqsong/InFoBench --repo-type dataset
hf download thu-coai/Agent-SafetyBench --repo-type dataset
# 编程任务语料（先缓存，待有执行环境再用）
hf download princeton-nlp/SWE-bench_Verified --repo-type dataset
# 交互式 harness（可直接装）
pip install -i https://mirrors.aliyun.com/pypi/simple/ agentdojo==0.1.9
```

## G8. 未核实项

- `agentdojo` 包内是否内嵌全部 benchmark suite（li­brarian 未安装验证；建议装上后 `ls agentdojo/data`）。
- Terminal-Bench 的容器镜像来源与 Docker Hub 可达性。
- `nebius/SWE-rebench` 是否有 PyPI 包（阿里云镜像 404，不代表官方 PyPI 无）。
- 许可：`princeton-nlp/SWE-bench*` 卡片无 license tag（上游 repo 为 MIT，需以仓库 LICENSE 为准）。
