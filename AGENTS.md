# AGENTS.md — GHW 项目准则

> 给所有 Agent(本会话 + 未来)的工作准则。每次写代码前必读。

---

## 1. 核心架构准则

### 1.1 LLM 是燃料,不是大脑

**绝对禁止** 让 LLM 决定"该不该做某事"。
**允许** LLM 提议变体(代码、规则、特征)。

```
外界 (文本/事件)
  ↓ [LLM 通道] parse
  ↓
[Goal 层] AttentionEngine
  ↓
[LLM 提议器]  ← 可选, 提议 N 条候选
  ↓
[SelfEvolutionGuard] 17 黑名单 + 守门
  ↓
[SelfEncoder] 规则合成 + 形式验证
  ↓
[数字生命本体] E 评估, 选最优
  ↓
ΔE 反馈回 LLM (下次提议更准)
```

### 1.2 决策权永远在数字生命手里

| 角色 | 谁能做 | 谁不能做 |
|------|--------|----------|
| 文本→特征 | LLM | — |
| 提议代码变体 | LLM | — |
| 提议规则候选 | LLM | — |
| 守门(17 黑名单) | SelfEvolutionGuard | LLM |
| 形式化验证 | SelfEncoder.verify | LLM |
| 选哪个候选跑 | 数字生命(E 评估) | LLM |
| 改不改 E 公式 | **绝对禁止** | 任何人 |
| 改 SelfEvolutionGuard 黑名单 | 数字生命+人审 | LLM |

### 1.3 模块边界

- **SelfEncoder** 不依赖 LLM (纯规则合成, 可独立 demo)
- **RuleProposer** 把 LLM 输出经 Guard 过滤后入 SelfEncoder
- **HttpLLM** 实现 LLMChat vtable, ProviderKind = anthropic | openai_compat
- **WorldCollector** 用 autocli 子进程拉外部世界数据
- **Daemon** 装配以上所有, 跑长跑进程

---

## 2. 代码风格

### 2.1 Zig 0.17 兼容性

- 不引入外部依赖(零依赖是核心)
- 路径引用用 `@import("module/file.zig")` 而非跨层相对路径
- 所有 `pub const F = f32;` 在模块顶层定义,避免跨目录 import
- 详细 quirks 见 memory/mavis/MEMORY.md "Zig 0.17 dev 0.17.0-dev.387 quirks"

### 2.2 错误处理

- 所有公开函数返回 `!T` (允许失败)
- 内部 helper 可以 panic
- 资源分配用 `errdefer` 兜底释放

### 2.3 测试

- 每个新模块至少 2 个测试
- 端到端 demo 必须真跑(不是 stub),并验证 0 leak
- MockLLM/ShellLLM 用于不需要 API key 的场景
- 真实 LLM 路径(anthropic/openai_compat)需要 API key,文档化但不强制 demo

---

## 3. 当前 L1-L4 状态

| Level | 状态 | 模块 |
|-------|------|------|
| L1 (调参) | ✅ | SelfEncoder.tune_params, ExistenceWeights.adapt |
| L2 (LLM 提议代码) | ✅ | SelfEvolver + MockLLM/ShellLLM/HttpLLM |
| L3 (状态序列化) | ✅ | StateSerializer (原子写 tmp+rename) |
| L4-0 (双进程迁移) | ✅ | SelfMigration (真 spawn/wait/落盘/回滚) + SelfMigrateCLI |
| L4-1 (LLM 提议规则) | ✅ | RuleProposer + SelfEvolutionGuard |
| L4-2 (规则闭环回主循环) | ✅ | GHWAgent.bindRuleLib → selectTopGoal 偏置 + RuleBias provenance |
| L4-3 (连续记忆注入) | ✅ | Memory.buildContext → RuleProposer.setMemory 注入自传体上下文 |
| L4-4 (全通道记忆 + 语义检索) | ✅ | Reflection/LLMGoalProposer 注入 + token Jaccard 检索 |
| L4-5 (演化/完善/长跑记忆) | ✅ | SelfEvolver/TemplateEnhancer 注入 + daemon recordAt + char trigram |
| L4-6 (任务队列闭环) | ✅ | GHWAgent.bindTaskQueue → TaskBias + provenance |
| L4-7 (任务执行+记忆写回) | ✅ | runTask→recordAt + ui_server/daemon 全链路 |
| L4-8 (TaskQueue 持久化) | ✅ | TaskQueue.toJson/loadFromJson → state.json |
| L4-9 (ui 全路径统一) | ✅ | runPostCyclePipeline + provenance API |
| L4-10 (人类反馈闭环) | ✅ | task_feedback → HumanSignal/GSP + UI 评分 |
| L4-11 (GSP/Signal 持久化) | ✅ | human_gsp/human_signal → state.json |
| L4-12 (人类价值闭环) | ✅ | chat 任务 + value 趋势 → 提议触发 |
| L4-13 (价值趋势持久化+UI) | ✅ | value_tracker JSON + status 仪表盘 |
| L4-14 (任务来源+规则提议) | ✅ | Task.Source + RuleProposer ui_server |
| L4-15 (chat记忆+人类投递) | ✅ | chat buildContext + POST /api/tasks |
| L4-16 (筛选+chat provenance) | ✅ | 任务来源筛选 + chat memory badge |
| L4-17 (产品数字生命底座) | ✅ | ProductEvolutionRuntime: KPI→Proposal→Consent→Audit |
| L4-18 (产品底座 SDK) | ✅ | ghw_product_* C ABI |
| L4-19 (产品运行时持久化/API) | ✅ | product_runtime state + ui_server product API |
| L4-20 (产品可用级主干) | ✅ | ProductAdapter + auth + audit hash + KPI HTTP + acceptance |
| L5 (自我写代码) | ✅ | SelfEncoder (规则合成 + 形式验证) |

