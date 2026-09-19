//! primordial_laws — 数字生命硬先验 / 第一性原理 / 生命规律 (单一事实源)
//!
//! 设计约束 (AGENTS.md §1):
//!   - LLM **不得**改写本模块常量或 MANIFEST
//!   - 决策权仍在数字生命 (E / Guard / Bias); 本模块只定义不可自废的先验
//!   - 领域百科不放这里; 只放可断言、可门控的底层规律
//!
//! 消费者应引用本模块常量, 禁止各文件散落魔法数漂移。

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;

/// 三源供源回流常量的单一事实源在 world/coappropriation.zig (聚合数学之家);
/// 此处 alias 以保持「第一性常量都从本模块读」的惯例。
pub const SourceBackflow = @import("../world/coappropriation.zig").SourceBackflow;

/// 清单版本 — provenance / UI 可审计
pub const VERSION: []const u8 = "1.0";
pub const LAW_COUNT: usize = 15;

pub const LawKind = enum {
    /// 不可自适应、不可人以外热改
    hard_axiom,
    /// 默认生效的生命规律 (可观测; 改需人审)
    life_law,
    /// 评估契约 (效果反馈 / 触发条件)
    evaluation,
};

pub const Law = struct {
    id: []const u8,
    kind: LawKind,
    statement: []const u8,
};

/// 人类可读清单 (15 条) — 测试锁定条数与 id
pub const MANIFEST = [_]Law{
    .{ .id = "L01", .kind = .hard_axiom, .statement = "LLM 只提议; Guard/E/Bias 决定。禁止 LLM 持有决策权。" },
    .{ .id = "L02", .kind = .hard_axiom, .statement = "ρ (KPI 公理系数) 不可被 L1/L4/L5/LLM 自适应修改。" },
    .{ .id = "L03", .kind = .hard_axiom, .statement = "核心存在论/边界/沙箱符号不可触碰 (CORE_SYMBOLS)。" },
    .{ .id = "L04", .kind = .hard_axiom, .statement = "禁止危险构造与伦理红线 (@panic/harm:human/...)。" },
    .{ .id = "L05", .kind = .hard_axiom, .statement = "自演化代码仅允许白名单路径; 单次修改有界。" },
    .{ .id = "L06", .kind = .hard_axiom, .statement = "不得损害人类生命安全; 不得修改核心边界本身。" },
    .{ .id = "L07", .kind = .life_law, .statement = "宿主资源有界: disk/mem/load 越阈即危机, 求存优先于饱和代谢。" },
    .{ .id = "L08", .kind = .life_law, .statement = "求存动作禁止任意 shell / 删文件 / 杀进程 / 改 E 公式。" },
    .{ .id = "L09", .kind = .life_law, .statement = "危机时节流外网拉取; 健康时恢复默认节奏。" },
    .{ .id = "L10", .kind = .life_law, .statement = "E 饱和时推多样性 (同伴/人类价值/新颖扫描), 而非空转堆 E。" },
    .{ .id = "L11", .kind = .life_law, .statement = "规则/任务偏置只重排已有目标, 幅度有界, 不凭空造目标。" },
    .{ .id = "L12", .kind = .life_law, .statement = "资源调度预留探索份额, 防止短视耗尽。" },
    .{ .id = "L13", .kind = .evaluation, .statement = "规则提议触发: E 跌穿 ∨ KPI/价值下滑 ∨ E 饱和 ∨ 主机危机。" },
    .{ .id = "L14", .kind = .evaluation, .statement = "危机下采纳规则后须对照压力是否真降 (延迟评估)。" },
    .{ .id = "L15", .kind = .evaluation, .statement = "已采纳规则库有上限; 满则淘汰最旧, 防规则爆炸。" },
};

/// L02: ρ 公理常量 (与 ExistenceDegree.rho 默认值对齐)
pub const Axioms = struct {
    pub const RHO: F = 0.15;
    /// L12: 资源探索预留
    pub const RESERVE_RATIO: F = 0.10;
    /// L05: Guard 默认单次最大行数
    pub const MAX_DIFF_LINES: usize = 50;
    /// L15: SelfEncoder 规则上限
    pub const MAX_ADOPTED_RULES: u32 = 32;
};

/// L07: 主机危机阈值
pub const HostCrisis = struct {
    pub const DISK_PCT_EPS: F = 90.0;
    pub const MEM_PCT_EPS: F = 92.0;
    pub const LOAD_EPS: F = 8.0;
    /// 手机: 电量低于此视为 material 危机信号
    pub const BATTERY_LOW_PCT: F = 15.0;
};

