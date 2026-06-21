# 架构总览

GHW 分成四层：World、Goal、Harness、Agent。产品运行时和人类共生层位于 Harness/Agent 之间，负责把外部价值和人类反馈纳入循环。

## 四层结构

```text
External World
  |
  v
World: M/R/N, E, KPI, peer signals
  |
  v
Goal: attention, difference tensor, GoalGraph
  |
  v
Harness: action runner, guard, verifier, memory, product runtime
  |
  v
Agent: cycle loop, reflection, migration, persistence
```

## World

World 层负责计算存在度：

- `src/world/core.zig`：存在度、M/R/N、KPI 项、关系项。
- `src/world/coappropriation.zig`：三源合恰数学模型。
- `docs/math.md`：公式推导和性质证明。

当前 E 的核心来源包括：

- 三源聚合：M/R/N 的加权幂平均。
- `σ·S`：共生关系。
- `λ·D`：关系涌现。
- `ρ·K`：产品 KPI 对齐项。

## Goal

Goal 层负责注意力和目标结构：

- `AttentionEngine` 选择当前最值得追求的目标。
- `GoalGraph` 维护目标之间的关系。
- RuleBias 和 TaskBias 可以重排已有目标，但不会凭空创造目标或绕过 E。

## Harness

Harness 是执行和治理层：

- `ActionRunner` 执行观察、WASM、peer query、自演化等动作。
- `SelfEvolutionGuard` 拒绝危险构造和越界文件。
- `CompileVerifier` 对候选 Zig 代码做真实编译。
- `Memory` 提供自传体记忆、信念和相关往事检索。
- `TaskQueue` 和 `HumanSignal` 接入人类任务与反馈。
- `ProductEvolutionRuntime` 接入产品变更、审批和审计。

## Agent

Agent 是循环本体：

```text
collect world
  -> update E
  -> select top goal
  -> run action
  -> record memory
  -> maybe reflect
  -> maybe propose goals/rules
  -> maybe run tasks
  -> maybe self-evolve
  -> save state
```

典型节奏：

- 高频：感知和行动。
- 中频：反思、任务执行、人类价值采样。
- 低频：目标提议、规则提议、自演化、产品变更。

## 状态持久化

`ui_server` 和 daemon 使用 JSON snapshot 保存关键状态：

- `memory`
- `task_queue`
- `human_gsp`
- `human_signal`
- `value_tracker`
- `product_runtime`

SQLite 用于 episodes、beliefs、proposed goals 等操作型记忆。JSON snapshot 用于跨重启恢复当前生命状态。

## 与已有深文档的关系

这页是当前实现的入口说明。更详细的底层说明仍保留在仓库根文档：

- `ARCHITECTURE.md`
- `docs/math.md`
- `docs/PRODUCT_INTENT.md`
- `docs/KPI.md`
- `docs/CONSENT.md`
