//! survival_remedy — 诊断后有界补救提议 (P3)
//!
//! diagnose_host 完成后, 根据 finding 入队只读后续任务:
//!   disk → scan landscape (找大户)
//!   mem  → scan memory hogs
//!   load → query peer 求协作 (有 peer) 或 scan runaway
//!
//! 仍守架构: 只提议入队, 选跑靠 TaskBias + ΔE; 执行器仍只读 (无 shell/杀进程)。

const std = @import("std");
const Allocator = std.mem.Allocator;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const world_sensor = @import("world_sensor.zig");

pub const FollowUpResult = struct {
    submitted: u32 = 0,
    skipped_dup: u32 = 0,
};

fn hasPendingTitlePrefix(queue: *const TaskQueue, prefix: []const u8) bool {
    for (queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        if (std.mem.startsWith(u8, t.title, prefix)) return true;
    }
    return false;
}

fn submitOnce(
    queue: *TaskQueue,
    prefix: []const u8,
    title_suffix: []const u8,
    desc: []const u8,
    dim: Task.Dimension,
    priority: u8,
    out: *FollowUpResult,
) !void {
    if (hasPendingTitlePrefix(queue, prefix)) {
        out.skipped_dup += 1;
        return;
    }
    const title = try std.fmt.allocPrint(queue.allocator, "{s}{s}", .{ prefix, title_suffix });
    defer queue.allocator.free(title);
    _ = try queue.submitWithSource(title, desc, "survival_remedy", priority, dim, 4, .survival_remedy);
    out.submitted += 1;
}

/// 从诊断报告 finding 行提议补救任务 (最多 2 条)
pub fn maybeFollowUpFromReport(
    queue: *TaskQueue,
    report: []const u8,
    has_live_peers: bool,
    alloc: Allocator,
) !FollowUpResult {
    _ = alloc;
    var out: FollowUpResult = .{};
    if (report.len == 0) return out;

    const disk = std.mem.indexOf(u8, report, "disk near full") != null;
    const mem = std.mem.indexOf(u8, report, "memory pressure") != null;
    const load = std.mem.indexOf(u8, report, "load spike") != null;
    if (!disk and !mem and !load) return out;

    // 优先级: disk > mem > load; 硬顶 2 条
    if (disk and out.submitted < 2) {
        try submitOnce(
            queue,
            "[remedy] scan disk landscape",
            "",
            "Read-only: list top procs / landscape after disk pressure diagnosis. No deletes.",
            .material,
            8,
            &out,
        );
    }
    if (mem and out.submitted < 2) {
        try submitOnce(
            queue,
            "[remedy] scan memory hogs",
            "",
            "Read-only: identify high-RSS processes after memory diagnosis. No kills.",
            .material,
            7,
            &out,
        );
    }
    if (load and out.submitted < 2) {
        if (has_live_peers) {
            try submitOnce(
                queue,
                "[remedy] query peer load relief",
                "",
                "Ask a live peer for state — seek symbiotic load sharing (read-only query).",
                .nature,
                7,
                &out,
            );
        } else {
            try submitOnce(
                queue,
                "[remedy] scan runaway cpu",
                "",
                "Read-only: find high-CPU processes after load spike. No kills.",
                .material,
                7,
                &out,
            );
        }
    }
    return out;
}

/// 无报告时: 直接从 snapshot 阈值提议 (诊断跳过仍可补救)
pub fn maybeFollowUpFromSnapshot(
    queue: *TaskQueue,
    snap: SystemSnapshot,
    has_live_peers: bool,
    alloc: Allocator,
) !FollowUpResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    if (snap.disk_used_pct >= world_sensor.DISK_PCT_EPS) {
        try buf.appendSlice(alloc, "finding: disk near full\n");
    }
    if (snap.mem_pct >= world_sensor.MEM_PCT_EPS) {
        try buf.appendSlice(alloc, "finding: memory pressure\n");
    }
    if (snap.load_1m >= world_sensor.LOAD_EPS) {
        try buf.appendSlice(alloc, "finding: load spike\n");
    }
    return maybeFollowUpFromReport(queue, buf.items, has_live_peers, alloc);
}

const testing = std.testing;

test "survival_remedy: disk finding submits scan landscape once" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const report =
        \\[diagnose_host] task="[world] disk"
        \\finding: disk near full — free caches
    ;
    const r1 = try maybeFollowUpFromReport(&q, report, false, alloc);
    try testing.expectEqual(@as(u32, 1), r1.submitted);
    try testing.expectEqual(Task.Source.survival_remedy, q.tasks.items[0].source);
    try testing.expect(std.mem.startsWith(u8, q.tasks.items[0].title, "[remedy] scan disk"));
    const r2 = try maybeFollowUpFromReport(&q, report, false, alloc);
    try testing.expectEqual(@as(u32, 0), r2.submitted);
    try testing.expectEqual(@as(u32, 1), r2.skipped_dup);
}

test "survival_remedy: load + peers → query peer" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try maybeFollowUpFromReport(&q, "finding: load spike\n", true, alloc);
    try testing.expectEqual(@as(u32, 1), r.submitted);
    try testing.expect(std.mem.indexOf(u8, q.tasks.items[0].title, "peer") != null);
}

test "survival_remedy: caps at 2 follow-ups" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const report =
        \\finding: disk near full
        \\finding: memory pressure
        \\finding: load spike
    ;
    const r = try maybeFollowUpFromReport(&q, report, false, alloc);
    try testing.expectEqual(@as(u32, 2), r.submitted);
    try testing.expectEqual(@as(u32, 2), q.pending_count);
}
