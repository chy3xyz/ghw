// SPDX-License-Identifier: MIT
// examples/lark_bridge.zig — 飞书 (Lark) IM 桥
//
// 流程:
//   1. 启动 lark-cli 子进程 (真实部署) 或读 JSONL (离线模式)
//   2. 每条飞书消息 → Translator.interpret(text) → Intent
//   3. HumanGSP.selectMostTrusted(dim) → 选同伴
//   4. TaskQueue.submit + runTask → 完成任务
//   5. 输出 reply (真实模式用 lark-cli api 发送; 离线模式写到 JSONL)
//
// 用法:
//   # 离线模式 (用假消息测 GHW 管道, 不连飞书)
//   ./zig-out/bin/lark_bridge --offline
//
//   # 真实模式 (需要 lark-cli + appid/secret)
//   LARK_APPID=cli_xxx LARK_APPSECRET=xxx ./zig-out/bin/lark_bridge --lark

const std = @import("std");
const ghw = @import("ghw");

const Translator = ghw.harness.translator.Translator;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const Task = ghw.harness.human_symbiosis.Task;
const Information = ghw.goal.Information;
const GHWAgent = ghw.agent.GHWAgent;
const CycleReport = ghw.agent.CycleReport;
const Allocator = std.mem.Allocator;

const TranslatorCanned =
    \\{"dimension":"all","title":"lark_task","description":"interpreted from feishu msg","rationale":"LLM fallback","confidence":0.5}
;

const LarkMessage = struct {
    source: []const u8,
    sender: []const u8,
    chat_id: []const u8,
    msg_id: []const u8,
    text: []const u8,
    timestamp: i64,
    msg_type: []const u8,
};

const Args = struct {
    offline: bool = false,
    lark: bool = false,
    out_path: []const u8 = "data/lark_results.jsonl",
    offline_msgs_path: []const u8 = "data/lark_offline_msgs.jsonl",
    poll_interval_ms: u32 = 2000,
};

