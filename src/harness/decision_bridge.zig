//! decision_bridge — GHW ↔ ZJEV (System-0 概率决策核, P0)
//!
//! 「System 0」外挂认知层: 把 GHW 的结构化状态 (M/R/N + 宿主传感) 发给
//! zjev-serve (https://github.com/chy3xyz/zjev, 独立 sidecar 进程), 取回经
//! 温度校准的类型化决策 (choice + confidence + abstention)。
//!
//! 门语义 (有界, 只偏置不夺权):
//!   .above   置信达标 → 照常执行
//!   .below   置信不足 → 照常执行 + 升级人类移交任务
//!   .abstain 模型弃权 → 本轮等待下一采样
//! 红线: E/Guard/主循环从不被本模块改写; 未配置端点 = 调用方直通 (.above),
//! 零行为变化。校准数据由 GHW 的任务史 (sqlite) 导出经 zjev-fit 拟合 (P1)。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const net_read = @import("../util/net_read.zig");

/// 弃权概率 ≥ 此值 ⇒ gate=.abstain (等待下一采样)
pub const ABSTAIN_EPS: F = 0.30;
/// confidence < threshold ⇒ gate=.below (升级人类移交)
pub const DEFAULT_THRESHOLD: F = 0.60;
/// System-0 咨询的最小 tick 间隔 (与 world_sensor 同频, 防高频打爆 sidecar)
pub const CONSULT_INTERVAL_TICKS: u64 = 8;

pub const GateAction = enum {
    above,
    below,
    abstain,

    pub fn label(self: GateAction) []const u8 {
        return switch (self) {
            .above => "above",
            .below => "below",
            .abstain => "abstain",
        };
    }
};

/// 一次咨询的值快照 (定长缓冲, 无堆生命周期问题; 供 provenance/日志)
pub const Decision0 = struct {
    ok: bool = false,
    action_buf: [32]u8 = std.mem.zeroes([32]u8),
    action_len: usize = 0,
    confidence: F = 0,
    abstention: F = 0,
    entropy: F = 0,
    gate: GateAction = .above,
    latency_us: u64 = 0,
    calibration_buf: [24]u8 = std.mem.zeroes([24]u8),
    calibration_len: usize = 0,

    pub fn action(self: *const Decision0) []const u8 {
        return self.action_buf[0..self.action_len];
    }

    pub fn calibration(self: *const Decision0) []const u8 {
        return self.calibration_buf[0..self.calibration_len];
    }
};

/// 门派生: 弃权优先, 其次阈值二分。纯函数 (可测)。
pub fn mapGate(confidence: F, abstention: F, threshold: F) GateAction {
    if (abstention >= ABSTAIN_EPS) return .abstain;
    if (confidence >= threshold) return .above;
    return .below;
}

/// 构造 /v1/decide 请求体: 危机动作三选一 (+弃权)。
/// state.text 全 ASCII 数值字段, 无需 JSON 转义。
pub fn buildCrisisRequest(
    alloc: Allocator,
    m: F,
    r: F,
    n: F,
    disk_pct: F,
    mem_pct: F,
    load_1m: F,
    n_cpus: u32,
    e: F,
) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"state":{{"text":"M={d:.3} R={d:.3} N={d:.3} E={d:.3} disk={d:.1}% mem={d:.1}% load={d:.2}/{d}c"}},"decisions":[{{"id":"crisis_action","type":"choice","options":["proceed","diagnose","handoff"],"abstain":true}}]}}
    , .{ m, r, n, e, disk_pct, mem_pct, load_1m, @max(n_cpus, 1) });
}

fn jsonToF(v: ?std.json.Value) F {
    const val = v orelse return 0;
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(F, s) catch 0,
        else => 0,
    };
}

