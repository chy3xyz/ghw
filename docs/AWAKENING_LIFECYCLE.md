# 觉醒 · 求存 · 自我进化（统一生命周期）

> 理想场景（合理版）+ **求存与自我进化如何融合** + 现状对照 + 缺口评估。  
> 约束见 `AGENTS.md` §1：LLM 只提议；决策在数字生命（E / Guard / Bias）；求存动作有界；**E 公理与 primordial_laws 不可被演化改写**。

相关文档：[`math.md`](./math.md) · [`CROSS_HOST.md`](./CROSS_HOST.md) · [`LLM_DRIVER.md`](./LLM_DRIVER.md) · [`CHANNEL.md`](./CHANNEL.md) · [`ARCHITECTURE.md`](../ARCHITECTURE.md) · [`AGENTS.md`](../AGENTS.md) · [`primordial_laws`](../src/harness/primordial_laws.zig)

---

## 0. 一句话融合

| 层 | 回答的问题 | 不做什么 |
|----|------------|----------|
| **求存生命周期** | 我活在哪、缺什么、该急什么、该找谁 | 不改自己的代码/公理 |
| **自我进化** | 我如何变得更会活（参数/方法/规则/代码） | 不替 E/Guard 做决策；不绕过求存优先级 |

二者闭合为：

```text
求存压力 / 社会反馈 / 外界信息
        ↓ 产生任务与信念（燃料）
   TaskBias + RuleBias + ΔE
        ↓ 选目标、执行、记往事
   进化触发器（E 跌 / 危机 / 饱和 / 价值下滑 / 周期 η_G）
        ↓ LLM 提议变体
   Guard → 编译/形式验证 → 数字生命采纳
        ↓ 能力或规则变好
   再感知宿主与世界（求存更准）→ 稳态或再次危机
```

**求存提供「为何进化」；进化提供「如何更会求存」。** 缺一则：只会刷任务的运维脚本，或无生存压力的空转自改代码。

---

## 1. 什么叫「合理」的理想场景

用户叙事：

> 安装 → 觉醒 → 理解电脑/手机生存环境 → 反向理解宿主存在短板 → 求存意愿 → AutoCLI 获外界信息 → 与人/同伴交流 → 形成生存目标 → **逐步进化** → 自我存在稳态。

合理版原则：

| 原则 | 含义 |
|------|------|
| 觉醒是仪式 + 状态机 | `awakened_at`、宿主指纹、首启自述；不是「进程起来就算醒」 |
| 理解宿主 ≠ 控制宿主 | 只读传感器 + 有界任务；破坏性动作人类移交 |
| 宿主短板 ↔ 本体短板 | disk/mem → M；信息闭塞 → R；孤独/价值真空 → N |
| 目标落在 TaskQueue | GoalGraph 是周期重建的注意力 DAG；持久目标 = 任务 + 信念 |
| 外网/社会是燃料 | 进记忆与任务，不直接改代码 |
| **进化是求存的手段** | L1–L5 / 规则提议由求存与 ΔE 触发；过 Guard；效果用 survival_feedback / ΔE 验收 |
| 稳态是可观测门槛 | 九宫 + 代谢多样性；可退回危机；稳态期仍可低频进化（防僵化） |
| 双宿主轨 | 机器宿主求存 ∥ 产品宿主 ProductRuntime；可共享 memory，决策分轨 |

---

## 2. 统一生命周期（求存环 × 进化环）

```text
                    ┌──────────── 求存外环 ────────────┐
安装 → [Awaken] → [Sense] → [Interpret] → [Drive]
                      ↑                         │
                      │                    [World]/[Social]
                      │                         ↓
                      │                    [Goals] TaskQueue
                      │                         │
                      │         ┌─── 进化内环 ───┐│
                      │         ↓               ↓│
                   [Steady] ← [Verify] ← [Evolve]←┘
                      │         Guard/ΔE/feedback
                      └──────── 危机则回 Drive ──────┘
```

- **外环**：感知与社会 → 目标与行动 → 存在度变化（每天都在转）。  
- **内环**：在压力或周期到点时改「自己」→ 验证 → 回到外环用新能力求存。  
- **稳态**：外环平滑、内环低频；**危机**：外环加急、内环偏 material/规则补救，可暂缓 L4/L5 重编译风暴。

