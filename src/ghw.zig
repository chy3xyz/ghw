//! GHW — Goal-Harness-World 数字生命范式 (Zig 0.17 dev 实现)
//!
//! 公共 API 根模块,聚合 World / Goal / Harness / Agent 四层。
//! 所有依赖零外部 crate,仅使用 Zig 标准库。
//!
//! ## 架构
//!  - `world`  物象性三源合恰 (Existence Degree M/R/N + 三源合恰张量 + 世界模型)
//!  - `goal`   注目 (Attention) → 察觉 (Detection) → 差集 (Difference Set)
//!  - `harness` 边界守护者 (Boundary) + 资源调度 (Resource) + 方法库 (Method)
//!  - `agent`  三时间尺度主循环 (Existential-Degree-Update-Loop)
//!  - `util`   通用数学工具 (张量运算、统计、随机)
//!
//! 关键设计:
//!   1. 存在度 E = αM + βR + γN
//!   2. 三源合恰张量 W ∈ R^{d_P × d_S × d_E}
//!   3. 差异张量 Δ ∈ R^{d_G × 4 × d_W}
//!   4. 三时间尺度:  η_H (反应) > η_W (适应) > η_G (反思)

pub const world = @import("world/mod.zig");
pub const goal = @import("goal/mod.zig");
pub const harness = @import("harness/mod.zig");
pub const agent = @import("agent/mod.zig");
pub const util = @import("util/mod.zig");
/// 新增: WASM 沙箱 + SQLite 记忆库 (v1)
pub const sandbox = @import("sandbox/mod.zig");

// === 核心类型再导出 ===
pub const ExistenceDegree = world.ExistenceDegree;
pub const ExistenceVector = world.ExistenceVector;
pub const CoappropriationTensor = world.CoappropriationTensor;
pub const WorldModel = world.WorldModel;
pub const ExistenceWeights = world.ExistenceWeights;

pub const AttentionEngine = goal.AttentionEngine;
pub const AttentionParams = goal.AttentionParams;
pub const AttentionResult = goal.AttentionResult;
pub const PerceptionEngine = goal.PerceptionEngine;
pub const DifferenceTensor = goal.DifferenceTensor;
pub const ExistenceGap = goal.ExistenceGap;
pub const DifferenceSetEngine = goal.DifferenceSetEngine;
pub const Goal = goal.Goal;
pub const GoalGraph = goal.GoalGraph;
pub const GoalKind = goal.GoalKind;

pub const BoundaryGuardian = harness.BoundaryGuardian;
pub const BoundaryLayer = harness.BoundaryLayer;
pub const Action = harness.Action;
pub const ActionKind = harness.ActionKind;
pub const ActionOutcome = harness.ActionOutcome;
pub const ResourceScheduler = harness.ResourceScheduler;
pub const MethodLibrary = harness.MethodLibrary;
pub const MethodKind = harness.MethodKind;

// 自演化 (L1-L4 自我升级)
pub const SelfEvolutionGuard = harness.SelfEvolutionGuard;
pub const ReviewVerdict = harness.ReviewVerdict;
pub const CodeGenerator = harness.CodeGenerator;
pub const StaticCodeGenerator = harness.StaticCodeGenerator;
pub const GenerationRequest = harness.GenerationRequest;
pub const GenerationResult = harness.GenerationResult;
pub const GenerationKind = harness.GenerationKind;
pub const SelfEvolver = harness.SelfEvolver;
pub const EvolutionEvent = harness.EvolutionEvent;
pub const EvolutionOutcome = harness.EvolutionOutcome;

// 真正的自编码 (元编程, 不是 LLM 调)
pub const SelfEncoder = harness.SelfEncoder;
pub const Intent = harness.Intent;
pub const EncodedCode = harness.EncodedCode;
pub const CodeRef = harness.CodeRef;
pub const Verification = harness.Verification;

// L3 LLM 桥
pub const LLM = harness.LLM;
pub const LLMRequest = harness.LLMRequest;
pub const LLMResponse = harness.LLMResponse;
pub const MockLLM = harness.MockLLM;
pub const ShellLLM = harness.ShellLLM;

