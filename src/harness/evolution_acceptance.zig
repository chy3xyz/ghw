//! evolution_acceptance — 求存×进化验收快照 (AWAKENING P1 provenance)
//!
//! 汇总 L1–L5、危机锁、规则反馈、稳态门槛，供 UI 验收面板只读展示。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const existence_phase = @import("existence_phase.zig");

pub const Snapshot = struct {
    l1_count: u32 = 0,
    l2_count: u32 = 0,
    l3_count: u32 = 0,
    l3_approved: u32 = 0,
    l4_count: u32 = 0,
    l4_approved: u32 = 0,
    l5_count: u32 = 0,
    self_evolve_total: u32 = 0,
    rule_propose_total: u32 = 0,
    adopted_rules: u32 = 0,
    crisis_lock: bool = false,
    awakened: bool = false,
    phase_label: []const u8 = "awakening",
    iv1: u64 = 0,
    iv3: u64 = 0,
    iv4: u64 = 0,
    iv5: u64 = 0,
    feedback_pending: bool = false,
    feedback_evals: u32 = 0,
    feedback_improved: u32 = 0,
    rules_at_mark: u32 = 0,
    steady: existence_phase.SteadyGates = .{},
};

pub fn appendJson(alloc: Allocator, body: *std.ArrayList(u8), s: Snapshot) !void {
    try body.appendSlice(alloc, "\"evolution_acceptance\":{");
    try body.print(alloc,
        \\"l1":{d},"l2":{d},"l3":{d},"l3_approved":{d},"l4":{d},"l4_approved":{d},"l5":{d},"self_evolve_total":{d},"rule_propose_total":{d},"adopted_rules":{d},"crisis_lock":{s},"awakened":{s},"phase":"{s}","intervals":{{"l1":{d},"l3":{d},"l4":{d},"l5":{d}}},"feedback":{{"pending":{s},"evals":{d},"improved":{d},"rules_at_mark":{d}}},"steady":{{"mrn_balanced":{s},"value_ok":{s},"e_ok":{s},"all_ok":{s}}}
    , .{
        s.l1_count,
        s.l2_count,
        s.l3_count,
        s.l3_approved,
        s.l4_count,
        s.l4_approved,
        s.l5_count,
        s.self_evolve_total,
        s.rule_propose_total,
        s.adopted_rules,
        if (s.crisis_lock) "true" else "false",
        if (s.awakened) "true" else "false",
        s.phase_label,
        s.iv1,
        s.iv3,
        s.iv4,
        s.iv5,
        if (s.feedback_pending) "true" else "false",
        s.feedback_evals,
        s.feedback_improved,
        s.rules_at_mark,
        if (s.steady.mrn_balanced) "true" else "false",
        if (s.steady.value_ok) "true" else "false",
        if (s.steady.e_ok) "true" else "false",
        if (s.steady.allOk()) "true" else "false",
    });
    try body.append(alloc, '}'); // close evolution_acceptance
}

const testing = std.testing;

test "evolution_acceptance: appendJson contains crisis_lock" {
    const alloc = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{");
    const snap: Snapshot = .{
        .crisis_lock = true,
        .l3_approved = 2,
        .phase_label = "crisis",
        .steady = .{ .e_ok = false, .mrn_balanced = true, .value_ok = true },
    };
    try appendJson(alloc, &body, snap);
    try body.appendSlice(alloc, "}");
    const j = body.items;
    try testing.expect(std.mem.indexOf(u8, j, "\"crisis_lock\":true") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"l3_approved\":2") != null);
    // roundtrip: 合法 JSON (evolution_acceptance 自闭合)
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, j, .{});
    defer parsed.deinit();
}

test "evolution_acceptance: 全量字段 + steady allOk 序列化" {
    const alloc = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{");
    const snap: Snapshot = .{
        .l1_count = 4,
        .l2_count = 3,
        .l3_count = 2,
        .l3_approved = 2,
        .l4_count = 1,
        .l4_approved = 1,
        .l5_count = 1,
        .self_evolve_total = 11,
        .rule_propose_total = 5,
        .adopted_rules = 2,
        .crisis_lock = false,
        .awakened = true,
        .phase_label = "steady",
        .iv1 = 32,
        .iv3 = 64,
        .iv4 = 96,
        .iv5 = 192,
        .feedback_pending = false,
        .feedback_evals = 3,
        .feedback_improved = 2,
        .rules_at_mark = 2,
        .steady = .{ .mrn_balanced = true, .value_ok = true, .e_ok = true },
    };
    try appendJson(alloc, &body, snap);
    try body.appendSlice(alloc, "}");
    const j = body.items;

    // 三段块均序列化: 计数 / intervals / feedback / steady
    try testing.expect(std.mem.indexOf(u8, j, "\"self_evolve_total\":11") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"intervals\":{\"l1\":32,\"l3\":64,\"l4\":96,\"l5\":192}") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"feedback\":{\"pending\":false,\"evals\":3,\"improved\":2,\"rules_at_mark\":2}") != null);
    // 稳态门槛全开 ⇒ all_ok=true
    try testing.expect(std.mem.indexOf(u8, j, "\"steady\":{\"mrn_balanced\":true,\"value_ok\":true,\"e_ok\":true,\"all_ok\":true}") != null);

    // 合法 JSON: evolution_acceptance 块可被宿主直接 parse
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, j, .{});
    defer parsed.deinit();
    const blk = parsed.value.object.get("evolution_acceptance").?;
    try testing.expectEqual(@as(i64, 192), blk.object.get("intervals").?.object.get("l5").?.integer);
    try testing.expectEqual(true, blk.object.get("steady").?.object.get("all_ok").?.bool);
}
