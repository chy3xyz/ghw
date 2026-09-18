//! peer_symbiosis — query_peer 结果写回 (P7)
//!
//! 历史缺口: TaskExecutor.query_peer 拿到响应后只进 task output,
//! 不更新 peer_E_avg / 信念 / 后续共生任务。
//!
//! 本模块:
//!   1. 从 response JSON 抽 E/M/R/N
//!   2. 写 nature 信念 (去重前缀)
//!   3. 可选入队有界 follow-up (向更强学习 / 支援更弱)
//!
//! 决策权仍在数字生命: 只写认知+入队; σ/adaptFromPeers 由 ui 用 peer_E 更新。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Memory = @import("memory.zig").Memory;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;

pub const GAP_LEARN: F = 0.08;
pub const GAP_SUPPORT: F = 0.12;

pub const Insight = struct {
    peer_e: F = 0,
    peer_m: F = 0,
    peer_r: F = 0,
    peer_n: F = 0,
    parsed: bool = false,
    beliefs_added: u32 = 0,
    followups: u32 = 0,
};

fn extractFloatField(hay: []const u8, key: []const u8) F {
    // key 如 "\"E\":"
    var i: usize = 0;
    while (i + key.len < hay.len) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + key.len], key)) {
            var j = i + key.len;
            while (j < hay.len and (hay[j] == ' ' or hay[j] == '\t')) : (j += 1) {}
            var end = j;
            while (end < hay.len and (hay[end] == '.' or hay[end] == '-' or (hay[end] >= '0' and hay[end] <= '9'))) : (end += 1) {}
            if (end > j) return std.fmt.parseFloat(F, hay[j..end]) catch 0;
            return 0;
        }
    }
    return 0;
}

/// 从 query_state 类 JSON 抽 E/M/R/N
pub fn parseStatePayload(resp: []const u8) Insight {
    var out: Insight = .{};
    out.peer_e = extractFloatField(resp, "\"E\":");
    if (out.peer_e < 0.01) out.peer_e = extractFloatField(resp, "\"e\":");
    out.peer_m = extractFloatField(resp, "\"M\":");
    if (out.peer_m < 0.01) out.peer_m = extractFloatField(resp, "\"material\":");
    out.peer_r = extractFloatField(resp, "\"R\":");
    if (out.peer_r < 0.01) out.peer_r = extractFloatField(resp, "\"representation\":");
    out.peer_n = extractFloatField(resp, "\"N\":");
    if (out.peer_n < 0.01) out.peer_n = extractFloatField(resp, "\"nature\":");
    out.parsed = out.peer_e >= 0.01;
    return out;
}

fn responseSlice(report: []const u8) []const u8 {
    if (std.mem.indexOf(u8, report, "response: ")) |idx| {
        return report[idx + "response: ".len ..];
    }
    return report;
}

fn hasBeliefPrefix(memory: *const Memory, prefix: []const u8) bool {
    for (memory.beliefs.items) |b| {
        if (std.mem.startsWith(u8, b.text, prefix)) return true;
    }
    return false;
}

fn hasPendingTitlePrefix(queue: *const TaskQueue, prefix: []const u8) bool {
    for (queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        if (std.mem.startsWith(u8, t.title, prefix)) return true;
    }
    return false;
}

/// 从 query_peer 报告学习 + 可选 follow-up
pub fn learnFromReport(
    memory: ?*Memory,
    io: ?std.Io,
    tick: u64,
    report: []const u8,
    own_e: F,
    queue: ?*TaskQueue,
) !Insight {
    var out = parseStatePayload(responseSlice(report));
    if (!out.parsed) return out;

    if (memory) |mem| {
        const prefix = "[peer:symbiosis]";
        if (!hasBeliefPrefix(mem, prefix)) {
            const gap = out.peer_e - own_e;
            const text = try std.fmt.allocPrint(mem.alloc, "{s} Peer E={d:.3} M={d:.3} R={d:.3} N={d:.3} (own E={d:.3}, gap={d:.3}). Prefer co-evolution over solitary E grind.", .{
                prefix, out.peer_e, out.peer_m, out.peer_r, out.peer_n, own_e, gap,
            });
            defer mem.alloc.free(text);
            try mem.addBeliefAt(.nature, text, 0.80, &[_]u64{tick}, tick);
            out.beliefs_added = 1;
            if (io) |real_io| {
                const summary = try std.fmt.allocPrint(mem.alloc, "peer_symbiosis: E={d:.3} gap={d:.3}", .{ out.peer_e, gap });
                defer mem.alloc.free(summary);
                mem.recordAt(real_io, .peer_discovered, tick, summary, report[0..@min(report.len, 400)], 3, gap) catch {};
            }
        }
    }

    if (queue) |q| {
        if (out.peer_e > own_e + GAP_LEARN) {
            const prefix = "[peer] learn from stronger";
            if (!hasPendingTitlePrefix(q, prefix)) {
                _ = try q.submitWithSource(
                    prefix,
                    "Peer has higher E — query beliefs/actions and adopt compatible practices (read-only).",
                    "peer_symbiosis",
                    6,
                    .nature,
                    3,
                    .peer_symbiosis,
                );
                out.followups += 1;
            }
        } else if (own_e > out.peer_e + GAP_SUPPORT) {
            const prefix = "[peer] support weaker companion";
            if (!hasPendingTitlePrefix(q, prefix)) {
                _ = try q.submitWithSource(
                    prefix,
                    "Peer E is lower — share state via query and invite co-evolution (no remote mutation).",
                    "peer_symbiosis",
                    6,
                    .nature,
                    3,
                    .peer_symbiosis,
                );
                out.followups += 1;
            }
        }
    }
    return out;
}

