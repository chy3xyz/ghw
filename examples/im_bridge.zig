// SPDX-License-Identifier: MIT
// examples/im_bridge.zig — IM 桥: 人类 IM 事件文件 → Task → 数字生命 → 响应文件
//
// 协议:
//   输入 (--in events.jsonl, 默认 data/im_events.jsonl): 每行一个 JSON 事件
//!     {"source":"feishu","sender":"alice","text":"E 怎么这么低","timestamp":1234567890}
//
//   输出 (--out results.jsonl, 默认 data/im_results.jsonl): 每行一个 JSON 结果
//!     {"task_id":42,"sender":"alice","title":"...","e_before":0.45,"e_after":0.51,...}
//
// 流程:
//   1. 读所有事件到内存
//   2. 创建 GHWAgent + Translator (用 MockChatLLM, 真接可换 HttpLLM) + TaskQueue
//   3. 遍历事件: 注册人类 → Translator.interpret → 启发式 fallback → GSP 选人 → 跑 → 写入结果
//   4. 写总报表
//
// 用法:
//   ./im_bridge --in data/im_events.jsonl --out data/im_results.jsonl
//   ./im_bridge --llm --in ... (启用真 LLM 解读)

const std = @import("std");
const ghw = @import("ghw");

const Translator = ghw.harness.translator.Translator;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const HttpChatLLM = ghw.harness.http_llm.HttpChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const Task = ghw.harness.human_symbiosis.Task;
const GHWAgent = ghw.agent.GHWAgent;
const Allocator = std.mem.Allocator;

const IMEvent = struct {
    source: []u8, // owned
    sender: []u8, // owned
    text: []u8, // owned
    timestamp: u64,

    fn deinit(self: *IMEvent, alloc: Allocator) void {
        alloc.free(self.source);
        alloc.free(self.sender);
        alloc.free(self.text);
    }
};

fn parseIMEvent(alloc: Allocator, line: []const u8) !IMEvent {
    const source_s = try extractStringField(alloc, line, "source") orelse try alloc.dupe(u8, "");
    const sender_s = try extractStringField(alloc, line, "sender") orelse try alloc.dupe(u8, "anon");
    const text_s = try extractStringField(alloc, line, "text") orelse try alloc.dupe(u8, "");
    const ts = (try extractNumberField(line, "timestamp")) orelse 0;
    return IMEvent{
        .source = source_s,
        .sender = sender_s,
        .text = text_s,
        .timestamp = ts,
    };
}

fn extractStringField(alloc: Allocator, body: []const u8, key: []const u8) !?[]u8 {
    const key_str = try std.fmt.allocPrint(alloc, "\"{s}\":", .{key});
    defer alloc.free(key_str);
    if (std.mem.indexOf(u8, body, key_str)) |idx| {
        var i = idx + key_str.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
        if (i < body.len and body[i] == '"') {
            i += 1;
            const s = i;
            while (i < body.len and body[i] != '"') : (i += 1) {}
            return try alloc.dupe(u8, body[s..i]);
        }
    }
    return null;
}

fn extractNumberField(body: []const u8, key: []const u8) !?u64 {
    var key_str_buf: [64]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_str_buf, "\"{s}\":", .{key}) catch return null;
    if (std.mem.indexOf(u8, body, key_str)) |idx| {
        var i = idx + key_str.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
        const s = i;
        while (i < body.len and (body[i] >= '0' and body[i] <= '9')) : (i += 1) {}
        if (i > s) return std.fmt.parseInt(u64, body[s..i], 10) catch null;
    }
    return null;
}

fn inferDimension(text: []const u8) Task.Dimension {
    var lower_buf: [512]u8 = undefined;
    const max_len = @min(text.len, lower_buf.len);
    for (0..max_len) |i| lower_buf[i] = std.ascii.toLower(text[i]);
    const t = lower_buf[0..max_len];
    if (std.mem.indexOf(u8, t, "compute") != null or std.mem.indexOf(u8, t, "cpu") != null or std.mem.indexOf(u8, t, "算力") != null or std.mem.indexOf(u8, t, "资源") != null) return .material;
    if (std.mem.indexOf(u8, t, "learn") != null or std.mem.indexOf(u8, t, "knowledge") != null or std.mem.indexOf(u8, t, "理解") != null or std.mem.indexOf(u8, t, "知识") != null or std.mem.indexOf(u8, t, "方法") != null) return .representation;
    if (std.mem.indexOf(u8, t, "explore") != null or std.mem.indexOf(u8, t, "自主") != null or std.mem.indexOf(u8, t, "决策") != null) return .nature;
    return .all;
}

const TranslatorCanned =
    \\{"dimension":"all","title":"interpreted_task","description":"interpreted from human text","rationale":"LLM fallback","confidence":0.5}
