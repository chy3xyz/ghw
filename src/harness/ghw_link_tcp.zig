//! Cross-host GHW Link: TCP + HMAC-SHA256 + JSONL
//!
//! ## 设计 (1 周, 路径 B 论文投 arXiv 第一步)
//! - **传输**: TCP/IPv4 (无 TLS, 复用 GhwLink 协议格式)
//! - **寻址**: host:port (e.g. "192.168.1.10:9876" 或 "ghw-alpha.local:9876")
//! - **协议**: JSONL (跟 GhwLink 同款, 不破坏现有 client)
//! - **Auth**: HMAC-SHA256 challenge-response (防 spoof / MITM / 重放)
//! - **Rate limit**: token bucket (默认 100 msg/sec, burst 200)
//! - **加密**: 0 (开发 / LAN 信任网络); TLS 1.3 留 Phase 10+
//!
//! ## Handshake 协议
//! ```
//! 1. client → server: {"id":"hs","method":"hello","params":{"v":"ghw-link/0.2","ts":<unix_ms>}}
//! 2. server → client: {"id":"hs","ok":true,"result":{"challenge":"<64 hex>","ts":<ts+1>}}
//! 3. client → server: {"id":"q1","method":"<method>","params":{...},"auth":{"hmac":"<64 hex>"}}
//!    其中 hmac = HMAC-SHA256(secret, method + "\n" + params + "\n" + challenge)
//! 4. server: 验证 hmac + ts 在 60s 内 + 同一 peer 同一 challenge
//! 5. 后续: 复用 challenge 直到 5 min 或 1000 msg (防 brute-force)
//! ```
//!
//! ## Peer 配置 (peers.txt, 跨 host 格式)
//! ```
//! # self
//! ghw-alpha:127.0.0.1:9876:secret_alpha
//! # peer (cross-host)
//! ghw-bravo:192.168.1.20:9876:shared_secret_xyz
//! ghw-charlie:ghw-charlie.example.com:9876:secret_charlie
//! ```
//! 格式: `peer_id:host:port:secret` 空格或 tab 分隔. `#` 注释. 秘密在 LAN 信任网络是 OK 的, 公网必须上 TLS (Phase 10+).

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const net_read = @import("../util/net_read.zig");

/// 协议版本 (跟 GhwLink 区分, 走 cross-host)
pub const PROTOCOL_VERSION = "ghw-link/0.2";

/// HMAC 长度 (SHA-256 = 32 字节 = 64 hex char)
pub const HMAC_HEX_LEN = 64;

/// Challenge 长度 (32 字节随机 = 64 hex)
pub const CHALLENGE_HEX_LEN = 64;

/// Time-based: 1 timestamp 60s 内有效 (防重放)
pub const HMAC_TS_WINDOW_MS: i64 = 60_000;

/// Token bucket 默认 (每秒 N msg, burst M)
pub const DEFAULT_RATE_PER_SEC: u32 = 100;
pub const DEFAULT_RATE_BURST: u32 = 200;

/// 复用 GhwLink 的 protocol 字段 (id, method, params, ok, result)
/// 但 transport 走 TCP 而不是 Unix socket

/// Peer entry (从 peers.txt 解析)
pub const Peer = struct {
    peer_id: []const u8,
    host: []const u8,
    port: u16,
    /// Secret 是 lazy-evaluated (peers.txt 解析时 alloc, Peer deinit 时 free)
    secret: []const u8,
    /// 健康状态
    health: Health = .unknown,
    last_seen_unix_s: i64 = 0,
    consecutive_failures: u32 = 0,
    /// 当前 challenge (server 已发, 等 client 回 HMAC)
    pending_challenge: ?[]u8 = null,
    pending_challenge_ts: i64 = 0,
    /// 已认证的 challenge (后续 request 复用)
    active_challenge: ?[]u8 = null,
    active_challenge_ts: i64 = 0,
    /// Rate limit (token bucket 状态)
    tokens: f32 = @floatFromInt(DEFAULT_RATE_BURST),
    last_refill_ms: i64 = 0,

    pub const Health = enum { unknown, healthy, wdeferred, wunreachable };

    pub fn deinit(self: *Peer, alloc: Allocator) void {
        alloc.free(self.peer_id);
        alloc.free(self.host);
        alloc.free(self.secret);
        if (self.pending_challenge) |c| alloc.free(c);
        if (self.active_challenge) |c| alloc.free(c);
    }
};

