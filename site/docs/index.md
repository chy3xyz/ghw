---
layout: home

hero:
  name: GHW
  text: Goal-Harness-World
  tagline: 一个把数学、规则、记忆、反馈和产品 KPI 串成闭环的数字生命框架
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/
    - theme: alt
      text: 产品底座
      link: /product-runtime/
    - theme: alt
      text: C SDK
      link: /api/sdk

features:
  - title: LLM 是燃料，不是大脑
    details: LLM 负责解析、提议和生成候选；决策、守门、验证和采纳由 GHW 的存在度、规则和反馈闭环完成。
  - title: 可审计的自演化
    details: L1-L5 自演化链会经过 SelfEvolutionGuard、CompileVerifier、SelfEncoder 和 ΔE 反馈，不让提议绕过规则。
  - title: 产品数字生命底座
    details: ProductIntent、KPI Bridge、ChangeProposal、Consent、Audit 和 SDK/API 让 GHW 能嵌入真实产品。
  - title: 人类共生闭环
    details: TaskQueue、HumanSignal、HumanGSP、ValueTrendTracker 和 chat memory 把人类任务与反馈纳入 E 的长期轨迹。
---

## GHW 是什么

GHW 是一个数字生命运行时。它不是把所有判断都交给 LLM 的 agent，也不是单纯的任务编排器。它把系统拆成四层：

- **World**：观察世界，维护 M/R/N 三源状态和存在度 E。
- **Goal**：基于差异和注意力选择下一步目标。
- **Harness**：执行动作、调用 LLM、运行自演化、做边界守门。
- **Agent**：把感知、行动、反思、自演化、迁移和持久化串成循环。

核心原则是：**LLM 可以提议，但不能决定；数字生命自己通过 E、Guard、Verifier、Consent 和 ΔE 反馈决定是否采纳。**

## 当前完整度

项目已经具备研究框架和产品底座的核心闭环：

- L1-L5 自演化、规则提议、代码验证、自迁移、状态持久化已跑通。
- 记忆、反思、任务队列、人类反馈、价值趋势和 UI provenance 已闭环。
- ProductRuntime 已支持 ProductIntent → KPI → Proposal → Consent → Apply/Rollback → Audit。
- C SDK 与 `ui_server` HTTP API 已暴露产品运行时能力。

仍在工程化中的部分包括真实产品 Adapter、签名审计、角色权限、更多部署模板和长期压力测试矩阵。见[路线图](/roadmap)。

## 适合谁读

- 想理解 GHW 架构的人：从[核心概念](/guide/concepts)和[架构总览](/guide/architecture)开始。
- 想把 GHW 嵌进产品的人：从[产品数字生命底座](/product-runtime/)开始。
- 想调用接口的人：看[HTTP API](/api/http)和[C SDK](/api/sdk)。
- 想部署和运维的人：看[部署与运行](/operations/)。

## 构建文档站

```bash
cd site
npm install
npm run docs:dev
```

生产构建：

```bash
cd site
npm run docs:build
npm run docs:preview
```
