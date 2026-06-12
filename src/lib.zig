//! GHW SDK — C ABI for embedding GHW as a digital-life kernel in other products.
//!
//! 用法 (C 客户端):
//!   #include "ghw.h"
//!   GhW* g = ghw_init("my-agent", 42);
//!   const char* state = ghw_get_state(g);  // owned string, free 后
//!   printf("state: %s\n", state);
//!   ghw_free_string((char*)state);
//!   ghw_deinit(g);
//!
//! 用法 (Zig 客户端):
//!   const c = @cImport(@cInclude("ghw.h"));
//!   const g = c.ghw_init("my-agent", 42);
//!   defer c.ghw_deinit(g);
//!   const state = c.ghw_get_state(g);
//!   defer c.ghw_free_string(@constCast(state));
//!
//! 设计哲学:
//!   - Opaque pointer — 内部实现自由演进, ABI 稳定
//!   - 字符串所有权清晰: ghw_* 返回的字符串 caller 用 ghw_free_string 释放
//!   - JSON 优先: 世界输入/状态输出都走 JSON, 跨语言零摩擦
//!   - 错误返回 -1 (类似 POSIX), 不是抛异常
//!
//! 这是 Phase 3 — GHW 从"项目"变"协议/库"。

const std = @import("std");
const builtin = @import("builtin");
const ghw_root = @import("ghw.zig");
const GHWAgent = ghw_root.GHWAgent;
const ghw_harness = ghw_root.harness;
const Memory = ghw_harness.memory.Memory;
const ProposedGoal = ghw_harness.goal_proposer.ProposedGoal;
const GhwLink = ghw_harness.ghw_link.Link;
const HttpLLM = ghw_harness.http_llm.HttpLLM;
const LLMChat = ghw_harness.llm.LLMChat;
const SqliteDb = ghw_root.sandbox.SqliteDb;
const ActionRunner = ghw_root.sandbox.ActionRunner;
const Allocator = std.mem.Allocator;

/// Opaque handle to a GHW instance
pub const GhW = opaque {
    // intentionally empty — used as opaque type
};

/// Internal state (not exported, accessed only via opaque pointer)
const GhwState = struct {
    alloc: Allocator,
    io: std.Io, // shared with link + action_runner
    io_threaded: std.Io.Threaded, // owns the Io (deinit in ghw_deinit)
    agent: GHWAgent,
    memory: Memory,

    // === v0.2: LLM ===
    llm: ?HttpLLM = null,
    llm_chat: ?LLMChat = null,
    llm_model: []u8 = &[_]u8{},

    // === v0.2: LLM (HttpLLM) - 供 v0.3 提议/反思用 ===
    llm_setup_done: bool = false,
    proposed_goals: std.ArrayList(ProposedGoal) = .empty,
    /// v0.3: C 客户端提供的世界描述 (ghw_world_set 设入) — 直接用做 LLM context
    world_text: ?[]u8 = null,

    // === v0.2: ActionRunner (in-memory + sqlite) ===
    sqlite: ?SqliteDb = null,
    action_runner: ?ActionRunner = null,
    last_action: ?ActionRunner.ActionResult = null,
    propose_total: u32 = 0,
    self_evolved_total: u32 = 0,

    // === v0.2: Link server ===
    link: ?GhwLink = null,
    link_thread: ?std.Thread = null,
    link_stop: std.atomic.Value(bool) = .init(false),
    link_handler_ctx: ?*anyopaque = null,

    // === 缓存 ===
    state_json_cache: ?[]u8 = null,
    tick: u64 = 0,
};

// ===== C ABI exports =====