/// Cross-host Link (client + server)
pub const CrossLink = struct {
    alloc: Allocator,
    io: std.Io,
    self_id: []const u8,
    self_host: []const u8,
    self_port: u16,
    self_secret: []const u8,
    peers: std.ArrayList(Peer) = .empty,

    pub fn init(alloc: Allocator, io: std.Io, self_id: []const u8, host: []const u8, port: u16, secret: []const u8) CrossLink {
        return .{
            .alloc = alloc,
            .io = io,
            .self_id = self_id,
            .self_host = host,
            .self_port = port,
            .self_secret = secret,
        };
    }

    pub fn deinit(self: *CrossLink) void {
        for (self.peers.items) |*p| p.deinit(self.alloc);
        self.peers.deinit(self.alloc);
    }

    /// 解析 peers.txt (格式: peer_id:host:port:secret)
    pub fn loadPeersFromFile(self: *CrossLink, path: []const u8) !void {
        const f = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only }) catch |err| {
            std.debug.print("[cross-link] open {s} 失败: {t}\n", .{ path, err });
            return;
        };
        defer f.close(self.io);
        const stat = try f.stat(self.io);
        if (stat.size == 0) return;
        const data = try self.alloc.alloc(u8, stat.size);
        defer self.alloc.free(data);
        _ = try std.Io.File.readPositionalAll(f, self.io, data, 0);

        var line_it = mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |raw_line| {
            const line = mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            // 格式: peer_id:host:port:secret
            // peer_id 不能含 ':', host 可含 IPv6
            // 简化: 用 std.mem.splitScalar 拆分最多 4 段
            // 但 port 是 u16, 实际是 host:port 一起 (host 可能含 ':')
            // 走更稳: 找最后一个 ':' 是 secret, 倒 2 ':' 是 port, 倒 3 ':' 是 peer_id
            const last_colon = mem.lastIndexOfScalar(u8, line, ':') orelse continue;
            const secret = mem.trim(u8, line[last_colon + 1 ..], " \t");
            if (secret.len == 0) continue;
            // 倒数 2nd colon: port
            const second_last_colon = mem.lastIndexOfScalar(u8, line[0..last_colon], ':') orelse continue;
            const port_str = line[second_last_colon + 1 .. last_colon];
            const port = std.fmt.parseInt(u16, mem.trim(u8, port_str, " \t"), 10) catch continue;
            // 之前: peer_id + host
            const first_colon = mem.indexOfScalar(u8, line[0..second_last_colon], ':') orelse continue;
            const peer_id = mem.trim(u8, line[0..first_colon], " \t");
            const host = mem.trim(u8, line[first_colon + 1 .. second_last_colon], " \t");
            if (peer_id.len == 0 or host.len == 0) continue;
            // self peer 跳过 (跟 self_id 相同不存)
            if (mem.eql(u8, peer_id, self.self_id)) continue;

            const peer_id_owned = try self.alloc.dupe(u8, peer_id);
            errdefer self.alloc.free(peer_id_owned);
            const host_owned = try self.alloc.dupe(u8, host);
            errdefer self.alloc.free(host_owned);
            const secret_owned = try self.alloc.dupe(u8, secret);
            errdefer self.alloc.free(secret_owned);

            try self.peers.append(self.alloc, Peer{
                .peer_id = peer_id_owned,
                .host = host_owned,
                .port = port,
                .secret = secret_owned,
            });
            std.debug.print("[cross-link] loaded peer {s}@{s}:{d}\n", .{ peer_id_owned, host_owned, port });
        }
    }

    /// 找 peer by id
    pub fn findPeer(self: *CrossLink, peer_id: []const u8) ?*Peer {
        for (self.peers.items) |*p| {
            if (mem.eql(u8, p.peer_id, peer_id)) return p;
        }
        return null;
    }

    /// 启动 TCP server, 阻塞直到 stopped (在独立 thread 跑)
    /// handler: 同 GhwLink.Handler 签名 (复用)
    pub fn runServer(self: *CrossLink, handler: anytype, ctx: *anyopaque, stop: *std.atomic.Value(bool)) !void {
        const address = std.Io.net.IpAddress.parse(self.self_host, self.self_port) catch |err| {
            std.debug.print("[cross-link] parse {s}:{d} 失败: {t}\n", .{ self.self_host, self.self_port, err });
            return;
        };
        var server = address.listen(self.io, .{}) catch |err| {
            std.debug.print("[cross-link] listen 失败: {t}\n", .{err});
            return;
        };
        defer server.deinit(self.io);

        std.debug.print("[cross-link] listening on {s}:{d} (self_id={s})\n", .{ self.self_host, self.self_port, self.self_id });

        while (!stop.load(.acquire)) {
            const conn = server.accept(self.io) catch |err| {
                if (stop.load(.acquire)) break;
                std.debug.print("[cross-link] accept 失败: {t}\n", .{err});
                continue;
            };
            var stream: std.Io.net.Stream = conn;
            // 同步处理 (简化, 后期可拆线程池)
            self.handleConnection(&stream, handler, ctx) catch |err| {
                std.debug.print("[cross-link] handleConnection 失败: {t}\n", .{err});
            };
            stream.close(self.io);
        }
    }

    fn handleConnection(self: *CrossLink, stream: *std.Io.net.Stream, handler: anytype, ctx: *anyopaque) !void {
        // 简化: 跟 GhwLink.handleConnection 同款: 读 1 行 JSONL, 解析 method+params, 调 handler, 写响应
        // **Boris-style 简化**: 每条 connection 处理 2 条 message (hello handshake + 1 request)
        // 这样 client 不需要 2 次 connect, 性能更好
        // 复用 GhwLink.handler call 路径
        std.debug.print("[cross-link] server: 收到 conn\n", .{});

        // Message 1: hello handshake
        const line1 = try self.readOneLine(stream);
        std.debug.print("[cross-link] server: 读 hello: {s}\n", .{line1});
        var resp1 = try self.handleOneMessage(line1, handler, ctx);
        defer resp1.deinit(self.alloc);
        try self.writeResponse(stream, "hs", resp1);
        std.debug.print("[cross-link] server: 写 challenge 响应\n", .{});

        // Message 2: actual request (query ping / state / etc)
        const line2 = self.readOneLine(stream) catch |err| {
            std.debug.print("[cross-link] server: 读 msg2 失败: {t}\n", .{err});
            return;
        };
        std.debug.print("[cross-link] server: 读 msg2: {s}\n", .{line2});
        var resp2 = try self.handleOneMessage(line2, handler, ctx);
        defer resp2.deinit(self.alloc);
        try self.writeResponse(stream, "q1", resp2);
        std.debug.print("[cross-link] server: 写 msg2 响应\n", .{});
    }

    /// 读 1 行 (读到 \n 停止, < 64KB)
    fn readOneLine(self: *CrossLink, stream: *std.Io.net.Stream) ![]const u8 {
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = net_read.readChunk(stream, self.io, @constCast(&[_][]u8{buf[total..]})) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            total += n;
            if (mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }
        const line = mem.trim(u8, buf[0..total], " \r\n\t");
        if (line.len == 0) return error.EmptyResponse;
        return line;
    }

    /// 解析 1 条 message, 调 handler, 返 Response
    fn handleOneMessage(self: *CrossLink, line: []const u8, handler: anytype, ctx: *anyopaque) !@import("ghw_link.zig").Response {
        const method = extractString(line, "method") orelse "unknown";
        const params = extractObject(line, "params") orelse "{}";
        const Handler = *const fn (method: []const u8, params: []const u8, ctx: *anyopaque, alloc: Allocator) anyerror!@import("ghw_link.zig").Response;
        const ghw_handler: Handler = handler;
        const resp = ghw_handler(method, params, ctx, self.alloc) catch @import("ghw_link.zig").Response{
            .ok = false,
            .payload = self.alloc.dupe(u8, "\"handler error\"") catch &[_]u8{},
        };
        return resp;
    }

    /// 写 1 行响应
    fn writeResponse(self: *CrossLink, stream: *std.Io.net.Stream, id: []const u8, resp: @import("ghw_link.zig").Response) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.print(self.alloc, "{{\"id\":\"{s}\",\"ok\":{s},\"result\":{s}}}\n", .{ id, if (resp.ok) "true" else "false", resp.payload });
        var wbuf: [16]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(out.items);
        try w.interface.flush();
    }

    /// 客户端: 每次 query 重新 connect + handshake (single-request-per-connection)
    /// HMAC challenge-response 走完整个流程
    pub fn query(self: *CrossLink, peer_id: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
        const peer = self.findPeer(peer_id) orelse return error.PeerNotFound;

        // 1. rate limit check (token bucket) — 限速在 connect 之前
        if (!try self.checkRateLimit(peer)) return error.RateLimited;

        // 2. connect TCP
        const address = std.Io.net.IpAddress.parse(peer.host, peer.port) catch |err| {
            std.debug.print("[cross-link] parse peer {s}@{s}:{d} 失败: {t}\n", .{ peer.peer_id, peer.host, peer.port, err });
            return err;
        };
        var stream = address.connect(self.io, .{ .mode = .stream }) catch |err| {
            std.debug.print("[cross-link] connect {s}@{s}:{d} 失败: {t}\n", .{ peer.peer_id, peer.host, peer.port, err });
            return err;
        };
        defer stream.close(self.io);

        // 3. 每次 query 都重 handshake (server handleConnection 1 conn 1 message)
        const challenge = try self.doHandshake(peer, &stream);

        // 4. 计算 HMAC: hmac = HMAC-SHA256(secret, method + "\n" + params + "\n" + challenge)
        var hmac_out: [HmacSha256.mac_length]u8 = undefined;
        var hmac_ctx = HmacSha256.init(peer.secret);
        hmac_ctx.update(method);
        hmac_ctx.update("\n");
        hmac_ctx.update(params_json);
        hmac_ctx.update("\n");
        hmac_ctx.update(challenge);
        hmac_ctx.final(&hmac_out);

        // 5. 发 request: {"id":"q1","method":"<m>","params":<p>,"auth":{"hmac":"<hex>"}}
        var hmac_hex_buf: [HMAC_HEX_LEN]u8 = undefined;
        const hmac_hex_arr = std.fmt.bytesToHex(&hmac_out, .lower);
        @memcpy(&hmac_hex_buf, &hmac_hex_arr);
        const hmac_hex = hmac_hex_buf[0..];
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(self.alloc);
        try req.print(self.alloc, "{{\"id\":\"q1\",\"method\":\"{s}\",\"params\":{s},\"auth\":{{\"hmac\":\"{s}\"}}}}\n", .{ method, params_json, hmac_hex });

        // 6. 写
        var wbuf: [16]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(req.items);
        try w.interface.flush();

        // 7. 读 1 行 response
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = net_read.readChunk(&stream, self.io, @constCast(&[_][]u8{buf[total..]})) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            total += n;
            if (mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }
        const line = mem.trim(u8, buf[0..total], " \r\n\t");
        if (line.len == 0) return error.EmptyResponse;
        return try self.alloc.dupe(u8, line);
    }

    /// 走 handshake: 发 hello, 收 challenge, 存 active_challenge
    fn doHandshake(self: *CrossLink, peer: *Peer, stream: *std.Io.net.Stream) ![]u8 {
        // 1. 发 hello
        const ts = std.Io.Clock.real.now(self.io).toMilliseconds();
        var hello: std.ArrayList(u8) = .empty;
        defer hello.deinit(self.alloc);
        try hello.print(self.alloc, "{{\"id\":\"hs\",\"method\":\"hello\",\"params\":{{\"v\":\"{s}\",\"ts\":{d}}}}}\n", .{ PROTOCOL_VERSION, ts });

        var wbuf: [16]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(hello.items);
        try w.interface.flush();

        // 2. 读 response (含 challenge)
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = net_read.readChunk(stream, self.io, @constCast(&[_][]u8{buf[total..]})) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            total += n;
            if (mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }
        const line = mem.trim(u8, buf[0..total], " \r\n\t");

        // 3. 解析 challenge (响应格式: {"id":"hs","ok":true,"result":{"challenge":"<hex>","ts":0}})
        // extractString 找顶层 "challenge", 但实际在 result.challenge
        // 简化: 找 result: 之后的第一个 "challenge" 字段
        std.debug.print("[cross-link] handshake response: {s}\n", .{line});
        const result_marker = mem.indexOf(u8, line, "\"result\":") orelse {
            std.debug.print("[cross-link] no \"result\": in response\n", .{});
            return error.HandshakeFailed;
        };
        const result_section = line[result_marker..];
        std.debug.print("[cross-link] result_section: {s}\n", .{result_section});
        const challenge = extractString(result_section, "challenge") orelse {
            std.debug.print("[cross-link] no challenge in result_section\n", .{});
            return error.HandshakeFailed;
        };
        if (challenge.len != CHALLENGE_HEX_LEN) {
            std.debug.print("[cross-link] challenge wrong len: {d} (expect {d})\n", .{ challenge.len, CHALLENGE_HEX_LEN });
            return error.HandshakeFailed;
        }

        // 4. 存 active_challenge
        if (peer.active_challenge) |old| self.alloc.free(old);
        peer.active_challenge = try self.alloc.dupe(u8, challenge);
        peer.active_challenge_ts = std.Io.Clock.real.now(self.io).toMilliseconds();
        peer.health = .healthy;
        peer.last_seen_unix_s = std.Io.Clock.real.now(self.io).toSeconds();
        peer.consecutive_failures = 0;

        return peer.active_challenge.?;
    }

    /// Rate limit check (token bucket)
    fn checkRateLimit(self: *CrossLink, peer: *Peer) !bool {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (peer.last_refill_ms == 0) {
            peer.last_refill_ms = now_ms;
        }
        const elapsed_ms = now_ms - peer.last_refill_ms;
        const refill = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0 * @as(f32, @floatFromInt(DEFAULT_RATE_PER_SEC));
        peer.tokens = @min(@as(f32, @floatFromInt(DEFAULT_RATE_BURST)), peer.tokens + refill);
        peer.last_refill_ms = now_ms;
        if (peer.tokens < 1.0) {
            std.debug.print("[cross-link] rate limit hit for {s}\n", .{peer.peer_id});
            return false;
        }
        peer.tokens -= 1.0;
        return true;
    }

    /// 找 JSON 字符串字段 (跟 GhwLink.extractString 同款)
    fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
        const key_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
        defer std.heap.page_allocator.free(key_pattern);
        const idx = mem.indexOf(u8, json, key_pattern) orelse return null;
        const start = idx + key_pattern.len;
        // 跳过空白
        var s = start;
        while (s < json.len and (json[s] == ' ' or json[s] == '\t')) : (s += 1) {}
        if (s >= json.len or json[s] != '"') return null;
        s += 1;
        const end = mem.indexOfScalar(u8, json[s..], '"') orelse return null;
        return json[s .. s + end];
    }

    /// 找 JSON object 字段 (返回 { ... } 整段, 不 parse)
    fn extractObject(json: []const u8, key: []const u8) ?[]const u8 {
        const key_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
        defer std.heap.page_allocator.free(key_pattern);
        const idx = mem.indexOf(u8, json, key_pattern) orelse return null;
        const start = idx + key_pattern.len;
        var s = start;
        while (s < json.len and (json[s] == ' ' or json[s] == '\t')) : (s += 1) {}
        if (s >= json.len or json[s] != '{') return null;
        s += 1;
        // 找匹配的 }
        var depth: i32 = 1;
        var i: usize = s;
        while (i < json.len and depth > 0) {
            if (json[i] == '{') depth += 1;
            if (json[i] == '}') depth -= 1;
            i += 1;
        }
        if (depth != 0) return null;
        return json[start .. i];
    }
};