// L4 编译 + 状态 + 迁移
pub const CompileVerifier = harness.CompileVerifier;
pub const VerifyRequest = harness.VerifyRequest;
pub const VerifyResult = harness.VerifyResult;
pub const StateSerializer = harness.StateSerializer;
pub const StateSnapshot = harness.StateSnapshot;
pub const SerializedGoal = harness.SerializedGoal;
pub const ParsedMinimal = harness.ParsedMinimal;
pub const SelfMigration = harness.SelfMigration;
pub const MigrationConfig = harness.MigrationConfig;
pub const MigrationResult = harness.MigrationResult;
pub const MigrationStep = harness.MigrationStep;
pub const LLMKind = harness.LLMKind;

// 双进程协议 + 配置热加载
pub const detectMigrateFromArg = harness.detectMigrateFromArg;
pub const handleMigrateFromArg = harness.handleMigrateFromArg;
pub const ConfigLoader = harness.ConfigLoader;
pub const GuardConfig = harness.GuardConfig;

pub const GSPNode = harness.GSPNode;
pub const SymbiosisLedger = harness.SymbiosisLedger;

pub const GHWAgent = agent.GHWAgent;
pub const CycleReport = agent.CycleReport;
pub const ReflectionTrigger = agent.ReflectionTrigger;

pub const Information = goal.Information;

/// Sandbox (WASM + SQLite) 公共类型
pub const SqliteDb = sandbox.sqlite_db.SqliteDb;

// 引用所有子模块以便它们的测试被发现
comptime {
    _ = world;
    _ = world.coappropriation;
    _ = goal;
    _ = harness;
    _ = agent;
    _ = util;
    // 显式引用 LLM 子模块 (它们在 harness 之下)
    _ = harness.llm;
    _ = harness.mock_llm;
    _ = harness.shell_llm;
    _ = harness.http_llm;
    _ = harness.mock_chat_llm;
    _ = harness.human_symbiosis;
    _ = harness.human_symbiosis.human_signal;
    _ = harness.human_symbiosis.task_queue;
    _ = harness.human_symbiosis.human_gsp;
    _ = harness.human_symbiosis.human_signal;
    _ = harness.task_feedback;
    _ = harness.human_symbiosis.value_metric;
    _ = harness.human_symbiosis.chat_task;
    _ = harness.translator;
    _ = harness.balance_seeker;
    _ = harness.wechat;
    _ = harness.wechat.crypto;
    _ = harness.wechat.types;
    _ = harness.compile_verifier;
    _ = harness.state_serializer;
    _ = harness.self_migration;
    _ = harness.self_migrate_cli;
    _ = harness.config_loader;
    _ = @import("harness/chaos_test.zig");
    _ = harness.self_evolution;
    _ = harness.self_encoder;
    _ = harness.rule_proposer;
    _ = harness.world_collector;
    _ = harness.world_sensor;
    _ = harness.world_bridge;
    _ = harness.survival_remedy;
    _ = harness.survival_learn;
    _ = harness.survival_act;
    _ = harness.metabolism;
    _ = harness.peer_symbiosis;
    _ = harness.survival_feedback;
    _ = harness.primordial_laws;
    _ = harness.awaken;
    _ = harness.host_shortfall;
    _ = harness.host_profile;
    _ = harness.peer_inbox;
    _ = harness.existence_phase;
    _ = harness.state_contract;
    _ = harness.evolution_acceptance;
    _ = harness.task_executor;
    _ = harness.crm_kpi;
    _ = harness.product_intent;
    _ = harness.kpi_bridge;
    _ = harness.product_runtime;
}

// 注意: test {} 块在每个子模块自身内部,这样可以保持测试代码本地化
// Zig 编译器会自动发现所有子模块中的 test 块
test "ghw module references" {
    // 触发编译期引用
    _ = world.ExistenceDegree;
    _ = goal.AttentionEngine;
    _ = harness.BoundaryGuardian;
    _ = agent.GHWAgent;
    _ = util.math.shannonEntropy;
    // 触发 auto_eps registry (L3 L4 L5 落盘文件) 编译进 libghw.a
    _ = auto_eps;
}

/// 数字生命"自己写"的代码 (L3 L4 L5 落盘 + adopt 进 ghw 源码)
/// registry.zig 自动 @import 全部落盘文件, build 时编进 libghw.a
pub const auto_eps = @import("harness/auto_eps/registry.zig");
