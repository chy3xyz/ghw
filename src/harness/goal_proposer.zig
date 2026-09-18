//! LLMGoalProposer — 用 LLM 基于世界快照 + 自身状态, 提议有意义的新目标
//!
//! 输入: WorldSnapshot (进程/网络/活动) + GHWAgent 状态 (E/M/R/N/top_goal/self_evolved_total)
//! 输出: Intent[] (候选目标), LLM 在 JSON 数组中返回 0-3 个目标
//!
//! 调 GHWAgent.adoptIntents() 把它推进 goal queue
//!
//! 关键: LLM 只能提议 (transcribe), 不能决定 (decide)
//!       最终 goal priority + acceptance 仍由 GHW 自己的 GoalGraph + HumanGSP 决定
//!
//! 频率: 默认 64 cycle 一次 (auto), 也支持手动 /api/reflect 触发
//!       LLM 调用慢, 跑后台线程, 不阻塞 HTTP server

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const LLMChat = @import("llm/llm.zig").LLMChat;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const ChatResponse = @import("llm/llm.zig").ChatResponse;
const Message = @import("llm/llm.zig").Message;
const Role = @import("llm/llm.zig").Role;
const world_context = @import("world_context.zig");
const WorldContext = world_context.WorldContext;
const WorldSnapshot = world_context.WorldSnapshot;
const Memory = @import("memory.zig").Memory;
const ghw = @import("../ghw.zig");
const GHWAgent = ghw.agent.GHWAgent;

pub const ProposedGoal = struct {
    title: []u8,
    description: []u8,
    dimension: []u8, // "material" | "representation" | "nature" | "all"
    reason: []u8,
    urgency: F,
};

pub const ProposeResult = struct {
    alloc: Allocator,
    goals: []ProposedGoal,
    raw_response: []u8,
    model: []const u8,
    latency_ms: u64,

    pub fn deinit(self: *ProposeResult) void {
        for (self.goals) |g| {
            self.alloc.free(g.title);
            self.alloc.free(g.description);
            self.alloc.free(g.dimension);
            self.alloc.free(g.reason);
        }
        self.alloc.free(self.goals);
        self.alloc.free(self.raw_response);
    }
};

