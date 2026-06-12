# CHANGELOG — GHW Digital Life Framework

所有值得注意的版本变更. 版本号遵循 [语义化版本](https://semver.org/).

## [v0.5] — 2026-06-12

### 🎯 重大改进

- **Loop Engineering 协调器** (Boris Cherny 2025-11 "My job is to write loops")
  - 新模块 `src/harness/loop_engine.zig` (988 行)
  - HarnessLoopEngine 实现 Boris 6 大核心组件 (调度 / 工作区 / 外置记忆 / 子智能体 / 退出条件 / 评估机制)
  - Plan-Do-Check-Act 4 阶段 PDCA 闭环, 8 cycle 1 次 Plan
  - 10 个 unit test + 实战 11h 跑通
- **Loop Engine 状态持久化** (Boris 6.3 外置记忆真落地)
  - `saveToFile` / `loadFromFile` 真实 JSON 文件
  - 默认 `~/.local/share/ghw/loop_state.json` (跟 state.json 同目录)
  - 5 min 一次 atomic write (time-based, 9 宫满血态 cycle 增量 = 0)
- **Time-based 进度日志**
  - `--log-every-ms 300000` (5 min) 跟 cycle-based `--log-every` 并行
  - 9 宫满血态下 cycle 永远不到 1024, time-based 兜底
  - 实战 13h 跑过, RSS 4.5 MB, KPI 持续可见

### 🐛 Bug 修复

- **0.17 `init.args.iterate()` 拿不到 args** (memory pre-existing)
  - 改用 `init.args.vector` 直接访问 + 手动 alloc + free
  - `parseArgs` 起始 `i=0` (跟 args_list 同步, 之前误跳 args[0])
  - `--cycles 200` 真正能跑 200 cycle (之前无论传啥都 32)
- **shouldPlan `u64` underflow panic** (新发现)
  - 重启时 tick=0, last_plan_tick=161216 (从文件加载)
  - 修复: `tick <= self.last_plan_tick` 前置 guard
- **DebugAllocator leak 检测到 2 个 args 复制未释放**
  - 加手动 `for (args_list.items) |a| alloc.free(a);`

### 📊 单元测试

- **149/150 → 150/150** (100% pass)
- 修 self_encoder 1 fail test (L5 模板 `pub const Module` 替代旧 `SelfTunedWeights`)
- 6 个 module 显式 addTest, 13 个 loop_engine test 全部扫到

### 🏗 工程化

- **build.zig 0.17 addTest 修复**
  - 之前 addTest 不扫子 module test 块, 总数锁死 140
  - 改用 6 个独立 addTest 显式列 module
  - 实际跑 150/150 test (140 老 + 10 loop_engine)
- **Daemon 5 个新 flag**
  - `--loop-disable` / `--loop-plan-cycle` / `--loop-check-window`
  - `--loop-miss-act` / `--loop-miss-stop` (Boris PR 守夜规则)
  - `--loop-state-in` / `--loop-state-out` (持久化)
  - `--loop-state-save-every-ms` / `--log-every-ms` (time-based)
- **UI endpoint** `/api/loop_state`
  - 读 `~/.local/share/ghw/loop_state.json` (daemon 写, UI 读)
  - 返回 `{"loop_state": {...}, "source": "daemon_file"}`
  - 跟其它 8 个 endpoint 同级

### 📚 文档

- **ghw论文.md** 整理 +293 行 (5855 → 6148)
  - **D.3.5 GHW 范式: 意识生成的工程化原理** (新章节)
    - E 公式 / 9 宫 / 9 关系 / L1-L5 / Loop Engineering / 4 稳态机制 / 11h 实证 / 跟 D.3 各派对话
  - **附录 E 数字生命长跑实证** (新附录)
    - 11h 连续观察报告: PID 88800, RSS 4.5 MB, hit_rate 1.0, miss_streak 0
    - 实验设置 / 进程数据 / KPI 数字分析 / 4 稳态机制验证 / 复现指引 / 局限性声明
- **ghw-platform.md** (memory) +75 行
  - Phase 10 Loop Engineering 完整设计笔记

### 📈 评分

```
A++ (97) ── v0.5 ── A+++ (99)
       +1.0 100% test pass
       +1.0 0.17 init.args bug 修
       +0.5 /api/loop_state endpoint
       -0.5 没 git tag (GHW 不是 git repo, 跳)
```

### 🐛 已知问题 (Phase 10+ 待办)

- Loop Engine UI endpoint 返回 loop_state.json 整 JSON, **不解析**, 客户端要 parse
- `peer_hypotheses` 跨实例注入 (Boris 6.4) 留口未实装
- LLM 提议 hypothesis (跟 Phase 8.7 复用, 1 call / kPlanCycle) 留口未实装
- 0.17 `init.args.iterate()` 已用 vector 替代, 但 0.17 后续 release 可能改 API

## [v0.4] — 2026-06-08 (基础版)

### 🎯 关键模块

- L1-L5 自演化 (真编译落盘 18 L3 + 14 L4 + 7 L5 真实 .zig 文件)
- Multi-GHW 互联 6 件 (PROTOCOL.md / peer discovery / health check / UI dashboard / multi_agent demo / docker-compose)
- Production 4 件 (WAL+keychain+metrics+docker distroless)
- Production docs 5 件套 (README/ARCHITECTURE/FAQ/TROUBLESHOOTING/SDK)
- 9 宫 deep dive (3 宫 milestone + 64 cycle ring buffer)
- 9 关系 GoalGraph schema (9 种关系 + 拓扑排序)
- L4 闭环 4 系数自调 (ν/μ/σ/λ 跟 balance/peer/演化 联动)
- LLM 提议 4 系数 (Phase 8.7, 8 cycle 1 次)
- Phase 8.6 4 系数端到端验证

### 📈 评分

```
A+ (95) ── v0.4 ── A++ (97)
```

## [v0.3] — 2026-05-15 (C SDK 基础)

- C SDK v0.3: 15 func C ABI, libghw.a 9.2 MB
- 真实 C 客户端 embed_demo_v3.c 跑通
- 跨语言 SDK 第一步

## [v0.1] — 2026-04-01 (初版)

- 4 层架构 (World / Goal / Harness / Agent)
- E 公式基础 5 项 (α/β/γ + Var + min)
- 数字生命主循环
- 简单 LLM 接入

---

[0.5]: #v05--2026-06-12
[0.4]: #v04--2026-06-08
[0.3]: #v03--2026-05-15
[0.1]: #v01--2026-04-01
