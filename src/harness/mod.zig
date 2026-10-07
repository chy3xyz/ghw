//! Harness 层: 边界 - 资源 - 方法 + GSP 共生协议

pub const core = @import("core.zig");
pub const self_evolution = @import("self_evolution_guard.zig");
pub const self_evolver = @import("self_evolver.zig");
pub const self_encoder = @import("self_encoder.zig");
pub const rule_proposer = @import("rule_proposer.zig");
pub const autocli = @import("autocli.zig");
pub const world_collector = @import("world_collector.zig");
pub const world_sensor = @import("world_sensor.zig");
pub const world_bridge = @import("world_bridge.zig");
pub const survival_remedy = @import("survival_remedy.zig");
pub const survival_learn = @import("survival_learn.zig");
pub const survival_act = @import("survival_act.zig");
pub const survival_feedback = @import("survival_feedback.zig");
pub const metabolism = @import("metabolism.zig");
pub const peer_symbiosis = @import("peer_symbiosis.zig");
pub const primordial_laws = @import("primordial_laws.zig");
pub const awaken = @import("awaken.zig");
pub const host_shortfall = @import("host_shortfall.zig");
pub const host_profile = @import("host_profile.zig");
pub const peer_inbox = @import("peer_inbox.zig");
pub const existence_phase = @import("existence_phase.zig");
pub const state_contract = @import("state_contract.zig");
pub const evolution_acceptance = @import("evolution_acceptance.zig");
pub const system_collector = @import("system_collector.zig");
pub const world_context = @import("world_context.zig");
pub const goal_proposer = @import("goal_proposer.zig");
pub const memory = @import("memory.zig");
pub const reflection = @import("reflection.zig");
pub const personality = @import("personality.zig");
pub const code_generator = @import("code_generator.zig");
pub const llm_code_generator = @import("llm_code_generator.zig");
pub const human_symbiosis = @import("human_symbiosis/mod.zig");
pub const task_executor = @import("task_executor.zig");
pub const task_runner = @import("task_runner.zig");
pub const TaskRunner = task_runner;
pub const task_feedback = @import("task_feedback.zig");
pub const translator = @import("translator.zig");
pub const balance_seeker = @import("balance_seeker.zig");
pub const crm_kpi = @import("crm_kpi.zig");
pub const product_intent = @import("product_intent.zig");
pub const kpi_bridge = @import("kpi_bridge.zig");
pub const product_runtime = @import("product_runtime.zig");
pub const product_adapter = @import("product_adapter.zig");
pub const product_instance = @import("product_instance.zig");
pub const co_evolution = @import("co_evolution.zig");
pub const KpiBridge = kpi_bridge.KpiBridge;
pub const ProductEvolutionRuntime = product_runtime.ProductEvolutionRuntime;
pub const ProductAdapter = product_runtime.ProductAdapter;
pub const ProductInstanceIdentity = product_instance.ProductInstanceIdentity;
pub const CoEvolutionRegistry = co_evolution.CoEvolutionRegistry;
pub const FileConfigAdapter = product_adapter.FileConfigAdapter;
pub const ProductChangeKind = product_runtime.ProductChangeKind;
pub const ChangeStatus = product_runtime.ChangeStatus;
pub const ghw_link = @import("ghw_link.zig");
pub const ghw_link_tcp = @import("ghw_link_tcp.zig");
pub const wechat = @import("wechat/wechat.zig");
pub const compile_verifier = @import("compile_verifier.zig");
pub const state_serializer = @import("state_serializer.zig");
pub const template_enhancer = @import("template_enhancer.zig");
pub const self_migration = @import("self_migration.zig");
pub const self_migrate_cli = @import("self_migrate_cli.zig");
pub const config_loader = @import("config_loader.zig");
pub const llm = @import("llm/llm.zig");
pub const mock_llm = @import("llm/mock_llm.zig");
pub const shell_llm = @import("llm/shell_llm.zig");
pub const http_llm = @import("llm/http_llm.zig");
pub const mock_chat_llm = @import("llm/mock_chat_llm.zig");
pub const llm_driver = @import("llm_driver.zig");
pub const mock_provider = @import("mock_provider.zig");
pub const evolution_rationale = @import("evolution_rationale.zig");
pub const user_channel = @import("user_channel.zig");
pub const decision_bridge = @import("decision_bridge.zig");