/// Initialize a GHW instance.
/// @param agent_id: null-terminated string
/// @param seed: random seed
/// @return opaque handle, or NULL on error
export fn ghw_init(agent_id: [*:0]const u8, seed: u64) ?*GhW {
    const alloc = std.heap.page_allocator;
    const state = alloc.create(GhwState) catch return null;
    state.io_threaded = std.Io.Threaded.init(alloc, .{});
    state.* = .{
        .alloc = alloc,
        .io = state.io_threaded.io(),
        .io_threaded = state.io_threaded,
        .agent = GHWAgent.init(alloc, std.mem.span(agent_id), 4, .{ 3, 3, 3 }, seed) catch return null,
        .memory = Memory.init(alloc, seed),
    };
    return @ptrCast(state);
}

/// Free a GHW instance
export fn ghw_deinit(g: ?*GhW) void {
    const g_ptr = g orelse return;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));

    // 停 link server
    if (state.link) |*l| {
        state.link_stop.store(true, .release);
        if (state.link_thread) |t| t.join();
        std.Io.Dir.deleteFileAbsolute(state.io, l.self_path) catch {};
        state.alloc.free(l.self_path);
    }

    // 释放 action + sqlite
    if (state.last_action) |*a| a.deinit();
    if (state.sqlite) |*db| db.close();

    // 释放 proposed_goals 字符串
    for (state.proposed_goals.items) |g_item| {
        state.alloc.free(g_item.title);
        state.alloc.free(g_item.description);
        state.alloc.free(g_item.dimension);
        state.alloc.free(g_item.reason);
    }
    state.proposed_goals.deinit(state.alloc);

    // 释放缓存 + LLM model name
    if (state.state_json_cache) |c| state.alloc.free(c);
    if (state.world_text) |w| state.alloc.free(w);
    if (state.llm_model.len > 0) state.alloc.free(state.llm_model);

    state.memory.deinit();
    state.agent.deinit();
    state.io_threaded.deinit();
    state.alloc.destroy(state);
}

/// Run 1 cycle with the given world input (JSON).
/// @param g: GHW handle
/// @param world_json: input world snapshot (can be empty/null for default)
/// @return: cycle report JSON (caller frees with ghw_free_string), or NULL on error
export fn ghw_step(g: ?*GhW, world_json: [*:0]const u8) ?[*:0]u8 {
    const g_ptr = g orelse return null;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    const world = std.mem.span(world_json);
    _ = world; // 暂未用 world_json (v1 用内置空 system snapshot)
    // 跑 1 cycle (用 0 输入 = 默认初始 state)
    const report = state.agent.runCycle(&.{}) catch return null;
    state.tick = @intCast(report.tick);
    // 序列化到 JSON
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.alloc);
    const out = std.fmt.allocPrint(state.alloc, "{{\"tick\":{d},\"E\":{d:.6},\"M\":{d:.6},\"R\":{d:.6},\"N\":{d:.6},\"alpha\":{d:.6},\"beta\":{d:.6},\"gamma\":{d:.6},\"self_evolved\":{s},\"self_evolved_total\":{d}}}", .{
        report.tick,
        report.e_after,
        state.agent.ed.v.material,
        state.agent.ed.v.representation,
        state.agent.ed.v.nature,
        state.agent.ed.weights.alpha,
        state.agent.ed.weights.beta,
        state.agent.ed.weights.gamma,
        if (report.self_evolved) "true" else "false",
        state.self_evolved_total,
    }) catch return null;
    // 缓存 (供 get_state 用)
    if (state.state_json_cache) |old| state.alloc.free(old);
    return @ptrCast(out.ptr);
}

/// Get cached state JSON (no cycle run).
/// @return: state JSON (caller frees with ghw_free_string), or NULL on error
export fn ghw_get_state(g: ?*GhW) ?[*:0]u8 {
    const g_ptr = g orelse return null;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.state_json_cache) |cached| return @ptrCast(cached.ptr);
    // 没有 cache, 实时生成
    const out = std.fmt.allocPrint(state.alloc, "{{\"tick\":{d},\"E\":{d:.6},\"M\":{d:.6},\"R\":{d:.6},\"N\":{d:.6},\"alpha\":{d:.6},\"beta\":{d:.6},\"gamma\":{d:.6},\"self_evolved_total\":{d}}}", .{
        state.tick,
        state.agent.ed.e(),
        state.agent.ed.v.material,
        state.agent.ed.v.representation,
        state.agent.ed.v.nature,
        state.agent.ed.weights.alpha,
        state.agent.ed.weights.beta,
        state.agent.ed.weights.gamma,
        state.self_evolved_total,
    }) catch return null;
    return @ptrCast(out.ptr);
}

