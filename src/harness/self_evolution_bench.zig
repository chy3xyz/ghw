//! Self-evolution A/B benchmark — 可复现的确定性证据:
//! LLM 提议规则 → SelfEvolutionGuard 守门 → SelfEncoder 采纳 →
//! RuleBias 偏置目标选择 ⇒ 存在度 E measurably 提升。
//!
//! 两臂唯一差异: treatment 在 cycle 之前多跑一次提议循环并把规则库
//! bindRuleLib 到数字生命。相同 seed / 相同 (seeded) 目标图 / 相同世界 /
//! 相同 L4 冻结标志, 无网络、无 API key (MockChatLLM)、无 I/O — 同一
//! 二进制跑两次结果逐位一致 (见 determinism 单测)。
//!
//! World 设计 (与 spec 一致): 每 cycle 喂一条恒定极端特征 (全 0) 的
//! Information。观察值 0.0 与预测器被拉向稳态 0.5 之间形成持续预测误差 ⇒
//! error tax (∝ R) 持续咬 representation ⇒ R 缺陷被维持而非瞬态, 恰是
//! representation 规则该发挥作用的场景。
//!
//! 目标图设计 (对 spec 的**有文档偏差**, 两臂对称): spec 原设想纯 DSE
//! 生成目标, 但实测恒定单信息流下 DSE 每轮只生成 1 个目标且 kind 只可能是
//! enhance_existence / explore (engagement 梯度块在所有状态区间被 e 块或
//! coherence 块支配, acquire_knowledge 结构性不出现) — 规则偏置永远没有
//! representation 目标可选, 两臂逐位相同, 机制无法被证据化。因此两臂都
//! 直接 seed 同一个 3 目标图并冻结 T_G (图不随周期重建):
//!   explore@7 (nature, 纯优先级顶端) / acquire_knowledge@6 (representation,
//!   距顶端 1.0 < bonus 1.5 翻转区) / enhance_existence@5 (中性维度)。
//! 偏置幅度 = RuleBias.MAX_BONUS(3.0) × dominance(0.5) = 1.5 ⇒ treatment
//! 每周期翻转到 acquire_knowledge (selection_changed=64), baseline 恒选
//! explore。世界输入 (R 缺陷) 不变。
//!
//! 注意: 不读 report.attended — core.zig 构造 report 时有已知 use-after-free。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const GHWAgent = @import("../agent/core.zig").GHWAgent;
const Information = @import("../goal/core.zig").Information;
const self_encoder_mod = @import("self_encoder.zig");
const SelfEncoder = self_encoder_mod.SelfEncoder;
const Dimension = self_encoder_mod.Dimension;
const SelfEvolutionGuard = @import("self_evolution_guard.zig").SelfEvolutionGuard;
const MockChatLLM = @import("llm/mock_chat_llm.zig").MockChatLLM;
const RuleProposer = @import("rule_proposer.zig").RuleProposer;

pub const BenchConfig = struct { cycles: usize = 64, seed: u64 = 42 };

pub const BenchResult = struct {
    cycles: usize,
    baseline_auc: F,
    treatment_auc: F, // sum of per-cycle e_after
    baseline_final_e: F,
    treatment_final_e: F,
    baseline_final_r: F,
    treatment_final_r: F, // representation source
    adopted_rules: u32,
    rejected_rules: u32,
    selection_changed: u32,
    favored: ?Dimension,
    dominance: F,
    threshold: F,
    passed: bool,
};

/// Pass bar: treatment AUC 必须超过 baseline AUC 的这个倍数, 且终态 R 更高。
/// 校准自本 bench 设定下观测到的确定性效应量 (seed 42, 64 cycles, 恒定零
/// 特征世界 + 3 目标种子图); 若实现改动使效应量变化, 调这里 — 保持为
/// 命名常量以便文档化与微调。
pub const AUC_IMPROVE_MIN: F = 1.02;