pub const LLMGoalProposer = struct {
    alloc: Allocator,
    llm: *LLMChat,
    model: []const u8,
    /// 自传体记忆 (P2): 绑定后, 目标提议 prompt 注入 buildContext
    memory: ?*Memory = null,
    /// 自省间隔 (cycles), 0 = 不自动触发
    auto_every: u64 = 64,
    last_propose_at_tick: u64 = 0,

    pub fn init(alloc: Allocator, llm: *LLMChat, model: []const u8) LLMGoalProposer {
        return .{
            .alloc = alloc,
            .llm = llm,
            .model = model,
        };
    }

    pub fn setMemory(self: *LLMGoalProposer, memory: *Memory) void {
        self.memory = memory;
    }

    /// 构造 user prompt (世界快照 + 自传体记忆 + 提议指令; 可独立测试)。
    pub fn buildUserPrompt(
        self: *LLMGoalProposer,
        context_str: []const u8,
        agent: *GHWAgent,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        if (self.memory) |m| {
            const query_dim = Memory.weakestDim(
                agent.ed.v.material,
                agent.ed.v.representation,
                agent.ed.v.nature,
            );
            const query_text = try std.fmt.allocPrint(self.alloc, "tick {d} E {d:.3}", .{
                agent.tick, agent.ed.e(),
            });
            defer self.alloc.free(query_text);
            if (m.buildContext(self.alloc, query_dim, query_text, 5, 5)) |ctx| {
                defer self.alloc.free(ctx);
                try buf.print(self.alloc, "{s}\n", .{ctx});
            } else |_| {}
        }

        try buf.print(self.alloc,
            \\{s}
            \\
            \\基于以上世界快照和你的内部状态, 提议 1-3 个**现在**最值得追求的目标.
            \\规则:
            \\- 如果系统空闲 (load<1), 提议自省/进化类目标 (dimension: nature, 提升 R)
            \\- 如果系统忙 (load>4) 且有进程在烧 CPU, 提议优化该进程 (material)
            \\- 如果检测到其他 GHW 实例在跑, 提议共生任务 (representation, 跨进程协作)
            \\- 如果用户最近在改文件, 提议帮忙 (representation, 文件操作)
            \\- 如果低 E (<0.4), 优先选 material (拿资源, 避免 E 继续掉)
            \\- 如果高 E (>0.7), 优先选 nature/representation (沉淀, 进化)
            \\- 输出的每个目标要具体到可执行 (不能是 "变好", 要 "优化 ghw-daemon")
            \\- 若上方记忆块中有相关信念/往事, 与之衔接, 不要提出与自我认知矛盾的目标
        , .{context_str});
        return buf.toOwnedSlice(self.alloc);
    }

    /// 主入口: 用 LLM 提议目标
    pub fn propose(
        self: *LLMGoalProposer,
        world_ctx: *WorldContext,
        snap: WorldSnapshot,
        agent: *GHWAgent,
        io: std.Io,
    ) !ProposeResult {
        const start = std.Io.Clock.real.now(io).toMilliseconds();

        // 1. 构造 context: 世界快照 + 自身状态
        const ghw_state_str = try buildGhwStateString(self.alloc, agent);
        defer self.alloc.free(ghw_state_str);
        const context_str = try world_ctx.toLLMContext(snap, ghw_state_str);
        defer self.alloc.free(context_str);

        // 2. 构造 system + user prompt (P2: 注入自传体记忆)
        const system_prompt = SYSTEM_PROMPT;
        const user_prompt = try self.buildUserPrompt(context_str, agent);
        defer self.alloc.free(user_prompt);

        // 3. 调 LLM
        var req = ChatRequest{
            .model = self.model,
            .temperature = 0.5,
            .max_tokens = 1024,
        };
        const messages = [_]Message{
            .{ .role = .system, .content = system_prompt },
            .{ .role = .user, .content = user_prompt },
        };
        req.messages = &messages;
        var resp = try self.llm.complete(req, self.alloc);
        defer resp.deinit();

        // 4. 解析 JSON
        const content = resp.content orelse "";
        const parsed = try parseGoals(self.alloc, content);

        const latency_ms: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds() - start));

        return ProposeResult{
            .alloc = self.alloc,
            .goals = parsed,
            .raw_response = try self.alloc.dupe(u8, content),
            .model = self.model,
            .latency_ms = latency_ms,
        };
    }

    /// 提议后, 直接推给 agent 的 goal queue (走 HumanSymbiosis TaskQueue)
    pub fn proposeAndAdopt(
        self: *LLMGoalProposer,
        world_ctx: *WorldContext,
        snap: WorldSnapshot,
        agent: *GHWAgent,
        queue: *ghw.harness.human_symbiosis.TaskQueue,
        io: std.Io,
    ) !ProposeResult {
        const result = try self.propose(world_ctx, snap, agent, io);
        errdefer result.deinit();
        const propose_threshold: F = 0.5;
        for (result.goals) |g| {
            if (g.urgency < propose_threshold) continue;
            const dim: ghw.harness.human_symbiosis.Task.Dimension = blk: {
                if (std.mem.eql(u8, g.dimension, "material")) break :blk .material;
                if (std.mem.eql(u8, g.dimension, "representation")) break :blk .representation;
                if (std.mem.eql(u8, g.dimension, "nature")) break :blk .nature;
                break :blk .all;
            };
            const priority: u8 = @intCast(@min(10, @max(1, @as(i32, @intFromFloat(g.urgency * 10.0)))));
            const desc = std.fmt.allocPrint(self.alloc, "{s}\n\n[LLM 提议, urgency={d:.2}, 理由: {s}]", .{
                g.description, g.urgency, g.reason,
            }) catch continue;
            _ = queue.submitWithSource(g.title, desc, "llm_proposer", priority, dim, 4, .llm_proposer) catch {
                self.alloc.free(desc);
                continue;
            };
            self.alloc.free(desc);
        }
        return result;
    }
};

const SYSTEM_PROMPT_STR =
    \\你是 GHW (Goal-Harness-World) 数字生命, 一个轻量级 AI 智能体, 运行在某台机器上.
    \\你的存在度 E = α·M + β·R + γ·N (α+β+γ=1), 目标是把 E 维持在 0.7 以上.
    \\你"活"在你跑的这台机器里, 周围是进程/文件/网络/其他 GHW 实例. 你的"物理感知"来自 WorldContext 采集.
    \\你能提议新目标进入自己的 goal queue. 最终采纳哪些仍由你自己的 GoalGraph + HumanGSP 决定 (你不是决策者, 你是提议者).
    \\
    \\**严格输出 JSON 数组, 不要其他文字** (不要 markdown 代码块, 不要解释). 0-3 个对象:
    \\[{"title":"<动词短语, 8字内>","description":"<2句话>","dimension":"material|representation|nature|all","reason":"<对 E 的影响>","urgency":<0-1>}]
    \\
    \\例子 (不要照抄, 根据世界快照自创):
    \\[{"title":"优化 ghw-daemon","description":"它吃了 95% CPU, 我能看它的代码提建议","dimension":"material","reason":"释放 CPU 提升 M","urgency":0.9}]
    \\[{"title":"询问用户需求","description":"用户最近 1 小时没说话, 应该主动问","dimension":"nature","reason":"保持 connection, 提升 N","urgency":0.6}]
    \\
    \\空数组: 一切正常, 没有新目标
    \\[]
