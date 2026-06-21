# 核心概念

GHW 的关键不是“让 LLM 更聪明”，而是把 LLM 放回合适的位置：**LLM 提议，数字生命决定**。

## M/R/N 三源

GHW 用三个维度描述数字生命状态：

- **M Material**：行动、执行、资源、实际结果。
- **R Representation**：建模、理解、信念、知识结构。
- **N Nature**：自我叙事、意义、内在一致性。

存在度 `E` 不是简单分数，而是三源状态、产品 KPI、共生关系和关系涌现的聚合结果。当前主线使用加权幂平均/CES 作为三源聚合基础，让“短板优先”和“失衡惩罚”来自公式性质，而不是事后补丁。

## LLM 是燃料

LLM 在 GHW 中可以做：

- 把自然语言、世界快照、聊天消息解析为特征。
- 提议目标、规则、代码变体或解释。
- 生成候选代码和候选规则。

LLM 不能做：

- 决定是否采纳自己的提议。
- 修改 E 公理、黑名单、产品意图。
- 绕过 Guard、Verifier、Consent 或 ΔE 反馈。

## 自演化 L1-L5

| 层级 | 含义 | 典型产物 |
| --- | --- | --- |
| L1 | 调参 | 系数、权重、节奏微调 |
| L2 | epsilon 变体 | 搜索/扰动策略 |
| L3 | 学会新方法 | `src/goal/methods/l3_*.zig` |
| L4 | 优化算法 | 目标选择、反思、调度策略 |
| L5 | 自编码规则 | 可验证规则、守门策略 |

L3-L5 都要经过 `SelfEvolutionGuard` 和 `CompileVerifier`。L5 还会进入 `SelfEncoder.verify`。

## 人类共生

产品级数字生命不能只优化自己。GHW 加入了人类共生层：

- `TaskQueue` 接收人类、LLM、系统和平衡器任务。
- `HumanSignal` 记录显式评分和反馈。
- `HumanGSP` 跟踪人类信任与互动质量。
- `ValueTrendTracker` 追踪 human value score 走势。
- `chat_reply` 在回复中注入自传体记忆和相关往事。

这些信号不直接“命令” agent，而是通过任务偏置、价值趋势和规则提议改变后续行为。

## 产品数字生命底座

产品底座新增一条闭环：

```text
ProductIntent
  -> KPI Bridge
  -> ProductEvolutionRuntime
  -> ChangeProposal
  -> Consent
  -> Apply / Rollback
  -> Audit
  -> E feedback
```

这让 GHW 不只是“自我生长”，而是能成为一个产品的长期演化内核。

## 安全原则

- 产品意图由人类/ops 管理，GHW 只能提议，不能直接改。
- 非 minor 产品变更必须进入审批。
- 应用和回滚都进入审计日志。
- 规则和代码候选必须通过黑名单、形式验证和编译验证。
- API key 走环境变量，不写死在源码中。