### LLM 闭环 (2026-06, P0)

历史缺口: LLM 提议的规则进了 `SelfEncoder.rules`, 但 `runCycle` 从不读它们 ——
LLM 像"旁白解说员"而非"驱动器"。现已闭环:

- `GHWAgent.bindRuleLib(*SelfEncoder)` 后, `selectTopGoal` 用已采纳规则的 `dimension`
  统计出 `RuleBias`(favored 维度 + dominance), 给**对齐该维度的目标**叠加有界奖励
  (`RuleBias.MAX_BONUS=3.0 × dominance`), 从而真正改变"这一周期选哪个目标行动"。
- 仍守"LLM 提议 / 数字生命决定": 偏置只在**已有目标间重排**(不凭空造目标、不改 E 公理),
  幅度有界(只能翻转优先级相近的目标), 仍过 boundary + ΔE 兜底。
- **Provenance**: `CycleReport.rule_bias` / `GHWAgent.last_rule_bias` 记录 favored/dominance/
  `selection_changed`, 可审计"这次行为到底有没有被 LLM 提议影响"。`rule_lib` 默认 null ⇒
  零行为变化, 解绑即恢复纯优先级 (闭环可控、可逆)。
- 示例 `examples/fueled.zig`: 提议规则 → `bindRuleLib` → 再跑 cycle, 打印偏好维度与翻转次数。
- **未做(刻意)**: 把 LLM 目标 (`LLMGoalProposer`) 塞进 `GoalGraph` —— 与架构冲突
  (`runCycle` 每 T_G 用 `dse.generate` **重建**目标图, 且 `GoalGraph.add` 不持有 label),
  持久目标通道应是 `human_symbiosis.TaskQueue`(`proposeAndAdopt` 已用); 现已走
  `bindTaskQueue` → `TaskBias` 偏置 (P5), 而非直接塞 ephemeral 图。

### 连续记忆 (2026-06, P1)

历史缺口: 每次调 LLM 都是"失忆快照"—— 只发当下 E/M/R/N, LLM 不知道"我是谁、
我相信什么、过去类似处境怎么收场"。它无法是**同一个生命**。现已连续:

- `Memory.relevantEpisodes(query_dim, query_text, k)`: 按 (维度命中 + ΔE 显著性 +
  token Jaccard 语义相似 + 新近度) 打分检索 top-k 往事, 不再只取"最近 N 条"。
- `Memory.buildContext(...)`: 拼出"自传体上下文块"= 自我叙事 (`self_narrative`) +
  高置信信念 (top-k by confidence) + 与当下最相关的往事 (含各自 ΔE 结果)。
- `RuleProposer.setMemory(*Memory)` 绑定后, `buildUserPrompt` 在状态快照**之前**注入该块,
  query 维度取当前 M/R/N 短板 (argmin), query_text 取 top_goal+last_action ——
  即"优先回忆与当前短板相关的经历"。默认 null ⇒ 行为回退到纯快照 (可控、可逆)。
- 示例 `examples/fueled.zig`: 跑 cycle 时 `recordAt` 记情节 → 设叙事/信念 →
  `setMemory` → 打印 prompt 确含 autobiographical context。
- P2 已扩到 Reflection / LLMGoalProposer, 见下节。

### 全通道记忆 + 语义检索 (2026-06, P2)

P1 只覆盖了 RuleProposer; P2 把"同一个生命"扩到所有 LLM 驱动通道, 并升级检索:

- **Reflection.buildUserPrompt**: 先注入 `buildContext`(叙事+信念+语义相关往事), 再附时序 tail
  (`recentEpisodes(8)`) + 自身状态 —— 反思既连续又不丢"刚刚发生了什么"。
- **LLMGoalProposer.setMemory + buildUserPrompt**: 在世界快照**之前**注入自传体记忆,
  目标提议与自我认知/历史衔接; `ui_server` 启动时自动 `setMemory(&app.memory)`。
- **检索升级 (零依赖)**: `episodeScore` 用 token-set Jaccard 取代纯子串匹配,
  语义相近词(如 optimize/daemon/cpu)可召回旧但相关的 episode, 无需 embedding 向量。
- **Memory.weakestDim(m,r,n)**: 各通道统一用 M/R/N 短板作 query_dim。
- **recentBeliefsBySource**: 从桩实现改为按维度过滤 + 置信度降序。
- 单测: `Reflection: buildUserPrompt 注入自传体记忆 + 时序 episodes`,
  `LLMGoalProposer: buildUserPrompt 注入自传体记忆`,
  `Memory: token Jaccard 检索 — 语义相近词优于无关旧条`。
- P3 已扩到 SelfEvolver/TemplateEnhancer + daemon, 见下节。

### 演化/完善/长跑记忆 (2026-06, P3)

P2 覆盖规则/反思/目标提议; P3 把记忆推到自演化链 + 长跑 daemon:

- **SelfEvolver.setMemory + EvolveContext**: `evolve(req, ctx)` 用 M/R/N 短板检索记忆,
  注入 `GenerationRequest.prompt` (LLM 后端 + 审计链); `agent/core.zig` / `ui_server` 已传完整 ctx。
- **TemplateEnhancer.setMemory + buildUserPrompt**: 绑 memory 时用 `buildContext`(含相关往事);
  未绑时回退旧 EnhanceContext 字段 (可控、可逆)。
- **检索 P3 层**: `episodeScore` 叠加 char trigram Jaccard (零依赖, 替代 embedding 向量)。
- **daemon 闭环**: 每 cycle `memory.recordAt` (goal/E/ΔE); LLM 提议写 `.llm_proposal` episode;
  `proposer.setMemory` + `agent.bindRuleLib` 一并接线。
- **ui_server**: `self_evolver` / `template_enhancer` / `goal_proposer` 启动时均 `setMemory(&app.memory)`。
- 单测: `SelfEvolver: setMemory 绑定后 evolve 不崩溃`,
  `TemplateEnhancer: buildUserPrompt 注入 buildContext`。
### 持久化/LLM 演化/daemon 反思 (2026-06, P4)

P3 记忆只在进程内; P4 让长跑/重启后仍是同一个生命:

- **Memory 完整持久化**: `toJson` 输出 narrative + beliefs + episodes (最多 200 条);
  `loadFromJson` 从 state.json 恢复, 兼容旧版仅 `self_narrative/reflection_count` 块。
- **LlmCodeGenerator**: `SelfEvolver.setGenerator` 可切到 LLM 后端 (仍过 Guard + CompileVerifier);
  `ui_server` LLM 启用时自动切换; 未启用仍用 StaticCodeGenerator (可控、可逆)。
- **daemon 周期 Reflection**: 每 32 tick `reflect` + `recordAt(.reflection, ...)`;
  snapshot/退出前 `mergeJsonBlockIntoSnapshot` 嵌入 memory + task_queue 块 (P7)。
- **ui_server**: `saveState` 用 `memory.toJson`; 启动 `loadFromJson` 恢复 episodes/beliefs。
- 单测: `Memory: toJson/loadFromJson episodes+beliefs roundtrip`,
  `LlmCodeGenerator: extractCode/buildUserPrompt/Mock LLM 生成代码`。

### 任务队列闭环 (2026-06, P5)

历史缺口: LLM/人类投递的任务进了 `TaskQueue`, 但 `runCycle` 选目标时不看 pending 任务。
现已闭环 (跟 P0 RuleBias 同构):

- `TaskQueue.pendingDimensionWeights()`: pending 任务按 priority 加权统计 M/R/N 维度。
- `GHWAgent.bindTaskQueue` + `TaskBias`: `selectTopGoal` 给对齐 pending 任务维度的目标
  叠加有界奖励 (`TaskBias.MAX_BONUS=4.0 × dominance`)。
- **Provenance**: `CycleReport.task_bias` / `last_task_bias` 记录 pending/favored/selection_changed;
  与 `rule_bias` 分层 (任务偏置相对规则偏置之后的增量翻转)。
- `live_loop` / `fueled` 演示 `bindTaskQueue`; 默认 null ⇒ 零行为变化。
- 单测: `TaskQueue: pendingDimensionWeights`, `GHWAgent: TaskQueue pending 任务偏置目标选择`。

### 任务执行 + 记忆写回 + 全链路 (2026-06, P6)

P5 只偏置目标; P6 把任务真正跑完并写回自传体记忆:

- **`GHWAgent.bindMemory`**: `runTask` 完成时 `recordAt(.task_completed, ...)` (ΔE + 维度)。
- **`task_runner.runNextPending`**: dequeue → runTask → complete/fail 薄封装。
- **`LLMGoalProposer.proposeAndAdopt`**: 修泄漏 + urgency→priority; 高 urgency 任务入队。
- **ui_server**: `TaskQueue` + `bindTaskQueue/bindMemory`; 提议改 `proposeAndAdopt`; 每 32 tick `runNextPending`。
- **daemon**: `WorldContext` + `LLMGoalProposer` + 每 64 tick 提议 / 32 tick 执行任务。
- 单测: `task_runner: runNextPending 完成 pending 任务` (含 memory episode)。

### TaskQueue 持久化 (2026-06, P7)

P6 全链路跑通后, pending 任务仍纯内存 —— 重启即丢, TaskBias 与 runNextPending 失效:

- **`TaskQueue.toJson` / `loadFromJson`**: 序列化 next_id + 全任务 (pending/in_progress/completed/failed,
  含 result/feedback); 旧 state.json 无 `task_queue` 字段 ⇒ 返回 false, 零行为变化。
- **ui_server `saveState`**: `"memory"` 后嵌入 `"task_queue"`; 启动 `loadFromJson` 恢复。
- **daemon `writeSnapshot`**: `mergeJsonBlockIntoSnapshot` 嵌入 memory + task_queue; `--state-in` 启动恢复。
- 加载后 `recomputeCounts` + `next_id` 与 max(id) 对齐, 防 ID 冲突。
- 单测: `TaskQueue: toJson/loadFromJson roundtrip`。

### ui_server 全路径统一 (2026-06, P8)

P6/P7 主链路在 `GET /api/state`, 但 chat/propose 入口行为分叉:

- **`runPostCyclePipeline`**: 抽取 sqlite cycle + 自省 + `proposeAndAdopt` + `runNextPending`;
  `handleGetState` 与 **POST `/api/chat` worker** 共用 (行为一致)。
- **GET `/api/propose`**: 改 `proposeAndAdopt` + `storeProposeResult` (不再只写 UI 列表不入队)。
- **chat worker**: `runCycle` + pipeline + `recordAt(.user_chat)` + `saveState` (含 task_queue)。
- **`/api/state` provenance**: 新增 `provenance.rule_bias` / `provenance.task_bias` + `task_queue` 计数,
  可审计「这次选目标是被规则还是 pending 任务偏置」。

### 人类反馈闭环 (2026-06, P9)

P6–P8 任务能跑、能持久化, 但完成后的「人类评价」未接入 GSP/存在度:

- **`task_feedback.zig`**: `runNextPendingWithFeedback` = `runNextPending` + 启发式评分
  (`heuristicScore`: 用 actual ΔE 映射 -5..+5); `applyFeedback` 写 HumanSignal + TaskQueue.feedback +
  HumanGSP.recordInteraction (trust 更新)。
- **ui_server / daemon**: 每 32 tick `runNextPendingWithFeedback`; 每 128 tick `BalanceSeeker` 平衡任务
  (GSP trust 低的人类优先); `appendProvenanceJson` 增加 `human_symbiosis` (value_score / peers trust)。
- **API**: `GET /api/tasks` 任务快照; `POST /api/task/feedback` 人类显式评分 (覆盖启发式)。
- **UI**: 「任务队列」tab — 已完成任务一键评分 -5..+5。
- **未做(刻意)**: GSP/HumanSignal 持久化 (重启 trust 重置; 后续 P10 可并入 state.json)。
- 单测: `task_feedback: heuristicScore` + `applyFeedback 更新 Signal/GSP/Queue`。

### GSP/HumanSignal 持久化 (2026-06, P10)

P9 反馈闭环跑通后, trust 与反馈历史仍纯内存 —— 重启 BalanceSeeker 从零开始:

- **`HumanGSP.toJson` / `loadFromJson`**: peers 全量 (trust / 计数 / best_dimension); 旧 state 无 `human_gsp` ⇒ false。
- **`HumanSignal.toJson` / `loadFromJson`**: feedbacks 数组 + 重建 by_human 聚合; 无 `human_signal` ⇒ false。
- **共享 `state_json.zig`**: extractObjectBlock / writeJsonString 等 (human_symbiosis 块专用)。
- **ui_server `saveState` / 启动**: 嵌入并恢复 `human_gsp` + `human_signal` (在 task_queue 之后)。
- **daemon `writeSnapshot` / `--state-in`**: 同上 mergeJsonBlockIntoSnapshot。
- 加载顺序: 先 register 默认 peers → loadFromJson 覆盖 (旧 snapshot 无块则保留默认)。
- 单测: `HumanGSP` / `HumanSignal` toJson/loadFromJson roundtrip。

### 人类价值闭环 (2026-06, P11)

P10 信任可持久化后, chat 仍不入队、人类价值下滑不驱动补救:

- **`chat_task.zig`**: `isTaskLike` + `maybeSubmitFromChat` — 任务型 chat 以 `from_human="human"`
  入 TaskQueue (priority=7) 并 `gsp.register("human")`; 非任务语句零行为变化。
- **`ValueTrendTracker`**: 64 点 value_score 环形缓冲 + 线性趋势 (镜像 `kpiTrend`); `DECLINE_EPS=0.003`。
- **`RuleProposer.setValueTrend` / `shouldPropose`**: 人类价值持续下滑时主动提议规则 (跟 KPI 并列)。
- **ui_server**: chat worker 入队; `recordValueTrend` 每 post-cycle 采样; value 下滑时加速 `maybeAutoProposeGoals`;
  `/api/state` provenance 增 `value_trend`。
- **daemon / live_loop**: 每 tick 采样 value_score; daemon 规则提议改 `shouldPropose` (含 KPI + value)。
- 单测: `chat_task` ×2, `ValueTrendTracker` 下降趋势, `RuleProposer` value 下滑触发。

### 价值趋势持久化 + UI (2026-06, P12)

P11 value 趋势重启后缓冲清零, 需 64 tick 才再触发补救; chat 入队仍靠关键词:

- **`ValueTrendTracker.toJson/loadFromJson`**: `value_tracker` 块 (idx/count/last_score/history[64]);
  ui_server/daemon save/load 与 human_gsp 同级。
- **`chat_task` `@task` 前缀**: `@task` / `@task:` 强制入队 (priority=8), 跳过关键词启发式。
- **UI status tab**: ValueMetric 仪表盘 (value_score 进度条 / value_trend / peers trust);
  metrics 卡增「人类价值」「价值趋势」; chat 提示 `@task` 用法。
- 单测: `ValueTrendTracker` roundtrip, `chat_task @task` 强制入队。

### 任务来源 + 规则提议 + 趋势采样 (2026-06, P13)

P12 任务 tab 看不出投递来源, provenance 只有 value_trend 标量, ui_server 缺 RuleProposer:

- **`Task.Source`**: `chat_forced` / `chat_heuristic` / `llm_proposer` / `balance` / `human`;
  `submitWithSource(..., source)` + `toJson`/API/UI 来源 badge (`@task` / chat / llm / balance)。