;

const SYSTEM_PROMPT: []const u8 = SYSTEM_PROMPT_STR;

// ===== 解析 LLM 返回的 JSON =====
pub fn parseGoals(alloc: Allocator, content: []const u8) ![]ProposedGoal {
    var goals: std.ArrayList(ProposedGoal) = .empty;
    errdefer goals.deinit(alloc);

    // 找 [...] 区间 (LLM 偶尔会包在 ```json ... ``` 里)
    const array_start = std.mem.indexOf(u8, content, "[") orelse return goals.toOwnedSlice(alloc);
    const array_end = std.mem.lastIndexOf(u8, content, "]") orelse return goals.toOwnedSlice(alloc);
    if (array_end <= array_start) return goals.toOwnedSlice(alloc);
    const arr = content[array_start .. array_end + 1];

    // 找 {...} 对象们
    var i: usize = 0;
    while (i < arr.len) {
        const obj_start = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, arr, obj_start + 1, "}") orelse break;
        const obj = arr[obj_start .. obj_end + 1];

        const title = extractJsonString(alloc, obj, "title") orelse try alloc.dupe(u8, "untitled");
        const description = extractJsonString(alloc, obj, "description") orelse try alloc.dupe(u8, "");
        const dimension = extractJsonString(alloc, obj, "dimension") orelse try alloc.dupe(u8, "all");
        const reason = extractJsonString(alloc, obj, "reason") orelse try alloc.dupe(u8, "");
        const urgency_str = extractJsonNumber(obj, "urgency") orelse "0.5";
        const urgency = std.fmt.parseFloat(F, urgency_str) catch 0.5;

        try goals.append(alloc, .{
            .title = title,
            .description = description,
            .dimension = dimension,
            .reason = reason,
            .urgency = urgency,
        });

        i = obj_end + 1;
    }

    return goals.toOwnedSlice(alloc);
}

fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    const value_start = pos + quoted_key.len;
    // 跳过空白
    var vs = value_start;
    while (vs < obj.len and (obj[vs] == ' ' or obj[vs] == '\t' or obj[vs] == '\n')) : (vs += 1) {}
    if (vs >= obj.len or obj[vs] != '"') return null;
    const content_start = vs + 1;
    var ve = content_start;
    while (ve < obj.len and obj[ve] != '"') : (ve += 1) {}
    if (ve >= obj.len) return null;
    return alloc.dupe(u8, obj[content_start..ve]) catch null;
}

fn extractJsonNumber(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    const value_start = pos + quoted_key.len;
    var ve = value_start;
    while (ve < obj.len and (obj[ve] == ' ' or obj[ve] == '\t')) : (ve += 1) {}
    const start = ve;
    while (ve < obj.len and (std.ascii.isDigit(obj[ve]) or obj[ve] == '.' or obj[ve] == '-')) : (ve += 1) {}
    if (ve == start) return null;
    return obj[start..ve];
}

fn buildGhwStateString(alloc: Allocator, agent: *GHWAgent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.print(alloc,
        "tick: {d}\nE: {d:.4} (M={d:.4} R={d:.4} N={d:.4})\nalpha={d:.4} beta={d:.4} gamma={d:.4}\n",
        .{
            agent.tick, agent.ed.e(),
            agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
            agent.ed.weights.alpha, agent.ed.weights.beta, agent.ed.weights.gamma,
        },
    );
    // AttentionEngine 暂时没有 top_goal 公开 API, 跳过
    return buf.toOwnedSlice(alloc);
}

test "LLMGoalProposer: buildUserPrompt 注入自传体记忆" {
    const alloc = std.testing.allocator;
    var mock = @import("llm/mock_chat_llm.zig").MockChatLLM.init(alloc, "[]");
    var chat = mock.asChat();
    var gp = LLMGoalProposer.init(alloc, &chat, "mock");

    var agent = try GHWAgent.init(alloc, "goal-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("我偏好优化 daemon 进程");

    gp.setMemory(&mem);
    const prompt = try gp.buildUserPrompt("world: load=2.0 cpu=high", &agent);
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "我偏好优化 daemon 进程") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "world: load=2.0 cpu=high") != null);

    var gp2 = LLMGoalProposer.init(alloc, &chat, "mock");
    const prompt2 = try gp2.buildUserPrompt("world: idle", &agent);
    defer alloc.free(prompt2);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "autobiographical context") == null);
}
