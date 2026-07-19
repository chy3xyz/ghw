//! task_feedback — 任务完成 → HumanSignal + TaskQueue + HumanGSP (P9 L6 闭环)
//!
//! live_loop 完整链路的共享封装; ui_server / daemon 在 runNextPending 后调用。

const std = @import("std");
const F = @import("../util/math.zig").F;
const GHWAgent = @import("../agent/core.zig").GHWAgent;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const HumanGSP = @import("human_symbiosis/human_gsp.zig").HumanGSP;
const HumanSignal = @import("human_symbiosis/human_signal.zig").HumanSignal;
const HumanFeedback = @import("human_symbiosis/human_signal.zig").HumanFeedback;
const task_runner = @import("task_runner.zig");
const task_executor = @import("task_executor.zig");

pub const Context = struct {
    queue: *TaskQueue,
    gsp: *HumanGSP,
    signal: *HumanSignal,
};

/// 无人类显式评分时, 用内部 ΔE 映射到 -5..+5 (跟 live_loop 模拟反馈同量级)
pub fn heuristicScore(actual_delta_e: F) i8 {
    if (actual_delta_e >= 0.10) return 5;
    if (actual_delta_e >= 0.05) return 3;
    if (actual_delta_e > 0.001) return 1;
    if (actual_delta_e < -0.01) return -2;
    return 0;
}

/// 写入 Signal + TaskQueue.feedback + GSP trust; 返回人类 ΔE
pub fn applyFeedback(
    ctx: *const Context,
    task: *const Task,
    score: i8,
    comment: []const u8,
    timestamp: u64,
) !F {
    const fb = HumanFeedback{
        .from_human = task.from_human,
        .task_id = task.id,
        .score = score,
        .comment = comment,
        .timestamp = timestamp,
    };
    const de = fb.toDeltaE();
    try ctx.signal.receive(fb);
    try ctx.queue.attachFeedback(task.id, score, comment, timestamp, de);
    try ctx.gsp.recordInteraction(task.from_human, true, score, task.required_dimension, timestamp);
    return de;
}

/// 任务尚无 feedback 时写启发式评分; 已有则跳过
pub fn applyHeuristicIfMissing(
    ctx: *const Context,
    task_id: u64,
    actual_delta_e: F,
    timestamp: u64,
) !?F {
    const t = ctx.queue.find(task_id) orelse return null;
    if (t.feedback != null) return null;
    const score = heuristicScore(actual_delta_e);
    return try applyFeedback(ctx, t, score, "", timestamp);
}

/// runNextPending + 启发式反馈 (P9 默认路径)
pub fn runNextPendingWithFeedback(
    agent: *GHWAgent,
    ctx: *const Context,
    alloc: std.mem.Allocator,
    timestamp: u64,
) !?task_runner.RunResult {
    return runNextPendingWithFeedbackEnv(agent, ctx, alloc, timestamp, null);
}

/// P2: 带 ExecEnv 的有界真执行 + 启发式反馈
pub fn runNextPendingWithFeedbackEnv(
    agent: *GHWAgent,
    ctx: *const Context,
    alloc: std.mem.Allocator,
    timestamp: u64,
    env: ?task_executor.Env,
) !?task_runner.RunResult {
    const ran = try task_runner.runNextPendingWithEnv(agent, ctx.queue, alloc, env);
    if (ran) |r| {
        _ = try applyHeuristicIfMissing(ctx, r.task_id, r.actual_delta_e, timestamp);
    }
    return ran;
}

const testing = std.testing;

test "task_feedback: heuristicScore 映射" {
    try testing.expectEqual(@as(i8, 5), heuristicScore(0.12));
    try testing.expectEqual(@as(i8, 3), heuristicScore(0.06));
    try testing.expectEqual(@as(i8, 1), heuristicScore(0.02));
    try testing.expectEqual(@as(i8, 0), heuristicScore(0.0));
    try testing.expectEqual(@as(i8, -2), heuristicScore(-0.05));
}

test "task_feedback: applyFeedback 更新 Signal/GSP/Queue" {
    const alloc = testing.allocator;
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var signal = HumanSignal.init(alloc);
    defer signal.deinit();
    try gsp.register("alice");
    const id = try queue.submit("t", "d", "alice", 5, .nature, 2);
    const t = queue.dequeue().?;
    try queue.complete(id, "out", 0.08, 1);

    const ctx = Context{ .queue = &queue, .gsp = &gsp, .signal = &signal };
    const de = try applyFeedback(&ctx, t, 4, "nice", 100);
    try testing.expectApproxEqAbs(@as(F, 0.24), de, 0.001);
    try testing.expectEqual(@as(u32, 1), signal.total_count);
    try testing.expect(queue.find(id).?.feedback != null);
    try testing.expectApproxEqAbs(@as(F, 0.70), gsp.peers.get("alice").?.trust, 0.001);
}