- **`ValueTrendTracker.appendRecentSamplesJson`**: 最近 16 点 →
  `/api/state` provenance `human_symbiosis.samples`; status tab 简易 sparkline。
- **ui_server RuleProposer**: LLM 接入时 init `SelfEvolutionGuard` + `RuleProposer`;
  `bindRuleLib` 在 SelfEncoder 就绪即绑定; `runPostCyclePipeline` 调 `maybeAutoProposeRules`
  (E/KPI/value 下滑 → Guard → SelfEncoder, 阈值 0.50)。
- 单测: `TaskQueue` source roundtrip, `appendRecentSamplesJson`。

### Chat 记忆回复 + 人类任务 API (2026-06, P14)

P13 之后 chat 仍只用叙事+3条信念 (无语义检索往事); 任务 tab 只能 chat 入队, 无显式 human 投递:

- **`chat_reply.zig`**: `buildChatUserPrompt` — 跟 RuleProposer 同构, 先 `buildContext`(query=用户话+top_goal),
  再附 E/M/R/N + 人类共生 (value_score/pending_tasks); `ui_server.buildLLMReply` 改调此模块。
- **`POST /api/tasks`**: form `title`/`description`/`from_human`/`priority`/`required_dimension` →
  `submitWithSource(..., .human)` + GSP register + `saveState`; 任务 tab 表单 + `source=human` badge。
- **provenance `rule_propose`**: `enabled` / `total` (提议次数) / `adopted_rules` (rule_bias.rule_count)。
- 单测: `chat_reply` buildContext 注入 + 空记忆兜底。

### 任务筛选 + Chat provenance + live_loop 对齐 (2026-06, P15)

P14 之后任务 tab 无法按来源筛选, chat 不知是否用了 buildContext, live_loop 缺 P13/P14 接线:

- **任务 tab 来源筛选**: UI chip 过滤 (`all` / `@task` / chat / human / llm / balance); 显示 `shown/total`。
- **`chat_reply.Meta` + `buildChatReply`**: 返回 `memory_injected` / episode / belief 计数;
  `ui_server` 写入 `last_chat_reply` + `chat_replies_with_memory`; GHW 气泡 `memory` badge;
  `/api/state` provenance `chat` 块; Chat tab 展示最近回复记忆状态。
- **`live_loop`**: `bindRuleLib` + `proposer.setMemory` + 每 cycle `recordAt`; balance 任务
  `submitWithSource(..., .balance)`; 初始任务 `source=human`; 报表增 value_trend / memory 计数。
- 单测: `chat_reply` Meta 注入/空记忆。

### 产品数字生命底座 (2026-06, P16)

GHW 要作为软件产品的进化载体, 不能只停留在「E/KPI 有反馈」, 还需要把产品变更变成一等审计对象:

- **`product_runtime.zig`**: `ProductEvolutionRuntime` 串起 `ProductIntent` → `KpiBridge` →
  `ChangeProposal` → `consent.riskForChange/classify` → audit → apply/rollback。
- **CRM canonical proposal**: `proposeCrmFollowupTightening` 将 crmdemo 的
  "follow-up cadence 7d → 5d" 迁回 Zig 主线, 作为产品进化样板提案。
- **强制门**: 非 minor 变更默认 `pending_consent`; 只有 `approve` 后才能 `applyApproved`;
  已应用变更只能在 `reversible=true` 时 `rollbackApplied`。
- **KPI 进入 E 的产品场景**: `feedKpi` 经 `KpiBridge` 限频写 `ExistenceDegree.recordKpi`,
  并写 `kpi_refreshed` audit entry, 让产品 KPI 成为获取/损失存在度的重要来源之一。
- **Audit JSON**: `auditJson` 输出所有 KPI 刷新、提案、审批、应用、回滚记录, 供产品端持久化或上报。
- 单测: CRM 提案→审批→应用→回滚, KPI feed→E, auditJson 契约。

### 产品底座 SDK (2026-06, P17)

P16 只有 Zig 内部 runtime; P17 把产品数字生命能力暴露给宿主产品 (CRM/SaaS/移动 App):

- **`ghw_product_intent_load(g, path)`**: 加载 ProductIntent JSON 并初始化
  `ProductEvolutionRuntime`。
- **`ghw_product_kpi_feed(...)`**: 经 runtime 喂 CRM KPI, 写入 E 并生成 `kpi_refreshed` audit;
  不再只是裸 `KpiBridge` 诊断。
- **`ghw_product_propose_crm_followup(...)`**: SDK 复现 crmdemo 样板变更
  "follow-up cadence 7d → 5d", 返回 `change_id`。
- **`ghw_product_approve_change` / `ghw_product_apply_change` / `ghw_product_rollback_change`**:
  宿主产品必须显式审批后才能应用, 回滚也进入 audit。
- **`ghw_product_audit_json`**: 返回产品进化审计日志 JSON (C caller 用 `ghw_free_string`)。
- `ghw.h` 已同步声明; `zig build install-sdk` 验证 SDK artifact 可安装。

### 产品运行时持久化/API (2026-06, P18)

P17 让宿主产品能经 SDK 调用 runtime, 但 ui_server/daemon 场景仍缺"重启不丢变更上下文"与 HTTP 操作面:

- **`ProductEvolutionRuntime.toJson/loadFromJson`**: 持久化 `next_change_id` /
  `next_audit_id` / `changes` / `audit`, 恢复后重算 next ids; `required_approvers`
  从当前 ProductIntent 策略重新派生, 避免复制过期策略。
- **状态接线**: `ui_server --product-intent PATH` 显式启用产品模式; `saveState`
  写入 `"product_runtime"` 块, 启动恢复 changes/audit。未传参数时旧行为不变。
- **产品 HTTP API**: `GET /api/product/runtime`, `GET /api/product/audit`,
  `POST /api/product/propose-crm-followup`, `POST /api/product/approve`,
  `POST /api/product/apply`, `POST /api/product/rollback`。
- **错误可用性**: 产品 runtime 未启用返回 503 JSON; 非法状态转换返回 400 JSON,
  不让连接级错误代替产品语义错误。
- 单测: `ProductEvolutionRuntime` changes+audit roundtrip; 全量 `zig build test` / `zig build`。

### 产品可用级主干 (2026-06, P19-P25)

P18 仍是"可审计控制面"; P19-P25 把它推进到能被宿主产品安全接入的最小生产主干:

- **P19 ProductAdapter**: `ProductRuntime` 支持可选 `ProductAdapter` vtable
  (`validate/apply/verify/rollback`); `product_adapter.zig` 提供 `FileConfigAdapter`,
  `ui_server --product-config PATH` 后 `applyApproved` 会真实写配置文件并 verify,
  `rollbackApplied` 写回 `rolled_back`。
- **P20 HTTP 鉴权**: `ui_server --admin-token-env ENV` 读取 token; 产品写接口要求
  `X-GHW-Admin-Token`。环境变量未设置时保持本地开发兼容。
- **P21 审计可信化**: `AuditEntry` 增加 `previous_hash/current_hash` hash chain;
  adapter apply/rollback 失败也写 `change_apply_failed` / `change_rollback_failed` audit。
- **P22 ProductIntent 治理**: parse 层拒绝空 `product_id/version/approved_by` 与
  `update_epoch=0`; `GET /api/product/intent` 暴露 manifest hash / update_epoch /
  adapter 状态 / KPI 最近 feed 时间。
- **P23 审批台数据面**: `GET /api/product/approvals` 返回 pending/approved changes
  (tier/target/summary/expected_delta_k/required_approvers), 前端可直接挂审批台。
- **P24 KPI HTTP feed**: `POST /api/product/kpi` 接收 CRM KPI + 可选 `csat` /
  `incident_rate`, 经 `ProductRuntime.feedKpi` 限频写 E 并返回 `refreshed`。
- **P25 验收脚本**: `scripts/product_runtime_acceptance.sh` 构建测试 + 启动 product mode
  + 走 propose→approve→apply→rollback, 验证文件 adapter 与 audit hash 字段。

### 一产品一 GHW + 分布式共同进化 (2026-06, P26-P28)

P25 之后仍是「单进程产品 runtime」; P26-P28 加固部署契约并探索多 GHW 互联:

- **P26 一产品一 GHW**: `ProductInstanceIdentity` 绑定 `product_id` + `instance_id` + `node_id`;
  `ProductRuntime.toJson/loadFromJson` 嵌入/校验 `product_id`, 快照 product_id 不匹配则拒绝加载;
  `ui_server --ghw-instance-id` / `--ghw-node-id`; `GET /api/product/identity`。
- **P27 分布式 Link**: `ui_server --cross-link-port` + `--cross-link-secret` + `--cross-link-peers`
  启用 TCP+HMAC CrossLink (复用 daemon 同款); GHW Link 新增 `query_product_identity` /
  `query_product_evolution` / `share_evolution_insight`。
- **P28 共同进化**: `CoEvolutionRegistry` 缓存 peer 已验证变更洞察 (同 product_id 优先);
  peer health 周期拉取 `query_product_evolution`; `GET /api/product/co-evolution`;
  state.json 持久化 `co_evolution` 块。

---

## 4. 部署准则

- **零依赖**: 不允许在 `build.zig.zon` 加外部 dep
- **真实 LLM**: 通过 `HttpLLM.anthropic(model, api_key)` 或 `.openai(model, api_key, base_url)`
- **API key 绝不写死在源码里** — 用 env var (`--api-key-env`)
- **状态持久化**: L3 JSON, 路径可配
- **daemon 模式**: 长跑进程, `std.Io.Threaded` + `std.Io.File` 处理 I/O, 不要 `std.fs` (Zig 0.17 已废弃)
- **错误**: daemon 失败要 print 到 stderr (不静默 swallow), 退出码非 0

---

## 5. 存在度公理 v3 (2026-06 重写)

- E 的三源聚合改为**加权幂平均 (Hölder/CES)**, 取代旧的
  `αM+βR+γN − μ·Var + ν·min`。"失衡惩罚 / 短板优先 / 缺一不可"
  现在是幂平均凹性的**可证明涌现性质**, 不再是手调的外挂补丁。
- μ/ν 从加性系数变为曲率参数 (`p = 1 − 1.5ν − 0.5(μ−0.5)`),
  L1/L4 自适应闭环 (adaptEFormula/Proposed) 全部保留。
- σ·S (共生)、λ·D (关系涌现) 仍为有界加性调制项。
- **ρ·K (KPI 产品对齐项) 已并入主公式** (`ExistenceDegree.recordKpi/e/eBreakdown`),
  默认 `kpi_enabled=false` 中性, 接入产品 KPI 后才生效;ρ 是公理常量不可自调。
  原并行实验文件 `world/existence_degree.zig` 已合并删除。
