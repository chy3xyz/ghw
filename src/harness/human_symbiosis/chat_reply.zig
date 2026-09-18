//! chat_reply — 用户 chat → LLM 回复 prompt (P14/P15: 全通道 buildContext + provenance)
//!
//! ui_server chat worker 用; 跟 RuleProposer/Reflection 同构: 先注入自传体记忆,
//! 再附当下状态 + 用户原话。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;
const Memory = @import("../memory.zig").Memory;
const GHWAgent = @import("../../agent/core.zig").GHWAgent;

/// Chat 回复是否注入 buildContext (P15 provenance)
pub const Meta = struct {
    memory_injected: bool = false,
    episode_count: u32 = 0,
    belief_count: u32 = 0,
    has_narrative: bool = false,
    context_chars: u32 = 0,
};

pub const ReplyBuild = struct {
    prompt: []u8,
    meta: Meta,
};

/// 构造 chat LLM user prompt + 记忆注入元数据
pub fn buildChatReply(
    alloc: Allocator,
    memory: *Memory,
    agent: *GHWAgent,
    user_text: []const u8,
    goal_name: []const u8,
    value_score: F,
    pending_tasks: u32,
    sys_cpu_pct: F,
    sys_mem_pct: F,
    sys_load: F,
) !ReplyBuild {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    const query_dim = Memory.weakestDim(
        agent.ed.v.material,
        agent.ed.v.representation,
        agent.ed.v.nature,
    );
    const query_text = try std.fmt.allocPrint(alloc, "{s} {s}", .{ user_text, goal_name });
    defer alloc.free(query_text);

    var meta = Meta{
        .has_narrative = memory.self_narrative.len > 0,
    };
    if (memory.beliefs.items.len > 0) {
        meta.belief_count = @intCast(@min(3, memory.beliefs.items.len));
    }
    if (memory.episodes.items.len > 0) {
        const eidx = memory.relevantEpisodes(alloc, query_dim, query_text, 3) catch null;
        if (eidx) |idx| {
            defer alloc.free(idx);
            meta.episode_count = @intCast(idx.len);
        }
    }

    if (memory.buildContext(alloc, query_dim, query_text, 5, 3)) |ctx| {
        defer alloc.free(ctx);
        try buf.print(alloc, "{s}\n\n", .{ctx});
        meta.context_chars = @intCast(ctx.len);
        meta.memory_injected = meta.has_narrative or meta.belief_count > 0 or meta.episode_count > 0 or
            std.mem.indexOf(u8, ctx, "相关往事") != null;
    } else |_| {}

    try buf.print(alloc,
        \\你是 GHW 数字生命, 正在和用户实时对话.
        \\
        \\当前状态:
        \\  tick={d}, E={d:.3} (M={d:.3} R={d:.3} N={d:.3}), top_goal={s}
        \\  系统: CPU {d:.0}%, 内存 {d:.0}%, 负载 {d:.1}
        \\  人类共生: value_score={d:.3}, pending_tasks={d}
        \\
        \\用户刚说: {s}
        \\
        \\请用 1-3 句话, 第一人称 ("我"), 自然地回应.
        \\- 语气随 E 变化; 若上方记忆块有相关往事, 可自然衔接
        \\- 用户给任务时, 确认已收到 (@task 或任务型语句可能已自动入队)
        \\- 不要 markdown, 不要代码块, 纯文本
    , .{
        agent.tick, agent.ed.e(),
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
        goal_name,
        sys_cpu_pct, sys_mem_pct, sys_load,
        value_score, pending_tasks,
        user_text,
    });

    return .{
        .prompt = try buf.toOwnedSlice(alloc),
        .meta = meta,
    };
}

/// 兼容旧调用: 仅返回 prompt
pub fn buildChatUserPrompt(
    alloc: Allocator,
    memory: *Memory,
    agent: *GHWAgent,
    user_text: []const u8,
    goal_name: []const u8,
    value_score: F,
    pending_tasks: u32,
    sys_cpu_pct: F,
    sys_mem_pct: F,
    sys_load: F,
) ![]u8 {
    const built = try buildChatReply(alloc, memory, agent, user_text, goal_name, value_score, pending_tasks, sys_cpu_pct, sys_mem_pct, sys_load);
    return built.prompt;
}

const testing = std.testing;

test "chat_reply: buildChatReply meta 标记 memory 注入" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = Memory.init(alloc, 7);
    defer mem.deinit();
    try mem.setSelfNarrative("我是测试生命, 最近在探索 nature");
    try mem.addBelief(.nature, "探索比静止更有价值", 0.9, &[_]u64{1});
    try mem.recordAt(io, .system_event, 1, "cycle 1 explore", "explore daemon cpu", 3, 0.05);

    var agent = try GHWAgent.init(alloc, "chat-reply-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    agent.tick = 42;
    agent.ed.v = .{ .material = 0.4, .representation = 0.5, .nature = 0.3 };

    const built = try buildChatReply(alloc, &mem, &agent, "帮我优化 daemon", "explore", 0.55, 2, 12, 45, 1.2);
    defer alloc.free(built.prompt);
    try testing.expect(built.meta.memory_injected);
    try testing.expect(built.meta.has_narrative);
    try testing.expect(built.meta.context_chars > 0);
    try testing.expect(std.mem.indexOf(u8, built.prompt, "autobiographical context") != null);
}

test "chat_reply: 空记忆 meta.memory_injected=false" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 7);
    defer mem.deinit();
    var agent = try GHWAgent.init(alloc, "chat-reply-empty", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    agent.ed.v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 };

    const built = try buildChatReply(alloc, &mem, &agent, "你好", "observe", 0, 0, 0, 0, 0);
    defer alloc.free(built.prompt);
    try testing.expect(!built.meta.memory_injected);
    try testing.expect(std.mem.indexOf(u8, built.prompt, "你好") != null);
}
