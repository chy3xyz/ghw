//! net_read — `std.Io.net.Stream.read` 的跨工具链替代。
//!
//! 背景 (2026-10 工具链漂移):
//!   - dev.2151:   `NetRead.Result = Error!usize`, `Stream.read` 直通。
//!   - 0.17.0 正式版: `NetRead.Result = Error!Stream.ReadResult` (struct, 含
//!     `data_len`), 且正式版 std 的 `Stream.read` 内部对 ReadResult 做位置解构
//!     (`const rc, _ = ...`), 正式版编译器拒绝该写法 —— 一调用就在 std 内部炸。
//!
//! 这里直接调 `io.operate`, 按载荷形状取字节数, 同一份代码在
//! dev.2151 与 0.17.0 正式版上都能编译。

const std = @import("std");
const testing = std.testing;

/// 从 payload 取读取字节数: usize 直通 (dev.2151), struct 取 `data_len` (0.17.0)。
fn extractDataLen(payload: anytype) usize {
    const P = @TypeOf(payload);
    if (comptime @typeInfo(P) == .@"struct") {
        return payload.data_len;
    }
    return payload;
}

/// 从 stream 读一段到 data (scatter 组), 返回读取字节数; peer 关闭返回 0。
pub fn readChunk(stream: *const std.Io.net.Stream, io: std.Io, data: [][]u8) !usize {
    const payload = try (try io.operate(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = data,
    } })).net_read;
    return extractDataLen(payload);
}

test "net_read: extractDataLen usize 直通 (dev.2151 形状)" {
    try testing.expectEqual(@as(usize, 7), extractDataLen(@as(usize, 7)));
}

test "net_read: extractDataLen ReadResult 取 data_len (0.17.0 形状)" {
    if (comptime !@hasDecl(std.Io.net.Stream, "ReadResult")) return error.SkipZigTest;
    const rr = std.Io.net.Stream.ReadResult{ .data_len = 9 };
    try testing.expectEqual(@as(usize, 9), extractDataLen(rr));
}

test "net_read: readChunk 本地 TCP 往返" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 候选端口探测 (避免 CI 冲突, 同 decision_bridge mock 模式)
    var port: ?u16 = null;
    for ([_]u16{ 19871, 19872, 19873, 19874 }) |p| {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", p) catch continue;
        var srv = address.listen(io, .{ .reuse_address = true }) catch continue;
        srv.deinit(io);
        port = p;
        break;
    }
    try testing.expect(port != null);

    const Ctx = struct {
        io: std.Io,
        port: u16,

        fn run(ctx: *@This()) void {
            ctx.serve() catch |err| {
                std.debug.print("[net_read-mock] serve 失败: {t}\n", .{err});
            };
        }

        fn serve(ctx: *@This()) !void {
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", ctx.port);
            var server = try address.listen(ctx.io, .{ .reuse_address = true });
            defer server.deinit(ctx.io);
            var stream = try server.accept(ctx.io);
            defer stream.close(ctx.io);

            var wbuf: [64]u8 = undefined;
            var w = stream.writer(ctx.io, &wbuf);
            try w.interface.writeAll("hello-ghw\n");
            try w.interface.flush();
        }
    };

    var ctx: Ctx = .{ .io = io, .port = port.? };
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port.?);
    // server 线程可能还没走到 listen (慢核/CI 上必现竞态): 连接重试而非直接失败
    var stream: ?std.Io.net.Stream = null;
    for (0..100) |_| {
        stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => {
                std.Thread.sleep(20 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }
    var conn = stream orelse return error.ConnectionRefused;
    defer conn.close(io);

    var buf: [64]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try readChunk(&conn, io, @constCast(&[_][]u8{buf[total..]}));
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n') != null) break;
    }
    thread.join();

    try testing.expectEqualStrings("hello-ghw", std.mem.trim(u8, buf[0..total], "\n"));
}
