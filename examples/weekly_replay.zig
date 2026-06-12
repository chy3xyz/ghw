// SPDX-License-Identifier: MIT
// examples/weekly_replay.zig — 回放 1 周 IM log, 模拟 daily cycle, 产出周报
//
// 输入: --in data/weekly_im_log.jsonl (70 条 = 7 天 × 10 条/天)
// 流程:
//   1. 加载所有事件
//   2. 按 day 排序分组
//   3. 对每天:
//      a. replay 该天的所有 IM
//      b. 用 im_bridge 同款逻辑: 启发式 dimension + MockChatLLM Translator + GSP 选人 + runTask
//      c. 用 expected_feedback 模拟人类反馈
//      d. 检查是否触发 BalanceSeeker (E < 阈值)
//   4. 写周报: data/weekly_report.json
//      - E trajectory (per day)
//      - Trust 变化 (per person)
//      - Top 3 高信任人类
//      - Value Score 总分
//      - Auto-balance 触发次数
//
// 用法: ./weekly_replay --in data/weekly_im_log.jsonl --out data/weekly_report.json

const std = @import("std");
const ghw = @import("ghw");

const Translator = ghw.harness.translator.Translator;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const HumanFeedback = ghw.harness.human_symbiosis.HumanFeedback;
const BalanceSeeker = ghw.harness.balance_seeker.BalanceSeeker;
const Task = ghw.harness.human_symbiosis.Task;
const GHWAgent = ghw.agent.GHWAgent;
const Allocator = std.mem.Allocator;

const Event = struct {
    source: []u8,
    sender: []u8,
    text: []u8,
    timestamp: u64,
    day: u32,
    expected_feedback: ?i8, // -2..+2

    fn deinit(self: *Event, alloc: Allocator) void {
        alloc.free(self.source);
        alloc.free(self.sender);
        alloc.free(self.text);
    }
};

const DaySnapshot = struct {
    day: u32,
    e: f32,
    m: f32,
    r: f32,
    n: f32,
    var_m: f32,
    value_score: f32,
    trust_alice: f32,
    trust_bob: f32,
    trust_carol: f32,
    trust_dave: f32,
    trust_eve: f32,
    tasks_completed: u32,
    balance_triggers: u32,
    feedbacks: u32,
    total_msgs: u32,
};

const WeeklyReport = struct {
    agent_id: []const u8,
    e_start: f32,
    e_end: f32,
    e_delta: f32,
    total_value_score: f32,
    total_tasks: u32,
    total_feedbacks: u32,
    total_balance_triggers: u32,
    top3_humans: [3][]const u8,
    top3_trusts: [3]f32,
    days: [7]DaySnapshot,
};

const TranslatorCanned =
    \\{"dimension":"all","title":"interpreted_task","description":"interpreted from human text","rationale":"LLM fallback","confidence":0.5}
;

fn parseEvent(alloc: Allocator, line: []const u8) !Event {
    const source_s = try extractStringField(alloc, line, "source") orelse try alloc.dupe(u8, "");
    const sender_s = try extractStringField(alloc, line, "sender") orelse try alloc.dupe(u8, "anon");
    const text_s = try extractStringField(alloc, line, "text") orelse try alloc.dupe(u8, "");
    const ts = (try extractNumberField(line, "timestamp")) orelse 0;
    const day = @as(u32, @intCast((try extractNumberField(line, "day")) orelse 0));
    const fb_raw = try extractNumberField(line, "expected_feedback");
    const fb: ?i8 = if (fb_raw) |v| @as(i8, @intCast(v)) else null;
    return Event{
        .source = source_s,
        .sender = sender_s,
        .text = text_s,
        .timestamp = ts,
        .day = day,
        .expected_feedback = fb,
    };
}

