//! GHW Link: 多 GHW 实例互联协议
//!
//! 设计:
//!   - Unix Domain Socket (本地, 零网络依赖)
//!   - JSONL 协议 (一行一个 request/response)
//!   - 单 socket 同时跑 server + client
//!
//! 协议 (5 个方法):
//!   ping            → {peer_id, version, uptime_s}
//!   query_state     → {tick, E, M, R, N, top_goal, action_count}
//!   query_beliefs   → [{text, source, confidence}, ...]
//!   query_actions   → [{id, tick, kind, result, duration_ms}, ...]
//!   inject_event    → 把一个事件写入 peer 的 episodes
//!
//! 用法:
//!   const Link = ghw_link.Link;
//!   var link = Link.init(alloc, io, "/tmp/ghw_a.sock");
//!   try link.startServer(handler_fn);  // 在另一线程
//!   const resp = try link.query("/tmp/ghw_b.sock", "ping", "{}");
//!
//! 这是 GHW 从"单机闭环" 走向 "多体共生" 的基础 — Phase 1

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const net_read = @import("../util/net_read.zig");

/// 协议版本 (不兼容时 bump)
pub const PROTOCOL_VERSION = "ghw-link/0.1";

/// 单条 JSONL 消息
pub const Message = struct {
    id: []const u8,
    method: []const u8,
    params: []const u8, // raw JSON
};

/// Server handler: 给定 method+params, 返回 ok+result JSON
/// 返回的 result 由 caller 拥有 (handler 应 alloc 后传出)
pub const Handler = *const fn (
    method: []const u8,
    params: []const u8,
    ctx: *anyopaque,
    alloc: Allocator,
) anyerror!Response;

pub const Response = struct {
    ok: bool,
    payload: []u8, // JSON value (object or array)

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.payload);
    }
};

/// 一个运行中的 GHW Link (server + 客户端 helper)
pub const Link = struct {
    alloc: Allocator,
    io: std.Io,
    /// 本地 socket 路径 (e.g. /tmp/ghw_a.sock)
    self_path: []const u8,
    /// peer_id 来自 self_path 的 basename
    peer_id: []const u8,

    pub fn init(alloc: Allocator, io: std.Io, self_path: []const u8) Link {
        // peer_id 来自 path 的 basename (去掉 /tmp/ghw_ 和 .sock)
        const basename = std.fs.path.basename(self_path);
        var id_start: usize = 0;
        if (std.mem.startsWith(u8, basename, "ghw_")) id_start = 4;
        const id_slice = if (std.mem.endsWith(u8, basename, ".sock"))
            basename[id_start .. basename.len - ".sock".len]
        else
            basename[id_start..];
        return .{
            .alloc = alloc,
            .io = io,
            .self_path = self_path,
            .peer_id = id_slice,
        };
    }

    /// 启动 server, 阻塞直到 stopped
    /// handler: 处理收到的 request, ctx 透传给 handler
    /// 应在独立线程里跑 (用 std.Thread.spawn)
    pub fn runServer(self: *Link, handler: Handler, ctx: *anyopaque, stop: *std.atomic.Value(bool)) !void {
        // 删旧 socket 文件 (如果有) — std.Io.Dir 的 deleteFileAbsolute 是顶层函数
        std.Io.Dir.deleteFileAbsolute(self.io, self.self_path) catch {};

        const ua = try std.Io.net.UnixAddress.init(self.self_path);
        var server = ua.listen(self.io, .{}) catch |err| {
            std.debug.print("[link] listen {s} 失败: {t}\n", .{ self.self_path, err });
            return err;
        };
        defer server.deinit(self.io);

        std.debug.print("[link] listening on {s} (peer_id={s})\n", .{ self.self_path, self.peer_id });

        while (!stop.load(.acquire)) {
            const conn = server.accept(self.io) catch |err| {
                if (stop.load(.acquire)) break;
                std.debug.print("[link] accept 失败: {t}\n", .{err});
                continue;
            };
            var stream: std.Io.net.Stream = conn;
            self.handleConnection(&stream, handler, ctx) catch |err| {
                std.debug.print("[link] handleConnection 失败: {t}\n", .{err});
            };
            stream.close(self.io);
        }
    }

    fn handleConnection(self: *Link, stream: *std.Io.net.Stream, handler: Handler, ctx: *anyopaque) !void {
        // 读完整一行 (JSONL), 假设 < 64KB
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = net_read.readChunk(stream, self.io, @constCast(&[_][]u8{buf[total..]})) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            total += n;
            // 找到 \n 就 break
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }
        const line = std.mem.trim(u8, buf[0..total], " \r\n\t");
        if (line.len == 0) return;

        // 解析: {"id":"...", "method":"...", "params":{...}}
        const id = extractString(line, "id") orelse "unknown";
        const method = extractString(line, "method") orelse "unknown";
        const params = extractObject(line, "params") orelse "{}";

        // 调 handler
        var resp = handler(method, params, ctx, self.alloc) catch Response{
            .ok = false,
            .payload = self.alloc.dupe(u8, "\"handler error\"") catch &[_]u8{},
        };
        defer resp.deinit(self.alloc);

        // 拼响应: {"id":"...","ok":true,"result":<payload>}
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.print(self.alloc, "{{\"id\":\"{s}\",\"ok\":{s},\"result\":{s}}}\n", .{ id, if (resp.ok) "true" else "false", resp.payload });
        // 写: 用 writer + 16B 缓冲
        var wbuf: [16]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(out.items);
        try w.interface.flush();
    }

    /// 客户端: 连接到 peer, 发 request, 读 1 行 response
    /// 返回 response payload (调用方 free)
    pub fn query(self: *const Link, peer_path: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
        const ua = try std.Io.net.UnixAddress.init(peer_path);
        var stream = try ua.connect(self.io);
        defer stream.close(self.io);

        // 发 request
        var req_buf: std.ArrayList(u8) = .empty;
        defer req_buf.deinit(self.alloc);
        try req_buf.print(self.alloc, "{{\"id\":\"q1\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params_json });
        var wbuf: [16]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(req_buf.items);
        try w.interface.flush();

        // 读 1 行
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = net_read.readChunk(&stream, self.io, @constCast(&[_][]u8{buf[total..]})) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            total += n;
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }
        const line = std.mem.trim(u8, buf[0..total], " \r\n\t");
        return self.alloc.dupe(u8, line);
    }

    /// 从 socket path 提取 peer_id (basename 去 .sock, 去 ghw_ 前缀)
    /// 例: /tmp/ghw_alpha.sock → alpha
    pub fn parsePeerId(self: *const Link, peer_path: []const u8) []const u8 {
        _ = self;
        const basename = std.fs.path.basename(peer_path);
        var id_start: usize = 0;
        if (std.mem.startsWith(u8, basename, "ghw_")) id_start = 4;
        if (std.mem.endsWith(u8, basename, ".sock")) {
            return basename[id_start .. basename.len - ".sock".len];
        }
        return basename[id_start..];
    }
};