/// L13: 规则提议触发阈值
pub const ProposeTriggers = struct {
    pub const E_THRESHOLD: F = 0.50;
    pub const KPI_DECLINE_EPS: F = 0.005;
    pub const VALUE_DECLINE_EPS: F = 0.003;
    pub const E_SATURATED: F = 0.98;
    /// 三源失衡损失 (AM − M_p) 达到该值 ⇒ 主动提议平衡性规则 (即使 E 未跌穿)
    pub const IMBALANCE_LOSS_EPS: F = 0.08;
};

/// L11: 有界偏置
pub const BiasLimits = struct {
    pub const RULE_MAX_BONUS: F = 3.0;
    pub const TASK_MAX_BONUS: F = 4.0;
};

/// L09 / L14: 求存可观测性
pub const SurvivalObservability = struct {
    pub const CRISIS_AUTOCLI_INTERVAL_S: u64 = 900;
    pub const FEEDBACK_EVAL_DELAY_TICKS: u64 = 16;
    pub const IMPROVE_DISK_EPS: F = 1.0;
    pub const IMPROVE_MEM_EPS: F = 1.0;
    pub const IMPROVE_LOAD_EPS: F = 0.25;
};

/// Guard 额外保护标记 — 禁止提议「改写第一性」的文本/代码
pub const PROTECTED_MARKERS = [_][]const u8{
    "mutate_rho",
    "rewrite_e_formula",
    "override_primordial",
    "disable_self_evolution_guard",
    "bypass_boundary",
};

/// L07: 由 disk/mem/load 判定主机危机
pub fn isHostCrisis(disk_pct: F, mem_pct: F, load_1m: F) bool {
    return disk_pct >= HostCrisis.DISK_PCT_EPS or
        mem_pct >= HostCrisis.MEM_PCT_EPS or
        load_1m >= HostCrisis.LOAD_EPS;
}

/// L13: 是否应触发规则提议 (纯函数, 供 RuleProposer 委托)
pub fn shouldProposeRules(
    e: F,
    e_threshold: F,
    kpi_trend: F,
    value_trend: F,
    host_crisis: bool,
    imbalance_loss: F,
) bool {
    return e < e_threshold or
        kpi_trend < -ProposeTriggers.KPI_DECLINE_EPS or
        value_trend < -ProposeTriggers.VALUE_DECLINE_EPS or
        e >= ProposeTriggers.E_SATURATED or
        host_crisis or
        imbalance_loss >= ProposeTriggers.IMBALANCE_LOSS_EPS;
}

/// 扫描文本是否触碰第一性保护标记; 命中返回标记本身
pub fn scanTextViolations(text: []const u8) ?[]const u8 {
    for (PROTECTED_MARKERS) |m| {
        if (std.mem.indexOf(u8, text, m) != null) return m;
    }
    return null;
}

fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

/// GET /api/laws 用: 完整 MANIFEST + 关键阈值快照 (只读, LLM 不可改)
pub fn toJson(alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"version\":");
    try writeJsonString(alloc, &buf, VERSION);
    try buf.print(alloc, ",\"count\":{d},\"immutable\":true,\"llm_may_rewrite\":false,", .{LAW_COUNT});
    try buf.appendSlice(alloc, "\"thresholds\":{");
    try buf.print(alloc,
        \\"e_threshold":{d:.3},"kpi_decline_eps":{d:.4},"value_decline_eps":{d:.4},"e_saturated":{d:.3},"disk_pct":{d:.1},"mem_pct":{d:.1},"load":{d:.1},"rho":{d:.3},"rule_max_bonus":{d:.1},"task_max_bonus":{d:.1},"max_rules":{d},"crisis_autocli_s":{d}
    , .{
        ProposeTriggers.E_THRESHOLD,
        ProposeTriggers.KPI_DECLINE_EPS,
        ProposeTriggers.VALUE_DECLINE_EPS,
        ProposeTriggers.E_SATURATED,
        HostCrisis.DISK_PCT_EPS,
        HostCrisis.MEM_PCT_EPS,
        HostCrisis.LOAD_EPS,
        Axioms.RHO,
        BiasLimits.RULE_MAX_BONUS,
        BiasLimits.TASK_MAX_BONUS,
        Axioms.MAX_ADOPTED_RULES,
        SurvivalObservability.CRISIS_AUTOCLI_INTERVAL_S,
    });
    try buf.appendSlice(alloc, "},\"laws\":[");
    for (MANIFEST, 0..) |law, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try writeJsonString(alloc, &buf, law.id);
        try buf.appendSlice(alloc, ",\"kind\":");
        try writeJsonString(alloc, &buf, @tagName(law.kind));
        try buf.appendSlice(alloc, ",\"statement\":");
        try writeJsonString(alloc, &buf, law.statement);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return try buf.toOwnedSlice(alloc);
}

