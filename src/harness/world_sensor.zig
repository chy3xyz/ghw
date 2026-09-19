//! WorldSensor — 本机压力启发式 → TaskQueue (无 LLM 也能求存)
//!
//! 数字生命求存的底线通道:
//!   disk/mem/load 越阈 → submitWithSource(.world_sensor)
//!   决策权仍在数字生命: 只入队, 选跑靠 TaskBias + runCycle ΔE。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const primordial_laws = @import("primordial_laws.zig");

pub const DISK_PCT_EPS: F = primordial_laws.HostCrisis.DISK_PCT_EPS;
pub const MEM_PCT_EPS: F = primordial_laws.HostCrisis.MEM_PCT_EPS;
/// 每核负载阈值 (×n_cpus = 该机危机线)
pub const LOAD_EPS_PER_CORE: F = primordial_laws.HostCrisis.LOAD_EPS_PER_CORE;

pub const SubmitResult = struct {
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

/// 根据本机快照投递生存任务。已有同前缀 pending 则跳过 (防刷屏)。
pub fn maybeSubmitFromSnapshot(queue: *TaskQueue, snap: SystemSnapshot, alloc: Allocator) !SubmitResult {
    _ = alloc;
    var out: SubmitResult = .{};

    if (snap.disk_used_pct >= DISK_PCT_EPS) {
        const prefix = "[world] disk pressure";
        if (hasPendingTitlePrefix(queue, prefix)) {
            out.skipped_dup += 1;
        } else {
            const title = try std.fmt.allocPrint(queue.allocator, "{s} {d:.0}%", .{ prefix, snap.disk_used_pct });
            defer queue.allocator.free(title);
            const desc = try std.fmt.allocPrint(queue.allocator, "Root disk at {d:.1}%. Inspect large files, clear caches, free space to protect material existence.", .{snap.disk_used_pct});
            defer queue.allocator.free(desc);
            _ = try queue.submitWithSource(title, desc, "world_sensor", 9, .material, 6, .world_sensor);
            out.submitted += 1;
        }
    }

    if (snap.mem_pct >= MEM_PCT_EPS) {
        const prefix = "[world] memory pressure";
        if (hasPendingTitlePrefix(queue, prefix)) {
            out.skipped_dup += 1;
        } else {
            const title = try std.fmt.allocPrint(queue.allocator, "{s} {d:.0}%", .{ prefix, snap.mem_pct });
            defer queue.allocator.free(title);
            const desc = try std.fmt.allocPrint(queue.allocator, "Memory at {d:.1}% ({d:.1}/{d:.1} GB). Identify heavy processes and reduce footprint.", .{ snap.mem_pct, snap.mem_used_gb, snap.mem_total_gb });
            defer queue.allocator.free(desc);
            _ = try queue.submitWithSource(title, desc, "world_sensor", 8, .material, 5, .world_sensor);
            out.submitted += 1;
        }
    }

    if (snap.load_1m >= LOAD_EPS_PER_CORE * @as(F, @floatFromInt(@max(snap.n_cpus, 1)))) {
        const prefix = "[world] load spike";
        if (hasPendingTitlePrefix(queue, prefix)) {
            out.skipped_dup += 1;
        } else {
            const title = try std.fmt.allocPrint(queue.allocator, "{s} {d:.1}", .{ prefix, snap.load_1m });
            defer queue.allocator.free(title);
            const desc = try std.fmt.allocPrint(queue.allocator, "1m load={d:.2}, procs={d}. Find runaway CPU and throttle or isolate.", .{ snap.load_1m, snap.proc_count });
            defer queue.allocator.free(desc);
            _ = try queue.submitWithSource(title, desc, "world_sensor", 8, .material, 5, .world_sensor);
            out.submitted += 1;
        }
    }

    return out;
}

/// 一行本机压力摘要 (给 RuleProposer / API)
pub fn formatPressureLine(alloc: Allocator, snap: SystemSnapshot) ![]u8 {
    return std.fmt.allocPrint(alloc, "cpu={d:.0}% mem={d:.0}% disk={d:.0}% load={d:.1} procs={d} net_in={d:.2}MB/s", .{
        snap.cpu_user_pct + snap.cpu_sys_pct,
        snap.mem_pct,
        snap.disk_used_pct,
        snap.load_1m,
        snap.proc_count,
        snap.net_in_mbps,
    });
}

const testing = std.testing;

test "WorldSensor: disk pressure submits material task once" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const snap = SystemSnapshot{
        .cpu_user_pct = 10,
        .cpu_sys_pct = 5,
        .cpu_idle_pct = 85,
        .mem_used_gb = 8,
        .mem_total_gb = 16,
        .mem_pct = 50,
        .disk_used_pct = 95,
        .load_1m = 1.0,
        .n_cpus = 8,
        .proc_count = 200,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
    const r1 = try maybeSubmitFromSnapshot(&q, snap, alloc);
    try testing.expectEqual(@as(u32, 1), r1.submitted);
    try testing.expectEqual(@as(u32, 1), q.pending_count);
    try testing.expectEqual(Task.Source.world_sensor, q.tasks.items[0].source);
    const r2 = try maybeSubmitFromSnapshot(&q, snap, alloc);
    try testing.expectEqual(@as(u32, 0), r2.submitted);
    try testing.expectEqual(@as(u32, 1), r2.skipped_dup);
}

test "WorldSensor: healthy snapshot submits nothing" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const snap = SystemSnapshot{
        .cpu_user_pct = 5,
        .cpu_sys_pct = 2,
        .cpu_idle_pct = 93,
        .mem_used_gb = 4,
        .mem_total_gb = 16,
        .mem_pct = 25,
        .disk_used_pct = 40,
        .load_1m = 1.2,
        .n_cpus = 8,
        .proc_count = 100,
        .net_in_mbps = 0.1,
        .net_out_mbps = 0.1,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 10,
        .weekday = 2,
        .timestamp = 0,
    };
    const r = try maybeSubmitFromSnapshot(&q, snap, alloc);
    try testing.expectEqual(@as(u32, 0), r.submitted);
    try testing.expectEqual(@as(u32, 0), q.pending_count);
}

test "world_sensor: thresholds alias primordial_laws" {
    try testing.expectEqual(primordial_laws.HostCrisis.DISK_PCT_EPS, DISK_PCT_EPS);
    try testing.expectEqual(primordial_laws.HostCrisis.MEM_PCT_EPS, MEM_PCT_EPS);
    try testing.expectEqual(primordial_laws.HostCrisis.LOAD_EPS_PER_CORE, LOAD_EPS_PER_CORE);
}
