//! peer_inbox — 同伴短板报告收件箱 (AWAKENING P2)
//!
//! 与产品轨 CoEvolutionRegistry 分轨: 这里只存求存向 shortfall。
//! LLM 不决定是否协助; 数字生命经 peer_symbiosis.learnFromShortfall 入队有界任务。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const host_shortfall = @import("host_shortfall.zig");
const state_json = @import("human_symbiosis/state_json.zig");

pub const CAPACITY: usize = 32;

pub const Entry = struct {
    peer_id: [64]u8 = undefined,
    peer_id_len: usize = 0,
    report: host_shortfall.Report = .{},
    received_at_tick: u64 = 0,
    received_at_unix: i64 = 0,

    pub fn peerId(self: *const Entry) []const u8 {
        return self.peer_id[0..self.peer_id_len];
    }

    pub fn setPeerId(self: *Entry, id: []const u8) void {
        const n = @min(id.len, self.peer_id.len);
        @memcpy(self.peer_id[0..n], id[0..n]);
        self.peer_id_len = n;
    }
};

pub const Inbox = struct {
    entries: [CAPACITY]Entry = undefined,
    len: usize = 0,
    next: usize = 0, // ring write cursor
    total_received: u32 = 0,

    pub fn push(self: *Inbox, peer_id: []const u8, report: host_shortfall.Report, tick: u64, now_unix: i64) void {
        // 同 peer 更新最新一条 (不占新槽)
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + CAPACITY - self.len + i) % CAPACITY;
            if (std.mem.eql(u8, self.entries[idx].peerId(), peer_id)) {
                self.entries[idx].report = report;
                self.entries[idx].received_at_tick = tick;
                self.entries[idx].received_at_unix = now_unix;
                self.total_received += 1;
                return;
            }
        }
        var e: Entry = .{};
        e.setPeerId(peer_id);
        e.report = report;
        e.received_at_tick = tick;
        e.received_at_unix = now_unix;
        self.entries[self.next] = e;
        self.next = (self.next + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
        self.total_received += 1;
    }

    pub fn count(self: *const Inbox) u32 {
        return @intCast(self.len);
    }

    pub fn crisisCount(self: *const Inbox) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + CAPACITY - self.len + i) % CAPACITY;
            if (self.entries[idx].report.host_crisis) n += 1;
        }
        return n;
    }

    /// 按接收顺序从旧到新遍历回调
    pub fn forEach(self: *const Inbox, ctx: anytype, comptime cb: fn (@TypeOf(ctx), *const Entry) void) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + CAPACITY - self.len + i) % CAPACITY;
            cb(ctx, &self.entries[idx]);
        }
    }

    pub fn toJson(self: *const Inbox, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.print(alloc, "{{\"total_received\":{d},\"entries\":[", .{self.total_received});
        var first = true;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + CAPACITY - self.len + i) % CAPACITY;
            const e = &self.entries[idx];
            if (!first) try buf.append(alloc, ',');
            first = false;
            try buf.print(alloc, "{{\"peer_id\":\"", .{});
            try state_json.writeJsonString(alloc, &buf, e.peerId());
            try buf.print(alloc, "\",\"tick\":{d},\"received_at_unix\":{d},\"report\":", .{
                e.received_at_tick, e.received_at_unix,
            });
            try host_shortfall.appendJson(alloc, &buf, e.report);
            try buf.append(alloc, '}');
        }
        try buf.appendSlice(alloc, "]}");
        return buf.toOwnedSlice(alloc);
    }

    pub fn loadFromJson(self: *Inbox, json: []const u8) !bool {
        const obj = state_json.extractObjectBlock(json, "peer_inbox") orelse return false;
        self.* = .{};
        if (state_json.extractJsonNumber(obj, "total_received")) |n| {
            self.total_received = @intCast(std.fmt.parseInt(u32, n, 10) catch 0);
        }
        const arr_key = std.mem.indexOf(u8, obj, "\"entries\"") orelse return true;
        const arr_start = std.mem.indexOfPos(u8, obj, arr_key, "[") orelse return true;
        const arr_end = state_json.findMatchingBracket(obj, arr_start) orelse return true;
        const arr = obj[arr_start + 1 .. arr_end];
        var i: usize = 0;
        while (i < arr.len) {
            const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
            const oe = state_json.findMatchingBrace(arr, os) orelse break;
            const one = arr[os .. oe + 1];
            const peer_id = extractPeerIdInline(one) orelse "unknown";
            const tick: u64 = if (state_json.extractJsonNumber(one, "tick")) |t|
                std.fmt.parseInt(u64, t, 10) catch 0
            else
                0;
            const now_u: i64 = if (state_json.extractJsonNumber(one, "received_at_unix")) |t|
                std.fmt.parseInt(i64, t, 10) catch 0
            else
                0;
            const report = host_shortfall.parseJson(one) orelse host_shortfall.Report{};
            self.push(peer_id, report, tick, now_u);
            i = oe + 1;
        }
        return true;
    }

    pub fn appendSummaryJson(self: *const Inbox, alloc: Allocator, body: *std.ArrayList(u8)) !void {
        try body.print(alloc,
            \\"peer_inbox":{{"count":{d},"crisis_count":{d},"total_received":{d}}}
        , .{ self.count(), self.crisisCount(), self.total_received });
    }

    /// 给 RuleProposer / 日志用的短摘要 (零分配)
    pub fn formatDigest(self: *const Inbox, buf: []u8) usize {
        if (self.len == 0) {
            const empty = "peers inbox=0";
            const n = @min(empty.len, buf.len);
            @memcpy(buf[0..n], empty[0..n]);
            return n;
        }
        var favored_m: u32 = 0;
        var favored_r: u32 = 0;
        var favored_n: u32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + CAPACITY - self.len + i) % CAPACITY;
            switch (self.entries[idx].report.favored_dim) {
                1 => favored_m += 1,
                2 => favored_r += 1,
                else => favored_n += 1,
            }
        }
        const written = std.fmt.bufPrint(buf, "peers inbox={d} crisis={d} total={d} dim_m={d}/r={d}/n={d}", .{
            self.count(), self.crisisCount(), self.total_received, favored_m, favored_r, favored_n,
        }) catch return 0;
        return written.len;
    }
};

