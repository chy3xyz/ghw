//! 这台电脑上的助手简报。
//!
//! 数字生命已经有本机快照。这里只把它翻译成人对人的一句现状和一句请求。
//! 不改存在度，不杀进程，不删文件。LLM 可以后来润色，事实以这里为准。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const primordial_laws = @import("primordial_laws.zig");

pub const Posture = enum { steady, ask };

pub const Facts = struct {
    mem_pct: F = 0,
    mem_used_gb: F = 0,
    mem_total_gb: F = 0,
    disk_pct: F = 0,
    load_1m: F = 0,
    n_cpus: u32 = 1,
    cpu_pct: F = 0,
    top_comm: []const u8 = "",
    top_cpu: F = 0,
    pending: u32 = 0,
    /// 和这个人的共生句。空则 JSON 里 with 为空。
    with_you: []const u8 = "",
    /// 自己归纳出的主题。空则不说。
    known: []const u8 = "",
};

pub const Brief = struct {
    posture: Posture,
    line: []u8,
    ask: []u8,

    pub fn deinit(self: *Brief, alloc: Allocator) void {
        alloc.free(self.line);
        alloc.free(self.ask);
        self.* = undefined;
    }
};

fn cpuCount(n: u32) u32 {
    return @max(n, 1);
}

fn diskHot(facts: Facts) bool {
    return facts.disk_pct >= primordial_laws.HostCrisis.DISK_PCT_EPS;
}

fn memHot(facts: Facts) bool {
    return facts.mem_pct >= primordial_laws.HostCrisis.MEM_PCT_EPS;
}

fn loadHot(facts: Facts) bool {
    const limit = primordial_laws.HostCrisis.LOAD_EPS_PER_CORE * @as(F, @floatFromInt(cpuCount(facts.n_cpus)));
    return facts.load_1m >= limit;
}

fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var i: usize = max;
    while (i > 0 and s[i] & 0xc0 == 0x80) : (i -= 1) {}
    return s[0..i];
}

pub fn compose(alloc: Allocator, facts: Facts) !Brief {
    const hot_disk = diskHot(facts);
    const hot_mem = memHot(facts);
    const hot_load = loadHot(facts);
    const posture: Posture = if (hot_disk or hot_mem or hot_load) .ask else .steady;
    const status: []const u8 = if (posture == .ask) "有点吃紧" else "稳得住";
    const n = cpuCount(facts.n_cpus);

    const line = if (facts.top_comm.len > 0)
        try std.fmt.allocPrint(alloc, "这台 Mac 现在{s}：内存 {d:.0}%（{d:.1}/{d:.1} GB），磁盘 {d:.0}%，负载 {d:.1}（{d} 核）。眼下最忙的是 {s}（CPU {d:.0}%）。", .{
            status,
            facts.mem_pct,
            facts.mem_used_gb,
            facts.mem_total_gb,
            facts.disk_pct,
            facts.load_1m,
            n,
            facts.top_comm,
            facts.top_cpu,
        })
    else
        try std.fmt.allocPrint(alloc, "这台 Mac 现在{s}：内存 {d:.0}%（{d:.1}/{d:.1} GB），磁盘 {d:.0}%，负载 {d:.1}（{d} 核）。", .{
            status,
            facts.mem_pct,
            facts.mem_used_gb,
            facts.mem_total_gb,
            facts.disk_pct,
            facts.load_1m,
            n,
        });
    const spoken = if (facts.known.len == 0) line else blk: {
        const both = std.fmt.allocPrint(alloc, "我在了解你正在做的 {s}。{s}", .{ facts.known, line }) catch |err| {
            alloc.free(line);
            return err;
        };
        alloc.free(line);
        break :blk both;
    };
    errdefer alloc.free(spoken);

    const ask = try composeAsk(alloc, facts, hot_disk, hot_mem, hot_load);
    return .{
        .posture = posture,
        .line = spoken,
        .ask = ask,
    };
}