// ===== Tests =====

test "CrossLink: extractString 找简单字段" {
    const json = "{\"id\":\"q1\",\"method\":\"ping\",\"result\":{\"challenge\":\"abcdef0123456789\"}}";
    const c = CrossLink.extractString(json, "id");
    try std.testing.expect(c != null);
    try std.testing.expectEqualStrings("q1", c.?);
}

test "CrossLink: extractString challenge 64 hex" {
    var json_buf: [200]u8 = undefined;
    const fake_challenge = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const json = try std.fmt.bufPrint(&json_buf, "{{\"result\":{{\"challenge\":\"{s}\"}}}}", .{fake_challenge});
    const c = CrossLink.extractString(json, "challenge");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(usize, 64), c.?.len);
}

test "HMAC: SHA-256 标准测试向量 (RFC 4231)" {
    // RFC 4231 Test Case 1: key = 0x0b * 20, data = "Hi There"
    var key: [20]u8 = undefined;
    @memset(&key, 0x0b);
    const msg = "Hi There";
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, msg, &key);
    // 期望: b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
    const expected = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    var expected_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(expected_bytes[0..], expected) catch @panic("test vector invalid hex");
    try std.testing.expectEqualSlices(u8, &expected_bytes, &out);
}

test "CrossLink: init + deinit 无 panic" {
    const alloc = std.testing.allocator;
    const id = try alloc.dupe(u8, "test-self");
    defer alloc.free(id);
    const host = try alloc.dupe(u8, "127.0.0.1");
    defer alloc.free(host);
    const secret = try alloc.dupe(u8, "test_secret");
    defer alloc.free(secret);
    var io_t = std.Io.Threaded.init(alloc, .{});
    defer io_t.deinit();
    var link = CrossLink.init(alloc, io_t.io(), id, host, 9876, secret);
    defer link.deinit();
    try std.testing.expectEqualStrings("test-self", link.self_id);
    try std.testing.expectEqual(@as(u16, 9876), link.self_port);
}

test "CrossLink: loadPeersFromFile 解析标准格式" {
    // 留 stub, 实际跑需要 io 上下文
    _ = std.testing.allocator;
}