fn extractPeerIdInline(one: []const u8) ?[]const u8 {
    const key = "\"peer_id\":\"";
    const pos = std.mem.indexOf(u8, one, key) orelse return null;
    const start = pos + key.len;
    const end = std.mem.indexOfPos(u8, one, start, "\"") orelse return null;
    return one[start..end];
}

const testing = std.testing;

test "peer_inbox: push update same peer" {
    var inbox: Inbox = .{};
    var r: host_shortfall.Report = .{ .host_crisis = true, .favored_dim = 1, .material = 0.5 };
    inbox.push("peer-a", r, 1, 100);
    r.material = 0.9;
    inbox.push("peer-a", r, 2, 200);
    try testing.expectEqual(@as(u32, 1), inbox.count());
    try testing.expectEqual(@as(u32, 2), inbox.total_received);
    try testing.expectApproxEqAbs(@as(F, 0.9), inbox.entries[0].report.material, 0.001);
}

test "peer_inbox: toJson/loadFromJson roundtrip" {
    const alloc = testing.allocator;
    var inbox: Inbox = .{};
    inbox.push("alpha", .{ .host_crisis = true, .favored_dim = 2, .representation = 0.4, .world_starve = true }, 5, 50);
    const j = try inbox.toJson(alloc);
    defer alloc.free(j);
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"peer_inbox\":{s}}}", .{j});
    defer alloc.free(wrapped);
    var inbox2: Inbox = .{};
    try testing.expect(try inbox2.loadFromJson(wrapped));
    try testing.expectEqual(@as(u32, 1), inbox2.count());
    try testing.expect(inbox2.entries[0].report.host_crisis);
    try testing.expectEqual(@as(u8, 2), inbox2.entries[0].report.favored_dim);
}

test "peer_inbox: formatDigest" {
    var inbox: Inbox = .{};
    var buf: [128]u8 = undefined;
    const n0 = inbox.formatDigest(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n0], "inbox=0") != null);
    inbox.push("p1", .{ .host_crisis = true, .favored_dim = 1 }, 1, 10);
    inbox.push("p2", .{ .host_crisis = false, .favored_dim = 2 }, 2, 20);
    const n1 = inbox.formatDigest(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "inbox=2") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "crisis=1") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "dim_m=1") != null);
}
