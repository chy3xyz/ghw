// SPDX-License-Identifier: MIT
// src/harness/chaos_test.zig — Chaos 混沌测试
//
// 目的: 注入故障, 验证系统不会 panic/漏内存/状态损坏
//
// 测试场景:
//   1. IM 断流: Translator.interpret 持续失败, 系统应该 fallback 而不死
//   2. LLM 失败: HttpChatLLM 5xx 错误, GSP 不应该被污染
//   3. 状态损坏: GoalGraph / GSP 强制传非法输入, 验证防御
//   4. 资源耗尽: 大量注册人类, 看是否 OOM
//   5. 竞争条件: 并发 recordInteraction (Zig 0.17 单线程, 这里用顺序)
//
// 运行: zig test src/harness/chaos_test.zig

const std = @import("std");
const ghw = @import("../ghw.zig");

const Translator = ghw.harness.translator.Translator;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const HumanFeedback = ghw.harness.human_symbiosis.HumanFeedback;
const HumanSignal = ghw.harness.human_symbiosis.HumanSignal;
const Task = ghw.harness.human_symbiosis.Task;
const GoalGraph = ghw.goal.GoalGraph;
const Goal = ghw.goal.Goal;
const GoalKind = ghw.goal.GoalKind;
const TranslatorCannedBroken = "<<not valid json>>";

test "chaos: Translator 1000 次 interpret 全失败 → 不死 + fallback 返 valid Intent" {
    const alloc = std.testing.allocator;
    var mock = MockChatLLM.init(alloc, TranslatorCannedBroken);
    var tr = Translator.init(alloc, mock.asChat());
    const ed: ghw.world.ExistenceDegree = .{};
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var intent = try tr.interpret("hello world", ed);
        defer intent.deinit();
        // fallback 应该非空 title
        try std.testing.expect(intent.suggested_title.len > 0);
        try std.testing.expect(intent.suggested_priority == 5);
    }
}

test "chaos: 1 万次 GSP.recordInteraction 不会 OOM, trust 仍 clamp 0-1" {
    const alloc = std.testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");

    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        const success = (i % 2) == 0;
        try gsp.recordInteraction("alice", success, 1, .material, @as(u64, @intCast(i)));
        // trust 应该一直在 [0, 1]
        const p = gsp.peers.get("alice").?;
        try std.testing.expect(p.trust >= 0.0);
        try std.testing.expect(p.trust <= 1.0);
    }
}

test "chaos: GoalGraph 加 1000 个目标 + 拓扑排序 不漏" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    var i: u32 = 0;
    var prev_root: u64 = 0;
    while (i < 1000) : (i += 1) {
        const root = try g.add(.enhance_existence, "root", 5, 0.1, .{ 0, 0, 0, 0 });
        if (prev_root != 0) {
            // 每个新 root 是前一个 root 的子 (形成链)
            _ = try g.addChild(.acquire_knowledge, "child", 5, 0.05, .{ 0, 0.5, 0, 0 }, prev_root);
        }
        prev_root = root;
    }

    const sorted = try g.topologicalSort(alloc);
    defer alloc.free(sorted);
    try std.testing.expectEqual(@as(usize, 1999), sorted.len);
}

test "chaos: GoalGraph 大量 cascade remove 不漏" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 建 100 个根, 每个 5 个子
    var roots: [100]u64 = undefined;
    for (0..100) |i| {
        const root = try g.add(.enhance_existence, "r", 5, 0.1, .{ 0, 0, 0, 0 });
        roots[i] = root;
        for (0..5) |_| {
            _ = try g.addChild(.acquire_knowledge, "c", 5, 0.05, .{ 0, 0.5, 0, 0 }, root);
        }
    }
    try std.testing.expectEqual(@as(usize, 600), g.goals.items.len);

    // cascade delete 中间的根
    for (10..20) |i| {
        g.removeCascade(roots[i], true) catch {};
    }
    // 100 roots + 500 children = 600; 删 10 roots + 50 children = 60, 剩 540
    try std.testing.expectEqual(@as(usize, 540), g.goals.items.len);
}