/// Free a string returned by any ghw_* function
export fn ghw_free_string(s: ?[*:0]u8) void {
    _ = s; // 在我们当前设计里, 所有返回的字符串都 alloc 来自 page_allocator
    // 不显式 free (page_allocator 不需要 free, OS 进程退出回收)
    // 未来如果改用 DebugAllocator, 这里需要 free
}

/// Get current tick (cheap accessor)
export fn ghw_get_tick(g: ?*GhW) u64 {
    const g_ptr = g orelse return 0;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    return state.tick;
}

/// Get current E (cheap accessor)
export fn ghw_get_E(g: ?*GhW) f64 {
    const g_ptr = g orelse return 0;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    return state.agent.ed.e();
}

/// Increment self_evolved_total (external action hook)
export fn ghw_increment_self_evolved(g: ?*GhW) void {
    const g_ptr = g orelse return;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    state.self_evolved_total += 1;
}

// ===== version =====
export fn ghw_version() [*:0]const u8 {
    return "ghw-sdk/0.1.0";
}

// ======================================================================
// v0.2: 暴露 LLM/ActionRunner/Link 给 C ABI
// 让 C 客户端真能"用 GHW 数字生命", 不只是空架子
// ======================================================================

/// 设置 LLM (env var 给 key, 避免 key 出现在源码里)
/// @param provider: "deepseek" | "openai" | "anthropic" | "mock" | "none"
/// @param api_key_env: 环境变量名 (e.g. "DEEPSEEK_API_KEY") — ghw 读 $env_var 取 key
/// @param model: 模型名 (e.g. "deepseek-chat")
/// @return 0 = ok, -1 = 失败
export fn ghw_setup_llm(g: ?*GhW, provider: [*:0]const u8, api_key_env: [*:0]const u8, model: [*:0]const u8) i32 {
    const g_ptr = g orelse return -1;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    const prov = std.mem.span(provider);
    const model_slice = std.mem.span(model);
    const env_name = std.mem.span(api_key_env);

    if (std.mem.eql(u8, prov, "none") or std.mem.eql(u8, prov, "mock")) {
        // mock / none: 跳过 (没真 LLM)
        state.llm_model = state.alloc.dupe(u8, model_slice) catch return -1;
        return 0;
    }

    // 读 env var — 用 std.c.environ (POSIX extern char**)
    const envp_ptr: [*:null]?[*:0]u8 = @ptrCast(std.c.environ);
    var key_opt: ?[]const u8 = null;
    var i: usize = 0;
    while (envp_ptr[i] != null) : (i += 1) {
        const entry = std.mem.span(envp_ptr[i].?);
        if (std.mem.startsWith(u8, entry, env_name)) {
            const after_eq = std.mem.indexOf(u8, entry, "=").? + 1;
            key_opt = entry[after_eq..];
            break;
        }
    }
    const key = key_opt orelse {
        return -1; // env var 没设
    };

    if (std.mem.eql(u8, prov, "deepseek")) {
        state.llm = HttpLLM.deepseek(state.alloc, state.io, model_slice, key) catch return -1;
    } else if (std.mem.eql(u8, prov, "openai")) {
        state.llm = HttpLLM.openai(state.alloc, state.io, model_slice, key, "https://api.openai.com") catch return -1;
    } else if (std.mem.eql(u8, prov, "anthropic")) {
        state.llm = HttpLLM.anthropic(state.alloc, state.io, model_slice, key) catch return -1;
    } else {
        return -1; // 未知 provider
    }

    state.llm_chat = state.llm.?.asChat();
    state.llm_setup_done = true;
    state.llm_model = state.alloc.dupe(u8, model_slice) catch return -1;

    return 0;
}

