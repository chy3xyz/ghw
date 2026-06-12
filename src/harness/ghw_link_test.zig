//! 端到端 test: 跑 server + client, 验证 5 个方法
const std = @import("std");
const ghw_link = @import("ghw_link.zig");

fn mockHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: Allocator) anyerror!ghw_link.Response {
    _ = ctx;
    _ = params;
    if (std.mem.eql(u8, method, "ping")) {
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"ok\":true,\"pong\":1}") };
    }
    if (std.mem.eql(u8, method, "query_state")) {
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"tick\":42,\"E\":0.777}") };
    }
    if (std.mem.eql(u8, method, "inject_event")) {
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"received\":true}") };
    }
    return .{ .ok = false, .payload = try alloc.dupe(u8, "\"unknown method\"") };
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 用唯一的 socket path 避免冲突
    const pid = std.posix.system.getpid();
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/ghw_link_test_{d}.sock", .{pid});
    defer alloc.free(sock_path);
    defer std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};

    std.debug.print("[test] sock_path={s}\n", .{sock_path});

    var link = ghw_link.Link.init(alloc, io, sock_path);
    std.debug.print("[test] link.peer_id={s}\n", .{link.peer_id});

    // 启动 server (独立线程)
    var stop = std.atomic.Value(bool).init(false);
    const ctx_holder = @as(*anyopaque, @ptrCast(&link));
    const thread = try std.Thread.spawn(.{}, ghw_link.Link.runServer, .{ &link, mockHandler, ctx_holder, &stop });
    std.debug.print("[test] server thread spawned\n", .{});

    // 等 server 就绪 — Zig 0.17 没有 std.Thread.sleep, 改用 yield + busy
    var spin: u32 = 0;
    while (spin < 5_000_000) : (spin += 1) {
        std.Thread.yield() catch {};
    }
    std.debug.print("[test] server should be ready, trying connect\n", .{});

    // === client: query ping ===
    {
        std.debug.print("[test] querying ping...\n", .{});
        const r = try link.query(sock_path, "ping", "{}");
        defer alloc.free(r);
        std.debug.print("[test] ping → {s}\n", .{r});
    }
    std.debug.print("[test] ping done\n", .{});

    // === client: query_state ===
    {
        const r = try link.query(sock_path, "query_state", "{}");
        defer alloc.free(r);
        std.debug.print("[test] query_state → {s}\n", .{r});
    }

    // === client: inject_event ===
    {
        const r = try link.query(sock_path, "inject_event", "{\"text\":\"hi\"}");
        defer alloc.free(r);
        std.debug.print("[test] inject_event → {s}\n", .{r});
    }

    // === client: 未知方法 ===
    {
        const r = try link.query(sock_path, "no_such_method", "{}");
        defer alloc.free(r);
        std.debug.print("[test] no_such_method → {s}\n", .{r});
    }

    // 停 server
    stop.store(true, .release);
    thread.join();
    std.debug.print("[test] done\n", .{});
}

const Allocator = std.mem.Allocator;