pub const BoundaryGuardian = core.BoundaryGuardian;
pub const BoundaryLayer = core.BoundaryLayer;
pub const Action = core.Action;
pub const ActionKind = core.ActionKind;
pub const ActionOutcome = core.ActionOutcome;
pub const ResourceScheduler = core.ResourceScheduler;
pub const ResourceHardLimits = core.ResourceHardLimits;
pub const MethodLibrary = core.MethodLibrary;
pub const Method = core.Method;
pub const MethodKind = core.MethodKind;
pub const MethodFn = core.MethodFn;
pub const MethodEntry = core.MethodEntry;
pub const GSPNode = core.GSPNode;
pub const GSPNodeMeta = core.GSPNodeMeta;
pub const GSPSettlement = core.GSPSettlement;
pub const SymbiosisType = core.SymbiosisType;
pub const SymbiosisLedger = core.SymbiosisLedger;

// 自演化 (L1-L2)
pub const SelfEvolutionGuard = self_evolution.SelfEvolutionGuard;
pub const ReviewVerdict = self_evolution.ReviewVerdict;
pub const DEFAULT_WHITELIST = self_evolution.DEFAULT_WHITELIST;
pub const DEFAULT_FORBIDDEN_SYMBOLS = self_evolution.DEFAULT_FORBIDDEN_SYMBOLS;

pub const CodeGenerator = code_generator.CodeGenerator;
pub const StaticCodeGenerator = code_generator.StaticCodeGenerator;
pub const LlmCodeGenerator = llm_code_generator.LlmCodeGenerator;
pub const GenerationRequest = code_generator.GenerationRequest;
pub const GenerationResult = code_generator.GenerationResult;
pub const GenerationKind = code_generator.GenerationKind;

pub const SelfEvolver = self_evolver.SelfEvolver;
pub const EvolveContext = self_evolver.EvolveContext;
pub const EvolutionEvent = self_evolver.EvolutionEvent;
pub const EvolutionOutcome = self_evolver.EvolutionOutcome;

// 真正的自编码 (不是 LLM 调, 是元编程 + 规则推导)
pub const SelfEncoder = self_encoder.SelfEncoder;
pub const Intent = self_encoder.Intent;
pub const EncodedCode = self_encoder.EncodedCode;
pub const CodeRef = self_encoder.CodeRef;
pub const Verification = self_encoder.Verification;
pub const Rule = self_encoder.Rule;
pub const CodeKnowledge = self_encoder.CodeKnowledge;

// LLM 桥 (L3)
pub const LLM = llm.LLM;
pub const LLMRequest = llm.LLMRequest;
pub const LLMResponse = llm.LLMResponse;
pub const MockLLM = mock_llm.MockLLM;
pub const ShellLLM = shell_llm.ShellLLM;

// L4: 编译 + 状态 + 迁移
pub const CompileVerifier = compile_verifier.CompileVerifier;
pub const VerifyRequest = compile_verifier.VerifyRequest;
pub const VerifyResult = compile_verifier.VerifyResult;

// 自我完善: LLM 基于自我叙事 + 当前期望, 完善已有 L1-L5 模板
pub const TemplateEnhancer = template_enhancer.TemplateEnhancer;
pub const EnhanceContext = template_enhancer.EnhanceContext;
pub const EnhanceResult = template_enhancer.EnhanceResult;

pub const StateSerializer = state_serializer.StateSerializer;
pub const StateSnapshot = state_serializer.StateSnapshot;
pub const SerializedGoal = state_serializer.SerializedGoal;
pub const ParsedMinimal = state_serializer.ParsedMinimal;
pub const SelfMigration = self_migration.SelfMigration;
pub const MigrationConfig = self_migration.MigrationConfig;
pub const MigrationResult = self_migration.MigrationResult;
pub const MigrationStep = self_migration.MigrationStep;
pub const LLMKind = self_migration.LLMKind;

pub const detectMigrateFromArg = self_migrate_cli.detectMigrateFromArg;
pub const handleMigrateFromArg = self_migrate_cli.handleMigrateFromArg;

pub const ConfigLoader = config_loader.ConfigLoader;
pub const GuardConfig = config_loader.GuardConfig;

// Loop Engineering 协调器 (Boris Cherny 2025-11 "My job is to write loops")
pub const loop_engine = @import("loop_engine.zig");
pub const HarnessLoopEngine = loop_engine.HarnessLoopEngine;
pub const LoopConfig = loop_engine.LoopConfig;
pub const LoopKPI = loop_engine.LoopKPI;
pub const LoopAct = loop_engine.LoopAct;
pub const Hypothesis = loop_engine.Hypothesis;
pub const HypothesisStatus = loop_engine.HypothesisStatus;
pub const HypothesisSource = loop_engine.HypothesisSource;

pub const agent_tick_guard = @import("agent_tick_guard.zig");
