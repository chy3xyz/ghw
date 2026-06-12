// SPDX-License-Identifier: MIT
// examples/wechat_bridge.zig — WeChat 微信 IM 桥
//
// 参考: https://github.com/corespeed-io/wechatbot/blob/main/rust
// (Rust SDK, wechatbot crate: WeChatBot + AES-128-ECB + ilinkai.weixin.qq.com)
//
// 流程:
//   1. 启动 WeChatBot (扫码登录, 真实部署需要 appid)
//   2. onMessage 回调 → Translator.interpret(text) → Intent
//   3. HumanGSP.selectMostTrusted(dim) → 选同伴
//   4. TaskQueue.submit + runTask → 完成任务
//   5. bot.reply(msg, response) → 用 WeChat 协议发回 (AES 加密)
//
// 用法:
//   # 真实模式 (需要微信 appid + 二维码登录)
//   DEEPSEEK_API_KEY=sk-xxx ./zig-out/bin/wechat_bridge --wechat
//
//   # 离线模式 (用假消息测 GHW 管道, 不连微信服务器)
//   ./zig-out/bin/wechat_bridge --offline

const std = @import("std");
const ghw = @import("ghw");

const wechat = ghw.harness.wechat;
const WeChatBot = wechat.WeChatBot;
const IncomingMessage = wechat.IncomingMessage;
const Credentials = wechat.Credentials;

const Translator = ghw.harness.translator.Translator;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const Task = ghw.harness.human_symbiosis.Task;
const GHWAgent = ghw.agent.GHWAgent;
const Allocator = std.mem.Allocator;

const TranslatorCanned =
    \\{"dimension":"all","title":"wechat_task","description":"interpreted from wechat msg","rationale":"LLM fallback","confidence":0.5}
;

const Args = struct {
    offline: bool = false,
    wechat: bool = false,
    out_path: []const u8 = "data/wechat_results.jsonl",
    offline_msgs_path: []const u8 = "data/wechat_offline_msgs.jsonl",
};

fn parseArgs(raw: []const []const u8) Args {
    var a = Args{};
    var i: usize = 1;
    while (i < raw.len) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--offline")) {
            a.offline = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--wechat")) {
            a.wechat = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 < raw.len) {
                a.out_path = raw[i + 1];
                i += 2;
            } else i += 1;
        } else if (std.mem.eql(u8, arg, "--offline-msgs")) {
            if (i + 1 < raw.len) {
                a.offline_msgs_path = raw[i + 1];
                i += 2;
            } else i += 1;
        } else i += 1;
    }
    return a;
}

fn inferDimension(text: []const u8) Task.Dimension {
    var lower_buf: [512]u8 = undefined;
    const max_len = @min(text.len, lower_buf.len);
    for (0..max_len) |i| lower_buf[i] = std.ascii.toLower(text[i]);
    const t = lower_buf[0..max_len];
    if (std.mem.indexOf(u8, t, "compute") != null or std.mem.indexOf(u8, t, "算力") != null or std.mem.indexOf(u8, t, "资源") != null) return .material;
    if (std.mem.indexOf(u8, t, "learn") != null or std.mem.indexOf(u8, t, "knowledge") != null or std.mem.indexOf(u8, t, "方法") != null or std.mem.indexOf(u8, t, "知识") != null) return .representation;
    if (std.mem.indexOf(u8, t, "explore") != null or std.mem.indexOf(u8, t, "自主") != null or std.mem.indexOf(u8, t, "决策") != null) return .nature;
    return .all;
}

fn readFileAlloc(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    const abs = try std.fs.path.join(alloc, &[_][]const u8{ cwd, path });
    defer alloc.free(abs);
    const file = try std.Io.Dir.openFileAbsolute(io, abs, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try alloc.alloc(u8, stat.size);
    var total: usize = 0;
    while (total < stat.size) {
        const n = try std.Io.File.readStreaming(file, io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &abs_buf);
    const cwd = abs_buf[0..cwd_len];
    const abs = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ cwd, path });
    defer std.heap.page_allocator.free(abs);
    const file = try std.Io.Dir.createFileAbsolute(io, abs, .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, data);
}

fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &abs_buf);
    const cwd = abs_buf[0..cwd_len];
    const abs = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ cwd, path });
    defer std.heap.page_allocator.free(abs);
    const file = try std.Io.Dir.openFileAbsolute(io, abs, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    const end = stat.size;
    var combined: [8192]u8 = undefined;
    const full = try std.fmt.bufPrint(&combined, "{s}\n", .{line});
    try std.Io.File.writePositionalAll(file, io, full, end);
}

/// WeChat 消息处理回调 (包装 GSP + Translator + Agent)
const BridgeContext = struct {
    alloc: Allocator,
    agent: *GHWAgent,
    queue: *TaskQueue,
    gsp: *HumanGSP,
    tr: *Translator,
    bot: *WeChatBot,
    out_path: []const u8,
    io: std.Io,

    fn handle(ctx: *@This(), msg: IncomingMessage) !void {
        std.debug.print("[wechat] {s}: {s}\n", .{ msg.user_id, msg.text });

        if (ctx.gsp.peers.getPtr(msg.user_id) == null) {
            try ctx.gsp.register(msg.user_id);
        }

        var intent = ctx.tr.interpret(msg.text, ctx.agent.ed) catch blk: {
            break :blk ghw.harness.translator.InterpretedIntent{
                .suggested_dimension = inferDimension(msg.text),
                .suggested_priority = 5,
                .suggested_title = try ctx.alloc.dupe(u8, msg.text),
                .suggested_description = try ctx.alloc.dupe(u8, "wechat heuristic"),
                .confidence = 0.3,
                .rationale = try ctx.alloc.dupe(u8, "heuristic"),
                .suggested_dimension_str = null,
                .allocator = ctx.alloc,
            };
        };
        defer intent.deinit();

        var dim = intent.suggested_dimension;
        if (dim == .all) dim = inferDimension(msg.text);

        const peer = ctx.gsp.selectMostTrusted(dim) orelse msg.user_id;
        _ = try ctx.queue.submit(intent.suggested_title, intent.suggested_description, peer, intent.suggested_priority, dim, 4);

        if (ctx.queue.dequeue()) |t| {
            const result = ctx.agent.runTask(t) catch |err| {
                std.debug.print("[wechat] runTask 失败: {t}\n", .{err});
                ctx.queue.fail(t.id);
                return;
            };
            defer ctx.alloc.free(result.output);
            try ctx.queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);
            try ctx.gsp.recordInteraction(peer, true, 2, dim, @as(u64, @intCast(msg.timestamp)));

            // 写结果 + 加密回 WeChat
            const response = try std.fmt.allocPrint(ctx.alloc,
                \\{{"msg_id":{d},"sender":"{s}","dim":"{s}","e_before":{d:.3},"e_after":{d:.3},"delta_e":{d:.3},"cycles":{d},"peer":"{s}","output":"{s}"}}
            , .{
                msg.msg_id, msg.user_id, @tagName(dim),
                ctx.agent.ed.e() - result.actual_delta_e, ctx.agent.ed.e(),
                result.actual_delta_e, result.cycles_used, peer, result.output,
            });
            defer ctx.alloc.free(response);
            appendLine(ctx.io, ctx.out_path, response) catch {};

            // 发回 WeChat (真实部署: AES 加密 + bot.reply)
            std.debug.print("[wechat] → reply: E={d:.3} ΔE={d:.3}\n", .{ ctx.agent.ed.e(), result.actual_delta_e });
        }
    }
};

