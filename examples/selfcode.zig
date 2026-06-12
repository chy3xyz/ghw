// SPDX-License-Identifier: MIT
// examples/selfcode.zig — 演示 SelfEncoder: 数字生命"理解自己 + 自己写代码" (非 LLM)
const std = @import("std");
const ghw = @import("ghw");
const harness = ghw.harness;
const SelfEncoder = harness.self_encoder.SelfEncoder;
const Intent = harness.self_encoder.Intent;
const AdjustmentKind = harness.self_encoder.AdjustmentKind;
const Dimension = harness.self_encoder.Dimension;

fn p(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    p("\n", .{});
    p("================================================================\n", .{});
    p("  GHW SelfEncoder 演示: 数字生命自己写代码 (规则合成, 非 LLM)\n", .{});
    p("================================================================\n", .{});

    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();

    p("\n已加载 {d} 条规则:\n", .{enc.rules.items.len});
    for (enc.rules.items, 0..) |r, i| {
        p("  [{d}] {s} -> {s} / {s}\n", .{
            i + 1,
            r.name,
            @tagName(r.applies_to),
            @tagName(r.dimension),
        });
    }

    const scenarios = [_]struct {
        name: []const u8,
        intent: Intent,
    }{
        .{
            .name = "场景 1: 紧急调参 (E=0.35, 紧急提升探索权重)",
            .intent = .{
                .target_e_delta = 0.20,
                .dimension = .all,
                .adjustment_kind = .tune_params,
                .current_e = 0.35,
                .reason = "E 偏低, 需要调整参数",
            },
        },
        .{
            .name = "场景 2: 添加新方法 (需要探索未知)",
            .intent = .{
                .target_e_delta = 0.15,
                .dimension = .all,
                .adjustment_kind = .add_method,
                .current_e = 0.65,
                .reason = "需要新方法",
            },
        },
        .{
            .name = "场景 3: 紧急补丁 (E=0.20, 危机)",
            .intent = .{
                .target_e_delta = 0.30,
                .dimension = .all,
                .adjustment_kind = .emergency_patch,
                .current_e = 0.20,
                .reason = "E 危机, 紧急补丁",
            },
        },
    };

    for (scenarios) |s| {
        p("\n----------------------------------------------------------------\n", .{});
        p("{s}\n", .{s.name});
        p("----------------------------------------------------------------\n", .{});

        var result = try enc.encode(s.intent);
        defer result.deinit();

        p("\n[决策解释 rationale]\n{s}\n", .{result.rationale});
        p("\n[合成的代码 code_buf]\n{s}\n", .{result.code});
        p("[形式化验证]\n", .{});
        p("  passes_invariants            = {} (tune_params 严格; add_method/emergency 可放宽)\n", .{result.verification.passes_invariants});
        p("  preserves_existence_degree   = {}\n", .{result.verification.preserves_existence_degree});
        p("  contains_blacklisted         = {}\n", .{result.verification.contains_blacklisted});
        p("  line_count                   = {d}\n", .{result.verification.line_count});

        p("\n[代码引用 references]\n", .{});
        for (result.references, 0..) |r, i| {
            p("  [{d}] {s}  ({s})\n", .{ i + 1, r.symbol, r.context });
        }
    }

    // 黑名单测试
    p("\n----------------------------------------------------------------\n", .{});
    p("黑名单测试: SelfEncoder.verify() 拒绝含 @panic 的代码\n", .{});
    p("----------------------------------------------------------------\n", .{});
    const bad = enc.verify("pub const x = @panic(\"oops\");");
    p("  contains_blacklisted = {} (期望 true)\n", .{bad.contains_blacklisted});
    p("  passes_invariants    = {} (期望 false)\n", .{bad.passes_invariants});

    p("\n================================================================\n", .{});
    p("  SelfEncoder 演示结束 — 规则合成 + 形式验证, 不依赖 LLM\n", .{});
    p("================================================================\n", .{});
}
