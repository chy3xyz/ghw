//! ProductAdapter — product-facing execution adapters for approved changes.
//!
//! The runtime owns governance. Adapters own side effects. This first adapter is
//! intentionally small: it writes a JSON config file that a host product can read
//! or watch. It gives `applyApproved` a real, verifiable side effect without
//! binding GHW to a specific SaaS backend.

const std = @import("std");
const product_runtime = @import("product_runtime.zig");

const Allocator = std.mem.Allocator;
const ChangeProposal = product_runtime.ChangeProposal;
const ProductAdapter = product_runtime.ProductAdapter;

pub const FileConfigAdapter = struct {
    alloc: Allocator,
    io: std.Io,
    path: []const u8,

    pub fn init(alloc: Allocator, io: std.Io, path: []const u8) !FileConfigAdapter {
        const abs = if (std.fs.path.isAbsolute(path))
            try alloc.dupe(u8, path)
        else blk: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_len = try std.process.currentPath(io, &cwd_buf);
            break :blk try std.fs.path.join(alloc, &.{ cwd_buf[0..cwd_len], path });
        };
        return .{
            .alloc = alloc,
            .io = io,
            .path = abs,
        };
    }

    pub fn deinit(self: *FileConfigAdapter) void {
        self.alloc.free(self.path);
    }

    pub fn asAdapter(self: *FileConfigAdapter) ProductAdapter {
        return .{
            .ctx = @ptrCast(self),
            .validateFn = validate,
            .applyFn = apply,
            .verifyFn = verify,
            .rollbackFn = rollback,
        };
    }

    fn validate(ctx: *anyopaque, change: *const ChangeProposal) !void {
        const self: *FileConfigAdapter = @ptrCast(@alignCast(ctx));
        if (self.path.len == 0) return error.InvalidAdapterPath;
        if (change.target.len == 0) return error.InvalidChangeTarget;
        if (change.status != .approved) return error.ChangeNotApproved;
    }

    fn apply(ctx: *anyopaque, change: *const ChangeProposal) !void {
        const self: *FileConfigAdapter = @ptrCast(@alignCast(ctx));
        try self.writeChange(change, "applied");
    }

    fn verify(ctx: *anyopaque, change: *const ChangeProposal) !void {
        const self: *FileConfigAdapter = @ptrCast(@alignCast(ctx));
        const file = try std.Io.Dir.openFileAbsolute(self.io, self.path, .{ .mode = .read_only });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > 1024 * 1024) return error.AdapterStateTooLarge;
        const buf = try self.alloc.alloc(u8, stat.size);
        defer self.alloc.free(buf);
        _ = try std.Io.File.readStreaming(file, self.io, &.{buf});
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\"change_id\":{d}", .{change.id});
        if (std.mem.indexOf(u8, buf, needle) == null) return error.AdapterVerifyFailed;
        if (std.mem.indexOf(u8, buf, "\"status\":\"applied\"") == null) return error.AdapterVerifyFailed;
    }

    fn rollback(ctx: *anyopaque, change: *const ChangeProposal) !void {
        const self: *FileConfigAdapter = @ptrCast(@alignCast(ctx));
        try self.writeChange(change, "rolled_back");
    }

    fn writeChange(self: *FileConfigAdapter, change: *const ChangeProposal, status: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.print(self.alloc, "{{\"adapter\":\"file_config\",\"status\":\"{s}\",\"change_id\":{d},\"tenant_id\":\"", .{
            status,
            change.id,
        });
        try writeJsonString(self.alloc, &buf, change.tenant_id);
        try buf.appendSlice(self.alloc, "\",\"kind\":\"");
        try buf.appendSlice(self.alloc, @tagName(change.kind));
        try buf.appendSlice(self.alloc, "\",\"target\":\"");
        try writeJsonString(self.alloc, &buf, change.target);
        try buf.appendSlice(self.alloc, "\",\"summary\":\"");
        try writeJsonString(self.alloc, &buf, change.summary);
        try buf.appendSlice(self.alloc, "\"}\n");

        const file = try std.Io.Dir.createFileAbsolute(self.io, self.path, .{});
        defer file.close(self.io);
        try std.Io.File.writeStreamingAll(file, self.io, buf.items);
    }
};

fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) try buf.print(alloc, "\\u{x:0>4}", .{c}) else try buf.append(alloc, c),
        }
    }
}

const testing = std.testing;

test "FileConfigAdapter: apply writes and verify reads change" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/ghw_product_adapter_test.json";
    var adapter = try FileConfigAdapter.init(alloc, io, path);
    defer adapter.deinit();

    const change = ChangeProposal{
        .id = 9,
        .tenant_id = "acme",
        .kind = .workflow,
        .target = "crm.followup",
        .summary = "tighten followup",
        .rationale = "test",
        .expected_delta_k = 0.1,
        .affected_users = 10,
        .reversible = true,
        .tier = .minor,
        .risk = .{ .severity = 0.1, .blast = 0.1, .reversibility = 0.0 },
        .timeout_seconds = 0,
        .required_approvers = "",
        .status = .approved,
        .created_at = 1,
    };
    const v = adapter.asAdapter();
    try v.validate(&change);
    try v.apply(&change);
    try v.verify(&change);
    try v.rollback(&change);
}
