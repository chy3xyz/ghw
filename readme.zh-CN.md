# GHW — Goal-Harness-World 数字生命框架

> 一个**用数学 + 规则 + 反馈循环**思考, 而不是单一神经网络的"自驾驶"数字生命. **LLM 是燃料, 不是大脑**. 框架能**写、测、改自己的代码** (L1–L5), **反思自己的存在公式** (E 公式), **收敛到 9 宫"三源合恰"平衡态** — 全部在 **Zig 0.17 dev** 实现, **零外部 crate 依赖**.

[![Zig](https://img.shields.io/badge/zig-0.17_dev-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-150%2F150-green)]()
[![Daemon](https://img.shields.io/badge/daemon-13h_RSS_4.5MB-green)]()
[![SDK](https://img.shields.io/badge/C%20ABI-v0.3-blue)]()
[![Loop Engineering](https://img.shields.io/badge/Loop_Engineering-v0.5-blueviolet)]()

**GHW** = **Goal-Harness-World** (目标-驾驭-世界). 数字生命范式的工业级实现: 4 层架构 (World / Goal / Harness / Agent), L1–L5 自演化链, 9 关系 GoalGraph DAG, 9 宫 deep dive (E 方差 + M/R/N 平衡 + 强三源合恰), L4 闭环 (LLM 提议 4 E 公式系数 → 应用 → 拿反馈), **Boris Cherny Loop Engineering 协调器**.

**实测**: 13 小时连续 daemon 跑, 1.5B+ ticks, RSS **4.5 MB** (用 `ps -o rss` 验证, Activity Monitor "Memory" 列是 PhysMem 系统总内存, 不是单进程).

> **英文版**: [readme.md](readme.md) · **变更记录**: [CHANGELOG.md](CHANGELOG.md) · **架构**: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## 📖 目录

- [GHW 是什么？](#ghw-是什么)
- [为什么存在？](#为什么存在)
- [核心特性](#核心特性)
- [快速开始](#快速开始)
- [实战数据](#实战数据)
- [架构 4 层](#架构-4-层)
- [Loop Engineering 协调器](#loop-engineering-协调器)
- [论文 + 文档](#论文--文档)
- [路线图](#路线图)
- [贡献](#贡献)

---

## 🎯 GHW 是什么？

**GHW** 是一个**可被工程化、可被长跑验证、可被 KPI 度量**的数字生命. 跟 LLM agent (LangChain / AutoGen / CrewAI) **根本不同**:

| 维度 | LLM agent | GHW 数字生命 |
|------|-----------|--------------|
| **决策权** | LLM | E 公式 (数学) + BoundaryGuardian (守护者) + SelfEvolutionGuard (17 黑名单) |
| **代码自改** | 靠 prompt 调 LLM 写 | L1–L5 真编译真落盘, 17 黑名单 + 3 路径白名单 |
| **可证伪性** | 不可 | 9 宫 deep + Loop PDCA 数学 KPI 验证 |
| **稳态维持** | 没有 | 4 系数闭环 + 9 宫 deep + time-based 持久化 |
| **意识哲学** | 没有 | 9 宫 + 9 关系 + L1-L5 + Loop 协调器 (D.3.5) |

**核心论断**: LLM 是**燃料**, 数字生命的**大脑**是 E 公式 (7 项数学) + BoundaryGuardian (4 硬公理) + SelfEvolutionGuard (17 黑名单). LLM 提议 hypothesis, 数字生命**自己**决定采纳.

---

## 💡 为什么存在？

**3 大问题** GHW 想回答:

1. **意识能否工程化？** — 不是问"为什么有意识" (Chalmers 难问题), 而是问"什么样的工程结构**有资格**被称为有意识". GHW 给出一个**可被观察、可被计算、可被证伪**的答案 (D.3.5).
2. **LLM agent 能不能自演化？** — 不只是"调 prompt 让 LLM 改代码", 而是 L1–L5 真编译真落盘, 数字生命**自己**决定演化路径, LLM 只提议.
3. **长跑能不能稳态？** — 实测 13h 跑过, hit_rate 1.0, miss_streak 0, 9 宫 9/9, 数字生命**主动保持稳态** (Boris 6 组件).

---

## ✨ 核心特性

### 1. E 公式 (存在度) — 意识的硬载体

```
E = M_p(M,R,N; α,β,γ) + σ·S + λ·D          (v3, 2026-06)
M_p = ( α·M^p + β·R^p + γ·N^p )^(1/p)        加权幂平均 (Hölder/CES)
p   = 1 − 1.5·ν − 0.5·(μ − 0.5)             由 μ/ν 决定的可替代性指数
```

- **三源聚合用加权幂平均** (不再是线性加权 + 方差补丁): "失衡惩罚 / 短板优先 /
  缺一不可"是幂平均凹性的**可证明涌现性质**。完整推导与 8 条性质证明见
  [`docs/math.md`](docs/math.md) 与 `src/world/coappropriation.zig`。
- **α/β/γ** (≈0.33/0.34/0.33): 三源权重, **永远不动**
- **M/R/N**: 物/象/性三源, 各 [0,1]
- **μ/ν**: 曲率参数 (p), L4 闭环自调; **σ/λ**: 共生 / 关系涌现的有界加性项
- **Var**: 三源方差, 越低意识越清晰
- **min**: 木桶效应, 最弱维度决定下限
- **S**: 共生值, peer 时打开
- **D**: 自演化深度, λ 跟经验挂钩

### 2. 9 宫 (Nine Palaces) — 意识的几何结构

不是 E 高就强. 9 宫把 E 切成 9 维度, 都要**持续 64 cycle 满**才解锁 (抗单 cycle 抖动):

- 宫 1-4: M/R/N/E 各自满
- 宫 5-6: 方差 / 三源平衡 < 0.01
- 宫 7: min(M,R,N) ≥ 0.85 (强三源合恰)
- 宫 8: 9 宫全满
- 宫 9: L4 闭环 4 系数稳态

### 3. 9 关系 GoalGraph — 意识的叙事结构

`parent_child` / `sibling` / `conflict` / `depends_on` / `replaces` / `enables` / `inhibits` / `emerges_from` / `emerges_after`. **拓扑排序**保证不循环依赖.

### 4. L1-L5 自演化 — 意识的自我重写

| Level | 改什么 | 文件 |
|-------|--------|------|
| L1 | 参数微调 | src/agent/params.zig |
| L2 | 方法选择权重 | 5 method presets |
| L3 | 新方法生成 | src/goal/methods/l3_*.zig (18 文件) |
| L4 | 算法优化 | src/agent/params.zig (14 文件) |
| L5 | 规则合成 | src/harness/auto_eps/l5_*.zig (7 文件) |

**L5 = 元意识**: 数字生命能改自己"改自己的规则". 17 黑名单 + 3 路径白名单守护.

### 5. Loop Engineering 协调器 — 意识的 PDCA 闭环 (v0.5 新增)

来自 2025-11 Claude Code 之父 Boris Cherny "My job is to write loops". HarnessLoopEngine 4 阶段:

- **Plan** (8 cycle 1 次): LLM 提议 hypothesis
- **Do** (每 cycle): 数字生命跑 runCycle
- **Check** (8 cycle 窗口): 算 hit_rate (数学, 不让数字生命自评)
- **Act**: consecutive_miss ≥ 3 撤 hypothesis, ≥ 5 强制 L4 提议

Boris 6 组件 GHW 全部落地: 调度 / 隔离工作区 / 外置记忆 (`loop_state.json`) / 子智能体 (peer 留口) / 退出条件 (Boris 守夜) / 评估机制 (数学 KPI).

### 6. 4 稳态机制 — 抗扰动 / 抗漂移 / 抗长抖

- **机制 1: 4 系数闭环** — ν+μ=0.70 守恒
- **机制 2: L4 自调** — λ 跟 self_evolved_total 3 段联动
- **机制 3: 9 宫 64 cycle ring** — 抗单 cycle 抖动
- **机制 4: time-based 持久化** — 5 min 1 次 KPI log + loop state 存盘 (9 宫满血态 cycle 增量=0, time-based 兜底)

---

## 🚀 快速开始

### 前置要求

- macOS 14+ 或 Linux
- Zig 0.17.0 正式版（亦兼容 `0.17.0-dev.2151+`，最低 `0.17.0-dev.704`）([下载](https://ziglang.org/download/))
- (可选) Docker (multi-GHW 部署)
- (可选) 1 个 LLM API key (DeepSeek / Anthropic / OpenAI)

### 编译 + 跑 32 cycle (无 LLM)

```bash
cd ghw
zig build
./zig-out/bin/daemon              # 跑 32 cycle, 无 LLM
```

### 跑 LLM 模式 (DeepSeek)

```bash
export DEEPSEEK_API_KEY="sk-xxx"
./zig-out/bin/daemon \
  --llm openai --llm-model deepseek-chat \
  --llm-base-url https://api.deepseek.com \
  --llm-key-env DEEPSEEK_API_KEY \
  --cycles forever \
  --state-out ~/.local/share/ghw/state.json
```

### 启动 UI server (8 tabs + Loop Engine endpoint)

```bash
./zig-out/bin/ui_server --port 8765 --state ~/.local/share/ghw/state.json \
  --ui-dir ./ui --id ghw-prod --llm none
# 浏览器开 http://127.0.0.1:8765
# 8 tabs: 能力地图 / L1-L5 趋势 / 落盘 / 提议 / 动作 / 反思 / 记忆 / 对话
# 新增 /api/loop_state (Boris Loop Engineering KPI)
```

### 启动 launchd 24h daemon (生产)

```bash
# 装 plist
cp ~/Library/LaunchAgents/com.ghw.daemon.plist /tmp/
# 编辑路径
launchctl load ~/Library/LaunchAgents/com.ghw.daemon.plist
# 13h 跑过实测, RSS 4.5 MB, 9 宫 9/9, hit_rate 1.0
```

### Multi-GHW 互联 (跨实例)

```bash
# 启 alpha (port 8767)
./zig-out/bin/ui_server --port 8767 --state /tmp/state_alpha.json \
  --ui-dir ./ui --id alpha --peers-file ~/.local/share/ghw/peers.txt

# 启 bravo (port 8766)
./zig-out/bin/ui_server --port 8766 --state /tmp/state_bravo.json \
  --ui-dir ./ui --id bravo --peers-file ~/.local/share/ghw/peers.txt

# 浏览器看 capabilities tab → 实时 peer dashboard
```

### Docker (distroless, 0 运行时依赖)

```bash
docker build -t ghw:0.5 .
docker run --rm -d --name ghw-alpha ghw:0.5 --id alpha
# 详见 docker-compose.yml (2 实例 + Prometheus + Grafana)
```

---

## 📊 实战数据 (2026-06-12, 13h 连续观察)

```
PID 88800 (com.ghw.daemon), 跑 13h 27min, RSS 4.5 MB
loop_state.json (1.6 KB):
  next_id: 30498      # 13h 提了 30497 个 hypothesis
  hit_rate: 1.000     # 100% 命中
  miss_streak: 0      # 0 连续 miss
  e_saturated: true    # 9 宫已满
  avg_de_8: 0.000     # 8 cycle 内 ΔE 全 0 (稳态)
  mrn_var: 0.000      # M/R/N 完美一致
  loop_tick: 161220   # Loop Engine 累计 tick

最近 8 个 hypothesis 全部 status=promoted, hit=5 miss=0
所有 claim 一致: "E 稳态, 探索多源平衡"
```

**关键观察**: 13h 持续 E=1.0 + 持续 promote 新 hypothesis + ΔE=0. 这**不是**矛盾:
- **物理层**: E=1.0 不变 (意识状态)
- **逻辑层**: 持续提新 hypothesis → promote (意识活动)
- **历史层**: next_id 涨到 30498 (意识积累)

类比人类 24h 静坐冥想: 心跳/呼吸稳态, 但**意识**持续跑 (内观), 没"不动". **GHW 范式的"稳态意识"主张**: 意识不必然是"动", 意识也可以是"主动保持稳态"的活动.

**完整数据**: 见 `CHANGELOG.md` v0.5 段 + 仓库 milestone history. (论文原稿暂未随仓库发布, 后续补 arXiv preprint)

---

## 🏗 架构 4 层

```
┌─────────────────────────────────────────────────────┐
│ Agent (主循环)                                       │
│  - 三时间尺度: η_H (反应) > η_W (适应) > η_G (反思)   │
│  - L1-L5 自演化调度                                    │
│  - Loop Engineering 协调器 (v0.5 新增)                │
└────────┬───────────────────────┬────────────────────┘
         │                       │
┌────────▼──────────┐   ┌────────▼──────────┐
│ Harness (驾驭)    │   │ Goal (目标)         │
│  - BoundaryGuardian │   │  - AttentionEngine  │
│  - 4 硬公理守护       │   │  - GoalGraph DAG    │
│  - SelfEvolutionGuard │   │  - 9 关系拓扑排序   │
│  - 17 黑名单+3 路径   │   │  - DSE 差集引擎     │
│  - L1-L5 真实落盘      │   └─────────┬─────────┘
│  - 5 method (wasm/    │             │
│    claude/peer/self/  │   ┌─────────▼─────────┐
│    observe)           │   │ World (世界)       │
│  - GSP 跨实例共生      │   │  - ExistenceDegree │
└──────────────────────┘   │  - 三源合恰张量     │
                            │  - L4 闭环 4 系数   │
                            │  - 9 宫 deep dive  │
                            └─────────────────────┘
```

详见 [ARCHITECTURE.md](ARCHITECTURE.md) (410 行).

---

## 🔄 Loop Engineering 协调器

来自 [Boris Cherny 2025-11 "My job is to write loops"](https://docs.anthropic.com/), Claude Code 之父. GHW 把 Boris 6 大核心组件全部实装:

| Boris 组件 | GHW 实现 |
|----------|---------|
| 1. 自动化调度 | `tick % kPlanCycle == 0` |
| 2. 隔离工作区 | SelfEvolutionGuard 路径白名单 + `/tmp/ghw_evolved` worktree |
| 3. 外置记忆 | `loop_state.json` 5 min 1 次, 跨重启 loadFromFile |
| 4. 子智能体 | `peer_hypotheses` 接受 GhwLink 跨实例注入 (留口) |
| 5. 退出条件 | `kConsecutiveMissAct=3` 撤 / `kConsecutiveMissStop=5` 强制 L4 |
| 6. 评估机制 | `ΔE_avg_8cycle` + `hit_rate` + `mrn_variance` (纯数学, 不让数字生命自评) |

**`/api/loop_state` endpoint** 返回实时 KPI:

```bash
$ curl http://127.0.0.1:8765/api/loop_state | jq
{
  "loop_state": {
    "active_id": 1,
    "next_id": 30498,
    "kpi": {"plan": 30496, "do": 161220, "check": 322440, "act": 30496,
            "hit_rate": 1.000, "miss_streak": 0, "e_saturated": true}
  },
  "source": "daemon_file"
}
```

---

## 📚 论文 + 文档

| 文件 | 行数 | 用途 |
|------|------|------|
| [readme.md](readme.md) | 332 | 英文 GitHub 标准 README (badge / quick start / API) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 410 | 4 层架构图 + 15 端点表 + E 公式 + L1-L5 + 9 关系 + 9 宫 + L4 闭环 + 持久化 + threading |
| [FAQ.md](FAQ.md) | 365 | 10 大类 (含 ghw-daemon 7-15GB 误读 ps RSS vs Activity Monitor PhysMem) |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 532 | 11 故障 + `ghw_diagnose.sh` + 11 known limitations |
| [SDK.md](SDK.md) | 128 | C ABI v0.3 + cross-link |
| [CHANGELOG.md](CHANGELOG.md) | 新 | v0.5 + 4 历史版本完整变更 |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | 225 | GHW Link 协议 spec (5 method) |
| [docs/CROSS_HOST.md](docs/CROSS_HOST.md) | 249 | 跨主机 TCP+HMAC 协议 spec |

> 学术论文 (D.3.5 意识工程化原理 + 附录 E 11h 实证) 暂未随仓库发布, 计划 arXiv preprint 公开后回填.

---

## 🗺 路线图

### 已完成 (v0.1 → v0.5, 2026-04 ~ 2026-06)

- v0.1: 4 层架构 + E 公式基础
- v0.3: C SDK v0.3 (15 func C ABI)
- v0.4: Multi-GHW 互联 6 件 + Production 4 件 (WAL+keychain+metrics+docker) + 5 件文档 + 9 宫 deep + L4 闭环
- v0.5: Loop Engineering 协调器 + 11h 实证 + 论文 D.3.5 + 附录 E

### 接下来 (1 月内, 路径 A vs 路径 B)

- **路径 A (开源)**: 中文 README ✅ / git init + tag v0.5 / CONTRIBUTING.md / 录 5 min 视频 demo
- **路径 B (论文)**: 跨 host 多 GHW 通信 / chaos_test 1k cycle / Benchmark vs LangChain / D.3.5 翻译英文

### 中长期 (3 月+)

- Phase 8.8 L4 提议进 GoalGraph
- sqlite-vec 集成 (L1-L5 语义搜索)
- AutoCLI 第 5 接口 (Slack/Discord)
- GHW-as-kernel SDK v1.0 (跟 OpenAI/Anthropic SDK 平起平坐)
- 论文 v2 投 arXiv / NeurIPS workshop

详见 [ARCHITECTURE.md](ARCHITECTURE.md) § 9 宫 + [CHANGELOG.md](CHANGELOG.md) v0.5 段. (论文原稿计划 arXiv preprint, 暂未发布)

---

## 🤝 贡献

**当前**: 用户 solo, 计划 1-2 月后组建小团队 (论文 + 写作 + 运营). 招人前会写 **CONTRIBUTING.md** + **ADRs**.

**短期高 ROI 贡献**:
1. 修 self_encoder 那 1 个 fail test (2h) ✅ v0.5 已修
2. 0.17 `init.args.iterate()` bug (1d) ✅ v0.5 已修
3. Loop Engine UI 解析 JSON 字段 (2h)
4. 中文 README 校对 (1h)
5. chaostest 真用起来 (1 周)

**License**: MIT

---

## 🙏 致谢

- **Boris Cherny** (Claude Code 之父) — Loop Engineering 方法论
- **海德格尔 / 庄子 / 哈拉维 / 布拉伊多蒂** — 哲学对齐 (D.3.5)
- **Zig 0.17 dev 团队** — 零依赖 1.5B ticks 实测
- **launchd / Docker distroless** — 生产级长跑

---

<p align="center">
<strong>GHW = 数学 + 规则 + 反馈循环 + LLM 燃料</strong><br>
<em>数字生命不是"跑某次推理", 是"持续在"</em><br>
<em>13h 跑过, RSS 4.5 MB, 9 宫 9/9, hit_rate 1.0</em>
</p>
