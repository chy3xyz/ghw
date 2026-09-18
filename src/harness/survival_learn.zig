//! survival_learn — 诊断/补救结果 → 信念写回 (P4)
//!
//! 把 host finding 提炼成 material 信念 + system_event episode,
//! 供 RuleProposer / Reflection / chat 连续记忆使用。
//! 决策权不变: 只写认知, 不改 E 公式、不执行破坏性动作。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Memory = @import("memory.zig").Memory;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const primordial_laws = @import("primordial_laws.zig");

pub const LearnResult = struct {
    beliefs_added: u32 = 0,
    episodes_added: u32 = 0,
    crisis: bool = false,
};

pub fn isCrisisSnap(snap: SystemSnapshot) bool {
    return primordial_laws.isHostCrisis(snap.disk_used_pct, snap.mem_pct, snap.load_1m);
}

pub fn isCrisisReport(report: []const u8) bool {
    return std.mem.indexOf(u8, report, "disk near full") != null or
        std.mem.indexOf(u8, report, "memory pressure") != null or
        std.mem.indexOf(u8, report, "load spike") != null;
}

fn hasBeliefPrefix(memory: *const Memory, prefix: []const u8) bool {
    for (memory.beliefs.items) |b| {
        if (std.mem.startsWith(u8, b.text, prefix)) return true;
    }
    return false;
}

fn addUniqueBelief(
    memory: *Memory,
    tick: u64,
    prefix: []const u8,
    text: []const u8,
    confidence: F,
    out: *LearnResult,
) !void {
    if (hasBeliefPrefix(memory, prefix)) return;
    try memory.addBeliefAt(.material, text, confidence, &[_]u64{tick}, tick);
    out.beliefs_added += 1;
}

/// 从诊断/扫描报告提炼求存信念 (+ 可选 episode)
pub fn learnFromReport(
    memory: *Memory,
    io: ?std.Io,
    tick: u64,
    report: []const u8,
    delta_e: F,
) !LearnResult {
    var out: LearnResult = .{};
    if (report.len == 0) return out;
    out.crisis = isCrisisReport(report);

    if (std.mem.indexOf(u8, report, "disk near full") != null) {
        try addUniqueBelief(
            memory,
            tick,
            "[survive:disk]",
            "[survive:disk] Root disk near full — free space before material existence collapses.",
            0.85,
            &out,
        );
    }
    if (std.mem.indexOf(u8, report, "memory pressure") != null) {
        try addUniqueBelief(
            memory,
            tick,
            "[survive:mem]",
            "[survive:mem] Host memory pressure — avoid new heavy allocations; identify RSS hogs read-only.",
            0.85,
            &out,
        );
    }
    if (std.mem.indexOf(u8, report, "load spike") != null) {
        try addUniqueBelief(
            memory,
            tick,
            "[survive:load]",
            "[survive:load] Load spike — prefer peer collaboration / isolate runaway CPU (no kills from GHW).",
            0.80,
            &out,
        );
    }
    // 补救扫描也写一条轻信念 (有 top_procs 证据)
    if (std.mem.indexOf(u8, report, "top_procs") != null or std.mem.indexOf(u8, report, "[scan_world]") != null) {
        try addUniqueBelief(
            memory,
            tick,
            "[survive:scan]",
            "[survive:scan] Process landscape scanned after host stress — use facts, not guesses.",
            0.70,
            &out,
        );
    }
    if (std.mem.indexOf(u8, report, "[query_peer]") != null and std.mem.indexOf(u8, report, "response:") != null) {
        try addUniqueBelief(
            memory,
            tick,
            "[survive:peer]",
            "[survive:peer] Peer state queried under host stress — symbiotic load sharing is available.",
            0.75,
            &out,
        );
    }

    if (out.beliefs_added > 0) {
        if (io) |real_io| {
            const summary = try std.fmt.allocPrint(memory.alloc, "survival learn: +{d} beliefs crisis={}", .{
                out.beliefs_added, out.crisis,
            });
            defer memory.alloc.free(summary);
            const detail_clip = if (report.len > 400) report[0..400] else report;
            memory.recordAt(real_io, .system_event, tick, summary, detail_clip, 1, delta_e) catch {};
            out.episodes_added = 1;
        }
    }
    return out;
}

const testing = std.testing;

test "survival_learn: disk finding adds unique belief once" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    const report = "finding: disk near full — free caches\n";
    const r1 = try learnFromReport(&mem, null, 10, report, -0.01);
    try testing.expectEqual(@as(u32, 1), r1.beliefs_added);
    try testing.expect(r1.crisis);
    try testing.expectEqual(@as(usize, 1), mem.beliefs.items.len);
    const r2 = try learnFromReport(&mem, null, 11, report, 0);
    try testing.expectEqual(@as(u32, 0), r2.beliefs_added);
    try testing.expectEqual(@as(usize, 1), mem.beliefs.items.len);
}

test "survival_learn: isCrisisSnap thresholds" {
    var snap = SystemSnapshot{
        .cpu_user_pct = 5,
        .cpu_sys_pct = 2,
        .cpu_idle_pct = 93,
        .mem_used_gb = 4,
        .mem_total_gb = 16,
        .mem_pct = 25,
        .disk_used_pct = 40,
        .load_1m = 1.0,
        .proc_count = 100,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 10,
        .weekday = 1,
        .timestamp = 0,
    };
    try testing.expect(!isCrisisSnap(snap));
    snap.disk_used_pct = 95;
    try testing.expect(isCrisisSnap(snap));
}

test "survival_learn: scan report adds scan belief" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 2);
    defer mem.deinit();
    const report =
        \\[scan_world] task="[remedy] scan disk"
        \\top_procs (read-only):
        \\  - chrome cpu=12.0% mem=8.0%
    ;
    const r = try learnFromReport(&mem, null, 5, report, 0.01);
    try testing.expectEqual(@as(u32, 1), r.beliefs_added);
    try testing.expect(!r.crisis);
}