/// 从同伴 shortfall 报告学习: 写信念 + 可选有界协助任务 (不改对方状态)
pub const ShortfallLearn = struct {
    beliefs_added: u32 = 0,
    followups: u32 = 0,
};

pub fn learnFromShortfall(
    memory: ?*Memory,
    queue: ?*TaskQueue,
    peer_id: []const u8,
    report: @import("host_shortfall.zig").Report,
    tick: u64,
) !ShortfallLearn {
    var out: ShortfallLearn = .{};
    if (!report.hasSignal() and !report.host_crisis) return out;

    const dim = @import("host_shortfall.zig").dimName(report.favored_dim);
    if (memory) |mem| {
        var prefix_buf: [96]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "[peer:shortfall:{s}]", .{peer_id});
        if (!hasBeliefPrefix(mem, prefix)) {
            const text = try std.fmt.allocPrint(mem.alloc, "{s} Peer shortfall crisis={} favored={s} M={d:.2} R={d:.2} N={d:.2}. Assist via local tasks only (no remote mutation).", .{
                prefix,
                report.host_crisis,
                dim,
                report.material,
                report.representation,
                report.nature,
            });
            defer mem.alloc.free(text);
            const belief_dim: @import("memory.zig").BeliefSource = switch (report.favored_dim) {
                1 => .material,
                2 => .representation,
                else => .nature,
            };
            try mem.addBeliefAt(belief_dim, text, 0.75, &[_]u64{tick}, tick);
            out.beliefs_added = 1;
        }
    }

    if (queue) |q| {
        if (report.host_crisis or report.favored_dim != 0) {
            var title_buf: [80]u8 = undefined;
            const title = try std.fmt.bufPrint(&title_buf, "[peer] shortfall assist {s}", .{peer_id});
            if (!hasPendingTitlePrefix(q, title)) {
                const req_dim: Task.Dimension = switch (report.favored_dim) {
                    1 => .material,
                    2 => .representation,
                    3 => .nature,
                    else => .all,
                };
                const desc = try std.fmt.allocPrint(q.allocator, "Peer {s} reports shortfall favored={s} crisis={}. Local bounded help only.", .{
                    peer_id, dim, report.host_crisis,
                });
                defer q.allocator.free(desc);
                _ = try q.submitWithSource(title, desc, "peer_symbiosis", 7, req_dim, 3, .peer_symbiosis);
                out.followups = 1;
            }
        }
    }
    return out;
}

const testing = std.testing;

test "peer_symbiosis: parseStatePayload extracts E" {
    const raw =
        \\{"ok":true,"E":0.87,"M":0.6,"R":0.5,"N":0.7,"tick":12}
    ;
    const ins = parseStatePayload(raw);
    try testing.expect(ins.parsed);
    try testing.expectApproxEqAbs(@as(F, 0.87), ins.peer_e, 0.001);
    try testing.expectApproxEqAbs(@as(F, 0.6), ins.peer_m, 0.001);
}

test "peer_symbiosis: learn adds belief and followup when gap large" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const report =
        \\[query_peer] task="seek peer"
        \\response: {"E":0.95,"M":0.8,"R":0.7,"N":0.9}
    ;
    const ins = try learnFromReport(&mem, null, 5, report, 0.70, &q);
    try testing.expect(ins.parsed);
    try testing.expectEqual(@as(u32, 1), ins.beliefs_added);
    try testing.expectEqual(@as(u32, 1), ins.followups);
    try testing.expectEqual(Task.Source.peer_symbiosis, q.tasks.items[0].source);
}

test "peer_symbiosis: learnFromShortfall enqueues assist" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r: @import("host_shortfall.zig").Report = .{
        .host_crisis = true,
        .favored_dim = 1,
        .material = 0.8,
        .disk_hot = true,
    };
    const out = try learnFromShortfall(&mem, &q, "bravo", r, 9);
    try testing.expectEqual(@as(u32, 1), out.beliefs_added);
    try testing.expectEqual(@as(u32, 1), out.followups);
    try testing.expect(std.mem.startsWith(u8, q.tasks.items[0].title, "[peer] shortfall assist"));
}
