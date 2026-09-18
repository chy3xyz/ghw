//! survival_act — 有界可审计补救 (P5a)
//!
//! 诊断/危机后允许的「真动作」仅限进程内、可逆、无破坏:
//!   1. throttle_world_fetch — 建议拉长 AutoCLI 间隔 (降 I/O/内存压力)
//!   2. request_human_help — 入队高优人类介入任务 (清单式, 不杀进程)
//!   3. write_plan — 写 episode 审计「我做了什么决策」
//!
//! 禁止: 任意 shell、删文件、杀进程、改 E 公式。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Memory = @import("memory.zig").Memory;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const world_sensor = @import("world_sensor.zig");
const survival_learn = @import("survival_learn.zig");
const primordial_laws = @import("primordial_laws.zig");

/// 危机时建议的 AutoCLI 间隔 (秒); 健康时返回 null (用默认)
pub const CRISIS_AUTOCLI_INTERVAL_S: u64 = primordial_laws.SurvivalObservability.CRISIS_AUTOCLI_INTERVAL_S;
pub const HEALTHY_CLEAR: u64 = 0;

pub const ApplyResult = struct {
    human_tasks: u32 = 0,
    skipped_dup: u32 = 0,
    /// 非 null 时 caller 应写入 autocli interval override
    throttle_autocli_s: ?u64 = null,
    plan_written: bool = false,
};

fn hasPendingTitlePrefix(queue: *const TaskQueue, prefix: []const u8) bool {
    for (queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        if (std.mem.startsWith(u8, t.title, prefix)) return true;
    }
    return false;
}

fn submitHumanAct(
    queue: *TaskQueue,
    prefix: []const u8,
    desc: []const u8,
    priority: u8,
    out: *ApplyResult,
) !void {
    if (hasPendingTitlePrefix(queue, prefix)) {
        out.skipped_dup += 1;
        return;
    }
    _ = try queue.submitWithSource(prefix, desc, "survival_act", priority, .material, 3, .survival_act);
    out.human_tasks += 1;
}

/// 从诊断报告执行有界补救。max_human 限制本轮人类任务数 (默认 1)。
pub fn applyFromReport(
    queue: *TaskQueue,
    memory: ?*Memory,
    io: ?std.Io,
    tick: u64,
    report: []const u8,
    max_human: u32,
) !ApplyResult {
    var out: ApplyResult = .{};
    if (report.len == 0) return out;

    const disk = std.mem.indexOf(u8, report, "disk near full") != null;
    const mem = std.mem.indexOf(u8, report, "memory pressure") != null;
    const load = std.mem.indexOf(u8, report, "load spike") != null;
    const crisis = disk or mem or load;
    if (!crisis) {
        out.throttle_autocli_s = HEALTHY_CLEAR;
        return out;
    }

    out.throttle_autocli_s = CRISIS_AUTOCLI_INTERVAL_S;

    var human_budget = max_human;
    if (disk and human_budget > 0) {
        try submitHumanAct(
            queue,
            "[act] human: free disk space",
            "GHW cannot delete files. Please: (1) clear caches/logs (2) empty Trash (3) move large archives off root. Then reply @task disk cleared.",
            10,
            &out,
        );
        human_budget -|= 1;
    }
    if (mem and human_budget > 0) {
        try submitHumanAct(
            queue,
            "[act] human: reduce memory footprint",
            "GHW will not kill processes. Please: (1) close heavy apps from top_procs scan (2) restart leaky services. Then reply @task mem ok.",
            9,
            &out,
        );
        human_budget -|= 1;
    }
    if (load and human_budget > 0) {
        try submitHumanAct(
            queue,
            "[act] human: investigate load spike",
            "GHW will not kill CPU hogs. Please: (1) identify runaway from scan (2) nice/isolate or stop safely. Then reply @task load ok.",
            9,
            &out,
        );
        human_budget -|= 1;
    }

    if (memory) |mem_ref| {
        if (io) |real_io| {
            var plan_buf: std.ArrayList(u8) = .empty;
            defer plan_buf.deinit(mem_ref.alloc);
            try plan_buf.print(mem_ref.alloc, "survival_act: throttle_autocli={d}s human_tasks={d} disk={} mem={} load={}", .{
                CRISIS_AUTOCLI_INTERVAL_S, out.human_tasks, disk, mem, load,
            });
            mem_ref.recordAt(real_io, .system_event, tick, plan_buf.items, report[0..@min(report.len, 300)], 1, 0) catch {};
            out.plan_written = true;
        }
    }
    return out;
}

/// 无报告时从 snapshot 决策 (健康 → 清 throttle)
pub fn applyFromSnapshot(
    queue: *TaskQueue,
    memory: ?*Memory,
    io: ?std.Io,
    tick: u64,
    snap: SystemSnapshot,
    max_human: u32,
) !ApplyResult {
    if (!survival_learn.isCrisisSnap(snap)) {
        return .{ .throttle_autocli_s = HEALTHY_CLEAR };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(queue.allocator);
    if (snap.disk_used_pct >= world_sensor.DISK_PCT_EPS)
        try buf.appendSlice(queue.allocator, "finding: disk near full\n");
    if (snap.mem_pct >= world_sensor.MEM_PCT_EPS)
        try buf.appendSlice(queue.allocator, "finding: memory pressure\n");
    if (snap.load_1m >= world_sensor.LOAD_EPS)
        try buf.appendSlice(queue.allocator, "finding: load spike\n");
    return applyFromReport(queue, memory, io, tick, buf.items, max_human);
}

const testing = std.testing;

test "survival_act: crisis throttles and submits one human task" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try applyFromReport(&q, null, null, 1, "finding: disk near full\n", 1);
    try testing.expect(r.throttle_autocli_s != null);
    try testing.expectEqual(CRISIS_AUTOCLI_INTERVAL_S, r.throttle_autocli_s.?);
    try testing.expectEqual(@as(u32, 1), r.human_tasks);
    try testing.expectEqual(Task.Source.survival_act, q.tasks.items[0].source);
    const r2 = try applyFromReport(&q, null, null, 2, "finding: disk near full\n", 1);
    try testing.expectEqual(@as(u32, 0), r2.human_tasks);
    try testing.expectEqual(@as(u32, 1), r2.skipped_dup);
}

test "survival_act: healthy clears throttle" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try applyFromReport(&q, null, null, 1, "all good", 1);
    try testing.expectEqual(@as(?u64, HEALTHY_CLEAR), r.throttle_autocli_s);
    try testing.expectEqual(@as(u32, 0), r.human_tasks);
}
