//! task_runner — TaskQueue 与 GHWAgent.runTask 的薄封装 (P6)
//!
//! dequeue → runTask (含 memory.recordAt) → complete / fail

const std = @import("std");
const Allocator = std.mem.Allocator;
const GHWAgent = @import("../agent/core.zig").GHWAgent;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;

pub const RunResult = struct {
    task_id: u64,
    title: []const u8,
    actual_delta_e: f32,
    cycles_used: u32,
};

/// 取最高优先级 pending 任务并执行。返回 null 表示队列空或 dequeue 失败。
pub fn runNextPending(agent: *GHWAgent, queue: *TaskQueue, alloc: Allocator) !?RunResult {
    const t = queue.dequeue() orelse return null;
    const result = agent.runTask(t) catch {
        queue.fail(t.id);
        return null;
    };
    defer alloc.free(result.output);
    try queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);
    return .{
        .task_id = t.id,
        .title = t.title,
        .actual_delta_e = result.actual_delta_e,
        .cycles_used = result.cycles_used,
    };
}

test "task_runner: runNextPending 完成 pending 任务" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var agent = try GHWAgent.init(alloc, "tr-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    var mem = @import("memory.zig").Memory.init(alloc, 1);
    defer mem.deinit();
    agent.bindMemory(&mem, io);

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    _ = try queue.submit("do thing", "desc", "alice", 8, .nature, 2);

    const ran = try runNextPending(&agent, &queue, alloc);
    try std.testing.expect(ran != null);
    try std.testing.expectEqual(@as(u32, 1), queue.completed_count);
    try std.testing.expectEqual(@as(usize, 1), mem.episodes.items.len);
    try std.testing.expectEqual(@import("memory.zig").EpisodeKind.task_completed, mem.episodes.items[0].kind);
}
