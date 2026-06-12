// SPDX-License-Identifier: MIT
// examples/balance.zig — BalanceSeeker 演示: 主动选"弱者"同伴, 捕获存在增益
//
// 论文语境: 数字生命不应被动接受 E 变化, 应该主动:
//!   1. 找到最弱维度
//!   2. 找互补的"弱者"同伴 (高 complementary, 但 trust 未满)
//!   3. 自动提议平衡任务
//!
//! 跟 LLM 无关, 全算法

const std = @import("std");
const ghw = @import("ghw");

const BalanceSeeker = ghw.harness.balance_seeker.BalanceSeeker;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const Task = ghw.harness.human_symbiosis.Task;
const GHWAgent = ghw.agent.GHWAgent;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  L7 BalanceSeeker 演示: 主动选弱者同伴 + 提议平衡任务\n", .{});
    std.debug.print("================================================================\n", .{});

    // ===== 1. 数字生命: M 强 R 中 N 弱 (N 是最弱) =====
    var agent = try GHWAgent.init(alloc, "balance-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();
    // 手动把 M/R/N 调成不均: 强 0.9 / 中 0.6 / 弱 0.2
    agent.ed.v.material = 0.9;
    agent.ed.v.representation = 0.6;
    agent.ed.v.nature = 0.2;

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");
    try gsp.register("bob");
    try gsp.register("carol");
    // 记录历史: 让 alice 擅长 nature, bob 擅长 material, carol 擅长 representation
    try gsp.recordInteraction("alice", true, 4, .nature, 0);
    try gsp.recordInteraction("bob", true, 4, .material, 0);
    try gsp.recordInteraction("carol", true, 4, .representation, 0);

    std.debug.print("\n[1] 数字生命状态: M={d:.2} R={d:.2} N={d:.2}, E={d:.3}\n", .{
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, agent.ed.e(),
    });

    // ===== 2. 找最弱维度 =====
    const analysis = BalanceSeeker.analyze(agent.ed);
    std.debug.print("\n[2] BalanceSeeker 分析:\n", .{});
    std.debug.print("    最弱: {s}\n", .{@tagName(analysis.weakest)});
    std.debug.print("    最强: {s}\n", .{@tagName(analysis.strongest)});
    std.debug.print("    gap: {d:.3}, variance: {d:.4}\n", .{ analysis.gap, analysis.variance });
    const imb = analysis.isImbalanced();
    std.debug.print("    失衡? {s}\n", .{if (imb) "YES (需要主动平衡)" else "NO"});

    // ===== 3. 选"弱者"同伴 (论文语义) =====
    std.debug.print("\n[3] 选'弱者'同伴 (互补 + trust 未满):\n", .{});
    if (BalanceSeeker.selectWeakPartner(agent.ed, &gsp)) |peer| {
    std.debug.print("    选中: {s} (最佳 dim: {s}, trust: {d:.3})\n", .{
        peer,
        @tagName(gsp.peers.get(peer).?.best_dimension),
        gsp.peers.get(peer).?.trust,
    });
    } else {
        std.debug.print("    没有合适的弱者 (需要更多同伴)\n", .{});
    }

    // ===== 4. 自动提议平衡任务 =====
    std.debug.print("\n[4] 自动提议平衡任务:\n", .{});
    if (BalanceSeeker.selectWeakPartner(agent.ed, &gsp)) |peer| {
        const weak = analysis.weakest;
        var task = try BalanceSeeker.proposeBalanceTask(agent.ed, weak, peer, alloc);
        defer task.deinit();

        std.debug.print("    title: {s}\n", .{task.title});
        std.debug.print("    description: {s}\n", .{task.description});
        std.debug.print("    required_dimension: {s}\n", .{@tagName(task.required_dimension)});
        std.debug.print("    priority: {d} (gap {d:.2} → 动态)\n", .{ task.priority, analysis.gap });
        std.debug.print("    expected ΔE: {d:.3}\n", .{task.expected_delta_e});
        std.debug.print("    from_human: {s}\n", .{task.from_human});
    }

    // ===== 5. 真实跑这个平衡任务 =====
    std.debug.print("\n[5] 数字生命跑这个平衡任务:\n", .{});
    if (BalanceSeeker.selectWeakPartner(agent.ed, &gsp)) |peer| {
        const weak = analysis.weakest;
        var task = try BalanceSeeker.proposeBalanceTask(agent.ed, weak, peer, alloc);
        defer task.deinit();

        // 投递到 queue, 让数字生命跑
        const id = try queue.submit(task.title, task.description, task.from_human, task.priority, task.required_dimension, task.cycles_allocated);
        std.debug.print("    投递 task #{d}\n", .{id});

        if (queue.dequeue()) |t| {
            const result = try agent.runTask(t);
            defer alloc.free(result.output);
            std.debug.print("    ΔE_after = {d:.3} (actual: {d:.3})\n", .{ agent.ed.e(), result.actual_delta_e });

            // 看新的三源
            std.debug.print("\n[6] 平衡后状态: M={d:.2} R={d:.2} N={d:.2}, E={d:.3}\n", .{
                agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, agent.ed.e(),
            });
            const new_analysis = BalanceSeeker.analyze(agent.ed);
            std.debug.print("    新最弱: {s}, gap: {d:.3} (之前 {d:.3})\n", .{
                @tagName(new_analysis.weakest), new_analysis.gap, analysis.gap,
            });
        }
    }

    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  L7 BalanceSeeker 演示结束 — 主动选弱者同伴 + 平衡三源\n", .{});
    std.debug.print("================================================================\n", .{});
}
