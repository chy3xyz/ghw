//! 先问再做。共生配置里写了必须先问的事，数字生命只能把请求挂在这里，等人批准。
//!
//! 只记录请求和人的决定，不执行。执行由调用方在批准之后做。

const std = @import("std");
const Allocator = std.mem.Allocator;
const state_json = @import("human_symbiosis/state_json.zig");

pub const MAX_ITEMS: usize = 50;

pub const Kind = enum {
    code,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .code => "code",
        };
    }
};

pub const Status = enum {
    pending,
    approved,
    denied,
    /// 批准了，但要写入的文件已经不在。
    missing,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .approved => "approved",
            .denied => "denied",
            .missing => "missing",
        };
    }

    fn parse(s: []const u8) ?Status {
        return std.meta.stringToEnum(Status, s);
    }
};

pub const Request = struct {
    id: u32,
    kind: Kind,
    path: []u8,
    summary: []u8,
    tick: u64,
    created_unix: i64,
    status: Status = .pending,
};

pub const DecideError = error{ NotFound, NotPending };

pub const AskFirst = struct {
    alloc: Allocator,
    items: std.ArrayList(Request) = .empty,
    next_id: u32 = 1,

    pub fn init(alloc: Allocator) AskFirst {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *AskFirst) void {
        for (self.items.items) |r| freeRequest(self.alloc, r);
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    /// 同一路径已有待批请求时返回原 id，不重复挂。
    pub fn ask(self: *AskFirst, kind: Kind, path: []const u8, summary: []const u8, tick: u64, now_unix: i64) !u32 {
        for (self.items.items) |r| {
            if (r.status == .pending and std.mem.eql(u8, r.path, path)) return r.id;
        }
        try self.makeRoom();
        const path_copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(path_copy);
        const summary_copy = try self.alloc.dupe(u8, summary);
        errdefer self.alloc.free(summary_copy);
        const id = self.next_id;
        try self.items.append(self.alloc, .{
            .id = id,
            .kind = kind,
            .path = path_copy,
            .summary = summary_copy,
            .tick = tick,
            .created_unix = now_unix,
        });
        self.next_id += 1;
        return id;
    }

    pub fn find(self: *AskFirst, id: u32) ?*Request {
        for (self.items.items) |*r| {
            if (r.id == id) return r;
        }
        return null;
    }

    pub fn pendingCount(self: *const AskFirst) u32 {
        var n: u32 = 0;
        for (self.items.items) |r| {
            if (r.status == .pending) n += 1;
        }
        return n;
    }

    /// 只把待批请求改成人的决定，返回该请求供调用方执行。
    pub fn decide(self: *AskFirst, id: u32, status: Status) DecideError!*Request {
        const r = self.find(id) orelse return DecideError.NotFound;
        if (r.status != .pending) return DecideError.NotPending;
        r.status = status;
        return r;
    }

    fn makeRoom(self: *AskFirst) !void {
        if (self.items.items.len < MAX_ITEMS) return;
        for (self.items.items, 0..) |r, i| {
            if (r.status != .pending) {
                const old = self.items.orderedRemove(i);
                freeRequest(self.alloc, old);
                return;
            }
        }
        const old = self.items.orderedRemove(0);
        freeRequest(self.alloc, old);
    }

    pub fn appendJson(self: *const AskFirst, alloc: Allocator, buf: *std.ArrayList(u8)) !void {
        try buf.print(alloc, "{{\"next_id\":{d},\"pending\":{d},\"items\":[", .{ self.next_id, self.pendingCount() });
        for (self.items.items, 0..) |r, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.print(alloc, "{{\"id\":{d},\"kind\":\"{s}\",\"status\":\"{s}\",\"tick\":{d},\"created_unix\":{d},\"path\":\"", .{
                r.id,
                r.kind.label(),
                r.status.label(),
                r.tick,
                r.created_unix,
            });
            try state_json.writeJsonString(alloc, buf, r.path);
            try buf.appendSlice(alloc, "\",\"summary\":\"");
            try state_json.writeJsonString(alloc, buf, r.summary);
            try buf.appendSlice(alloc, "\"}");
        }
        try buf.appendSlice(alloc, "]}");
    }

    /// 从 state.json 顶层的 "ask_first" 块恢复。没有该块返回 false。
    pub fn loadFromJson(self: *AskFirst, json: []const u8) !bool {
        const block = state_json.extractObjectBlock(json, "ask_first") orelse return false;
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, block, .{}) catch return false;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        for (self.items.items) |r| freeRequest(self.alloc, r);
        self.items.clearRetainingCapacity();
        const items = root.get("items") orelse return true;
        if (items != .array) return true;
        var max_id: u32 = 0;
        for (items.array.items) |v| {
            if (v != .object) continue;
            const o = v.object;
            const id = intField(o, "id") orelse continue;
            const path = strField(o, "path") orelse continue;
            const status = Status.parse(strField(o, "status") orelse "pending") orelse .pending;
            const path_copy = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(path_copy);
            const summary_copy = try self.alloc.dupe(u8, strField(o, "summary") orelse "");
            errdefer self.alloc.free(summary_copy);
            try self.items.append(self.alloc, .{
                .id = @intCast(id),
                .kind = .code,
                .path = path_copy,
                .summary = summary_copy,
                .tick = @intCast(intField(o, "tick") orelse 0),
                .created_unix = intField(o, "created_unix") orelse 0,
                .status = status,
            });
            max_id = @max(max_id, @as(u32, @intCast(id)));
        }
        const stored_next: u32 = @intCast(intField(root, "next_id") orelse 1);
        self.next_id = @max(stored_next, max_id + 1);
        return true;
    }
};

fn freeRequest(alloc: Allocator, r: Request) void {
    alloc.free(r.path);
    alloc.free(r.summary);
}

fn intField(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) n else null,
        else => null,
    };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "ask_first: same path asks once and only pending requests can be decided" {
    var q = AskFirst.init(testing.allocator);
    defer q.deinit();
    const a = try q.ask(.code, "src/harness/auto_eps/l5_1.zig", "L5", 1, 100);
    const again = try q.ask(.code, "src/harness/auto_eps/l5_1.zig", "L5", 2, 101);
    try testing.expectEqual(a, again);
    try testing.expectEqual(@as(u32, 1), q.pendingCount());
    const r = try q.decide(a, .denied);
    try testing.expectEqual(Status.denied, r.status);
    try testing.expectEqual(@as(u32, 0), q.pendingCount());
    try testing.expectError(DecideError.NotPending, q.decide(a, .approved));
    try testing.expectError(DecideError.NotFound, q.decide(99, .approved));
}

test "ask_first: state json roundtrip keeps decisions and the next id" {
    const alloc = testing.allocator;
    var q = AskFirst.init(alloc);
    defer q.deinit();
    _ = try q.ask(.code, "src/a\"b.zig", "第一条", 3, 10);
    const second = try q.ask(.code, "src/c.zig", "第二条", 4, 11);
    _ = try q.decide(second, .approved);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ask_first\":");
    try q.appendJson(alloc, &buf);
    try buf.append(alloc, '}');

    var back = AskFirst.init(alloc);
    defer back.deinit();
    try testing.expect(try back.loadFromJson(buf.items));
    try testing.expectEqual(@as(usize, 2), back.items.items.len);
    try testing.expectEqualStrings("src/a\"b.zig", back.items.items[0].path);
    try testing.expectEqual(Status.approved, back.find(second).?.status);
    try testing.expectEqual(q.next_id, back.next_id);
}