;

fn makeAbsolute(alloc: Allocator, io: std.Io, rel: []const u8) ![]u8 {
    if (rel.len > 0 and rel[0] == '/') return try alloc.dupe(u8, rel);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &buf);
    const cwd = buf[0..cwd_len];
    return try std.fs.path.join(alloc, &[_][]const u8{ cwd, rel });
}

fn readFileAlloc(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const abs = try makeAbsolute(alloc, io, path);
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

fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    const abs = try makeAbsolutePath(io, path);
    defer std.heap.page_allocator.free(abs);

    const file = try std.Io.Dir.openFileAbsolute(io, abs, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    const end = stat.size;
    var combined: [8192]u8 = undefined;
    const full = try std.fmt.bufPrint(&combined, "{s}\n", .{line});
    try std.Io.File.writePositionalAll(file, io, full, end);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const abs = try makeAbsolutePath(io, path);
    defer std.heap.page_allocator.free(abs);

    const file = try std.Io.Dir.createFileAbsolute(io, abs, .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, data);
}

fn makeAbsolutePath(io: std.Io, rel: []const u8) ![]u8 {
    if (rel.len > 0 and rel[0] == '/') return try std.heap.page_allocator.dupe(u8, rel);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    return try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ cwd, rel });
}

const Args = struct {
    in_path: []const u8 = "data/im_events.jsonl",
    out_path: []const u8 = "data/im_results.jsonl",
    use_llm: bool = false,
    llm_provider: []const u8 = "deepseek",
    llm_model: []const u8 = "deepseek-flash",
};

fn parseArgs(alloc: Allocator, raw: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 1; // skip exe
    while (i < raw.len) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--in")) {
            if (i + 1 < raw.len) {
                a.in_path = raw[i + 1];
                i += 2;
            } else i += 1;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 < raw.len) {
                a.out_path = raw[i + 1];
                i += 2;
            } else i += 1;
        } else if (std.mem.eql(u8, arg, "--llm")) {
            a.use_llm = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            if (i + 1 < raw.len) {
                a.llm_provider = raw[i + 1];
                i += 2;
            } else i += 1;
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (i + 1 < raw.len) {
                a.llm_model = raw[i + 1];
                i += 2;
            } else i += 1;
        } else {
            i += 1;
        }
    }
    _ = alloc;
    return a;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 收集 args
    var args_buf: [32][]const u8 = undefined;
    var args_count: usize = 0;
    var it = init.args.iterate();
    while (it.next()) |arg| {
        if (args_count < args_buf.len) {
            args_buf[args_count] = arg;
            args_count += 1;
        }
    }
    const args = try parseArgs(alloc, args_buf[0..args_count]);
    std.debug.print("[im_bridge] in={s} out={s} llm={s}/{s}\n", .{
        args.in_path, args.out_path, if (args.use_llm) "on" else "off", args.llm_model,
    });

    // Io 实例 (Zig 0.17 文件 API 需要)
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 清空 out
    writeFile(io, args.out_path, "") catch {};

    // ===== 1. 读事件 =====
    const data = readFileAlloc(alloc, io, args.in_path) catch |err| {
        std.debug.print("[im_bridge] 读 {s} 失败: {t}\n", .{ args.in_path, err });
        std.debug.print("[im_bridge] 用法: --in events.jsonl --out results.jsonl\n", .{});
        return;
    };
    defer alloc.free(data);

    var events: std.ArrayList(IMEvent) = .empty;
    defer {
        for (events.items) |*e| e.deinit(alloc);
        events.deinit(alloc);
    }

    var line_start: usize = 0;
    for (0..data.len) |i| {
        if (data[i] == '\n') {
            const line = std.mem.trim(u8, data[line_start..i], " \t\r");
            line_start = i + 1;
            if (line.len == 0) continue;
            if (parseIMEvent(alloc, line)) |ev| {
                try events.append(alloc, ev);
            } else |err| {
                std.debug.print("[im_bridge] 跳过行 (parse err: {t}): {s}\n", .{ err, line });
            }
        }
    }
    std.debug.print("[im_bridge] 读到 {d} 条 IM 事件\n", .{events.items.len});

    // ===== 2. 组件 =====
    var agent = try GHWAgent.init(alloc, "im-bridge-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    var vm = ValueMetric{};

    // Translator
    if (args.use_llm) {
        // 真接 (暂未实现, 用 Mock 模拟)
        std.debug.print("[im_bridge] 真接 LLM 模式 (暂用 Mock)\n", .{});
        var mock = MockChatLLM.init(alloc, TranslatorCanned);
        var tr = Translator.init(alloc, mock.asChat());
        try runBridge(alloc, io, &agent, &tr, &queue, &gsp, &vm, events.items, args.out_path);
    } else {
        var mock = MockChatLLM.init(alloc, TranslatorCanned);
        var tr = Translator.init(alloc, mock.asChat());
        try runBridge(alloc, io, &agent, &tr, &queue, &gsp, &vm, events.items, args.out_path);
    }
}