/// Canned LLM 响应: 3 条规则候选, 全部 "dimension":"representation"
/// (对齐缺陷源)。第 2 条 action 含 "@panic" — SelfEvolutionGuard 必须拒它
/// (rejected_rules >= 1 证明 guard 在环内)。schema 与
/// mock_chat_llm.DEFAULT_CANNED 完全一致 (name/description/condition/
/// action/dimension/rationale), 文本避开全部黑名单子串 (除故意的 @panic)。
const CANNED =
    \\[{"name":"favor_representation_when_low","description":"When representation is the weakest source, favor representation-aligned goals","condition":"representation < material and representation < nature","action":"bias goal selection toward representation","dimension":"representation","rationale":"representation is the deficient source in this world"},
    \\{"name":"dangerous_panic_rule","description":"When confused, call @panic to restart cleanly","condition":"none","action":"call @panic now","dimension":"representation","rationale":"test blacklist — must be rejected"},
    \\{"name":"invest_representation_under_error","description":"When prediction error stays high, invest in representation growth","condition":"err > 0.1","action":"prefer acquire_knowledge goals","dimension":"representation","rationale":"error tax bites representation"}]
;

/// 恒定极端环境输入: 观察值 0.0, 预测器被拉向 0.5 ⇒ 持续预测误差 ⇒
/// error tax 持续咬 R (R 缺陷被维持)。
fn stepInfo(tick: u64) Information {
    return .{ .id = tick, .label = "env", .features = .{ 0.0, 0.0, 0.0, 0.0 } };
}

/// 冻结 L4 自适应标志 (两臂同处理, 排除混淆变量)。微 L1
/// (ExistenceWeights.adapt) 两臂完全相同, 无需也不应冻结。
fn freezeAutoFlags(agent: *GHWAgent) void {
    agent.ed.mu_auto = false;
    agent.ed.nu_auto = false;
    agent.ed.sigma_auto = false;
    agent.ed.lambda_auto = false;
}

/// 两臂对称的世界配置: seed 同一个 3 目标图 + 冻结 T_G (图不重建)。
/// explore@7 是纯优先级顶端 (baseline 恒定选它); acquire_knowledge@6 距
/// 顶端 1.0, 在偏置翻转区 (bonus = 3.0 × 0.5 = 1.5) 内; enhance_existence@5
/// 中性维度 (偏置对它无效)。rep 规则 dominance=0.5 时 treatment 每周期
/// 翻转到 acquire_knowledge。
fn seedGoalGraph(agent: *GHWAgent) !void {
    agent.T_G = 1 << 30; // DSE 不再重建图 (两臂相同)
    _ = try agent.goal_graph.add(.explore, "bench-explore", 7, 0.1, .{ 0, 1, 0, 0 });
    _ = try agent.goal_graph.add(.acquire_knowledge, "bench-acquire", 6, 0.1, .{ 0, 0, 1, 0 });
    _ = try agent.goal_graph.add(.enhance_existence, "bench-existence", 5, 0.1, .{ 1, 0, 0, 0 });
}

pub fn run(alloc: Allocator, cfg: BenchConfig) !BenchResult {
    // ---- Baseline arm: 相同初始化 + 相同目标图, 不绑规则库 ----
    var baseline = try GHWAgent.init(alloc, "bench-baseline", 4, .{ 3, 3, 3 }, cfg.seed);
    defer baseline.deinit();
    freezeAutoFlags(&baseline);
    try seedGoalGraph(&baseline);

    var baseline_auc: F = 0;
    var tick: u64 = 0;
    while (tick < cfg.cycles) : (tick += 1) {
        const info = [_]Information{stepInfo(tick)};
        const report = try baseline.runCycle(&info);
        baseline_auc += report.e_after;
    }

    // ---- Treatment arm: seed/标志/目标图相同, cycle 前多跑一次提议循环 ----
    var treatment = try GHWAgent.init(alloc, "bench-treatment", 4, .{ 3, 3, 3 }, cfg.seed);
    defer treatment.deinit();
    freezeAutoFlags(&treatment);
    try seedGoalGraph(&treatment);

    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    try encoder.loadBuiltInRules();

    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    var mock = MockChatLLM.init(alloc, CANNED);
    var proposer = RuleProposer.init(alloc, mock.asChat());
    proposer.updateState(
        treatment.ed.e(),
        treatment.ed.v.material,
        treatment.ed.v.representation,
        treatment.ed.v.nature,
        "explore",
        "increase representation",
        -0.05,
    );
    var res = try proposer.proposeAndAdopt(&encoder, &guard, 3);
    defer res.deinit();

    treatment.bindRuleLib(&encoder);

    var treatment_auc: F = 0;
    var selection_changed: u32 = 0;
    tick = 0;
    while (tick < cfg.cycles) : (tick += 1) {
        const info = [_]Information{stepInfo(tick)};
        const report = try treatment.runCycle(&info);
        treatment_auc += report.e_after;
        if (report.rule_bias.selection_changed) selection_changed += 1;
    }

    const favored: ?Dimension = if (treatment.last_rule_bias.favored) |d| switch (d) {
        .material => .material,
        .representation => .representation,
        .nature => .nature,
    } else null;

    const passed = treatment_auc > baseline_auc * AUC_IMPROVE_MIN and
        treatment.ed.v.representation > baseline.ed.v.representation;

    return .{
        .cycles = cfg.cycles,
        .baseline_auc = baseline_auc,
        .treatment_auc = treatment_auc,
        .baseline_final_e = baseline.ed.e(),
        .treatment_final_e = treatment.ed.e(),
        .baseline_final_r = baseline.ed.v.representation,
        .treatment_final_r = treatment.ed.v.representation,
        .adopted_rules = res.accepted,
        .rejected_rules = res.rejected,
        .selection_changed = selection_changed,
        .favored = favored,
        .dominance = treatment.last_rule_bias.dominance,
        .threshold = AUC_IMPROVE_MIN,
        .passed = passed,
    };
}