fn copyBounded(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// 解析 zjev /v1/decide 响应, 填充 out (含 gate 派生)。纯解析 (可测)。
pub fn parseDecision0(body: []const u8, threshold: F, out: *Decision0) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results") orelse return error.Decision0BadResponse;
    if (results != .array or results.array.items.len == 0) return error.Decision0BadResponse;
    // 找 crisis_action; 找不到退回第一条
    var item: std.json.Value = results.array.items[0];
    for (results.array.items) |it| {
        if (it != .object) continue;
        if (it.object.get("id")) |id| {
            if (id == .string and std.mem.eql(u8, id.string, "crisis_action")) {
                item = it;
                break;
            }
        }
    }
    if (item != .object) return error.Decision0BadResponse;
    const obj = item.object;

    if (obj.get("value")) |v| {
        if (v == .string) out.action_len = copyBounded(&out.action_buf, v.string);
    }
    if (obj.get("uncertainty")) |u| {
        if (u == .object) {
            out.confidence = jsonToF(u.object.get("confidence"));
            out.abstention = jsonToF(u.object.get("abstention"));
            out.entropy = jsonToF(u.object.get("entropy"));
        }
    }
    if (obj.get("latency_us")) |l| out.latency_us = @intFromFloat(jsonToF(l));
    if (parsed.value.object.get("calibration")) |c| {
        if (c == .string) out.calibration_len = copyBounded(&out.calibration_buf, c.string);
    }

    // 模型显式弃权 (argmax 落在 __abstain__) ⇒ gate 直接 abstain
    if (std.mem.eql(u8, out.action(), "__abstain__")) out.abstention = 1.0;
    out.gate = mapGate(out.confidence, out.abstention, threshold);
    out.ok = true;
}

/// 完整咨询: POST {endpoint}/v1/decide → Decision0。失败返回错误 (调用方决定降级)。
pub fn consult(
    alloc: Allocator,
    io: std.Io,
    endpoint: []const u8,
    request_json: []const u8,
    threshold: F,
    out: *Decision0,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try std.fmt.allocPrint(a, "{s}/v1/decide", .{endpoint});
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = request_json,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
        .response_writer = &writer.writer,
    });
    if (@intFromEnum(result.status) != 200) {
        std.debug.print("[decision0] non-200: {d} body={s}\n", .{ @intFromEnum(result.status), writer.writer.buffered() });
        return error.Decision0RequestFailed;
    }
    return parseDecision0(writer.writer.buffered(), threshold, out);
}

// ===== Tests =====

const testing = std.testing;

test "decision_bridge: mapGate 弃权优先 + 阈值二分" {
    try testing.expectEqual(GateAction.abstain, mapGate(0.95, 0.30, DEFAULT_THRESHOLD));
    try testing.expectEqual(GateAction.above, mapGate(0.60, 0.10, DEFAULT_THRESHOLD));
    try testing.expectEqual(GateAction.below, mapGate(0.59, 0.10, DEFAULT_THRESHOLD));
    try testing.expectEqual(GateAction.above, mapGate(0.95, 0.29, DEFAULT_THRESHOLD));
}

test "decision_bridge: buildCrisisRequest 契约形状" {
    const body = try buildCrisisRequest(testing.allocator, 0.3, 0.45, 0.67, 64.0, 79.0, 8.31, 12, 0.49);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"crisis_action\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"abstain\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "load=8.31/12c") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"options\":[\"proceed\",\"diagnose\",\"handoff\"]") != null);
}

test "decision_bridge: parseDecision0 提取 value/置信/弃权 + gate 派生" {
    const canned =
        \\{"results":[{"id":"crisis_action","type":"choice","value":"handoff","probabilities":{"proceed":0.1,"diagnose":0.1,"handoff":0.65,"__abstain__":0.15},"uncertainty":{"entropy":0.9,"confidence":0.55,"abstention":0.15},"latency_us":716}],"calibration":"temp-fit-v1"}
    ;
    var d0: Decision0 = .{};
    try parseDecision0(canned, DEFAULT_THRESHOLD, &d0);
    try testing.expect(d0.ok);
    try testing.expectEqualStrings("handoff", d0.action());
    try testing.expectEqual(@as(F, 0.55), d0.confidence);
    try testing.expectEqual(@as(F, 0.15), d0.abstention);
    try testing.expectEqual(@as(u64, 716), d0.latency_us);
    try testing.expectEqualStrings("temp-fit-v1", d0.calibration());
    try testing.expectEqual(GateAction.below, d0.gate); // 0.55 < 0.60
}