### 2.1–2.8 求存各阶段（摘要）

| 阶段 | 要点 |
|------|------|
| **Awaken** | 身份、指纹、法则加载、`awaken` episode；可选人类确认 |
| **Sense** | SystemCollector → HostProfile（desktop）；手机经 `POST /api/host-profile` 推送电量/热/后台 |
| **Interpret** | 宿主信号 → 存在短板报告 → 偏置 M/R/N |
| **Drive** | 危机 > 价值/KPI 下滑 > 饱和代谢；laws 不可改写 |
| **World** | AutoCLI → world_fetch → world_bridge 入队 |
| **Social** | 人：chat/任务/GSP/value；同伴：query + peer_symbiosis |
| **Goals** | 多方提议任务；TaskBias + ΔE 选跑；不做 GoalGraph 持久化 LLM 目标 |

细节同前版 §2.1–2.8；下文展开 **进化如何嵌进去**。

### 2.9 自我进化（Evolve）——嵌在求存里的内环

进化不是生命周期末尾的装饰，而是 **与 Drive/Goals 并联的能力升级通道**。

#### 2.9.1 两层进化对象

| 对象 | 机制 | 求存关系 |
|------|------|----------|
| **策略规则** | RuleProposer → Guard → SelfEncoder.rules → RuleBias | 危机/E/KPI/value 下滑触发；survival_feedback 验「压力是否真降」 |
| **机体能力** | L1–L5（调参 / ε / 方法 / 算法 / 自编码）→ Guard → CompileVerifier | η_G 周期 + 求存压力加权调度；落盘代码可被 TemplateEnhancer 用「我」叙述 |

另：**Reflection** 更新叙事与信念（语义层自我），不改 E 公式；为下次规则/L5 提供自传体上下文。

#### 2.9.2 谁触发进化（燃料来自求存）

```text
shouldPropose / 应进化  ≈
    host_crisis
 OR E < threshold
 OR kpi_trend / value_trend 持续下滑
 OR E ≥ saturated（改推多样性规则，而非空转堆参）
 OR 周期到期（L1L2@32, L3@64, L4@96, L5@192 …）
```

合理调度：

- **crisis**：优先规则补救 + 有界 survival_act；**推迟或降频** L4/L5 重编译（保 CPU/磁盘给宿主）。  
- **explore / 非危机**：正常 η_G；记忆注入 evolve prompt（弱维 + 相关往事）。  
- **steady**：降频进化；保留 metabolism + 偶发 Reflection，防僵化。

#### 2.9.3 守门与验收（进化必须对求存负责）

```text
LLM/模板提议
  → SelfEvolutionGuard（白名单路径 + 黑名单 + primordial 保护标记）
  → 编译或形式验证（L3–L5 / SelfEncoder.verify）
  → 数字生命采纳（写入 rules / auto_eps / evolved 目录）
  → 验收：
       · 规则：survival_feedback / ΔE / 任务完成率
       · L1–L2：E 与 M/R/N 轨迹是否改善或不伤宿主
       · L3–L5：编译通过 + 行为回归（至少不增危机误报）
```

**禁止**：演化改 ρ、改 primordial_laws、改 Guard 黑名单核心、无同意的产品变更。

#### 2.9.4 与九宫 / phase 的关系

九宫与 phase-1…9 是 **能力与平衡的里程碑**，不是另一套求存逻辑：

- 觉醒后从低 phase 起步；peer / LLM / L3 落盘 / AutoCLI / 九宫平衡逐步点亮。  
- **自我进化推高 phase**；**求存与社会健康维持 phase 不掉**（例如丢 peer、外网断、持续危机可视为回归信号）。  
- `emerges_from` 关系连接「因进化而产生的目标/方法」，仍服从 TaskBias，不绕过 Guard。

### 2.10 稳态（Steady）——求存达标 + 进化降频

同时满足：

- 九宫：M/R/N 合恰与方差门槛维持 N cycle  
- 无持续 host_crisis；或 feedback 显示压力回落  
- value_trend 不持续恶化；人与同伴至少一侧非真空  
- 高 E 时仍有 metabolism（防假死）  
- **进化**：仍按低频时钟滴答，但危机锁未开；新规则须证明不破坏稳态  