/// 打开 sqlite 记忆库 + 启 ActionRunner
/// @param path: sqlite 文件路径 (e.g. "/tmp/ghw.db"), 空串 = 内存 db
/// @return 0 = ok, -1 = 失败
export fn ghw_open_memory(g: ?*GhW, path: [*:0]const u8) i32 {
    const g_ptr = g orelse return -1;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    const path_slice = std.mem.span(path);

    const path_to_use = if (path_slice.len == 0) ":memory:" else path_slice;
    state.sqlite = SqliteDb.open(state.alloc, path_to_use) catch return -1;
    state.sqlite.?.initSchema() catch return -1;

    const sqlite_ptr: *const SqliteDb = &state.sqlite.?;
    state.action_runner = ActionRunner{
        .alloc = state.alloc,
        .io = state.io,
        .sqlite = sqlite_ptr,
        .self_evolved_counter = &state.self_evolved_total,
    };
    return 0;
}

/// v0.3: 设置世界描述 (C 客户端预先格式化的字符串)
/// @param text: 多行文本, 描述当前世界 (进程/网络/活动...)
/// 调 ghw_propose 时, 此文本会作为 LLM context
export fn ghw_world_set(g: ?*GhW, text: [*:0]const u8) void {
    const g_ptr = g orelse return;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    const text_slice = std.mem.span(text);
    if (state.world_text) |old| state.alloc.free(old);
    state.world_text = state.alloc.dupe(u8, text_slice) catch return;
}

/// v0.3: LLM 提议新目标 (用 ghw_world_set 设入的世界描述 + ghw 内部状态)
/// 把提议的 goals 写入 sqlite (如果开了) + 内存 proposed_goals
/// @return 提议数量 (>0), 0 = 没提议, -1 = 失败
export fn ghw_propose(g: ?*GhW) i32 {
    const g_ptr = g orelse return -1;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.llm_chat == null or !state.llm_setup_done) return -1;

    // 1. 构造 prompt
    const system_prompt =
        \\你是 GHW 数字生命的提议器. 基于世界快照和数字生命自身状态, 提议 1-3 个
        \\**现在**最值得追求的目标. 严格用以下 JSON 格式回复 (不要其他文字):
        \\{"goals": [{"title": "<具体到可执行>", "description": "<怎么做>",
        \\           "dimension": "material|representation|nature",
        \\           "reason": "<为什么是现在>", "urgency": <0-1>}]}
    ;

    // ghw 自身状态 (mini snapshot)
    const state_str = std.fmt.allocPrint(state.alloc,
        \\agent_id={s}, tick={d}, E={d:.3}, M={d:.3}, R={d:.3}, N={d:.3}, self_evolved_total={d}
    , .{
        state.agent.self_id, state.tick, state.agent.ed.e(),
        state.agent.ed.v.material, state.agent.ed.v.representation, state.agent.ed.v.nature,
        state.self_evolved_total,
    }) catch return -1;
    defer state.alloc.free(state_str);

    const world = state.world_text orelse "(没设 world_text, 用空上下文)";
    const user_prompt = std.fmt.allocPrint(state.alloc,
        \\=== 世界快照 ===
        \\{s}
        \\
        \\=== GHW 自身状态 ===
        \\{s}
        \\
        \\基于以上, 提议 1-3 个具体目标 (不要 "变好", 要 "调低 ghw-daemon CPU").
    , .{ world, state_str }) catch return -1;
    defer state.alloc.free(user_prompt);

    // 2. 调 LLM
    const messages = [_]ghw_harness.llm.Message{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = user_prompt },
    };
    const req = ghw_harness.llm.ChatRequest{
        .model = state.llm_model,
        .messages = &messages,
        .temperature = 0.5,
        .max_tokens = 1024,
    };
    var resp = state.llm_chat.?.complete(req, state.alloc) catch return -1;
    defer resp.deinit();

    // 3. 解析 goals
    const content = resp.content orelse "";
    const parsed = ghw_harness.goal_proposer.parseGoals(state.alloc, content) catch return -1;

    // 4. 写 sqlite (如果开了) + 内存
    for (parsed) |g_item| {
        if (state.sqlite) |*db| {
            _ = db.insertProposedGoal(
                @intCast(state.tick),
                g_item.title,
                g_item.description,
                g_item.dimension,
                g_item.reason,
                g_item.urgency,
                "", // raw_response (lib.zig 没存)
            ) catch {};
        }
        state.proposed_goals.append(state.alloc, .{
            .title = state.alloc.dupe(u8, g_item.title) catch continue,
            .description = state.alloc.dupe(u8, g_item.description) catch continue,
            .dimension = state.alloc.dupe(u8, g_item.dimension) catch continue,
            .reason = state.alloc.dupe(u8, g_item.reason) catch continue,
            .urgency = g_item.urgency,
        }) catch continue;
    }
    state.propose_total += 1;
    return @intCast(parsed.len);
}