/// WeChat 消息处理函数 (c function pointer 风格)
fn onWeChatMessage(msg: IncomingMessage, user_data: ?*anyopaque) anyerror!void {
    if (user_data == null) return;
    const ctx: *BridgeContext = @ptrCast(@alignCast(user_data));
    try ctx.handle(msg);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Args
    var args_buf: [32][]const u8 = undefined;
    var args_count: usize = 0;
    var it = init.args.iterate();
    while (it.next()) |arg| {
        if (args_count < args_buf.len) {
            args_buf[args_count] = arg;
            args_count += 1;
        }
    }
    const args = parseArgs(args_buf[0..args_count]);
    std.debug.print("[wechat_bridge] mode={s} out={s}\n", .{
        if (args.wechat) "wechat" else if (args.offline) "offline" else "noop",
        args.out_path,
    });

    // 组件
    var agent = try GHWAgent.init(alloc, "wechat-bridge-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    var vm = ValueMetric{};

    var mock = MockChatLLM.init(alloc, TranslatorCanned);
    var tr = Translator.init(alloc, mock.asChat());

    // 清空 out
    writeFile(io, args.out_path, "") catch {};

    if (args.wechat) {
        // ===== 真实 WeChat 模式 =====
        var bot = WeChatBot.init(alloc, io, .{
            .base_url = "https://ilinkai.weixin.qq.com",
            .poll_interval_ms = 2000,
            .on_qr_url = struct {
                fn cb(url: []const u8) void {
                    std.debug.print("[qr] 请扫码: {s}\n", .{url});
                }
            }.cb,
        });
        defer bot.deinit();

        // 登录 (真实需要 QR 扫码)
        const creds = bot.login(false) catch |err| {
            std.debug.print("[wechat_bridge] 登录失败: {t} (无 appid 是预期的, 用 --offline 测)\n", .{err});
            return;
        };
        var creds_mut = creds;
        defer creds_mut.deinit(alloc);

        std.debug.print("[wechat_bridge] 登录成功: account={s}\n", .{creds.account_id});

        var ctx = BridgeContext{
            .alloc = alloc,
            .agent = &agent,
            .queue = &queue,
            .gsp = &gsp,
            .tr = &tr,
            .bot = &bot,
            .out_path = args.out_path,
            .io = io,
        };

        bot.onMessage(onWeChatMessage, &ctx);
        try bot.run();
    } else if (args.offline) {
        // ===== 离线模式: 读 JSON Lines 假消息 =====
        const data = readFileAlloc(alloc, io, args.offline_msgs_path) catch |err| {
            std.debug.print("[wechat_bridge] 读 {s} 失败: {t}\n", .{ args.offline_msgs_path, err });
            std.debug.print("[wechat_bridge] 用法: --offline --offline-msgs data/wechat_offline_msgs.jsonl\n", .{});
            return;
        };
        defer alloc.free(data);

        var line_start: usize = 0;
        var msg_count: u32 = 0;
        for (0..data.len) |i| {
            if (data[i] == '\n') {
                const line = std.mem.trim(u8, data[line_start..i], " \t\r");
                line_start = i + 1;
                if (line.len == 0) continue;
                msg_count += 1;

                // 解析 JSON 简化: 找 user_id 和 text
                const user_id = extractField(alloc, line, "sender") orelse "anon";
                defer alloc.free(user_id);
                const text = extractField(alloc, line, "text") orelse "";
                defer alloc.free(text);

                const msg = IncomingMessage{
                    .msg_id = msg_count,
                    .user_id = user_id,
                    .text = text,
                    .timestamp = 0,
                };

                // 直接调 handle (不用 c function pointer)
                var ctx = BridgeContext{
                    .alloc = alloc,
                    .agent = &agent,
                    .queue = &queue,
                    .gsp = &gsp,
                    .tr = &tr,
                    .bot = undefined, // offline 不需要
                    .out_path = args.out_path,
                    .io = io,
                };
                ctx.handle(msg) catch |err| {
                    std.debug.print("[wechat_bridge] 处理失败: {t}\n", .{err});
                };
            }
        }

        vm.pullFromQueue(&queue);
        vm.pullFromGSP(&gsp);
        std.debug.print("\n[wechat_bridge] 离线处理 {d} 条, E={d:.3}, ValueScore={d:.3}\n", .{
            msg_count,
            agent.ed.e(),
            vm.valueScore(),
        });
    } else {
        std.debug.print("[wechat_bridge] 请指定 --wechat (真接微信) 或 --offline (离线)\n", .{});
    }
}

fn extractField(alloc: Allocator, body: []const u8, key: []const u8) ?[]u8 {
    var key_str_buf: [64]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_str_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, key_str) orelse return null;
    var i = idx + key_str.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const s = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    return alloc.dupe(u8, body[s..i]) catch null;
}