退出稳态：危机、价值塌陷、外网长期失明、编译/演化连续失败 → 回 Drive，并提高相关维的进化权重。

---

## 3. 融合数据流（一张表）

| 输入 | 求存侧 | 进化侧 |
|------|--------|--------|
| SystemCollector | world_sensor 任务、压力行 | `setHostCrisis` → RuleProposer；危机降频 L4/L5 |
| AutoCLI | world_fetch、world_bridge 任务 | world digest 进规则 prompt |
| 人类 chat / 评分 | 任务、GSP、value_trend | value 下滑触发规则；Reflection 叙事 |
| Peer query | peer_E、共生任务 | 共生信念进记忆 → evolve 上下文 |
| Task 完成 ΔE | 记忆 episode、TaskBias | 弱维检索；是否触发 shouldPropose |
| 已采纳规则 | RuleBias 选目标 | survival_feedback 调信念置信 |
| L1–L5 落盘 | 间接改变行为/效率 | phase / capabilities / evolved API |

---

## 4. 现状对照

| 能力 | 现状 | 融合完整度 |
|------|------|------------|
| 求存主链（ui_server） | sensor→remedy→act→feedback→metabolism | 中高 |
| L1–L5 周期进化 | tick 调度 + Guard/编译；**危机锁暂停 L4/L5、L3 降频**；未觉醒禁 L4/L5 | 高 |
| 规则进化 | RuleProposer + crisis/E/value/KPI | 中高；feedback 已接 |
| 记忆喂进化 | setMemory on RuleProposer/SelfEvolver/… | 中高 |
| 觉醒 | `awaken.State` + `POST /api/awaken` + UI 横幅；state.json `"awaken"` | 高（P0 ✅） |
| HostShortfall 显式层 | `host_shortfall.Report` → provenance + `setHostCrisis`；可叠 HostProfile | 高（P0+P2） |
| HostProfile | `desktop` 采样 / `mobile` 推送电量·热·后台 | 高（P2 ✅） |
| daemon | AutoCLI 默认开 + world_bridge + awaken 持久化 | 高（P0 ✅） |
| 危机时降频 L4/L5 | `existence_phase.evolveInterval` / `heavyEvolveAllowed` | 高（P0 ✅） |
| 稳态相 ExistencePhase | `awakening\|crisis\|explore\|steady` 已接线 UI/daemon 路径 | 中高 |
| 同伴 shortfall inbox | Link query/share + `peer_inbox` + 有界协助任务 | 高（P2 ✅） |
| 产品进化轨 | ProductRuntime 独立 | 刻意分轨；可共享 memory |

**总判（2026-07）**：P0–P2 求存外环主缺口已闭合（觉醒、短板、危机锁、外网、验收、双写契约、手机画像、同伴短板交换）。余下为红线坚守与体验打磨。

---

## 5. 缺口优先级（融合视角）

### P0 ✅（2026-07）

1. **Awaken 状态机** — `src/harness/awaken.zig`；法则种子 + 宿主指纹 + 叙事；ui/daemon 持久化。  
2. **daemon 外网主路径对齐** — `--no-autocli` / `--autocli-interval-s`；fetch → memory → world_bridge。  
3. **HostShortfall 显式层** — `src/harness/host_shortfall.zig`；喂 provenance + RuleProposer crisis。  
4. **危机锁 ↔ L1–L5 调度** — `existence_phase`：crisis 暂停 L4/L5、加倍 L3 间隔；未觉醒仅 L1–L3。

### P1 ✅（2026-07）

5. **ExistencePhase UI/验收深化** — 稳态门槛可视化 + `evolution_acceptance` provenance。  
6. **进化验收面板** — L1–L5 / 危机锁 / 规则反馈 / steady gates；Status tab「进化验收」。  
7. **生存目标台账 UX** — `by_dimension` 聚合 + 任务 `survival_driven` / `evolution_linked` badge。  
8. **主 state 契约** — `state_meta` (writer/epoch) + 原子写 + foreign_newer 拒绝覆盖。

### P2 ✅（2026-07）