fn composeAsk(alloc: Allocator, facts: Facts, hot_disk: bool, hot_mem: bool, hot_load: bool) ![]u8 {
    if (!hot_disk and !hot_mem and !hot_load) {
        if (facts.pending > 0) {
            return std.fmt.allocPrint(alloc, "你不用动手。我手头还有 {d} 件事，做完会留在任务里。", .{facts.pending});
        }
        return alloc.dupe(u8, "你不用动手。我继续看着这台电脑。");
    }
    if (hot_disk and hot_mem) {
        if (facts.top_comm.len > 0) {
            return std.fmt.allocPrint(alloc, "磁盘已经到 {d:.0}%。我不会删你的文件，请你自己清掉不需要的大目录。内存也到了 {d:.0}%，我不会替你结束进程。先看 {s} 能不能退出。", .{
                facts.disk_pct,
                facts.mem_pct,
                facts.top_comm,
            });
        }
        return std.fmt.allocPrint(alloc, "磁盘已经到 {d:.0}%。我不会删你的文件，请你自己清掉不需要的大目录。内存也到了 {d:.0}%，我不会替你结束进程。", .{
            facts.disk_pct,
            facts.mem_pct,
        });
    }
    if (hot_disk) {
        return std.fmt.allocPrint(alloc, "磁盘已经到 {d:.0}%。我不会删你的文件，请你自己清掉不需要的大目录。", .{facts.disk_pct});
    }
    if (hot_mem) {
        if (facts.top_comm.len > 0) {
            return std.fmt.allocPrint(alloc, "内存已经到 {d:.0}%。我不会替你结束进程。先看 {s} 能不能退出。", .{ facts.mem_pct, facts.top_comm });
        }
        return alloc.dupe(u8, "内存已经偏高。我不会替你结束进程。请你在活动监视器里看是谁占着机器。");
    }
    if (facts.top_comm.len > 0) {
        return std.fmt.allocPrint(alloc, "负载 {d:.1}，{d} 核已经饱和。我不会替你结束进程。先看 {s} 能不能放下。", .{
            facts.load_1m,
            cpuCount(facts.n_cpus),
            facts.top_comm,
        });
    }
    return std.fmt.allocPrint(alloc, "负载 {d:.1}，{d} 核已经饱和。我不会替你结束进程。请你在活动监视器里看是谁占着机器。", .{
        facts.load_1m,
        cpuCount(facts.n_cpus),
    });
}

pub fn replyTo(alloc: Allocator, facts: Facts, user_text: []const u8) ![]u8 {
    var brief = try compose(alloc, facts);
    defer brief.deinit(alloc);
    const said = clipUtf8(user_text, 48);
    return std.fmt.allocPrint(alloc, "你说「{s}」。{s}{s}", .{ said, brief.line, brief.ask });
}

fn appendEscaped(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            else => if (c < 0x20) try buf.print(alloc, "\\u{x:0>4}", .{c}) else try buf.append(alloc, c),
        }
    }
}

pub fn appendJson(alloc: Allocator, buf: *std.ArrayList(u8), facts: Facts) !void {
    var brief = try compose(alloc, facts);
    defer brief.deinit(alloc);
    try buf.appendSlice(alloc, "{\"posture\":\"");
    try buf.appendSlice(alloc, if (brief.posture == .ask) "ask" else "steady");
    try buf.appendSlice(alloc, "\",\"line\":\"");
    try appendEscaped(alloc, buf, brief.line);
    try buf.appendSlice(alloc, "\",\"ask\":\"");
    try appendEscaped(alloc, buf, brief.ask);
    try buf.appendSlice(alloc, "\",\"with\":\"");
    try appendEscaped(alloc, buf, facts.with_you);
    try buf.appendSlice(alloc, "\"}");
}

const testing = std.testing;

fn calmFacts() Facts {
    return .{
        .mem_pct = 40,
        .mem_used_gb = 6.4,
        .mem_total_gb = 16,
        .disk_pct = 55,
        .load_1m = 2.1,
        .n_cpus = 10,
        .cpu_pct = 18,
        .top_comm = "WindowServer",
        .top_cpu = 9,
    };
}

test "desk brief: steady machine tells the human not to act" {
    const alloc = testing.allocator;
    var brief = try compose(alloc, calmFacts());
    defer brief.deinit(alloc);
    try testing.expectEqual(Posture.steady, brief.posture);
    try testing.expect(std.mem.indexOf(u8, brief.line, "稳得住") != null);
    try testing.expect(std.mem.indexOf(u8, brief.line, "WindowServer") != null);
    try testing.expect(std.mem.indexOf(u8, brief.ask, "不用动手") != null);
}

test "desk brief: disk pressure asks the human and refuses to delete" {
    const alloc = testing.allocator;
    var facts = calmFacts();
    facts.disk_pct = 95;
    facts.mem_pct = 93;
    facts.top_comm = "clang";
    var brief = try compose(alloc, facts);
    defer brief.deinit(alloc);
    try testing.expectEqual(Posture.ask, brief.posture);
    try testing.expect(std.mem.indexOf(u8, brief.ask, "不会删") != null);
    try testing.expect(std.mem.indexOf(u8, brief.ask, "不会替你结束") != null);
    try testing.expect(std.mem.indexOf(u8, brief.ask, "clang") != null);
}

test "desk brief: json stays legal when the process name has a quote" {
    const alloc = testing.allocator;
    var facts = calmFacts();
    facts.top_comm = "a\"b";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try appendJson(alloc, &buf, facts);
    try testing.expect(std.mem.indexOf(u8, buf.items, "a\\\"b") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();
}
