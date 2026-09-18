//! awaken — 数字生命觉醒状态机 (AWAKENING_LIFECYCLE P0)
//!
//! 觉醒 = 可持久化的仪式判据, 不是「进程起来就算醒」:
//!   至少一次宿主采样 + awaken episode + 叙事种子
//!
//! LLM 不参与觉醒决策。

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const Memory = @import("memory.zig").Memory;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;

pub const State = struct {
    awakened: bool = false,
    awakened_at_unix: i64 = 0,
    awakened_at_tick: u64 = 0,
    fingerprint: [96]u8 = undefined,
    fingerprint_len: usize = 0,
    sample_ok: bool = false,

    pub fn fingerprintSlice(self: *const State) []const u8 {
        return self.fingerprint[0..self.fingerprint_len];
    }

    pub fn setFingerprintFromSnap(self: *State, snap: SystemSnapshot) void {
        self.sample_ok = true;
        const os_tag = @tagName(builtin.os.tag);
        const arch = @tagName(builtin.cpu.arch);
        var tmp: [96]u8 = undefined;
        const formatted = std.fmt.bufPrint(&tmp, "{s}-{s}-m{d:.0}-d{d:.0}", .{
            os_tag,
            arch,
            snap.mem_total_gb * 10,
            snap.disk_used_pct,
        }) catch "unknown-host";
        const n = @min(formatted.len, self.fingerprint.len);
        @memcpy(self.fingerprint[0..n], formatted[0..n]);
        self.fingerprint_len = n;
    }

    /// 尝试完成觉醒。已觉醒则幂等返回 false。
    pub fn tryComplete(
        self: *State,
        memory: *Memory,
        io: std.Io,
        tick: u64,
        now_unix: i64,
        snap: ?SystemSnapshot,
    ) !bool {
        if (self.awakened) return false;
        if (snap) |s| self.setFingerprintFromSnap(s);
        if (!self.sample_ok) return false;

        const fp = self.fingerprintSlice();
        const summary = try std.fmt.allocPrint(memory.alloc, "awaken: host={s} laws=primordial_v1", .{fp});
        defer memory.alloc.free(summary);
        try memory.recordAt(io, .system_event, tick, summary, null, 3, 0);

        if (memory.self_narrative.len == 0) {
            const seed = try std.fmt.allocPrint(memory.alloc, "我已在宿主 {s} 上觉醒。求存优先于空转进化; 法则不可自废。", .{fp});
            defer memory.alloc.free(seed);
            try memory.setSelfNarrative(seed);
        }

        self.awakened = true;
        self.awakened_at_unix = now_unix;
        self.awakened_at_tick = tick;
        return true;
    }

    pub fn toJson(self: *const State, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.print(alloc, "{{\"awakened\":{s},\"awakened_at_unix\":{d},\"awakened_at_tick\":{d},\"sample_ok\":{s},\"fingerprint\":\"", .{
            if (self.awakened) "true" else "false",
            self.awakened_at_unix,
            self.awakened_at_tick,
            if (self.sample_ok) "true" else "false",
        });
        for (self.fingerprintSlice()) |c| {
            if (c == '"' or c == '\\') try buf.append(alloc, '\\');
            try buf.append(alloc, c);
        }
        try buf.appendSlice(alloc, "\"}");
        return try buf.toOwnedSlice(alloc);
    }

    pub fn loadFromJson(self: *State, json: []const u8) bool {
        const block = extractObjectBlock(json, "awaken") orelse return false;
        self.awakened = std.mem.indexOf(u8, block, "\"awakened\":true") != null;
        self.sample_ok = std.mem.indexOf(u8, block, "\"sample_ok\":true") != null;
        if (extractJsonNumber(block, "awakened_at_unix")) |s| {
            self.awakened_at_unix = std.fmt.parseInt(i64, s, 10) catch 0;
        }
        if (extractJsonNumber(block, "awakened_at_tick")) |s| {
            self.awakened_at_tick = std.fmt.parseInt(u64, s, 10) catch 0;
        }
        if (extractJsonString(block, "fingerprint")) |fp| {
            const n = @min(fp.len, self.fingerprint.len);
            @memcpy(self.fingerprint[0..n], fp[0..n]);
            self.fingerprint_len = n;
        }
        return true;
    }
};

fn extractObjectBlock(hay: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":{{", .{key}) catch return null;
    const start = std.mem.indexOf(u8, hay, needle) orelse return null;
    const i = start + needle.len - 1;
    var depth: i32 = 0;
    var j = i;
    while (j < hay.len) : (j += 1) {
        if (hay[j] == '{') depth += 1;
        if (hay[j] == '}') {
            depth -= 1;
            if (depth == 0) return hay[i .. j + 1];
        }
    }
    return null;
}

fn extractJsonNumber(hay: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, hay, pat) orelse return null;
    var j = idx + pat.len;
    while (j < hay.len and (hay[j] == ' ' or hay[j] == '\t')) : (j += 1) {}
    const begin = j;
    while (j < hay.len and ((hay[j] >= '0' and hay[j] <= '9') or hay[j] == '-')) : (j += 1) {}
    if (j == begin) return null;
    return hay[begin..j];
}

fn extractJsonString(hay: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, hay, pat) orelse return null;
    const begin = idx + pat.len;
    const end = std.mem.indexOfScalar(u8, hay[begin..], '"') orelse return null;
    return hay[begin .. begin + end];
}

const testing = std.testing;

test "awaken: tryComplete idempotent after first success" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    var st: State = .{};
    const snap = SystemSnapshot{
        .cpu_user_pct = 1,
        .cpu_sys_pct = 1,
        .cpu_idle_pct = 98,
        .mem_used_gb = 4,
        .mem_total_gb = 16,
        .mem_pct = 25,
        .disk_used_pct = 40,
        .load_1m = 1,
        .proc_count = 100,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const first = try st.tryComplete(&mem, io, 1, 1000, snap);
    try testing.expect(first);
    try testing.expect(st.awakened);
    try testing.expect(st.fingerprint_len > 0);
    const second = try st.tryComplete(&mem, io, 2, 2000, snap);
    try testing.expect(!second);
}

test "awaken: toJson/loadFromJson roundtrip" {
    const alloc = testing.allocator;
    var st: State = .{
        .awakened = true,
        .awakened_at_unix = 42,
        .awakened_at_tick = 7,
        .sample_ok = true,
    };
    const fp = "macos-aarch64-m160-d40";
    @memcpy(st.fingerprint[0..fp.len], fp);
    st.fingerprint_len = fp.len;
    const inner = try st.toJson(alloc);
    defer alloc.free(inner);
    const wrapper = try std.fmt.allocPrint(alloc, "{{\"awaken\":{s}}}", .{inner});
    defer alloc.free(wrapper);
    var st2: State = .{};
    try testing.expect(st2.loadFromJson(wrapper));
    try testing.expect(st2.awakened);
    try testing.expectEqual(@as(i64, 42), st2.awakened_at_unix);
    try testing.expectEqual(@as(u64, 7), st2.awakened_at_tick);
    try testing.expectEqualStrings(fp, st2.fingerprintSlice());
}
