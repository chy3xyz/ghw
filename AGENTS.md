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
| L3 (状态序列化) | ✅ (stub) | StateSerializer |
| L4 (双进程迁移) | ✅ (骨架) | SelfMigration + SelfMigrateCLI |
| L4' (LLM 提议规则) | ✅ 新 | RuleProposer + SelfEvolutionGuard |
| L5 (自我写代码) | ✅ | SelfEncoder (规则合成 + 形式验证) |

---

## 4. 部署准则

- **零依赖**: 不允许在 `build.zig.zon` 加外部 dep
- **真实 LLM**: 通过 `HttpLLM.anthropic(model, api_key)` 或 `.openai(model, api_key, base_url)`
- **API key 绝不写死在源码里** — 用 env var (`--api-key-env`)
- **状态持久化**: L3 JSON, 路径可配
- **daemon 模式**: 长跑进程, `std.Io.Threaded` + `std.Io.File` 处理 I/O, 不要 `std.fs` (Zig 0.17 已废弃)
- **错误**: daemon 失败要 print 到 stderr (不静默 swallow), 退出码非 0

---

## 5. 已知限制 + TODO

- `compile_verifier.zig`: 真实 zig build subprocess 待接 std.Io.Threaded 的 spawn
- `state_serializer.zig`: writeToFile 是 stub (用 debug.print), 真实部署需 Io
- `self_migration.zig`: spawnSelfNewVersion 是 stub (返回 -1), 真实部署需 std.Io.Threaded
- `daemon.zig`: 状态恢复只读不写, 需要把 loaded JSON 实际应用回 agent.ed
- `boundaryguardian.acceptRejection` 是命名错误, 待清理