// === helpers: 极简 JSON 解析, 只支持 flat object ===
// "id":"foo","method":"bar","params":{...} → 拿指定 key 的 string / object 值
// 不引入 JSON 解析器, 直接扫字符. 这是单机内部协议, 不会传不可信 JSON.

fn extractString(line: []const u8, key: []const u8) ?[]const u8 {
    // 找 "key":"
    var i: usize = 0;
    while (i + key.len + 4 < line.len) {
        if (line[i] == '"' and std.mem.eql(u8, line[i + 1 .. i + 1 + key.len], key) and line[i + 1 + key.len] == '"' and line[i + 2 + key.len] == ':' and line[i + 3 + key.len] == '"') {
            const start = i + 4 + key.len;
            // 找结束的 "
            var j: usize = start;
            while (j < line.len and line[j] != '"') : (j += 1) {}
            return line[start..j];
        }
        i += 1;
    }
    return null;
}

fn extractObject(line: []const u8, key: []const u8) ?[]const u8 {
    // 找 "key":{
    var i: usize = 0;
    while (i + key.len + 4 < line.len) {
        if (line[i] == '"' and std.mem.eql(u8, line[i + 1 .. i + 1 + key.len], key) and line[i + 1 + key.len] == '"' and line[i + 2 + key.len] == ':' and line[i + 3 + key.len] == '{') {
            const start = i + 3 + key.len;
            // 找匹配的 }
            var depth: i32 = 0;
            var j: usize = start;
            while (j < line.len) {
                if (line[j] == '{') depth += 1 else if (line[j] == '}') {
                    depth -= 1;
                    if (depth == 0) return line[start .. j + 1];
                }
                j += 1;
            }
        }
        i += 1;
    }
    return null;
}

// ===== 测试 =====
test "Link basics: extractString / extractObject" {
    const line =
        \\{"id":"req_42","method":"query_state","params":{"k":"v"}}
    ;
    try std.testing.expectEqualStrings("req_42", extractString(line, "id").?);
    try std.testing.expectEqualStrings("query_state", extractString(line, "method").?);
    try std.testing.expectEqualStrings("{\"k\":\"v\"}", extractObject(line, "params").?);
}

test "Link init derives peer_id" {
    const l = Link.init(std.testing.allocator, undefined, "/tmp/ghw_alpha.sock");
    try std.testing.expectEqualStrings("alpha", l.peer_id);
}

test "Link init handles no prefix" {
    const l = Link.init(std.testing.allocator, undefined, "/tmp/foo.sock");
    try std.testing.expectEqualStrings("foo", l.peer_id);
}