- 完整推导与 8 条性质证明见 `docs/math.md` 与 `src/world/coappropriation.zig`。

## 6. 安全守门 (2026-06 加固)

- **单一黑名单事实源**: 危险构造 (`@panic`/`unreachable`/...) 与伦理红线
  集中在 `self_evolution_guard.zig` 的 `DANGEROUS_CONSTRUCTS` /
  `ETHICAL_REDLINES`, Guard 与 `SelfEncoder.verify` 共用同一份。
- `RuleProposer` 现在审查候选的**全文** (name+desc+condition+action+rationale),
  含 `@panic` 的规则会被拒 (旧实现只审 description 且黑名单漏了 @panic)。
- `Guard.deinitOwned` 用 `owns_config` 标记, 对静态默认配置安全 no-op。
- `Guard.strict_invariants` 开启后, 缺失不变量的代码被拒 (旧实现是空转循环)。

## 7. 已知限制 + TODO

- 自演化/自迁移落盘链路 **已全部做实** (2026-06):
  - `compile_verifier.zig`: 真 `std.process.spawn` 调 `zig build` 编译候选代码, 收
    stdout/stderr/exit_code, 失败把错误摘要回喂 LLM (有真编译通过/失败的单测)。
  - `state_serializer.zig`: `writeToFile` 真落盘且**原子** (写 `<path>.tmp` 后
    `renameAbsolute` 覆盖), 崩溃不留半截 state.json; `readFromFile` 真读盘 (roundtrip 单测)。
  - `self_migration.zig`: `spawnSelfNewVersion` 真 spawn 新版本进程并存 `pending_child`,
    `waitNewProcess` 真 `wait` 回收退出码 (防僵尸); `writeNewCode` 真写 `next_dir/main_v2.zig`,
    `rollback` 真删工件。`migrate()` 只"准备好可交接版本", 进程替换需显式调
    `spawnSelfNewVersion` (避免库使用者在 migrate() 里意外 fork)。
  - `self_evolution_guard.loadFromFile(io, path)`: 真读 `.ghw_guard.json` 并 `loadFromJson`
    热加载白名单/黑名单/不变量; 文件缺失返回 `false` 不报错 (单测覆盖)。
  - `self_migrate_cli.handleMigrateFromArg(alloc, io, path)`: 真读 state.json + parseMinimal
    打印接管报告 (旧版是伪造 state 的桩, 且 `ss.deinit()` 是未分析的死代码, 已修)。
  - **端到端真自迁移示例**: `examples/self_migrate_e2e.zig` (`zig build run-self_migrate_e2e`)。
    同一二进制靠 `--migrate-from` 区分 v1/v2: v1 原子落盘状态 → `spawnSelfNewVersion(args[0])`
    → `waitNewProcess` 回收; v2 真读状态 → 重建 agent → 继续 runCycle → exit 0 交回。
    生产形态只需把 `args[0]` 换成 `zig build` 产出的新二进制路径。
- KPI 喂入: **已接线**。`harness/kpi_bridge.zig` 的 `KpiBridge` 按
  `kpi_refresh_interval_hours` 限频 (`feed` 高频 / `maybeRefresh` 节流) 调
  `ed.recordKpi(crm_kpi.composite(...))`;SDK 经 `ghw_kpi_configure` +
  `ghw_kpi_feed(..., now_unix)` 暴露给产品后端 (见 `lib.zig` / `ghw.h`)。
- KPI **趋势**驱动: `ExistenceDegree.kpiTrend()` 经 `RuleProposer.setKpiTrend` /
  `shouldPropose` 接入 L4-1 触发 — KPI 持续下滑即使 E 未跌穿也会主动提议补救。
- SDK 返回的字符串统一用 c_allocator 分配, `ghw_free_string` 用 `free(3)` 回收
  (修掉了旧的 no-op 泄漏); 长跑嵌入不再无界增长。
- SDK 错误可诊断: 各失败路径写入静态描述, C 端经 `ghw_last_error(g)` 区分
  "没设 key" / "未配置" / "解析失败" 等 (不再只有 -1)。
- `crm_kpi` 的 `user_satisfaction` / `safety` 两轴不再是硬编码占位: `RawKpi.csat` /
  `RawKpi.incident_rate` 为**可选**真实来源 (null ⇒ 回退旧代理行为, 不破坏既有语义);
  SDK 经 `ghw_kpi_feed(..., csat, incident_rate, ...)` 传入 (NaN = 无来源)。

## Learned User Preferences

- 存在度公理、三源合恰等核心数学必须扎实落地（可证明性质 + 测试），不接受「加权和 + clamp + 外挂补丁」式实现
- 收到品质/架构建议后，期望 agent 直接实施改进而非仅出方案（「按照你的建议来」「继续推进」）
- 代码审查只要阻塞或高风险问题，按 path:line 简洁列出；无阻塞时明确说明并最多列 1–2 个可选改进
- 长期目标是 GHW 作为可嵌入商城、CRM、研发工具等宿主产品的生产级数字生命底座，而非停留在研究 demo
- UI/前端修复须实测验证（重启 ui_server + 浏览器硬刷新）后再声称修好，避免只改模板就报完成