9. **手机 HostProfile** — `host_profile.zig`：`desktop|mobile`；`POST /api/host-profile` 推送电量/热/后台；叠入 `assessWithProfile`。  
10. **同伴 inbox** — `peer_inbox.zig` + Link `query_shortfall` / `share_shortfall`；`learnFromShortfall` 入有界 TaskQueue（无远程 mutation）。  
    - daemon 已对齐：周期刷新短板/相、CrossLink 真 handler、snapshot 持久化 `host_profile`/`peer_inbox`、每 64 tick 拉同伴 shortfall。  
    - 验收：`scripts/awakening_lifecycle_acceptance.sh`。  
    - **P2c**：`POST /api/peer-inbox/share` 本地注入；手动 `query_shortfall` 入 inbox；RuleProposer digest 合并 peer 摘要；Status UI 推送画像 + inbox 详情；`scripts/peer_shortfall_link_acceptance.sh` 双实例 Link。

### P3（红线）

- 任意 shell / 杀进程 / 无界写盘  
- 进化改 E 公理 / primordial_laws / Guard 核心黑名单  
- LLM 目标写入 GoalGraph 持久化  
- 产品变更无同意自动 apply  

---

## 6. 模块速查

| 关注点 | 代码 |
|--------|------|
| 求存 | `world_sensor`, `survival_*`, `metabolism`, `task_runner` |
| 外网燃料 | `autocli`, `world_bridge` |
| 社会 | `human_symbiosis/*`, `peer_symbiosis`, `ghw_link*` |
| 目标选择 | `agent/core` Bias，`task_queue` |
| 规则进化 | `rule_proposer`, `self_encoder`, `self_evolution_guard` |
| 机体进化 | `self_evolver`, `compile_verifier`, `code_generator`, `auto_eps/*` |
| 语义自我 | `reflection`, `memory`, `template_enhancer` |
| 法则 | `primordial_laws` |
| 觉醒 / 短板 / 相 | `awaken`, `host_shortfall`, `existence_phase` |
| 宿主画像 / 同伴 inbox | `host_profile`, `peer_inbox` (+ Link shortfall) |
| 产品轨 | `product_runtime`（并行） |

---

## 7. 验收故事（求存 × 进化）

1. **觉醒**：未觉醒横幅 → `POST /api/awaken` / 自动 tryComplete → 法则 + 指纹；此后才允许自动 **L4/L5**（L1–L3 可轻量跑）。  
2. **危机求存**：磁盘危机 → 任务/信念 → RuleProposer 采纳 material 规则 → 16 tick 后 feedback 显示改善或记失败。  
3. **危机中不炸编译**：`host_crisis` / phase=crisis 时 L4/L5 不 due；危机解除后恢复。  
4. **外界→进化上下文**：AutoCLI 条目进入记忆；随后 evolve/规则 prompt 含相关往事（daemon 已对齐）。  
5. **社会→进化**：人类 value 下滑触发规则；peer 信念进入 Reflection。  
6. **能力进化回哺求存**：L3/L4 采纳后，同等压力下任务完成更快或误报减少（可观测指标）。  
7. **稳态**：九宫达标 → `existence_phase=steady` → 进化降频；再危机 → crisis 相 + 求存优先。

**1、3、4(daemon)、7(相)** 已可演示；P1 验收面板 / 维度台账 / state 双写契约已落地。修改 UI 后需重启 ui_server 并硬刷新。

---

## 8. 修订记录

- 2026-07：初版 — 求存生命周期合理版 + 缺口。  
- 2026-07：融合修订 — 求存外环 × 进化内环；触发/守门/验收/危机锁；与九宫、L1–L5、RuleProposer 对齐。  
- 2026-07：P1 落地 — `evolution_acceptance` / `state_contract` / 任务维度台账；UI 进化验收面板。  
- 2026-07：P2 落地 — `host_profile`（手机推送）+ `peer_inbox` + Link `query_shortfall`/`share_shortfall`。  
- 2026-07：P2 加固 — daemon CrossLink 真 shortfall；`scripts/awakening_lifecycle_acceptance.sh`。
- 2026-07：P2c — peer-inbox UI/share API + RuleProposer digest；`scripts/peer_shortfall_link_acceptance.sh`。