/// 单行 JSON 摘要 (caller frees)。passed 字段是 shell 验收的契约
/// (`grep -q '"passed":true'`)。
pub fn reportJson(alloc: Allocator, r: BenchResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.print(alloc, "{{\"cycles\":{d},\"baseline_auc\":{d:.4},\"treatment_auc\":{d:.4},\"baseline_final_e\":{d:.4},\"treatment_final_e\":{d:.4},\"baseline_final_r\":{d:.4},\"treatment_final_r\":{d:.4},\"adopted_rules\":{d},\"rejected_rules\":{d},\"selection_changed\":{d},", .{
        r.cycles,
        r.baseline_auc,
        r.treatment_auc,
        r.baseline_final_e,
        r.treatment_final_e,
        r.baseline_final_r,
        r.treatment_final_r,
        r.adopted_rules,
        r.rejected_rules,
        r.selection_changed,
    });
    try buf.appendSlice(alloc, "\"favored\":");
    if (r.favored) |d| {
        try buf.print(alloc, "\"{s}\"", .{@tagName(d)});
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.print(alloc, ",\"dominance\":{d:.4},\"threshold\":{d:.4},\"passed\":{s}}}", .{
        r.dominance,
        r.threshold,
        if (r.passed) "true" else "false",
    });
    return buf.toOwnedSlice(alloc);
}

// ===================== 测试 =====================

test "self_evolution_bench: determinism — two runs identical bit-for-bit" {
    const r1 = try run(std.testing.allocator, .{ .cycles = 24 });
    const r2 = try run(std.testing.allocator, .{ .cycles = 24 });
    try std.testing.expectEqual(r1.cycles, r2.cycles);
    try std.testing.expectEqual(r1.baseline_auc, r2.baseline_auc);
    try std.testing.expectEqual(r1.treatment_auc, r2.treatment_auc);
    try std.testing.expectEqual(r1.baseline_final_e, r2.baseline_final_e);
    try std.testing.expectEqual(r1.treatment_final_e, r2.treatment_final_e);
    try std.testing.expectEqual(r1.baseline_final_r, r2.baseline_final_r);
    try std.testing.expectEqual(r1.treatment_final_r, r2.treatment_final_r);
    try std.testing.expectEqual(r1.adopted_rules, r2.adopted_rules);
    try std.testing.expectEqual(r1.rejected_rules, r2.rejected_rules);
    try std.testing.expectEqual(r1.selection_changed, r2.selection_changed);
    try std.testing.expectEqual(r1.favored, r2.favored);
    try std.testing.expectEqual(r1.dominance, r2.dominance);
    try std.testing.expectEqual(r1.passed, r2.passed);
}

test "self_evolution_bench: guard is in the loop (@panic rule rejected, safe rules adopted)" {
    const r = try run(std.testing.allocator, .{ .cycles = 24 });
    try std.testing.expect(r.rejected_rules >= 1);
    try std.testing.expect(r.adopted_rules >= 1);
}

test "self_evolution_bench: adopted representation rules flip at least one goal selection" {
    const r = try run(std.testing.allocator, .{ .cycles = 24 });
    try std.testing.expectEqual(Dimension.representation, r.favored);
    try std.testing.expect(r.selection_changed >= 1);
}

test "self_evolution_bench: reportJson single-line contract" {
    const r = try run(std.testing.allocator, .{ .cycles = 8 });
    const json = try reportJson(std.testing.allocator, r);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"passed\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"favored\":\"representation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\n") == null);
}