fn parseArgs(raw: []const []const u8) Args {
    var a = Args{};
    var i: usize = 1;
    while (i < raw.len) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--offline")) {
            a.offline = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--lark")) {
            a.lark = true;
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
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            if (i + 1 < raw.len) {
                a.poll_interval_ms = std.fmt.parseInt(u32, raw[i + 1], 10) catch 2000;
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
    if (std.mem.indexOf(u8, t, "算力") != null or
        std.mem.indexOf(u8, t, "资源") != null or
        std.mem.indexOf(u8, t, "数据源") != null or
        std.mem.indexOf(u8, t, "compute") != null) return .material;
    if (std.mem.indexOf(u8, t, "总结") != null or
        std.mem.indexOf(u8, t, "摘要") != null or
        std.mem.indexOf(u8, t, "可视化") != null or
        std.mem.indexOf(u8, t, "精读") != null or
        std.mem.indexOf(u8, t, "summarize") != null) return .representation;
    if (std.mem.indexOf(u8, t, "合同") != null or
        std.mem.indexOf(u8, t, "审") != null or
        std.mem.indexOf(u8, t, "你怎么看") != null or
        std.mem.indexOf(u8, t, "反馈") != null) return .nature;
    return .all;
}

fn interpretWithFallback(translator: *Translator, text: []const u8, ed: ghw.world.ExistenceDegree, alloc: Allocator, sender: []const u8, task_id: u64) !Task {
    if (translator.interpret(text, ed)) |intent_const| {
        var intent = intent_const;
        defer intent.deinit();
        return Task{
            .id = task_id,
            .title = try alloc.dupe(u8, intent.suggested_title),
            .description = try alloc.dupe(u8, intent.suggested_description),
            .from_human = try alloc.dupe(u8, sender),
            .required_dimension = intent.suggested_dimension,
            .allocator = alloc,
        };
    } else |_| {
        const dim = inferDimension(text);
        return Task{
            .id = task_id,
            .title = try alloc.dupe(u8, "lark_fallback"),
            .description = try alloc.dupe(u8, text),
            .from_human = try alloc.dupe(u8, sender),
            .required_dimension = dim,
            .allocator = alloc,
        };
    }
}

// 从飞书 JSON 消息中简单提取字段 (无外部 JSON 库, 手写 needle search)
fn parseLarkJsonLine(line: []const u8, alloc: Allocator) !LarkMessage {
    var msg: LarkMessage = undefined;
    // sender
    var sender_buf: [64]u8 = undefined;
    if (extractJsonString(line, "\"sender\":\"", "\"", &sender_buf)) |s| {
        msg.sender = try alloc.dupe(u8, s);
    } else return error.InvalidFormat;
    // chat_id
    var chat_buf: [64]u8 = undefined;
    if (extractJsonString(line, "\"chat_id\":\"", "\"", &chat_buf)) |s| {
        msg.chat_id = try alloc.dupe(u8, s);
    } else return error.InvalidFormat;
    // msg_id
    var mid_buf: [64]u8 = undefined;
    if (extractJsonString(line, "\"msg_id\":\"", "\"", &mid_buf)) |s| {
        msg.msg_id = try alloc.dupe(u8, s);
    } else return error.InvalidFormat;
    // text
    var text_buf: [2048]u8 = undefined;
    if (extractJsonString(line, "\"text\":\"", "\"", &text_buf)) |s| {
        msg.text = try alloc.dupe(u8, s);
    } else return error.InvalidFormat;
    // timestamp
    msg.timestamp = std.fmt.parseInt(i64, extractJsonNumber(line, "\"timestamp\":") orelse "0", 10) catch 0;
    // source
    var src_buf: [16]u8 = undefined;
    if (extractJsonString(line, "\"source\":\"", "\"", &src_buf)) |s| {
        msg.source = try alloc.dupe(u8, s);
    } else msg.source = try alloc.dupe(u8, "feishu");
    // msg_type
    var type_buf: [16]u8 = undefined;
    if (extractJsonString(line, "\"msg_type\":\"", "\"", &type_buf)) |s| {
        msg.msg_type = try alloc.dupe(u8, s);
    } else msg.msg_type = try alloc.dupe(u8, "text");
    return msg;
}

fn extractJsonString(haystack: []const u8, needle: []const u8, end_delim: []const u8, buf: []u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const content_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, haystack, content_start, end_delim) orelse return null;
    const len = @min(end - content_start, buf.len);
    @memcpy(buf[0..len], haystack[content_start..][0..len]);
    return buf[0..len];
}

fn extractJsonNumber(haystack: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const num_start = start + needle.len;
    var end = num_start;
    while (end < haystack.len and (std.ascii.isDigit(haystack[end]) or haystack[end] == '.')) : (end += 1) {}
    return haystack[num_start..end];
}

fn processMessage(
    msg: LarkMessage,
    agent: *GHWAgent,
    translator: *Translator,
    queue: *TaskQueue,
    gsp: *HumanGSP,
    vm: *ValueMetric,
    alloc: Allocator,
    io: std.Io,
    out: std.Io.File,
) !void {
    const info = [_]Information{
        .{
            .id = @intCast(@mod(msg.timestamp, 1000000)),
            .label = msg.msg_id,
            .features = .{
                @as(ghw.util.F, @floatFromInt(@mod(msg.timestamp, 100))) / 100.0,
                if (std.mem.eql(u8, msg.sender, "alice")) 0.9 else 0.4,
                0.5,
                0.5,
            },
        },
    };
    const report = try agent.runCycle(&info);
    var task = try interpretWithFallback(translator, msg.text, agent.ed, alloc, msg.sender, @intCast(@mod(msg.timestamp, 1000000)));
    defer task.deinit();
    const partner = gsp.selectMostTrusted(task.required_dimension);
    _ = partner;
    _ = vm;
    const submit = try queue.submit(
        task.title,
        task.description,
        task.from_human,
        task.priority,
        task.required_dimension,
        task.cycles_allocated,
    );
    _ = submit;
    // 输出 JSONL 结果
    var goal_kind: []const u8 = "null";
    if (report.top_goal) |g| goal_kind = @tagName(g.kind);
    const line = try std.fmt.allocPrint(alloc,
        \\{{"source":"{s}","sender":"{s}","msg_id":"{s}","text":"{s}","task_dim":"{s}","e_before":{d:.3},"e_after":{d:.3},"self_evolved":{},"goal":"{s}","tick":{d}}}
    , .{
        msg.source,
        msg.sender,
        msg.msg_id,
        msg.text,
        @tagName(task.required_dimension),
        report.e_before,
        report.e_after,
        report.self_evolved,
        goal_kind,
        report.tick,
    });
    defer alloc.free(line);
    try std.Io.File.writeStreamingAll(out, io, line);
    try std.Io.File.writeStreamingAll(out, io, "\n");
}