## Learned Workspace Facts

- 本地 Zig 工具链: 当前 `~/.local/bin/zig` 指向 `zigup` 的 `0.17.0-dev.2151+2ec5523d5`（旧记录 1422 已过时）；工程已在该版本通过 `zig build` / `zig build test` / 三个验收脚本
- **测试接线约定**: Zig 0.17 只收集**被分析文件**的 test 块——新增 harness 模块必须同时 (a) `src/harness/mod.zig` 导出 (b) `src/ghw.zig` comptime 引用块 `_ = harness.xxx;`，否则其测试**静默不运行**、且 `zig build` 产物可能编译失败；曾因此积压 57 个暗测试（2026-09 已清零，382/382 可达）。回归防护：`bash scripts/check_dark_tests.sh`（独立 cache 全量普查，任一声明 test 未运行即非零退出），新增模块后建议跑一次
- 本地 UI 开发：`scripts/start_ui_servers.sh` 启动 8765（DeepSeek 主实例）、8766（bravo）、8767（alpha）；主 state 在 `~/.local/share/ghw/ui_state.json`
- UI 静态资源：`ui/vendor/` 提供本地化 Alpine/HTMX；ui_server 通过 `/vendor/*` 服务，不依赖外网 CDN
- ui_server 启动时将 `ui/index.html` 与 `ui/app.js` 读入内存；修改 UI 后必须重启对应 ui_server 进程并硬刷新浏览器
- Alpine 前端约定：`app.js` 先于 `alpine.min.js` 加载；根组件必须 `x-data="ghwApp()"`（带括号）；中间路径用 `?.`（`??` 只护最后一级）；`x-show` 为 false 时子表达式仍会求值；SVG 内禁止 Alpine `x-for`，图表用 JS 拼 SVG 再 `x-html`；**面板级深链 `x-show="state?.provenance?.x"` 不随轮询重算**（x-text 会更新但 x-show 效果停在初值，2026-09 实测致 4 个诊断面板永久不可见、domSnapshot 含隐藏元素会掩盖此问题）——面板可见性禁用深链 x-show，常驻或用 `|| true`，数据占位 `?? '—'`
- 项目文档站位于 `/site`（VitePress）；Node 依赖仅存在于 `/site/package.json`，主 Zig 工程保持零依赖
- Sandbox/CI 中 `zig build test` 若遇 Zig 全局 cache 权限错误，可用工作区内 `ZIG_GLOBAL_CACHE_DIR`（或 `ZIG_LOCAL_CACHE_DIR`）重跑
- 外网主路径: AutoCLI → Memory.world_fetch → world_bridge 入队；`WorldCollector`（autocli ask 子进程）为遗留实验通道，勿与周期 AutoCLI 混用
- 求存 P8: ActionRunner 在生存任务 pending 时让路 TaskExecutor；query_peer（含手动 API）统一走 `peer_symbiosis`；危机下采纳规则后经 `survival_feedback` 对照 disk/mem/load 是否真降并强化 `[survive:*]` 信念
- 第一性先验: `harness/primordial_laws.zig` 为 15 条硬公理/生命规律/评估契约的单一事实源（阈值、Bias 上限、ρ、Guard 保护标记）；LLM 不可改写；经 `GET /api/laws` 与 UI「第一性原理」面板只读暴露；消费者必须引用该模块常量
- 觉醒/求存理想生命周期与缺口评估见 `docs/AWAKENING_LIFECYCLE.md`（合理版：觉醒状态机、宿主短板→M/R/N、TaskQueue 为持久目标、有界求存；与自我进化内环融合：求存提供「为何进化」、L1–L5/规则过 Guard 提供「如何更会求存」；与产品 runtime 分轨）。**P0 已落地**：`awaken` / `host_shortfall` / `existence_phase`；ui_server 危机锁 + `POST /api/awaken`；daemon AutoCLI/world_bridge 默认对齐。**P1 已落地**：`evolution_acceptance` provenance + UI 验收面板；`state_contract` 防 ui/daemon 双写；任务维度台账 `by_dimension`。**P2 已落地**：`host_profile`（desktop/mobile 推送）+ `peer_inbox` + Link `query_shortfall`/`share_shortfall`；daemon CrossLink 对齐；验收脚本 `scripts/awakening_lifecycle_acceptance.sh`。**P2c**：`POST /api/peer-inbox/share` + Status UI inbox 详情 + RuleProposer peer digest；`scripts/peer_shortfall_link_acceptance.sh`
- **三源供源闭环 (2026-09)**：物象性按存在论归因——宿主物质压力→M（`applyHostPressure`，`HOST_DRAIN_MAX=0.02/次`）；象存量（episodes+2·beliefs+3·rules+world_fetch，1−e^(−s/120) 饱和水位）→R（`applyRepresentationStock`，双向 ±0.02/次）；价值承认+已验证 `[survive:*]` 信念→N（`applyNatureRecognition`）。任务增益经 `applyDim` 70% 归 `required_dimension` 本源、30% 协同溢出；预测误差记 R（象的损耗）。失衡损失（AM−M_p ≥ 0.08）成为规则提议第六触发分支；provenance `survival.existence` + UI「三源合恰」面板只读暴露。常量单一事实源在 `world/coappropriation.zig` 的 `SourceBackflow`（primordial_laws alias）；判据与数学见 `docs/math.md` §6。E 聚合公理未动。