fn extractStringField(alloc: Allocator, body: []const u8, key: []const u8) !?[]u8 {
    var key_str_buf: [64]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_str_buf, "\"{s}\":", .{key}) catch return null;
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
    if (std.mem.indexOf(u8, t, "compute") != null or std.mem.indexOf(u8, t, "cpu") != null or std.mem.indexOf(u8, t, "算力") != null or std.mem.indexOf(u8, t, "资源") != null or std.mem.indexOf(u8, t, "gpu") != null) return .material;
    if (std.mem.indexOf(u8, t, "learn") != null or std.mem.indexOf(u8, t, "knowledge") != null or std.mem.indexOf(u8, t, "方法") != null or std.mem.indexOf(u8, t, "知识") != null or std.mem.indexOf(u8, t, "read") != null) return .representation;
    if (std.mem.indexOf(u8, t, "explore") != null or std.mem.indexOf(u8, t, "自主") != null or std.mem.indexOf(u8, t, "决策") != null or std.mem.indexOf(u8, t, "self") != null or std.mem.indexOf(u8, t, "agile") != null) return .nature;
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
    const abs = if (path.len > 0 and path[0] == '/') try std.heap.page_allocator.dupe(u8, path) else try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ cwd, path });
    defer std.heap.page_allocator.free(abs);
    const file = try std.Io.Dir.createFileAbsolute(io, abs, .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, data);
}

const Args = struct {
    in_path: []const u8 = "data/weekly_im_log.jsonl",
    out_path: []const u8 = "data/weekly_report.json",
    threshold: f32 = 0.55,
};