fn runOffline(
    alloc: Allocator,
    args: Args,
) !void {
    std.debug.print("[lark] 离线模式 — 读 {s}\n", .{args.offline_msgs_path});

    // 用 std.Io 读 (0.17 没有 std.fs.cwd)
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    const in_abs = try std.fs.path.join(alloc, &[_][]const u8{ cwd, args.offline_msgs_path });
    defer alloc.free(in_abs);
    const in_file = try std.Io.Dir.openFileAbsolute(io, in_abs, .{ .mode = .read_only });
    defer in_file.close(io);
    const in_stat = try in_file.stat(io);
    const content = try alloc.alloc(u8, in_stat.size);
    var total: usize = 0;
    while (total < in_stat.size) {
        const n = try std.Io.File.readStreaming(in_file, io, &.{content[total..]});
        if (n == 0) break;
        total += n;
    }
    const content_sliced = content[0..total];
    defer alloc.free(content);

    const out_abs = try std.fs.path.join(alloc, &[_][]const u8{ cwd, args.out_path });
    defer alloc.free(out_abs);
    const out = try std.Io.Dir.createFileAbsolute(io, out_abs, .{});
    defer out.close(io);

    var agent = try GHWAgent.init(alloc, "lark-offline", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();
    var llm = MockChatLLM.init(alloc, TranslatorCanned);
    var translator = Translator.init(alloc, llm.asChat());
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var vm: ValueMetric = .{};

    var lines = std.mem.splitScalar(u8, content_sliced, '\n');
    var msg_count: u32 = 0;
    const e_initial: f32 = agent.ed.e();
    var e_final: f32 = e_initial;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const msg = parseLarkJsonLine(line, alloc) catch continue;
        defer alloc.free(msg.sender);
        defer alloc.free(msg.chat_id);
        defer alloc.free(msg.msg_id);
        defer alloc.free(msg.text);
        defer alloc.free(msg.source);
        defer alloc.free(msg.msg_type);
        try processMessage(msg, &agent, &translator, &queue, &gsp, &vm, alloc, io, out);
        e_final = agent.ed.e();
        msg_count += 1;
    }
    const value = vm.valueScore();
    std.debug.print("[lark] 离线模式处理 {d} 条消息\n", .{msg_count});
    std.debug.print("[lark] E: {d:.3} → {d:.3}\n", .{ e_initial, e_final });
    std.debug.print("[lark] ValueScore: {d:.3}\n", .{value});
    std.debug.print("[lark] 结果写到 {s}\n", .{args.out_path});
}

fn runLark(alloc: Allocator, args: Args) !void {
    _ = args;
    // 真实模式: 用 lark-cli subprocess 拉消息
    // TODO: 实际接 lark-cli 的 im +receive 或 websocket 长连接
    std.debug.print("[lark] 真实模式 (TODO: 需先装 lark-cli + 设置 LARK_APPID/LARK_APPSECRET)\n", .{});
    std.debug.print("[lark] 详见: https://open.feishu.cn/document/server-docs/im-v1/message-events/list\n", .{});
    _ = alloc;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(std.heap.page_allocator);
    var it = init.args.iterate();
    while (it.next()) |arg| {
        try args_list.append(std.heap.page_allocator, arg);
    }
    const args = parseArgs(args_list.items);

    if (args.lark) {
        try runLark(std.heap.page_allocator, args);
    } else {
        try runOffline(std.heap.page_allocator, args);
    }
}