test "chaos: HumanSignal 收 10 万条 feedback 不漏, by_human 索引正确" {
    const alloc = std.testing.allocator;
    var sig = HumanSignal.init(alloc);
    defer sig.deinit();

    const senders = [_][]const u8{ "alice", "bob", "carol", "dave", "eve" };
    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        const sender = senders[i % senders.len];
        const fb = HumanFeedback{
            .from_human = sender,
            .task_id = i,
            .score = @as(i8, @intCast(@as(i32, @intCast(i % 11)) - 5)), // -5..+5
        };
        try sig.receive(fb);
    }
    try std.testing.expectEqual(@as(u32, 100_000), sig.total_count);
    try std.testing.expectEqual(@as(u32, 5), sig.by_human.count());
    // 每个 human 应该有 20000 条
    for (senders) |s| {
        const h = sig.by_human.get(s).?;
        try std.testing.expectEqual(@as(u32, 20_000), h.feedback_count);
    }
}

test "chaos: TaskQueue 1000 个 task priority 顺序严格" {
    const alloc = std.testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    // 随机 priority 投递
    var prng = std.Random.DefaultPrng.init(42);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const p: u8 = @intFromFloat(prng.random().float(ghw.util.F) * 10.0 + 1.0);
        _ = try q.submit("t", "d", "a", p, .all, 1);
    }
    try std.testing.expectEqual(@as(u32, 1000), q.pending_count);

    // 验证出队顺序 priority 降序
    var last_p: i32 = 999;
    while (q.dequeue()) |t| {
        try std.testing.expect(@as(i32, t.priority) <= last_p);
        last_p = t.priority;
    }
    try std.testing.expectEqual(@as(u32, 0), q.pending_count);
}

test "chaos: ValueMetric 在极端值不爆" {
    _ = std.testing.allocator;
    var vm = ValueMetric{};
    // 极端: 0/0, 10亿/0, 负数
    vm.tasks_completed = 0;
    vm.tasks_failed = 0;
    _ = vm.valueScore();
    vm.tasks_completed = 1_000_000_000;
    vm.tasks_failed = 0;
    _ = vm.valueScore();
    vm.current_trust_sum = -1.0;
    _ = vm.valueScore();
    _ = ghw.util.F;
    // 应该不 panic, 值在 [0, 1]
    const s = vm.valueScore();
    try std.testing.expect(s >= 0.0);
    try std.testing.expect(s <= 1.0);
}

test "chaos: GoalGraph 加自己为父 → error.CycleDetected (or wouldCreateCycle 拦)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();
    const a = try g.add(.explore, "a", 5, 0.1, .{ 0, 0, 0, 0 });

    // 直接调 wouldCreateCycle 测自环
    const self_loop = try g.wouldCreateCycle(5, 5);
    try std.testing.expect(self_loop);
    // 但 a 是 1, 所以 a 当 c1 的父 OK
    _ = try g.addChild(.acquire_knowledge, "b", 5, 0.05, .{ 0, 0.5, 0, 0 }, a);
}

test "chaos: 1000 次 runCycle 在 E 偏低时不漏" {
    const alloc = std.testing.allocator;
    var agent = try ghw.agent.GHWAgent.init(alloc, "chaos-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    // 准备信息流
    const info = ghw.goal.Information{
        .id = 0,
        .label = "test",
        .features = .{ 0.5, 0.3, 0.2, 0.1 },
    };
    const infos = [_]ghw.goal.Information{info};

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = agent.runCycle(&infos) catch continue;
    }
    // E 应该还在 [0, 1]
    const e = agent.ed.e();
    try std.testing.expect(e >= 0.0);
    try std.testing.expect(e <= 1.0);
    try std.testing.expect(agent.tick == 1000);
}