/// 单连接 mock: 收一条请求回固定 decide 响应 (同 http_llm 测试模式, 无需真 zjev)
const MockServerCtx = struct {
    io: std.Io,
    port: u16,

    fn run(ctx: *MockServerCtx) void {
        ctx.serve() catch |err| {
            std.debug.print("[decision0-mock] serve 失败: {t}\n", .{err});
        };
    }

    fn serve(ctx: *MockServerCtx) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", ctx.port);
        var server = try address.listen(ctx.io, .{ .reuse_address = true });
        defer server.deinit(ctx.io);
        var stream: std.Io.net.Stream = try server.accept(ctx.io);
        defer stream.close(ctx.io);

        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        var header_end: usize = 0;
        var content_len: usize = 0;
        while (total < buf.len) {
            if (header_end == 0) {
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |he| {
                    header_end = he + 4;
                    content_len = parseContentLength(buf[0..header_end]);
                }
            }
            if (header_end > 0 and total >= header_end + content_len) break;
            const n = try net_read.readChunk(&stream, ctx.io, @constCast(&[_][]u8{buf[total..]}));
            if (n == 0) break;
            total += n;
        }
        const body =
            \\{"results":[{"id":"crisis_action","type":"choice","value":"proceed","probabilities":{"proceed":0.9},"uncertainty":{"confidence":0.9,"abstention":0.02},"latency_us":500}],"calibration":"default"}
        ;
        var head_buf: [160]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len});
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(ctx.io, &wbuf);
        try w.interface.writeAll(head);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }
};

fn parseContentLength(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10) catch 0;
        }
    }
    return 0;
}

test "decision_bridge: consult 本地 mock server HTTP 往返" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 候选端口探测 (避免 CI 冲突)
    var port: ?u16 = null;
    for ([_]u16{ 19891, 19892, 19893, 19894 }) |p| {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", p) catch continue;
        var srv = address.listen(io, .{ .reuse_address = true }) catch continue;
        srv.deinit(io);
        port = p;
        break;
    }
    try testing.expect(port != null);

    var ctx: MockServerCtx = .{ .io = io, .port = port.? };
    const thread = try std.Thread.spawn(.{}, MockServerCtx.run, .{&ctx});

    const req = try buildCrisisRequest(alloc, 0.3, 0.45, 0.67, 64, 79, 8.3, 12, 0.49);
    defer alloc.free(req);
    var d0: Decision0 = .{};
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port.?});
    defer alloc.free(url);
    try consult(alloc, io, url, req, DEFAULT_THRESHOLD, &d0);
    thread.join();

    try testing.expect(d0.ok);
    try testing.expectEqualStrings("proceed", d0.action());
    try testing.expectEqual(@as(F, 0.9), d0.confidence);
    try testing.expectEqual(GateAction.above, d0.gate);
    try testing.expectEqual(@as(u64, 500), d0.latency_us);
}

test "decision_bridge: 显式 __abstain__ 归一为 abstain gate" {
    const canned =
        \\{"results":[{"id":"crisis_action","type":"choice","value":"__abstain__","probabilities":{},"uncertainty":{"confidence":0.30,"abstention":0.28}}],"calibration":"default"}
    ;
    var d0: Decision0 = .{};
    try parseDecision0(canned, DEFAULT_THRESHOLD, &d0);
    try testing.expectEqual(GateAction.abstain, d0.gate);
    try testing.expectEqual(@as(F, 1.0), d0.abstention);
}