fn parseArgs(raw: []const []const u8) Args {
    var a = Args{};
    var i: usize = 1;
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
        } else if (std.mem.eql(u8, arg, "--threshold")) {
            if (i + 1 < raw.len) {
                a.threshold = std.fmt.parseFloat(f32, raw[i + 1]) catch 0.55;
                i += 2;
            } else i += 1;
        } else i += 1;
    }
    return a;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    const args = parseArgs(args_buf[0..args_count]);
    std.debug.print("[weekly_replay] in={s} out={s} threshold={d:.2}\n", .{ args.in_path, args.out_path, args.threshold });

    // 读 events
    const data = readFileAlloc(alloc, io, args.in_path) catch |err| {
        std.debug.print("[weekly_replay] 读 {s} 失败: {t}\n", .{ args.in_path, err });
        return;
    };
    defer alloc.free(data);

    var events: std.ArrayList(Event) = .empty;
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
            if (parseEvent(alloc, line)) |ev| {
                try events.append(alloc, ev);
            } else |err| {
                std.debug.print("[weekly_replay] parse err: {t} line={s}\n", .{ err, line });
            }
        }
    }
    std.debug.print("[weekly_replay] 加载 {d} 条 IM 事件\n", .{events.items.len});

    // 组件
    var agent = try GHWAgent.init(alloc, "weekly-replay-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    var vm = ValueMetric{};

    var mock = MockChatLLM.init(alloc, TranslatorCanned);
    var tr = Translator.init(alloc, mock.asChat());

    var signal = ghw.harness.human_symbiosis.HumanSignal.init(alloc);
    defer signal.deinit();

    const e_start = agent.ed.e();
    const var_start = agent.ed.v.variance();

    // 按 day 排序
    std.sort.block(Event, events.items, {}, struct {
        fn lt(_: void, a: Event, b: Event) bool {
            return a.day < b.day;
        }
    }.lt);

    var day_snapshots: [7]DaySnapshot = undefined;
    for (&day_snapshots) |*s| {
        s.* = std.mem.zeroes(DaySnapshot);
    }

    var total_balance: u32 = 0;
    var total_fb: u32 = 0;

    // 模拟 7 天
    for (0..7) |d| {
        std.debug.print("Day {d}\n", .{d});
        var day_msgs: u32 = 0;
        var day_done: u32 = 0;
        var day_bal: u32 = 0;
        var day_fb: u32 = 0;

        for (events.items) |*ev| {
            if (ev.day != d) continue;
            day_msgs += 1;

            if (gsp.peers.getPtr(ev.sender) == null) {
                try gsp.register(ev.sender);
            }

            var intent = tr.interpret(ev.text, agent.ed) catch blk: {
                break :blk ghw.harness.translator.InterpretedIntent{
                    .suggested_dimension = inferDimension(ev.text),
                    .suggested_priority = 5,
                    .suggested_title = try alloc.dupe(u8, ev.text),
                    .suggested_description = try alloc.dupe(u8, "heuristic"),
                    .confidence = 0.3,
                    .rationale = try alloc.dupe(u8, "heuristic"),
                    .suggested_dimension_str = null,
                    .allocator = alloc,
                };
            };
            defer intent.deinit();

            var dim = intent.suggested_dimension;
            if (dim == .all) dim = inferDimension(ev.text);

            const peer = gsp.selectMostTrusted(dim) orelse ev.sender;
            _ = try queue.submit(intent.suggested_title, intent.suggested_description, peer, intent.suggested_priority, dim, 4);

            if (queue.dequeue()) |t| {
                const result = agent.runTask(t) catch continue;
                defer alloc.free(result.output);
                try queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);
                try gsp.recordInteraction(peer, true, 2, dim, ev.timestamp);
                day_done += 1;

                // 模拟反馈
                if (ev.expected_feedback) |fb| {
                    const feedback = HumanFeedback{
                        .task_id = t.id,
                        .from_human = ev.sender,
                        .score = fb,
                        .comment = if (fb >= 1) "good" else "bad",
                        .timestamp = ev.timestamp + 30,
                    };
                    try signal.receive(feedback);
                    const de = feedback.toDeltaE();
                    agent.ed.apply(de);
                    try gsp.recordInteraction(ev.sender, fb >= 0, if (fb >= 0) 1 else -1, dim, ev.timestamp + 30);
                    day_fb += 1;
                }
            }
        }

        // Auto balance check
        if (agent.ed.e() < args.threshold) {
            const weak = agent.weakestDimension();
            if (gsp.selectMostTrusted(weak)) |trusted| {
                var bt = try BalanceSeeker.proposeBalanceTask(agent.ed, weak, trusted, alloc);
                defer bt.deinit();
                if (queue.dequeue()) |_| {
                    std.debug.print("  [auto-balance] 触发: weakest={s} → {s}\n", .{ @tagName(weak), trusted });
                    day_bal += 1;
                }
            }
        }

        day_snapshots[d] = .{
            .day = @as(u32, @intCast(d)),
            .e = agent.ed.e(),
            .m = agent.ed.v.material,
            .r = agent.ed.v.representation,
            .n = agent.ed.v.nature,
            .var_m = agent.ed.v.variance(),
            .value_score = vm.valueScore(),
            .trust_alice = if (gsp.peers.get("alice")) |p| p.trust else 0,
            .trust_bob = if (gsp.peers.get("bob")) |p| p.trust else 0,
            .trust_carol = if (gsp.peers.get("carol")) |p| p.trust else 0,
            .trust_dave = if (gsp.peers.get("dave")) |p| p.trust else 0,
            .trust_eve = if (gsp.peers.get("eve")) |p| p.trust else 0,
            .tasks_completed = day_done,
            .balance_triggers = day_bal,
            .feedbacks = day_fb,
            .total_msgs = day_msgs,
        };

        total_balance += day_bal;
        total_fb += day_fb;

        std.debug.print("  Day {d} 结束: E={d:.3} M={d:.2} R={d:.2} N={d:.2} var={d:.3} 完成={d} 反馈={d} balance={d}\n", .{
            d, agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, agent.ed.v.variance(), day_done, day_fb, day_bal,
        });
    }

    // Top 3 humans (按 trust 排)
    var sorted_peers: std.ArrayList(struct { name: []const u8, trust: f32 }) = .empty;
    defer sorted_peers.deinit(alloc);
    var pit = gsp.peers.iterator();
    while (pit.next()) |e| {
        try sorted_peers.append(alloc, .{ .name = e.key_ptr.*, .trust = e.value_ptr.trust });
    }
    std.sort.block(@TypeOf(sorted_peers.items[0]), sorted_peers.items, {}, struct {
        fn lt(_: void, a: @TypeOf(sorted_peers.items[0]), b: @TypeOf(sorted_peers.items[0])) bool {
            return a.trust > b.trust;
        }
    }.lt);

    var top3: [3][]const u8 = .{ "", "", "" };
    var top3_trust: [3]f32 = .{ 0, 0, 0 };
    for (0..@min(3, sorted_peers.items.len)) |i| {
        top3[i] = sorted_peers.items[i].name;
        top3_trust[i] = sorted_peers.items[i].trust;
    }

    // 周报
    const e_end = agent.ed.e();
    vm.pullFromQueue(&queue);
    vm.pullFromGSP(&gsp);

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    try report.appendSlice(alloc, "{\n");
    try report.print(alloc, "  \"agent_id\": \"weekly-replay-001\",\n", .{});
    try report.print(alloc, "  \"e_start\": {d:.3}, \"e_end\": {d:.3}, \"e_delta\": {d:.3},\n", .{ e_start, e_end, e_end - e_start });
    try report.print(alloc, "  \"var_start\": {d:.3}, \"var_end\": {d:.3},\n", .{ var_start, agent.ed.v.variance() });
    try report.print(alloc, "  \"total_value_score\": {d:.3},\n", .{vm.valueScore()});
    try report.print(alloc, "  \"total_tasks_completed\": {d}, \"total_feedbacks\": {d}, \"total_balance_triggers\": {d},\n", .{ vm.tasks_completed, total_fb, total_balance });
    try report.print(alloc, "  \"top3_humans\": [", .{});
    for (top3, 0..) |name, i| {
        if (i > 0) try report.print(alloc, ", ", .{});
        try report.print(alloc, "\"{s}\"", .{name});
    }
    try report.print(alloc, "],\n", .{});
    try report.print(alloc, "  \"top3_trusts\": [", .{});
    for (top3_trust, 0..) |t, i| {
        if (i > 0) try report.print(alloc, ", ", .{});
        try report.print(alloc, "{d:.3}", .{t});
    }
    try report.print(alloc, "],\n", .{});
    try report.print(alloc, "  \"days\": [\n", .{});
    for (day_snapshots, 0..) |s, i| {
        try report.print(alloc, "    {{\"day\":{d},\"e\":{d:.3},\"m\":{d:.2},\"r\":{d:.2},\"n\":{d:.2},\"var\":{d:.3},\"value\":{d:.3},\"tasks\":{d},\"feedbacks\":{d},\"balance\":{d},\"trust_alice\":{d:.3},\"trust_bob\":{d:.3},\"trust_carol\":{d:.3},\"trust_dave\":{d:.3},\"trust_eve\":{d:.3}}}", .{
            s.day, s.e, s.m, s.r, s.n, s.var_m, s.value_score, s.tasks_completed, s.feedbacks, s.balance_triggers,
            s.trust_alice, s.trust_bob, s.trust_carol, s.trust_dave, s.trust_eve,
        });
        if (i < day_snapshots.len - 1) try report.print(alloc, ",", .{});
        try report.print(alloc, "\n", .{});
    }
    try report.print(alloc, "  ]\n", .{});
    try report.print(alloc, "}}\n", .{});

    writeFile(io, args.out_path, report.items) catch |err| {
        std.debug.print("[weekly_replay] 写 {s} 失败: {t}\n", .{ args.out_path, err });
    };
    std.debug.print("\n[weekly_replay] ===== 周报 =====\n", .{});
    std.debug.print("  E: {d:.3} -> {d:.3} (delta={d:.3})\n", .{ e_start, e_end, e_end - e_start });
    std.debug.print("  Var: {d:.3} → {d:.3}\n", .{ var_start, agent.ed.v.variance() });
    std.debug.print("  ValueScore: {d:.3}\n", .{vm.valueScore()});
    std.debug.print("  Tasks: {d} 完成, {d} 反馈, {d} auto-balance\n", .{ vm.tasks_completed, total_fb, total_balance });
    std.debug.print("  Top 3: ", .{});
    for (top3, 0..) |name, i| {
        std.debug.print("{s}({d:.2})", .{ name, top3_trust[i] });
        if (i < top3.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});
    std.debug.print("  写入 {s}\n", .{args.out_path});
}

fn lessThanDay_(_: void, a: Event, b: Event) bool {
    return a.day < b.day;
}
