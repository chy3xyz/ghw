//! state_contract — ui_server / daemon 共享 state.json 写锁契约 (AWAKENING P1)
//!
//! 嵌入 `"state_meta"` 块: writer + epoch + tick + updated_at。
//! 保存前读盘 meta; 若其他 writer 的 epoch 更新则拒绝覆盖 (防双写撕状态)。

const std = @import("std");
const Allocator = std.mem.Allocator;
const state_json = @import("human_symbiosis/state_json.zig");

pub const VERSION: u32 = 1;

pub const Writer = enum {
    unknown,
    ui_server,
    daemon,

    pub fn parse(s: []const u8) Writer {
        if (std.mem.eql(u8, s, "ui_server")) return .ui_server;
        if (std.mem.eql(u8, s, "daemon")) return .daemon;
        return .unknown;
    }

    pub fn label(self: Writer) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .ui_server => "ui_server",
            .daemon => "daemon",
        };
    }
};

pub const Meta = struct {
    version: u32 = VERSION,
    writer: Writer = .unknown,
    epoch: u64 = 0,
    tick: u64 = 0,
    updated_at_unix: i64 = 0,

    pub fn parseFromJson(json: []const u8, alloc: Allocator) !?Meta {
        const obj = state_json.extractObjectBlock(json, "state_meta") orelse return null;
        var out: Meta = .{};
        if (state_json.extractJsonNumber(obj, "version")) |v| {
            out.version = std.fmt.parseInt(u32, v, 10) catch VERSION;
        }
        if (state_json.extractJsonString(alloc, obj, "writer")) |w| {
            defer alloc.free(w);
            out.writer = Writer.parse(w);
        }
        if (state_json.extractJsonNumber(obj, "epoch")) |n| {
            out.epoch = std.fmt.parseInt(u64, n, 10) catch 0;
        }
        if (state_json.extractJsonNumber(obj, "tick")) |n| {
            out.tick = std.fmt.parseInt(u64, n, 10) catch 0;
        }
        if (state_json.extractJsonNumber(obj, "updated_at_unix")) |n| {
            out.updated_at_unix = std.fmt.parseInt(i64, n, 10) catch 0;
        }
        return out;
    }

    pub fn toJson(self: Meta, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc,
            \\{{"version":{d},"writer":"{s}","epoch":{d},"tick":{d},"updated_at_unix":{d}}}
        , .{ self.version, self.writer.label(), self.epoch, self.tick, self.updated_at_unix });
    }
};

pub const Conflict = enum {
    none,
    /// 磁盘 epoch 比本地 loaded 新且 writer 不同
    foreign_newer,
    /// 磁盘 epoch 比本地新 (同 writer 重启竞态)
    stale_local,

    pub fn label(self: Conflict) []const u8 {
        return switch (self) {
            .none => "none",
            .foreign_newer => "foreign_newer",
            .stale_local => "stale_local",
        };
    }
};

pub fn detectConflict(local: Meta, disk: Meta, our_writer: Writer) Conflict {
    if (disk.epoch == 0) return .none;
    if (disk.epoch <= local.epoch) return .none;
    if (disk.writer != our_writer and disk.writer != .unknown) return .foreign_newer;
    return .stale_local;
}

pub fn nextEpoch(local: Meta, disk: Meta) u64 {
    return @max(local.epoch, disk.epoch) + 1;
}

/// 原子写: path.tmp → rename(path)
pub fn writeAtomic(io: std.Io, alloc: Allocator, path: []const u8, json: []const u8) !void {
    const tmp_path = try alloc.alloc(u8, path.len + 4);
    defer alloc.free(tmp_path);
    @memcpy(tmp_path[0..path.len], path);
    @memcpy(tmp_path[path.len..][0..4], ".tmp");

    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, json);
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

pub fn mergeBlockIntoJson(alloc: Allocator, base_json: []const u8, field_name: []const u8, block_json: []const u8) ![]u8 {
    var end = base_json.len;
    while (end > 0 and (base_json[end - 1] == '\n' or base_json[end - 1] == ' ' or base_json[end - 1] == '\r')) end -= 1;
    if (end > 0 and base_json[end - 1] == '}') end -= 1;
    while (end > 0 and base_json[end - 1] == ' ') end -= 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_json[0..end]);
    try buf.print(alloc, ",\n  \"{s}\": ", .{field_name});
    try buf.appendSlice(alloc, block_json);
    try buf.appendSlice(alloc, "\n}\n");
    return buf.toOwnedSlice(alloc);
}

const testing = std.testing;

test "state_contract: epoch bump and foreign conflict" {
    const local: Meta = .{ .writer = .ui_server, .epoch = 3, .tick = 10 };
    const disk: Meta = .{ .writer = .daemon, .epoch = 5, .tick = 20 };
    try testing.expect(detectConflict(local, disk, .ui_server) == .foreign_newer);
    try testing.expectEqual(@as(u64, 6), nextEpoch(local, disk));

    const same: Meta = .{ .writer = .ui_server, .epoch = 4, .tick = 11 };
    try testing.expect(detectConflict(local, same, .ui_server) == .stale_local);
    try testing.expect(detectConflict(local, local, .ui_server) == .none);
}

test "state_contract: toJson/parseFromJson roundtrip" {
    const alloc = testing.allocator;
    const m: Meta = .{ .writer = .daemon, .epoch = 7, .tick = 99, .updated_at_unix = 1700 };
    const j = try m.toJson(alloc);
    defer alloc.free(j);
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"tick\":0,\"state_meta\":{s}}}", .{j});
    defer alloc.free(wrapped);
    const parsed = (try Meta.parseFromJson(wrapped, alloc)).?;
    try testing.expect(parsed.writer == .daemon);
    try testing.expectEqual(@as(u64, 7), parsed.epoch);
    try testing.expectEqual(@as(u64, 99), parsed.tick);
}
