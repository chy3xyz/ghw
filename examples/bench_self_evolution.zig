// SPDX-License-Identifier: MIT
// examples/bench_self_evolution.zig — 可复现 A/B 基准: 自我进化闭环提升存在度 E
//
// 两臂唯一差异: treatment 在跑 cycle 前经 MockChatLLM 提议 3 条 representation
// 规则 (Guard 拒掉含 @panic 的那条) 并 bindRuleLib; baseline 不绑任何规则库。
// 相同 seed / 相同恒定零特征世界 / 相同 L4 冻结标志 — 完全确定性, 无需网络。
//
// 退出码: passed → 0, 否则 1 (gpa deinit 后 std.process.exit)。
// 输出: 人类摘要 → stderr; 单行 JSON → stdout (机器契约, 供验收脚本 grep)。
const std = @import("std");
const ghw = @import("ghw");
const harness = ghw.harness;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bench = harness.self_evolution_bench;

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  GHW self-evolution A/B benchmark (deterministic, mock LLM)\n", .{});
    std.debug.print("================================================================\n", .{});

    const r = try bench.run(alloc, .{});

    const fav: []const u8 = if (r.favored) |d| @tagName(d) else "(none)";
    std.debug.print("\n  cycles per arm          : {d} (seed 42)\n", .{r.cycles});
    std.debug.print("  baseline  AUC / E / R   : {d:.3} / {d:.3} / {d:.3}\n", .{ r.baseline_auc, r.baseline_final_e, r.baseline_final_r });
    std.debug.print("  treatment AUC / E / R   : {d:.3} / {d:.3} / {d:.3}\n", .{ r.treatment_auc, r.treatment_final_e, r.treatment_final_r });
    std.debug.print("  AUC ratio               : {d:.4} (pass bar x{d:.2})\n", .{ r.treatment_auc / r.baseline_auc, r.threshold });
    std.debug.print("  rules adopted / rejected: {d} / {d}\n", .{ r.adopted_rules, r.rejected_rules });
    std.debug.print("  rule bias favored       : {s} (dominance {d:.2})\n", .{ fav, r.dominance });
    std.debug.print("  selection_changed       : {d} cycles\n", .{r.selection_changed});
    std.debug.print("\n  VERDICT: {s}\n", .{if (r.passed) "PASS" else "FAIL"});
    std.debug.print("================================================================\n", .{});

    const json = try bench.reportJson(alloc, r);
    // JSON 走 stdout (机器可读契约, 供 scripts/self_evolution_bench.sh grep);
    // 人类摘要在 stderr。
    const stdout = std.Io.File.stdout();
    try std.Io.File.writeStreamingAll(stdout, io, json);
    try std.Io.File.writeStreamingAll(stdout, io, "\n");
    alloc.free(json);

    const code: u8 = if (r.passed) 0 else 1;
    _ = gpa.deinit();
    std.process.exit(code);
}
