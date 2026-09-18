//! metabolism — 高 E 代谢策略 (P5b)
//!
//! E 接近天花板时 ΔE 难涨; 改推「多样性求存」任务:
//!   - 同伴共生 (query_peer)
//!   - 人类价值触达
//!   - 世界景观扫描 (novelty)
//!
//! 只入队, 选跑仍靠 TaskBias + ΔE; 无 LLM 决策权。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const primordial_laws = @import("primordial_laws.zig");

pub const E_SATURATED: F = primordial_laws.ProposeTriggers.E_SATURATED;

pub const InjectResult = struct {
    submitted: u32 = 0,
    skipped_dup: u32 = 0,
    skipped_not_due: bool = false,
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
    title: []const u8,
    desc: []const u8,
    dim: Task.Dimension,
    priority: u8,
    out: *InjectResult,
) !void {
    if (hasPendingTitlePrefix(queue, title)) {
        out.skipped_dup += 1;
        return;
    }
    _ = try queue.submitWithSource(title, desc, "metabolism", priority, dim, 4, .metabolism);
    out.submitted += 1;
}

/// E 饱和且到点时注入代谢任务。最多 2 条; interval_ticks 内只触发一次 (由 caller 守 last_tick)。
pub fn maybeInject(
    queue: *TaskQueue,
    e: F,
    has_live_peers: bool,
    value_flat: bool,
    alloc: Allocator,
) !InjectResult {
    _ = alloc;
    var out: InjectResult = .{};
    if (e < E_SATURATED) {
        out.skipped_not_due = true;
        return out;
    }

    // 同伴优先 (有 live peer)
    if (has_live_peers and out.submitted < 2) {
        try submitOnce(
            queue,
            "[meta] seek peer symbiosis",
            "E saturated — query a live peer for state/beliefs and seek co-evolution, not more E grinding.",
            .nature,
            7,
            &out,
        );
    } else if (!has_live_peers and out.submitted < 2) {
        try submitOnce(
            queue,
            "[meta] await peer connection",
            "E saturated and lonely — register/connect a peer path; diversity beats idle high-E.",
            .nature,
            6,
            &out,
        );
    }

    if (value_flat and out.submitted < 2) {
        try submitOnce(
            queue,
            "[meta] sample human value",
            "Value trend flat at high E — invite human feedback or @task collaboration to raise symbiotic σ.",
            .representation,
            7,
            &out,
        );
    }

    if (out.submitted < 2) {
        try submitOnce(
            queue,
            "[meta] novelty world scan",
            "High-E metabolism: read-only process landscape for novelty (not more material grind).",
            .representation,
            5,
            &out,
        );
    }
    return out;
}

const testing = std.testing;

test "metabolism: low E skips inject" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try maybeInject(&q, 0.5, false, true, alloc);
    try testing.expect(r.skipped_not_due);
    try testing.expectEqual(@as(u32, 0), r.submitted);
}

test "metabolism: saturated injects up to 2" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try maybeInject(&q, 0.99, true, true, alloc);
    try testing.expectEqual(@as(u32, 2), r.submitted);
    try testing.expectEqual(Task.Source.metabolism, q.tasks.items[0].source);
    // 第二轮可能再补一条尚未入队的 novelty; 第三轮应全去重
    _ = try maybeInject(&q, 0.99, true, true, alloc);
    const r3 = try maybeInject(&q, 0.99, true, true, alloc);
    try testing.expectEqual(@as(u32, 0), r3.submitted);
}