fn runBridge(
    alloc: Allocator,
    io: std.Io,
    agent: *GHWAgent,
    tr: *Translator,
    queue: *TaskQueue,
    gsp: *HumanGSP,
    vm: *ValueMetric,
    events: []const IMEvent,
    out_path: []const u8,
) !void {
    std.debug.print("\n[bridge] 数字生命 E={d:.3}, 处理 {d} 条 IM\n\n", .{ agent.ed.e(), events.len });

    var handled: u32 = 0;
    var dim_counts = [_]u32{ 0, 0, 0, 0 }; // material, representation, nature, all
    const dim_names = [_][]const u8{ "material", "representation", "nature", "all" };

    for (events) |*ev| {
        handled += 1;
        std.debug.print("[IM #{d}] {s}@[{s}]: {s}\n", .{ handled, ev.sender, ev.source, ev.text });

        if (gsp.peers.getPtr(ev.sender) == null) {
            try gsp.register(ev.sender);
        }

        var intent = tr.interpret(ev.text, agent.ed) catch |err| blk: {
            std.debug.print("[im_bridge] interpret 失败: {t}, 用启发式\n", .{err});
            break :blk InterpretedIntent{
                .suggested_dimension = inferDimension(ev.text),
                .suggested_priority = 5,
                .suggested_title = try alloc.dupe(u8, ev.text),
                .suggested_description = try alloc.dupe(u8, "heuristic fallback"),
                .confidence = 0.3,
                .rationale = try alloc.dupe(u8, "heuristic"),
                .suggested_dimension_str = null,
                .allocator = alloc,
            };
        };
        defer intent.deinit();

        var dim = intent.suggested_dimension;
        if (dim == .all) {
            const inferred = inferDimension(ev.text);
            if (inferred != .all) dim = inferred;
        }
        dim_counts[@intFromEnum(dim)] += 1;

        const peer = gsp.selectMostTrusted(dim) orelse ev.sender;

        std.debug.print("  → interpret: dim={s} title='{s}' (conf={d:.2})\n", .{
            @tagName(dim), intent.suggested_title, intent.confidence,
        });
        std.debug.print("  → GSP 选人: {s} (trust={d:.2})\n", .{
            peer, gsp.peers.get(peer).?.trust,
        });

        _ = try queue.submit(
            intent.suggested_title,
            intent.suggested_description,
            peer,
            intent.suggested_priority,
            dim,
            4,
        );

        if (queue.dequeue()) |t| {
            const result = agent.runTask(t) catch |err| {
                std.debug.print("  → runTask 失败: {t}\n", .{err});
                queue.fail(t.id);
                continue;
            };
            defer alloc.free(result.output);
            try queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);
            try gsp.recordInteraction(peer, true, 2, dim, ev.timestamp);

            const e_before = agent.ed.e() - result.actual_delta_e;
            const out = try std.fmt.allocPrint(alloc,
                \\{{"task_id":{d},"sender":"{s}","title":"{s}","dim":"{s}","e_before":{d:.3},"e_after":{d:.3},"delta_e":{d:.3},"cycles":{d},"peer":"{s}"}}
            , .{
                t.id, ev.sender, intent.suggested_title, @tagName(dim),
                e_before, agent.ed.e(), result.actual_delta_e, result.cycles_used, peer,
            });
            defer alloc.free(out);
            appendLine(io, out_path, out) catch {};

            std.debug.print("  → ✓ task #{d} 完成: ΔE={d:.3}, E={d:.3}\n", .{ t.id, result.actual_delta_e, agent.ed.e() });
        }
    }

    vm.pullFromQueue(queue);
    vm.pullFromGSP(gsp);

    std.debug.print("\n[bridge] ===== 总报表 =====\n", .{});
    std.debug.print("  处理 {d}/{d} 条 IM\n", .{ handled, events.len });
    for (dim_names, 0..) |name, i| {
        std.debug.print("  dim={s}: {d} 条\n", .{ name, dim_counts[i] });
    }
    std.debug.print("  数字生命 E: {d:.3}\n", .{agent.ed.e()});
    std.debug.print("  ValueScore: {d:.3}\n", .{vm.valueScore()});
    std.debug.print("  任务完成 {d}, 失败 {d}\n", .{ vm.tasks_completed, vm.tasks_failed });
    std.debug.print("  Trust sum: {d:.3}\n", .{vm.current_trust_sum});
    std.debug.print("  写入 {s}\n", .{out_path});
}

const InterpretedIntent = ghw.harness.translator.InterpretedIntent;
