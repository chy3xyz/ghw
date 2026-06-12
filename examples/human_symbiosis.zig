// SPDX-License-Identifier: MIT
// examples/human_symbiosis.zig — L6 演示: 数字生命跟人类共生
//
// 流程:
//!  1. 创建数字生命 + HumanGSP + TaskQueue + HumanSignal + ValueMetric
//!  2. 投递 3 个任务 (来自不同人类)
//!  3. 数字生命依次执行任务
//!  4. 模拟人类反馈 (好评/差评/中评)
//!  5. ValueMetric 输出价值报表

const std = @import("std");
const ghw = @import("ghw");

const HS = ghw.harness.human_symbiosis;
const TaskQueue = HS.TaskQueue;
const HumanSignal = HS.HumanSignal;
const HumanGSP = HS.HumanGSP;
const ValueMetric = HS.ValueMetric;
const HumanFeedback = HS.HumanFeedback;
const Task = HS.Task;

const GHWAgent = ghw.agent.GHWAgent;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  L6 HumanSymbiosis 演示: 数字生命接人类的活、挣反馈、算价值\n", .{});
    std.debug.print("================================================================\n", .{});

    // ===== 1. 组件装配 =====
    var agent = try GHWAgent.init(alloc, "life-sym-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    var signal = HumanSignal.init(alloc);
    defer signal.deinit();

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    // 注册 3 个 human
    try gsp.register("alice");
    try gsp.register("bob");
    try gsp.register("carol");

    std.debug.print("\n[1] 组件初始化: agent + queue + signal + gsp (3 humans)\n", .{});
    std.debug.print("    初始 E: {d:.3}\n", .{agent.ed.e()});

    // ===== 2. 投递 3 个任务 =====
    std.debug.print("\n[2] 人类投递 3 个任务 (不同优先级 + 不同维度):\n", .{});
    const id1 = try queue.submit(
        "生成 attention 调参规则",
        "我看到 E 经常 < 0.5, 帮我自动调整 attention 的 alpha/beta/gamma 权重",
        "alice",
        9, // 优先级高
        .material,
        4, // 给 4 cycle
    );
    const id2 = try queue.submit(
        "加一个新 method (探索型)",
        "MethodLibrary 里只有 3 个 method, 我想要一个专门用来探索未访问过的 method 类型",
        "bob",
        5,
        .nature,
        3,
    );
    const id3 = try queue.submit(
        "写一份状态序列化",
        "我想把当前 E 状态写到磁盘, 重启能恢复",
        "carol",
        3,
        .representation,
        2,
    );
    std.debug.print("    task #{d} (alice, material, P9)\n", .{id1});
    std.debug.print("    task #{d} (bob, nature, P5)\n", .{id2});
    std.debug.print("    task #{d} (carol, representation, P3)\n", .{id3});

    // ===== 3. 数字生命按优先级接活 =====
    std.debug.print("\n[3] 数字生命接活 (按 priority 降序):\n", .{});
    while (queue.dequeue()) |task| {
        std.debug.print("\n  >> 处理 task #{d} ({s}) by {s}\n", .{
            task.id, task.title, task.from_human,
        });

        // 选最适合的 human (GSP)
        if (gsp.selectMostTrusted(task.required_dimension)) |best_human| {
            std.debug.print("    GSP 选人: {s} (best dim: {s})\n", .{
                best_human,
                @tagName(gsp.peers.get(best_human).?.best_dimension),
            });
        }

        // 跑任务
        const result = try agent.runTask(task);
        defer alloc.free(result.output);
        std.debug.print("    ΔE_actual = {d:.3}, cycles_used = {d}\n", .{
            result.actual_delta_e, result.cycles_used,
        });

        // 标记完成
        try queue.complete(task.id, result.output, result.actual_delta_e, result.cycles_used);

        // 模拟人类反馈 (不同打分)
        const score: i8 = switch (task.id) {
            1 => 4,   // alice: 满意
            2 => -1,  // bob: 不太满意
            3 => 2,   // carol: 还行
            else => 0,
        };
        const comment: []const u8 = switch (task.id) {
            1 => "好, 涨了 0.05!",
            2 => "我想要的 method 类型不太对",
            3 => "能用, 但需要再调试",
            else => "",
        };
        const fb = HumanFeedback{
            .from_human = task.from_human,
            .task_id = task.id,
            .score = score,
            .comment = comment,
        };
        const de = fb.toDeltaE();
        try signal.receive(fb);
        try queue.attachFeedback(task.id, score, comment, 0, de);
        try gsp.recordInteraction(task.from_human, true, score, task.required_dimension, 0);

        std.debug.print("    反馈: score={d}, comment='{s}', ΔE_human={d:.3}\n", .{
            score, comment, de,
        });
    }

    // ===== 4. ValueMetric 报表 =====
    var vm = ValueMetric{};
    vm.pullFromSignal(&signal);
    vm.pullFromQueue(&queue);
    vm.pullFromGSP(&gsp);

    std.debug.print("\n[4] ValueMetric 报表:\n", .{});
    // 直接 print value_score (writer 麻烦)
    std.debug.print("  完成/失败: {d}/{d}\n", .{ vm.tasks_completed, vm.tasks_failed });
    std.debug.print("  反馈: count={d} total_score={d}\n", .{ vm.feedback_count, vm.feedback_total_score });
    std.debug.print("  Human E uplift: {d:.3} | Internal E uplift: {d:.3}\n", .{ vm.human_e_uplift, vm.actual_e_uplift });
    std.debug.print("  Reach: {d} humans | Trust sum: {d:.3}\n", .{ vm.unique_humans, vm.current_trust_sum });
    std.debug.print("  ───────────────────────────\n", .{});
    std.debug.print("  ★ VALUE SCORE: {d:.3} / 1.0\n", .{vm.valueScore()});
    std.debug.print("========================\n", .{});

    // GSP summary
    std.debug.print("\n[HumanGSP 信任分摘要]\n", .{});
    var it = gsp.peers.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        std.debug.print("  - {s}: trust={d:.3} ({s}) tasks={d} +{d}/-{d} best={s}\n", .{
            p.id, p.trust, p.trustLevel(),
            p.task_count, p.positive_count, p.negative_count,
            @tagName(p.best_dimension),
        });
    }

    // 最终状态
    std.debug.print("\n[5] 数字生命最终状态:\n", .{});
    std.debug.print("    E = {d:.3} (从 {d:.3} 涨到 {d:.3})\n", .{
        agent.ed.e(),
        @as(f32, 0.487),
        agent.ed.e(),
    });
    std.debug.print("    累计任务 ΔE = {d:.3}\n", .{queue.totalActualDeltaE()});
    std.debug.print("    累计人类反馈 ΔE = {d:.3}\n", .{signal.total_e_uplift});

    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  L6 演示结束 — 数字生命接活 + 挣反馈 + 涨 E + 算价值\n", .{});
    std.debug.print("================================================================\n", .{});
}
