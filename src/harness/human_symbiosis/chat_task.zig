//! chat_task — 用户 chat 消息 → TaskQueue (P11/P12)
//!
//! 检测任务型语句, 以 from_human="human" 入队并注册 GSP peer。
//! `@task` 前缀强制入队 (跳过关键词启发式)。

const std = @import("std");
const Allocator = std.mem.Allocator;
const GHWAgent = @import("../../agent/core.zig").GHWAgent;
const Task = @import("task_queue.zig").Task;
const TaskQueue = @import("task_queue.zig").TaskQueue;
const HumanGSP = @import("human_gsp.zig").HumanGSP;

pub const human_peer_id = "human";

pub const TaskBody = struct {
    body: []const u8,
    forced: bool,
};

/// 剥除 `@task` / `@task:` 前缀; 无则 null
pub fn stripTaskPrefix(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "@task")) return null;
    var i: usize = 5;
    while (i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t')) i += 1;
    if (i >= text.len) return null;
    return text[i..];
}

/// 解析 chat 正文: forced=true 表示 @task 强制入队
pub fn parseTaskBody(text: []const u8) TaskBody {
    if (stripTaskPrefix(text)) |rest| return .{ .body = rest, .forced = true };
    return .{ .body = text, .forced = false };
}

/// 启发式: 用户是否在投递任务 (保守, 避免每条 chat 都入队)
pub fn isTaskLike(text: []const u8) bool {
    if (text.len < 6) return false;
    const kws = [_][]const u8{
        "帮我",     "请帮",     "任务",     "麻烦你",   "麻烦",
        "能不能",   "可不可以", "请做",     "帮我做",   "去做",
        "完成一下", "处理一下", "实现",
    };
    for (kws) |kw| {
        if (std.mem.indexOf(u8, text, kw) != null) return true;
    }
    return false;
}

fn weakestDimension(agent: *const GHWAgent) Task.Dimension {
    const m = agent.ed.v.material;
    const r = agent.ed.v.representation;
    const n = agent.ed.v.nature;
    if (m <= r and m <= n) return .material;
    if (r <= m and r <= n) return .representation;
    return .nature;
}

fn truncateTitle(alloc: Allocator, text: []const u8, max_len: usize) ![]u8 {
    var end = @min(text.len, max_len);
    if (std.mem.indexOfScalar(u8, text[0..end], '\n')) |nl| end = nl;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
    if (end == 0) end = @min(text.len, max_len);
    return try alloc.dupe(u8, text[0..end]);
}

/// 任务型 chat → TaskQueue; 非任务返回 null
pub fn maybeSubmitFromChat(
    gsp: *HumanGSP,
    queue: *TaskQueue,
    agent: *const GHWAgent,
    alloc: Allocator,
    user_text: []const u8,
) !?u64 {
    const parsed = parseTaskBody(user_text);
    if (!parsed.forced and !isTaskLike(parsed.body)) return null;
    if (parsed.body.len < 2) return null;
    try gsp.register(human_peer_id);
    const title = try truncateTitle(alloc, parsed.body, 48);
    defer alloc.free(title);
    const id = try queue.submitWithSource(
        title,
        parsed.body,
        human_peer_id,
        if (parsed.forced) 8 else 7,
        weakestDimension(@constCast(agent)),
        4,
        if (parsed.forced) .chat_forced else .chat_heuristic,
    );
    return id;
}

const testing = std.testing;
const GHWAgentMod = @import("../../agent/core.zig");

test "chat_task: isTaskLike 关键词" {
    try testing.expect(isTaskLike("帮我优化一下 daemon"));
    try testing.expect(isTaskLike("有个任务给你"));
    try testing.expect(!isTaskLike("hi"));
    try testing.expect(!isTaskLike("E 多少"));
}

test "chat_task: @task 前缀强制入队" {
    const alloc = testing.allocator;
    var agent = try GHWAgentMod.GHWAgent.init(alloc, "chat-task-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    const id = try maybeSubmitFromChat(&gsp, &queue, &agent, alloc, "@task 写单元测试");
    try testing.expect(id != null);
    try testing.expectEqualStrings("写单元测试", queue.find(id.?).?.title);
    try testing.expectEqual(Task.Source.chat_forced, queue.find(id.?).?.source);

    const short = try maybeSubmitFromChat(&gsp, &queue, &agent, alloc, "@task x");
    try testing.expect(short == null);
}

test "chat_task: maybeSubmitFromChat 入队 human" {
    const alloc = testing.allocator;
    var agent = try GHWAgentMod.GHWAgent.init(alloc, "chat-task-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    const id = try maybeSubmitFromChat(&gsp, &queue, &agent, alloc, "帮我整理一下日志");
    try testing.expect(id != null);
    try testing.expectEqual(@as(u32, 1), queue.pending_count);
    const t = queue.find(id.?).?;
    try testing.expectEqualStrings(human_peer_id, t.from_human);
    try testing.expect(gsp.peers.get(human_peer_id) != null);

    const none = try maybeSubmitFromChat(&gsp, &queue, &agent, alloc, "你好");
    try testing.expect(none == null);
}
