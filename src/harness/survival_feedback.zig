//! survival_feedback — 求存规则效果反馈 (P8b)
//!
//! 主机危机下采纳规则后, 隔若干 tick 对比 disk/mem/load:
//!   改善 → 强化 [survive:*] 信念置信度 + 写 episode
//!   未改善 → 写 episode (不惩罚 E 公式)
//!
//! LLM 不决定; 只审计「提议是否对宿主压力有用」。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Memory = @import("memory.zig").Memory;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const survival_learn = @import("survival_learn.zig");
const primordial_laws = @import("primordial_laws.zig");

pub const EVAL_DELAY_TICKS: u64 = primordial_laws.SurvivalObservability.FEEDBACK_EVAL_DELAY_TICKS;
pub const IMPROVE_DISK_EPS: F = primordial_laws.SurvivalObservability.IMPROVE_DISK_EPS;
pub const IMPROVE_MEM_EPS: F = primordial_laws.SurvivalObservability.IMPROVE_MEM_EPS;
pub const IMPROVE_LOAD_EPS: F = primordial_laws.SurvivalObservability.IMPROVE_LOAD_EPS;

pub const EvalResult = struct {
    improved: bool = false,
    disk_delta: F = 0,
    mem_delta: F = 0,
    load_delta: F = 0,
    beliefs_boosted: u32 = 0,
};

pub const Tracker = struct {
    pending: bool = false,
    tick_marked: u64 = 0,
    rules_at_mark: u32 = 0,
    baseline_disk: F = 0,
    baseline_mem: F = 0,
    baseline_load: F = 0,

    pub fn markAfterCrisisRules(self: *Tracker, snap: SystemSnapshot, tick: u64, accepted_rules: u32) void {
        if (accepted_rules == 0) return;
        if (!survival_learn.isCrisisSnap(snap)) return;
        self.pending = true;
        self.tick_marked = tick;
        self.rules_at_mark = accepted_rules;
        self.baseline_disk = snap.disk_used_pct;
        self.baseline_mem = snap.mem_pct;
        self.baseline_load = snap.load_1m;
    }

    pub fn maybeEvaluate(
        self: *Tracker,
        snap: SystemSnapshot,
        tick: u64,
        memory: ?*Memory,
        io: ?std.Io,
    ) !?EvalResult {
        if (!self.pending) return null;
        if (tick < self.tick_marked +% EVAL_DELAY_TICKS) return null;

        var out: EvalResult = .{
            .disk_delta = self.baseline_disk - snap.disk_used_pct,
            .mem_delta = self.baseline_mem - snap.mem_pct,
            .load_delta = self.baseline_load - snap.load_1m,
        };
        out.improved = out.disk_delta >= IMPROVE_DISK_EPS or
            out.mem_delta >= IMPROVE_MEM_EPS or
            out.load_delta >= IMPROVE_LOAD_EPS;

        self.pending = false;

        if (memory) |mem| {
            if (out.improved) {
                out.beliefs_boosted = boostSurviveBeliefs(mem, 0.05);
            }
            if (io) |real_io| {
                const summary = try std.fmt.allocPrint(mem.alloc, "survival_feedback: improved={} diskΔ={d:.1} memΔ={d:.1} loadΔ={d:.2} rules={d}", .{
                    out.improved, out.disk_delta, out.mem_delta, out.load_delta, self.rules_at_mark,
                });
                defer mem.alloc.free(summary);
                mem.recordAt(real_io, .system_event, tick, summary, null, 1, if (out.improved) @as(F, 0.02) else @as(F, -0.005)) catch {};
            }
        }
        return out;
    }
};

fn boostSurviveBeliefs(memory: *Memory, delta: F) u32 {
    var n: u32 = 0;
    for (memory.beliefs.items) |*b| {
        if (!std.mem.startsWith(u8, b.text, "[survive:")) continue;
        b.confidence = @min(1.0, b.confidence + delta);
        n += 1;
    }
    return n;
}

const testing = std.testing;

fn sampleSnap(disk: F, mem: F, load: F) SystemSnapshot {
    return .{
        .cpu_user_pct = 10,
        .cpu_sys_pct = 5,
        .cpu_idle_pct = 85,
        .mem_used_gb = 8,
        .mem_total_gb = 16,
        .mem_pct = mem,
        .disk_used_pct = disk,
        .load_1m = load,
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
}

test "survival_feedback: mark and improve after delay" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.addBeliefAt(.material, "[survive:disk] test", 0.5, &[_]u64{1}, 1);

    var tr: Tracker = .{};
    tr.markAfterCrisisRules(sampleSnap(95, 50, 1), 10, 2);
    try testing.expect(tr.pending);

    const early = try tr.maybeEvaluate(sampleSnap(90, 50, 1), 12, &mem, null);
    try testing.expect(early == null);

    const ev = try tr.maybeEvaluate(sampleSnap(90, 50, 1), 30, &mem, null);
    try testing.expect(ev != null);
    try testing.expect(ev.?.improved);
    try testing.expect(ev.?.beliefs_boosted >= 1);
    try testing.expect(!tr.pending);
}

test "survival_feedback: no mark when not crisis" {
    var tr: Tracker = .{};
    tr.markAfterCrisisRules(sampleSnap(40, 30, 1), 5, 3);
    try testing.expect(!tr.pending);
}