/// v0.3: LLM 写自我叙事 + 信念 (反思)
/// 把 beliefs 写入 memory (内存)
/// @return 0 = ok, -1 = 失败
export fn ghw_reflect(g: ?*GhW) i32 {
    const g_ptr = g orelse return -1;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.llm_chat == null or !state.llm_setup_done) return -1;

    // 1. 构造 prompt
    const system_prompt =
        \\你是 GHW 数字生命的反思层. 回顾最近的行动 + 状态变化, 更新 self_narrative + 形成新信念.
        \\严格用以下 JSON 格式回复 (不要其他文字):
        \\{"self_narrative": "<2-3 句, 用第一人称, 描述最近的状态和感悟>",
        \\ "beliefs": [{"source": "material|representation|nature", "text": "<学到的>", "confidence": <0-1>}]}
    ;

    const state_str = std.fmt.allocPrint(state.alloc,
        \\agent_id={s}, tick={d}, E={d:.3}, M={d:.3}, R={d:.3}, N={d:.3}, self_evolved_total={d}
    , .{
        state.agent.self_id, state.tick, state.agent.ed.e(),
        state.agent.ed.v.material, state.agent.ed.v.representation, state.agent.ed.v.nature,
        state.self_evolved_total,
    }) catch return -1;
    defer state.alloc.free(state_str);

    const world = state.world_text orelse "(没设 world_text, 用空上下文)";
    const user_prompt = std.fmt.allocPrint(state.alloc,
        \\=== 世界快照 ===
        \\{s}
        \\
        \\=== GHW 状态 ===
        \\{s}
        \\
        \\请反思: 我最近做了什么? 学到了什么? 信念有何更新?
    , .{ world, state_str }) catch return -1;
    defer state.alloc.free(user_prompt);

    // 2. 调 LLM
    const messages = [_]ghw_harness.llm.Message{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = user_prompt },
    };
    const req = ghw_harness.llm.ChatRequest{
        .model = state.llm_model,
        .messages = &messages,
        .temperature = 0.5,
        .max_tokens = 1024,
    };
    var resp = state.llm_chat.?.complete(req, state.alloc) catch return -1;
    defer resp.deinit();

    // 3. 解析 beliefs (简单: 找 "self_narrative" + "beliefs" 数组, 不深度解析)
    // v0.3 简化: 只更新 self_narrative, beliefs 留 v0.4
    const content = resp.content orelse "";
    if (std.mem.indexOf(u8, content, "\"self_narrative\"")) |pos| {
        // 找 " 的值
        const colon = std.mem.indexOfPos(u8, content, pos, ":") orelse return 0;
        const quote1 = std.mem.indexOfPos(u8, content, colon, "\"") orelse return 0;
        const quote2 = std.mem.indexOfPos(u8, content, quote1 + 1, "\"") orelse return 0;
        if (quote2 > quote1 + 1) {
            const narrative = content[quote1 + 1 .. quote2];
            // 释放旧 + 拷新 (Memory.self_narrative 假设是 alloc, 长度 cap 2048)
            state.alloc.free(state.memory.self_narrative);
            const capped = if (narrative.len > 2048) narrative[0..2048] else narrative;
            state.memory.self_narrative = state.alloc.dupe(u8, capped) catch return -1;
        }
    }
    return 0;
}