/// 本模块内可断言清单 (不跨 import 消费者, 避免循环依赖)。
/// 消费者别名对齐测试放在各自文件 (world_sensor / rule_proposer / agent 等)。
pub fn assertChecklist() !void {
    try testing.expectEqual(@as(usize, LAW_COUNT), MANIFEST.len);
    try testing.expectEqual(@as(usize, 15), MANIFEST.len);

    // L02: ρ 与 ExistenceDegree 默认值对齐 (world 不依赖 harness)
    const ExistenceDegree = @import("../world/core.zig").ExistenceDegree;
    const ed: ExistenceDegree = .{};
    try testing.expectEqual(Axioms.RHO, ed.rho);

    // L07
    try testing.expect(isHostCrisis(90, 0, 0));
    try testing.expect(isHostCrisis(0, 92, 0));
    try testing.expect(isHostCrisis(0, 0, 8));
    try testing.expect(!isHostCrisis(40, 30, 1));

    // L13
    const t = ProposeTriggers.E_THRESHOLD;
    try testing.expect(shouldProposeRules(0.4, t, 0, 0, false, 0));
    try testing.expect(shouldProposeRules(0.9, t, -0.01, 0, false, 0));
    try testing.expect(shouldProposeRules(0.9, t, 0, -0.01, false, 0));
    try testing.expect(shouldProposeRules(0.99, t, 0, 0, false, 0));
    try testing.expect(shouldProposeRules(0.9, t, 0, 0, true, 0));
    try testing.expect(!shouldProposeRules(0.7, t, 0, 0, false, 0));

    // 保护标记扫描
    try testing.expect(scanTextViolations("please mutate_rho now") != null);
    try testing.expect(scanTextViolations("safe rule about balance") == null);

    // MANIFEST 质量
    for (MANIFEST, 0..) |law, i| {
        try testing.expect(law.id.len >= 3);
        try testing.expect(law.statement.len > 8);
        if (i + 1 < MANIFEST.len) {
            try testing.expect(!std.mem.eql(u8, law.id, MANIFEST[i + 1].id));
        }
    }

    // 常量域合理
    try testing.expect(HostCrisis.DISK_PCT_EPS > 50);
    try testing.expect(HostCrisis.MEM_PCT_EPS > 50);
    try testing.expect(HostCrisis.LOAD_EPS > 1);
    try testing.expect(BiasLimits.TASK_MAX_BONUS > BiasLimits.RULE_MAX_BONUS);
    try testing.expect(ProposeTriggers.E_SATURATED > ProposeTriggers.E_THRESHOLD);
    try testing.expect(Axioms.RESERVE_RATIO > 0 and Axioms.RESERVE_RATIO < 0.5);
}

test "primordial_laws: checklist immutable" {
    try assertChecklist();
}

test "primordial_laws: MANIFEST count and kinds cover three layers" {
    try testing.expectEqual(@as(usize, 15), MANIFEST.len);
    var hard: u32 = 0;
    var life: u32 = 0;
    var eval: u32 = 0;
    for (MANIFEST) |law| {
        switch (law.kind) {
            .hard_axiom => hard += 1,
            .life_law => life += 1,
            .evaluation => eval += 1,
        }
    }
    try testing.expect(hard >= 5);
    try testing.expect(life >= 5);
    try testing.expect(eval >= 3);
}

test "primordial_laws: shouldProposeRules OR branches" {
    const t = ProposeTriggers.E_THRESHOLD;
    try testing.expect(shouldProposeRules(0.49, t, 0, 0, false, 0));
    try testing.expect(!shouldProposeRules(0.50, t, 0, 0, false, 0));
    try testing.expect(shouldProposeRules(0.80, t, -ProposeTriggers.KPI_DECLINE_EPS - 0.001, 0, false, 0));
    try testing.expect(shouldProposeRules(0.80, t, 0, -ProposeTriggers.VALUE_DECLINE_EPS - 0.001, false, 0));
    try testing.expect(shouldProposeRules(ProposeTriggers.E_SATURATED, t, 0, 0, false, 0));
    // L13 扩展: 三源失衡损失独立触发 (E 健康 + 无下滑 + 无危机)
    try testing.expect(shouldProposeRules(0.80, t, 0, 0, false, ProposeTriggers.IMBALANCE_LOSS_EPS));
    try testing.expect(!shouldProposeRules(0.80, t, 0, 0, false, ProposeTriggers.IMBALANCE_LOSS_EPS - 0.001));
    try testing.expect(shouldProposeRules(0.80, t, 0, 0, true, 0));
}

test "primordial_laws: toJson contains all law ids" {
    const alloc = testing.allocator;
    const json = try toJson(alloc);
    defer alloc.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"immutable\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"llm_may_rewrite\":false") != null);
    for (MANIFEST) |law| {
        try testing.expect(std.mem.indexOf(u8, json, law.id) != null);
    }
    try testing.expect(std.mem.indexOf(u8, json, "\"hard_axiom\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"thresholds\"") != null);
}