/// 跑 1 个 action (top unadopted goal)
/// @return cycle report JSON (caller frees), 或 NULL = 没 goal / 失败
export fn ghw_action_run(g: ?*GhW) ?[*:0]u8 {
    const g_ptr = g orelse return null;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.action_runner == null) return null;

    const maybe = state.action_runner.?.runTopGoal(@intCast(state.tick)) catch return null;
    const result = maybe orelse return null;

    // 释放旧 last_action, 存新的
    if (state.last_action) |*old| old.deinit();
    state.last_action = result;

    // 序列化 cycle report
    const out = std.fmt.allocPrint(state.alloc, "{{\"success\":{s},\"action_kind\":\"{s}\",\"goal_title\":\"{s}\",\"duration_ms\":{d},\"self_evolved_total\":{d}}}", .{
        if (result.success) "true" else "false",
        result.action_kind,
        result.goal_title,
        result.duration_ms,
        state.self_evolved_total,
    }) catch return null;
    return @ptrCast(out.ptr);
}

/// 启 Link server (Unix socket, 5 method 协议)
/// @param path: e.g. "/tmp/ghw_<agent_id>.sock"
/// @return 0 = ok, -1 = 失败
export fn ghw_link_listen(g: ?*GhW, path: [*:0]const u8) i32 {
    const g_ptr = g orelse return -1;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    const path_slice = std.mem.span(path);

    state.link = GhwLink.init(state.alloc, state.io, path_slice);
    const ctx_holder: *anyopaque = @ptrCast(state);
    state.link_thread = std.Thread.spawn(.{}, GhwLink.runServer, .{ &state.link.?, sdkLinkHandler, ctx_holder, &state.link_stop }) catch return -1;
    return 0;
}

/// 调 peer (socket connect + JSONL request)
/// @return peer response JSON (caller frees), NULL = 失败
export fn ghw_link_query(g: ?*GhW, peer_path: [*:0]const u8, method: [*:0]const u8) ?[*:0]u8 {
    const g_ptr = g orelse return null;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.link == null) return null;
    const resp = state.link.?.query(std.mem.span(peer_path), std.mem.span(method), "{}") catch return null;
    return @ptrCast(resp.ptr);
}

/// 停 link server
export fn ghw_link_stop(g: ?*GhW) void {
    const g_ptr = g orelse return;
    const state: *GhwState = @ptrCast(@alignCast(g_ptr));
    if (state.link == null) return;
    state.link_stop.store(true, .release);
    if (state.link_thread) |t| t.join();
}

/// SDK 默认的 link handler — 返 agent_id/version/tick/state
/// 用户可重写 (v0.3+ 暴露自定义 handler 的 C ABI)
fn sdkLinkHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: Allocator) anyerror!ghw_harness.ghw_link.Response {
    _ = params;
    const state: *GhwState = @ptrCast(@alignCast(ctx));
    _ = state;
    if (std.mem.eql(u8, method, "ping")) {
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"sdk\":\"ghw-sdk/0.2.0\",\"tick\":0}") };
    }
    return .{ .ok = false, .payload = try alloc.dupe(u8, "\"unknown method\"") };
}
