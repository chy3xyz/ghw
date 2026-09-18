// SPDX-License-Identifier: MIT
// examples/ui_server.zig — GHW 数字生命 UI 服务器
//
// 架构: 单进程, 同时跑 GHW agent + HTTP server
//   - GET  /                      → ui/index.html
//   - GET  /app.js                → ui/app.js
//   - GET  /api/state             → JSON 状态快照 (只读, 不跑 cycle)
//   - POST /api/tick              → 推进 1 cycle, 返回 JSON 状态
//   - GET  /api/log               → JSON 成长日志 (最近 100 周期)
//   - GET  /api/chat/history      → HTML 片段 (HTMX swap)
//   - POST /api/chat              → 接收消息, 跑 1 cycle, append HTML 片段
//
// 用法:
//   ./zig-out/bin/ui_server --port 8080 --ui-dir ui --state state.json
//
//   # 后台长跑模式 (持续 tick)
//   ./zig-out/bin/ui_server --port 8080 --auto-tick-ms 100
//
// 设计: blocking accept loop. GET /api/state 只读; --auto-tick-ms 或 POST /api/tick 推进生命.
//       client 轮询 GET /api/state; chat 经 worker 跑 cycle (cycle_mutex 互斥).

const std = @import("std");
const builtin = @import("builtin");
const ghw = @import("ghw");
const ghw_harness = ghw.harness;
const GHWAgent = ghw.GHWAgent;
const SystemCollector = ghw_harness.system_collector.SystemCollector;
const WorldContext = ghw_harness.world_context.WorldContext;
const Memory = ghw_harness.memory.Memory;
const TaskQueue = ghw_harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw_harness.human_symbiosis.HumanGSP;
const HumanSignal = ghw_harness.human_symbiosis.HumanSignal;
const Personality = ghw_harness.personality.Personality;
const Reflection = ghw_harness.reflection.Reflection;
const SqliteDb = ghw.sandbox.SqliteDb;
const ActionRunner = ghw.sandbox.ActionRunner;
const HttpLLM = ghw.harness.http_llm.HttpLLM;
const GhwLink = ghw.harness.ghw_link.Link;
const GhwLinkHandler = ghw.harness.ghw_link.Handler;
const LLMChat = ghw.harness.llm.LLMChat;
const LLMMessage = ghw.harness.llm.Message;
const LLMRole = ghw.harness.llm.Role;
const LLMChatRequest = ghw.harness.llm.ChatRequest;
const LLMChatResponse = ghw.harness.llm.ChatResponse;
const Allocator = std.mem.Allocator;
const CycleReport = ghw.CycleReport;
const SystemSnapshot = ghw.harness.system_collector.SystemSnapshot;

const F = ghw.util.F;
const GROWTH_LOG_MAX: usize = 100;

const GrowthEntry = struct {
    tick: u64,
    timestamp: i64,
    E: F,
    M: F,
    R: F,
    N: F,
    goal: ?[]const u8,
    self_evolved: bool,
};

const ChatMessage = struct {
    sender: []const u8, // "human" | "ghw"
    text: []const u8,
    timestamp: i64,
    tick: u64,
    /// P15: GHW 回复是否注入 buildContext
    memory_injected: bool = false,
};

/// 后台 chat worker context (chat 异步化: POST 立刻返 user bubble,
/// worker thread 跑 cycle + LLM, 完成后用 mutex 写回 chat_history)
const ChatWorkerCtx = struct {
    app: *App,
    user_text: []u8, // owned copy
    user_text_esc: []u8, // owned copy (json-escaped, 给 UI 用)
    alloc: Allocator,

    fn run(self: *ChatWorkerCtx) void {
        defer {
            self.alloc.free(self.user_text);
            self.alloc.free(self.user_text_esc);
            self.alloc.destroy(self);
        }
        const app = self.app;

        // 1. 推 user event + 采本机真信号
        app.sys_collector.pushUserEvent(self.user_text) catch |err| {
            std.debug.print("[chat-worker] pushUserEvent 失败: {t}\n", .{err});
            return;
        };

        // P11: 任务型 chat → TaskQueue (from_human=human)
        if (ghw_harness.human_symbiosis.chat_task.maybeSubmitFromChat(
            &app.human_gsp,
            &app.task_queue,
            &app.agent,
            app.alloc,
            self.user_text,
        ) catch null) |task_id| {
            std.debug.print("[chat-worker] 人类任务 #{d} 入队 pending={d}\n", .{ task_id, app.task_queue.pending_count });
        }

        // 2. 跑 1 cycle + 全套 post-cycle (跟 auto-tick / POST /api/tick 一致, cycle_mutex 互斥)
        const report = runAgentCycleLocked(app, self.alloc) catch |err| {
            std.debug.print("[chat-worker] advanceAgentCycle 失败: {t}\n", .{err});
            return;
        };
        const chat_summary = if (self.user_text.len > 80) self.user_text[0..80] else self.user_text;
        app.memory.recordAt(app.io, .user_chat, report.tick, chat_summary, self.user_text, 0, report.e_after - report.e_before) catch |err| {
            std.debug.print("[chat-worker] recordAt user_chat 失败: {t}\n", .{err});
        };
        saveState(app) catch {};

        // 3. 构造 GHW 回复 (LLM 模式 or 模板降级)
        const goal_name = if (report.top_goal) |g| @tagName(g.kind) else "observe";
        const sys_snap = app.sys_collector.last orelse SystemSnapshot{
            .cpu_user_pct = 0,
            .cpu_sys_pct = 0,
            .cpu_idle_pct = 100,
            .mem_used_gb = 0,
            .mem_total_gb = 0,
            .mem_pct = 0,
            .disk_used_pct = 0,
            .load_1m = 0,
            .proc_count = 0,
            .net_in_mbps = 0,
            .net_out_mbps = 0,
            .disk_read_mbps = 0,
            .disk_write_mbps = 0,
            .hour = 0,
            .weekday = 0,
            .timestamp = 0,
        };

        const reply: LLMReplyResult = if (app.llm_chat) |*lc| blk: {
            const r = buildLLMReply(app, lc, self.user_text, report, sys_snap, goal_name) catch |err| {
                std.debug.print("[chat-worker] LLM 失败: {t}, 降级到模板\n", .{err});
                break :blk LLMReplyResult{
                    .text = fallbackTemplate(app.alloc, self.user_text, report.e_after, sys_snap, goal_name) catch return,
                    .memory_injected = false,
                };
            };
            break :blk r;
        } else LLMReplyResult{
            .text = fallbackTemplate(app.alloc, self.user_text, report.e_after, sys_snap, goal_name) catch return,
            .memory_injected = false,
        };
        defer app.alloc.free(reply.text);

        // 4. 写 sqlite + 写 chat_history (lock)
        if (app.sqlite) |*db| {
            _ = db.insertEpisode(@intCast(report.tick), "chat", reply.text, 0.4, "llm") catch {};
        }
        app.chat_mutex.lockUncancelable(app.io);
        defer app.chat_mutex.unlock(app.io);
        app.chat_history.append(app.alloc, .{
            .sender = app.alloc.dupe(u8, "ghw") catch return,
            .text = app.alloc.dupe(u8, reply.text) catch return,
            .timestamp = std.Io.Clock.real.now(app.io).toSeconds(),
            .tick = report.tick,
            .memory_injected = reply.memory_injected,
        }) catch {};
        std.debug.print("[chat-worker] tick={d} GHW reply ready ({d}B memory={s})\n", .{
            report.tick, reply.text.len, if (reply.memory_injected) "on" else "off",
        });
    }
};

const LLMReplyResult = struct {
    text: []u8,
    memory_injected: bool,
    meta: ghw_harness.human_symbiosis.chat_reply.Meta = .{},
};

const ProductTransitionAction = enum { approve, apply, rollback };

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []u8,
    admin_token: ?[]const u8 = null,

    fn deinit(self: *const HttpRequest, alloc: Allocator) void {
        alloc.free(self.method);
        alloc.free(self.path);
        alloc.free(self.body);
        if (self.admin_token) |token| alloc.free(token);
    }
};

/// 构造 LLM 回复 (worker 用, 独立函数避免 worker struct 太大)
fn buildLLMReply(
    app: *App,
    lc: *LLMChat,
    user_text: []const u8,
    report: CycleReport,
    sys_snap: SystemSnapshot,
    goal_name: []const u8,
) !LLMReplyResult {
    const alloc = app.alloc;
    const value_score = ghw_harness.human_symbiosis.computeScore(
        &app.human_signal,
        &app.task_queue,
        &app.human_gsp,
    );
    const built = try ghw_harness.human_symbiosis.chat_reply.buildChatReply(
        alloc,
        &app.memory,
        &app.agent,
        user_text,
        goal_name,
        value_score,
        app.task_queue.pending_count,
        sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
        sys_snap.mem_pct,
        sys_snap.load_1m,
    );
    defer alloc.free(built.prompt);

    var req = LLMChatRequest{
        .model = app.llm_model,
        .temperature = 0.7,
        .max_tokens = 256,
    };
    const messages = [_]LLMMessage{
        .{ .role = .system, .content = "你是 GHW 数字生命, 一对一与用户对话, 真实可信, 不假装." },
        .{ .role = .user, .content = built.prompt },
    };
    req.messages = &messages;
    var llm_resp = try lc.complete(req, alloc);
    defer llm_resp.deinit();
    const llm_text = llm_resp.content orelse "";
    if (llm_text.len == 0) {
        return .{
            .text = try fallbackTemplate(alloc, user_text, report.e_after, sys_snap, goal_name),
            .memory_injected = false,
        };
    }
    const max_len = @min(llm_text.len, 500);
    app.last_chat_reply = built.meta;
    if (built.meta.memory_injected) app.chat_replies_with_memory += 1;
    return .{
        .text = try alloc.dupe(u8, llm_text[0..max_len]),
        .memory_injected = built.meta.memory_injected,
        .meta = built.meta,
    };
}

const App = struct {
    alloc: Allocator,
    io: std.Io,
    agent: GHWAgent,
    sys_collector: SystemCollector,
    world: WorldContext,
    llm: ?HttpLLM,
    llm_chat: ?LLMChat,
    llm_model: []const u8,
    memory: Memory,
    /// P6: 人类/LLM 任务队列 — proposeAndAdopt + 周期 runTask
    task_queue: TaskQueue,
    /// P2: 最近一次任务有界动作 (static tag, 不 alloc)
    last_task_action: []const u8 = "none",
    last_task_acted: bool = false,
    /// P3: 补救任务累计入队数
    remedy_submitted_total: u32 = 0,
    /// P4: 求存信念累计
    survival_beliefs_total: u32 = 0,
    /// P5a: 人类介入任务累计 + AutoCLI 节流
    act_human_total: u32 = 0,
    autocli_base_interval_s: u64 = 300,
    autocli_interval_override_s: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// P5b: 上次代谢注入 tick
    last_metabolism_tick: u64 = 0,
    metabolism_submitted_total: u32 = 0,
    /// P6: 外网桥接入队累计 + digest 缓冲 (RuleProposer)
    world_bridge_total: u32 = 0,
    world_digest_buf: [160]u8 = undefined,
    world_digest_len: usize = 0,
    /// P2c: peer inbox → RuleProposer world digest 后缀
    peer_digest_buf: [128]u8 = undefined,
    peer_digest_len: usize = 0,
    /// world + peer 合并摘要 (setWorldDigest 指针必须持久)
    combined_digest_buf: [288]u8 = undefined,
    combined_digest_len: usize = 0,
    /// P7: 同伴共生写回次数
    peer_symbiosis_total: u32 = 0,
    /// P8b: 求存规则效果反馈
    survival_feedback: ghw_harness.survival_feedback.Tracker = .{},
    survival_feedback_evals: u32 = 0,
    survival_feedback_improved: u32 = 0,
    /// P0 lifecycle: 觉醒 + 宿主短板 + 存在相
    awaken: ghw_harness.awaken.State = .{},
    last_shortfall: ghw_harness.host_shortfall.Report = .{},
    existence_phase: ghw_harness.existence_phase.Phase = .awakening,
    /// P2: 宿主画像 (desktop 采样 / mobile 推送)
    host_profile: ghw_harness.host_profile.Profile = .{},
    /// P2: 同伴短板收件箱
    peer_inbox: ghw_harness.peer_inbox.Inbox = .{},
    peer_shortfall_ingest_total: u32 = 0,
    /// P1: state.json 写锁契约 (防 ui/daemon 双写)
    state_meta: ghw_harness.state_contract.Meta = .{ .writer = .ui_server },
    state_save_blocked: bool = false,
    state_conflict: ghw_harness.state_contract.Conflict = .none,
    /// P9: 人类反馈 + 信任 (L6 HumanSignal / HumanGSP)
    human_gsp: HumanGSP,
    human_signal: HumanSignal,
    /// P11: 人类 value_score 趋势 (驱动 goal 提议加速 + provenance)
    value_tracker: ghw_harness.human_symbiosis.ValueTrendTracker = .{},
    /// P18: 产品数字生命 runtime (显式 --product-intent 启用)
    product_intent: ?ghw_harness.product_intent.ProductIntent = null,
    product_runtime: ?ghw_harness.product_runtime.ProductEvolutionRuntime = null,
    product_config_adapter: ?ghw_harness.FileConfigAdapter = null,
    product_intent_hash: []const u8 = "",
    product_kpi_last_feed_unix: i64 = 0,
    /// P28: 跨 GHW 共同进化洞察缓存
    co_evolution: ?ghw_harness.CoEvolutionRegistry = null,
    /// P27: Cross-host Link (TCP + HMAC)
    cross_link: ?ghw_harness.ghw_link_tcp.CrossLink = null,
    cross_link_thread: ?std.Thread = null,
    cross_link_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    admin_token: []const u8 = "",
    reflection: ?Reflection,
    /// Reflect 互斥锁: 后台 thread 跑 reflect 时, 主 thread 访问 memory 用这锁保护
    /// 避免 main thread 跟 reflect thread 同时改 self_narrative / beliefs 时 race
    reflection_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Reflect 后台 thread inflight 标记 (避免重叠)
    reflect_inflight: bool = false,
    /// Reflect 最近一次触发 tick (用于 UI 显示"距离上次 reflect N cycle")
    reflect_last_tick: u64 = 0,
    /// LLM 提议器: 基于世界快照 + 自身状态 提议新目标
    goal_proposer: ?ghw.harness.goal_proposer.LLMGoalProposer = null,
    /// 最近一次 LLM 提议的目标 (UI 展示)
    proposed_goals: std.ArrayList(ghw.harness.goal_proposer.ProposedGoal) = .empty,
    /// 最近一次 LLM 提议的 raw response (debug)
    last_propose_raw: ?[]u8 = null,
    /// 提议总次数
    propose_total: u32 = 0,
    personality: Personality,
    growth_log: std.ArrayList(GrowthEntry) = .empty,
    chat_history: std.ArrayList(ChatMessage) = .empty,
    self_evolve_total: u32 = 0,
    state_path: []const u8,
    ui_dir: []const u8,
    port: u16,
    /// Chat history 锁 (POST chat + background worker 共享; std.Io.Mutex 接受 io)
    chat_mutex: std.Io.Mutex = .init,
    /// Agent cycle 锁: runCycle / post-cycle / auto-tick / chat worker 互斥
    cycle_mutex: std.Io.Mutex = .init,
    /// 无 LLM 模板自省最近 tick (>= 32 触发)
    last_template_reflect_tick: u64 = 0,
    auto_tick_ms: u64 = 0,
    last_tick_ns: i128 = 0,
    /// GET /api/state 发现 cycle 锁被占用时置 true (只读快照仍返回)
    cycle_busy: bool = false,
    /// 最近一次成功推进 cycle 的 wall-clock (秒)
    last_cycle_unix_s: i64 = 0,
    /// RuleProposer 本机压力摘要缓冲 (持久, 供 setSystemPressure 指针)
    system_pressure_buf: [192]u8 = undefined,
    system_pressure_len: usize = 0,
    /// world_sensor 上次投递 tick (节流)
    last_world_sensor_tick: u64 = 0,
    // 静态资源缓存
    index_html: []u8 = &[_]u8{},
    app_js: []u8 = &[_]u8{},
    /// SQLite 记忆库: episodes / beliefs / proposed_goals
    sqlite: ?ghw.sandbox.SqliteDb = null,
    /// 累计写入 episodes 数
    sqlite_episodes_written: u64 = 0,
    /// ActionRunner: 每 N cycle 自动跑 top unadopted goal
    action_runner: ?ActionRunner = null,
    /// 最近一次 action 结果 (UI 展示)
    last_action: ?ActionRunner.ActionResult = null,
    /// action 总数
    action_count: u32 = 0,
    /// 每 N cycle 跑 1 次 action (默认 16, 比反思 32 快一倍)
    action_every: u64 = 16,
    /// L1-L5 自演化: StaticCodeGenerator (L3/L4 用, 不依赖 LLM)
    static_codegen: ?ghw.harness.code_generator.StaticCodeGenerator = null,
    /// P4: LLM 驱动的 CodeGenerator (LLM 启用时替换 StaticCodeGenerator)
    llm_codegen: ?ghw.harness.LlmCodeGenerator = null,
    /// L1-L5 自演化: SelfEvolver (持有 Guard + CodeGenerator)
    self_evolver: ?ghw.harness.SelfEvolver = null,
    /// L5 自演化: SelfEncoder (规则合成, 形式验证)
    self_encoder: ?ghw.harness.SelfEncoder = null,
    /// P13: LLM 规则提议 (Guard + RuleProposer, 跟 daemon 对齐)
    evolution_guard: ?ghw.harness.SelfEvolutionGuard = null,
    rule_proposer: ?ghw.harness.rule_proposer.RuleProposer = null,
    rule_propose_total: u32 = 0,
    /// P15: 最近一次 chat LLM 回复的记忆 provenance
    last_chat_reply: ghw_harness.human_symbiosis.chat_reply.Meta = .{},
    chat_replies_with_memory: u32 = 0,
    /// L1-L5 累计触发次数 (UI capabilities 展示)
    self_evolve_l1_count: u32 = 0,
    self_evolve_l2_count: u32 = 0,
    self_evolve_l3_count: u32 = 0,
    self_evolve_l3_approved: u32 = 0, // 编译通过 + 真落盘的 L3 数
    self_evolve_l4_count: u32 = 0,
    self_evolve_l4_approved: u32 = 0, // 编译通过 + 真落盘的 L4 数
    self_evolve_l5_count: u32 = 0,
    /// L1+L2 自动触发最近 tick (每 32 cycle 一次, 一起跑)
    last_auto_l1l2_tick: u64 = 0,
    /// L3 自动触发最近 tick (每 64 cycle 一次)
    last_auto_l3_tick: u64 = 0,
    /// L4 自动触发最近 tick (每 96 cycle 一次)
    last_auto_l4_tick: u64 = 0,
    /// L5 自动触发最近 tick (每 192 cycle 一次, 最重)
    last_auto_l5_tick: u64 = 0,
    /// L4 编译验证器 (CompileVerifier, 用于真编译 L4 生成的代码)
    verifier: ?ghw.harness.compile_verifier.CompileVerifier = null,
    /// 自我完善: LLM 基于自我叙事 + 当前期望, 完善已有 L1-L5 模板
    template_enhancer: ?ghw.harness.TemplateEnhancer = null,
    /// 自我完善触发最近 tick (每 64 cycle 触发 1 次)
    last_enhance_tick: u64 = 0,
    /// 自我完善结果 (最近 8 条, UI 展示)
    enhance_results: std.ArrayList(ghw.harness.EnhanceResult) = .empty,
    /// 当前阶段 (1-5) — 数字生命实装里程碑, UI 徽章展示
    /// 1: 基础自我 (有 Episode + 反思 + 行动) — 启动默认
    /// 2: 多体互联 (收到首个 peer message)
    /// 3: LLM 提议 (首个 LLM call 成功)
    /// 4: 自演化 (首个 L3 approved 真落盘)
    /// 5: 自我完善 (首个 enhanced_*.zig 落盘)
    /// 7-9 留 paper evidence 备用
    phase: u8 = 1,
    /// 阶段晋升标记 — 1=有 episode, 2=有 peer, 3=有 llm, 4=l3_approved>0, 5=enhance>0
    phase_progress: u32 = 0,
    /// Phase 6 触发: 6 接口 (人/系统/文档/多体/时间/自然) 全用过
    six_interfaces_done: u8 = 0,
    /// Phase 7 触发: 7 步反思 (觉察/差异/目标/评估/执行/学习/超越) 全走过 1 轮
    seven_reflection_done: u8 = 0,
    /// Phase 8 触发: 看到 ≥1 个非 parent-child 关系
    eight_relations_seen: u8 = 0,
    /// Phase 9 触发: E 方差 < 0.01 持续 64 cycle
    nine_palaces_e_var_seen: u8 = 0,
    /// E 历史 ring buffer (phase 9 检测方差用, 64 个槽)
    e_history_buf: [64]f32 = std.mem.zeroes([64]f32),
    e_history_idx: u8 = 0,
    e_history_count: u8 = 0,
    /// Phase 9 deep dive: M/R/N 平衡 (M/R/N 方差 < 0.01) 持续 64 cycle
    /// 注意: 这跟 M/R/N 平衡联动 nu/mu 系数 (Phase 8.6 闭环) 不同
    /// 这个是 "数字生命真的在 M≈R≈N 三源合恰状态" 的"成就"标记
    nine_palaces_mrn_seen: u8 = 0,
    mrn_history_buf: [64]f32 = std.mem.zeroes([64]f32), // 存 M/R/N variance
    mrn_history_idx: u8 = 0,
    mrn_history_count: u8 = 0,
    /// Phase 9 宫 deep: M/R/N 都 ≥ 0.85 (强三源合恰) 持续 64 cycle
    nine_palaces_mrn_strong_seen: u8 = 0,
    mrn_strong_buf: [64]f32 = std.mem.zeroes([64]f32), // 存 min(M,R,N)
    mrn_strong_idx: u8 = 0,
    mrn_strong_count: u8 = 0,
    /// autocli 拉过外网数据 (Wikipedia/ArXiv/RSS/HN) — phase 6 "自然" 接口标记
    autocli_done: bool = false,
    /// AutoCLI 实例 (拉 Wikipedia/ArXiv/RSS/HN, 5min 1 次)
    autocli: ?ghw.harness.autocli.AutoCLI = null,
    /// AutoCLI background thread (5min 节流)
    autocli_thread: ?std.Thread = null,
    /// AutoCLI 停止标志
    autocli_stop: std.atomic.Value(bool) = .init(false),
    /// L4 落盘目录 (verdict=approved 的代码写到这, 不污染 ghw 源码)
    evolved_dir: []const u8 = "/tmp/ghw_evolved",
    /// GHW 源码根目录 (L3 L4 L5 落盘时也 copy 一份到这里, 让"数字生命写的代码" 真在源码树里)
    ghw_root: []const u8 = "/Users/n0x/w4_proj/3yhq_uni/ghw",
    /// GHW Link: Unix socket 互联
    link: ?GhwLink = null,
    /// Link server thread (我们 spawn 出去, 传 ctx 是 &app 自身)
    link_thread: ?std.Thread = null,
    /// Link server 停止信号
    link_stop: std.atomic.Value(bool) = .init(false),
    /// 知道的 peers (path, peer_id, last_seen_tick)
    peers: std.ArrayList(ActionRunner.PeerInfo) = .empty,
    /// Peer registry file path (one socket path per line)
    /// 0-length = peer discovery disabled
    peers_file: []const u8 = "",
    /// Peer health check background thread handle
    peer_health_thread: ?std.Thread = null,
    peer_health_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    auto_tick_thread: ?std.Thread = null,
    /// 缓存: peer E 平均值 (0 = 没同伴, 供 E 函数层 reflect 共生关系)
    peer_E_avg: F = 0.0,
    /// 缓存: peer 总数 (>=1 时 σ 通道打开)
    peer_count_cached: u32 = 0,
};

/// /api/evolved[/file] — 列落盘文件 / 读单个落盘文件
/// - /api/evolved          → JSON 列表 {count, files: [{name, size, kind, lines}]}
/// - /api/evolved/l3_64.zig → 读 l3_64.zig 内容 (text/plain)
fn handleGetEvolved(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, query: []const u8) !void {
    // 0. 安全: query 必须是 "/" + 字母数字/dot/underscore, 防止目录穿越
    if (query.len > 0) {
        if (query[0] != '/') {
            const resp = try makeHttpResponse(alloc, 400, "Bad Request", "text/plain", "missing /");
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        }
        const name = query[1..];
        for (name) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-')) {
                const resp = try makeHttpResponse(alloc, 400, "Bad Request", "text/plain", "invalid filename");
                defer alloc.free(resp);
                try writeResponse(conn, io, resp);
                return;
            }
        }

        // 1. 读单个文件 (e.g. /api/evolved/l3_64.zig)
        const full_path = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, name });
        defer alloc.free(full_path);
        const file = std.Io.Dir.openFileAbsolute(io, full_path, .{ .mode = .read_only }) catch |err| {
            const body = try std.fmt.allocPrint(alloc, "open failed: {t}", .{err});
            defer alloc.free(body);
            const resp = try makeHttpResponse(alloc, 404, "Not Found", "text/plain", body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer file.close(io);
        const stat = file.stat(io) catch |err| {
            const body = try std.fmt.allocPrint(alloc, "stat failed: {t}", .{err});
            defer alloc.free(body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "text/plain", body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        const content = alloc.alloc(u8, stat.size) catch |err| {
            const body = try std.fmt.allocPrint(alloc, "alloc failed: {t}", .{err});
            defer alloc.free(body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "text/plain", body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer alloc.free(content);
        _ = std.Io.File.readStreaming(file, io, &.{content}) catch |err| {
            const body = try std.fmt.allocPrint(alloc, "read failed: {t}", .{err});
            defer alloc.free(body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "text/plain", body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        const resp = try makeHttpResponse(alloc, 200, "OK", "text/plain; charset=utf-8", content);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }

    // 2. 列表
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"evolved_dir\":\"/tmp/ghw_evolved\",\"files\":[");

    // 列举 /tmp/ghw_evolved
    var dir = std.Io.Dir.openDirAbsolute(io, app.evolved_dir, .{}) catch |err| {
        std.debug.print("[evolved] 打开 {s} 失败: {t}\n", .{app.evolved_dir, err});
        try body.append(alloc, ']');
        try body.append(alloc, '}');
        const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var first = true;
    while (it.next(io)) |maybe_entry| {
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (!first) try body.append(alloc, ',');
        first = false;
        // name
        const name_esc = jsonEscape(alloc, entry.name) catch continue;
        defer alloc.free(name_esc);
        try body.print(alloc, "{{\"name\":\"{s}\",", .{name_esc});
        // kind: l3_*, l4_*, l5_*.zig, l5_*.md
        const kind: []const u8 = if (std.mem.startsWith(u8, entry.name, "l3_"))
            "L3"
        else if (std.mem.startsWith(u8, entry.name, "l4_"))
            "L4"
        else if (std.mem.startsWith(u8, entry.name, "l5_"))
            if (std.mem.endsWith(u8, entry.name, ".md")) "L5_md" else "L5"
        else
            "other";
        try body.print(alloc, "\"kind\":\"{s}\",", .{kind});
        // size + line count (open + stat + read)
        const full_path = std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, entry.name }) catch continue;
        defer alloc.free(full_path);
        if (std.Io.Dir.openFileAbsolute(io, full_path, .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const st = f.stat(io) catch continue;
            const content = alloc.alloc(u8, @intCast(st.size)) catch continue;
            defer alloc.free(content);
            _ = std.Io.File.readStreaming(f, io, &.{content}) catch continue;
            const lines = std.mem.count(u8, content, "\n") + 1;
            try body.print(alloc, "\"size\":{d},\"lines\":{d}", .{ st.size, lines });
        } else |_| {}
        try body.append(alloc, '}');
    } else |err| {
        std.debug.print("[evolved] iter 失败: {t}\n", .{err});
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

// ===== L1-L5 自演化 callback (数字生命"自己改自己") =====
// ActionRunner.isSelfEvolveGoal 命中后, 调这个 callback.
// level: 1=调参 / 2=ε优化 / 3=习得方法 / 4=优化算法 / 5=自编码
// ctx: *App (用 @ptrCast 注入)
// 返: log 字符串 (写到 sqlite action.log)

/// Adopt 一个 L3/L4/L5 落盘文件到 ghw 源码树
/// - src_path: 相对 ghw_root 的路径 (e.g. "src/goal/methods/l3_64.zig")
/// - 行为: 读 /tmp/ghw_evolved/<basename(src_path)> → mkdir parent → 写到 ghw_root/src_path
/// - 防重: 计算 FNV-1a hash, 写之前查 sqlite evolved_adopted 表, 命中跳过
/// - 返: 写成功的绝对路径 (caller free), 或 null (失败/已存在)
fn adoptIntoGhwSource(app: *App, src_path: []const u8) !?[]u8 {
    const alloc = app.alloc;
    const basename = std.fs.path.basename(src_path);
    const evolved_src = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, basename });
    defer alloc.free(evolved_src);
    const ghw_dst = try std.fs.path.join(alloc, &[_][]const u8{ app.ghw_root, src_path });
    errdefer alloc.free(ghw_dst);

    // 1. 读 evolved_src
    const file_in = std.Io.Dir.openFileAbsolute(app.io, evolved_src, .{ .mode = .read_only }) catch |err| {
        std.debug.print("[adopt] 读 {s} 失败: {t}\n", .{evolved_src, err});
        return null;
    };
    defer file_in.close(app.io);
    const stat = file_in.stat(app.io) catch return null;
    const content = try alloc.alloc(u8, stat.size);
    defer alloc.free(content);
    _ = std.Io.File.readStreaming(file_in, app.io, &.{content}) catch return null;

    // 2. hash + dedup 检查
    const hash = ghw.sandbox.sqlite_db.fnv1a64(content);
    if (app.sqlite) |*db| {
        const kind: []const u8 = if (std.mem.startsWith(u8, basename, "l3_"))
            "L3"
        else if (std.mem.startsWith(u8, basename, "l4_"))
            "L4"
        else if (std.mem.startsWith(u8, basename, "l5_") and !std.mem.endsWith(u8, basename, ".md"))
            "L5"
        else
            "other";
        if (db.isAdopted(kind, hash) catch false) {
            std.debug.print("[adopt] SKIP dup {s} hash={x}\n", .{ basename, hash });
            return null; // 已 adopt 过, 跳过
        }
    }

    // 3. mkdir parent (Zig 0.17 std.fs.makeDirAbsolute 不存在, 用 posix mkdir 逐级)
    if (std.fs.path.dirname(ghw_dst)) |parent| {
        var parts_buf: [16][]const u8 = undefined;
        var parts_count: usize = 0;
        var iter: []const u8 = parent;
        while (iter.len > 0) {
            if (parts_count >= parts_buf.len) break;
            parts_buf[parts_count] = iter;
            parts_count += 1;
            const next = std.fs.path.dirname(iter) orelse break;
            if (next.len == iter.len) break;
            iter = next;
        }
        var i: usize = parts_count;
        while (i > 0) {
            i -= 1;
            const p_z = alloc.dupeSentinel(u8, parts_buf[i], 0) catch continue;
            defer alloc.free(p_z);
            _ = std.c.mkdir(p_z.ptr, 0o755);
        }
    }

    // 4. 写到 ghw_dst
    const write_ok = blk: {
        if (std.Io.Dir.createFileAbsolute(app.io, ghw_dst, .{})) |file_out| {
            defer file_out.close(app.io);
            std.Io.File.writeStreamingAll(file_out, app.io, content) catch |err| {
                std.debug.print("[adopt] 写 {s} 失败: {t}\n", .{ghw_dst, err});
                break :blk false;
            };
            break :blk true;
        } else |err| {
            std.debug.print("[adopt] 创建 {s} 失败: {t}\n", .{ghw_dst, err});
            break :blk false;
        }
    };
    if (!write_ok) return null;

    // 5. 写成功后 record 进 sqlite
    if (app.sqlite) |*db| {
        const kind: []const u8 = if (std.mem.startsWith(u8, basename, "l3_"))
            "L3"
        else if (std.mem.startsWith(u8, basename, "l4_"))
            "L4"
        else if (std.mem.startsWith(u8, basename, "l5_") and !std.mem.endsWith(u8, basename, ".md"))
            "L5"
        else
            "other";
        // 从 src_path 解析 tick (e.g. "src/goal/methods/l3_64.zig" → 64)
        var tick_val: i64 = 0;
        // 找 "l3_" 或 "l4_" 或 "l5_" 后面的数字
        const prefix = if (std.mem.startsWith(u8, basename, "l3_"))
            "l3_"
        else if (std.mem.startsWith(u8, basename, "l4_"))
            "l4_"
        else
            "l5_";
        if (std.mem.indexOf(u8, basename, prefix)) |pidx| {
            const num_start = pidx + prefix.len;
            var num_end = num_start;
            while (num_end < basename.len and basename[num_end] >= '0' and basename[num_end] <= '9') : (num_end += 1) {}
            if (num_end > num_start) {
                tick_val = std.fmt.parseInt(i64, basename[num_start..num_end], 10) catch 0;
            }
        }
        db.recordAdopted(app.io, kind, tick_val, basename, hash, evolved_src, ghw_dst, @intCast(stat.size)) catch |err| {
            std.debug.print("[adopt] recordAdopted 失败: {t}\n", .{err});
        };
    }
    return ghw_dst;
}
fn onSelfEvolveCallback(level: u8, ctx: *anyopaque) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const alloc = app.alloc;

    switch (level) {
        1 => {
            // L1: 调参 (ExistenceWeights.adapt — 维度低时自动抬权重 + 归一化)
            const v = app.agent.ed.v;
            const w_before = app.agent.ed.weights;
            app.agent.ed.weights.adapt(v);
            const w_after = app.agent.ed.weights;
            app.self_evolve_l1_count += 1;
            const log = try std.fmt.allocPrint(alloc,
                \\L1 调参: α {d:.3}→{d:.3}, β {d:.3}→{d:.3}, γ {d:.3}→{d:.3} (基于 M={d:.3} R={d:.3} N={d:.3})
            , .{
                w_before.alpha, w_after.alpha,
                w_before.beta, w_after.beta,
                w_before.gamma, w_after.gamma,
                v.material, v.representation, v.nature,
            });
            std.debug.print("[self-evolve] {s}\n", .{log});
            return log;
        },
        2 => {
            // L2: ε 优化 — E 高 → 降 ε (稳态, 少探索); E 低 → 升 ε (危机, 多探索)
            const e = app.agent.ed.e();
            const eps_before = app.agent.attn.params.epsilon_base;
            const new_eps: F = if (e < 0.4)
                @min(0.20, eps_before * 1.5) // E 低 → 大胆探索
            else if (e > 0.85)
                @max(0.01, eps_before * 0.5) // E 高 → 收敛
            else
                eps_before;
            app.agent.attn.params.epsilon_base = new_eps;
            app.self_evolve_l2_count += 1;
            const log = try std.fmt.allocPrint(alloc,
                \\L2 ε 优化: epsilon_base {d:.4}→{d:.4} (E={d:.3}, 探索策略调)
            , .{ eps_before, new_eps, e });
            std.debug.print("[self-evolve] {s}\n", .{log});
            return log;
        },
        3 => {
            // L3: 习得方法 — 调 SelfEvolver.evolve(method_implementation) + apply + 真落盘
            // target_file 必须以 "src/goal/methods/" 开头 (SelfEvolutionGuard 白名单 prefix 匹配)
            const evolver = &(app.self_evolver orelse return error.NoSelfEvolver);
            const e = app.agent.ed.e();
            const req = ghw.harness.code_generator.GenerationRequest{
                .kind = .method_implementation,
                .context = try std.fmt.allocPrint(alloc, "tick={d} E={d:.3} L3 learn new method", .{ app.agent.tick, e }),
                .target_file = try std.fmt.allocPrint(alloc, "src/goal/methods/l3_{d}.zig", .{app.agent.tick}),
            };
            const ev_ctx = ghw.harness.EvolveContext{
                .e = e,
                .tick = app.agent.tick,
                .material = app.agent.ed.v.material,
                .representation = app.agent.ed.v.representation,
                .nature = app.agent.ed.v.nature,
                .query_text = "L3 learn method",
            };
            const outcome = try evolver.evolve(req, ev_ctx);
            const applied = try evolver.apply(outcome);
            app.self_evolve_l3_count += 1;

            // 真落盘: 写 code 到 evolved_dir/l3_<tick>.zig (verdict=approved 时)
            const approved = (outcome.verdict == .approved) and applied;
            var landed_path: ?[]u8 = null;
            if (approved) {
                const fname = try std.fmt.allocPrint(alloc, "l3_{d}.zig", .{app.agent.tick});
                const full = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, fname });
                alloc.free(fname);
                if (std.Io.Dir.createFileAbsolute(app.io, full, .{})) |file| {
                    defer file.close(app.io);
                    std.Io.File.writeStreamingAll(file, app.io, outcome.generated_code) catch |err| {
                        std.debug.print("[L3] 写 {s} 失败: {t}\n", .{full, err});
                    };
                    landed_path = full;
                    app.self_evolve_l3_approved += 1;
                } else |err| {
                    std.debug.print("[L3] 落盘失败: {t}\n", .{err});
                    alloc.free(full);
                }
                // Adopt: copy 到 ghw 源码树 (C 项: 让数字生命写的代码真在源码里)
                if (landed_path) |_| {
                    const sub_path = try std.fmt.allocPrint(alloc, "src/goal/methods/l3_{d}.zig", .{app.agent.tick});
                    defer alloc.free(sub_path);
                    if (try adoptIntoGhwSource(app, sub_path)) |ghw_path| {
                        std.debug.print("[L3] adopted: {s}\n", .{ghw_path});
                        alloc.free(ghw_path);
                    }
                }
            }

            const log = if (outcome.compile_stderr.len > 0) blk: {
                const stderr_preview = if (outcome.compile_stderr.len > 800)
                    outcome.compile_stderr[0..800]
                else
                    outcome.compile_stderr;
                break :blk if (landed_path) |p| try std.fmt.allocPrint(alloc,
                    \\L3 习得方法: verdict={s} applied={s} code={d}B 落盘={s}
                    \\
                    \\COMPILE_STDERR: {s}
                , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len, p, stderr_preview }) else try std.fmt.allocPrint(alloc,
                    \\L3 习得方法: verdict={s} applied={s} code={d}B
                    \\
                    \\COMPILE_STDERR: {s}
                , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len, stderr_preview });
            } else if (landed_path) |p| try std.fmt.allocPrint(alloc,
                \\L3 习得方法: verdict={s} applied={s} code={d}B 落盘={s}
            , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len, p }) else try std.fmt.allocPrint(alloc,
                \\L3 习得方法: verdict={s} applied={s} code={d}B
            , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len });
            std.debug.print("[self-evolve] {s}\n", .{log});
            return log;
        },
        4 => {
            // L4: 优化算法 — 调 SelfEvolver.evolve(algorithm_optimization) + apply + 真落盘
            // target_file = "src/agent/params.zig" (白名单精确匹配, guard 通过)
            // 然后若 CompileVerifier 通过, 落盘到 /tmp/ghw_evolved/l4_<tick>.zig
            //       + adopt 到 src/agent/auto_eps/l4_<tick>.zig (子目录避开覆盖原 params.zig)
            const evolver = &(app.self_evolver orelse return error.NoSelfEvolver);
            const e = app.agent.ed.e();
            const req = ghw.harness.code_generator.GenerationRequest{
                .kind = .algorithm_optimization,
                .context = try std.fmt.allocPrint(alloc, "tick={d} E={d:.3} L4 optimize algorithm", .{ app.agent.tick, e }),
                .target_file = "src/agent/params.zig", // 白名单精确匹配
            };
            const ev_ctx = ghw.harness.EvolveContext{
                .e = e,
                .tick = app.agent.tick,
                .material = app.agent.ed.v.material,
                .representation = app.agent.ed.v.representation,
                .nature = app.agent.ed.v.nature,
                .query_text = "L4 optimize algorithm",
            };
            const outcome = try evolver.evolve(req, ev_ctx);
            const applied = try evolver.apply(outcome);
            app.self_evolve_l4_count += 1;

            // 真落盘: 写 code 到 evolved_dir/l4_<tick>.zig (不污染 ghw 源码)
            const approved = (outcome.verdict == .approved) and applied;
            var landed_path: ?[]u8 = null;
            if (approved) {
                const fname = try std.fmt.allocPrint(alloc, "l4_{d}.zig", .{app.agent.tick});
                const full = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, fname });
                alloc.free(fname);
                if (std.Io.Dir.createFileAbsolute(app.io, full, .{})) |file| {
                    defer file.close(app.io);
                    std.Io.File.writeStreamingAll(file, app.io, outcome.generated_code) catch |err| {
                        std.debug.print("[L4] 写 {s} 失败: {t}\n", .{full, err});
                    };
                    landed_path = full;
                    app.self_evolve_l4_approved += 1;
                } else |err| {
                    std.debug.print("[L4] 落盘失败: {t}\n", .{err});
                    alloc.free(full);
                }
                // Adopt: copy 到 ghw 源码树 (C 项)
                if (landed_path) |_| {
                    const sub_path = try std.fmt.allocPrint(alloc, "src/agent/auto_eps/l4_{d}.zig", .{app.agent.tick});
                    defer alloc.free(sub_path);
                    if (try adoptIntoGhwSource(app, sub_path)) |ghw_path| {
                        std.debug.print("[L4] adopted: {s}\n", .{ghw_path});
                        alloc.free(ghw_path);
                    }
                }
            }

            const log = if (landed_path) |p| try std.fmt.allocPrint(alloc,
                \\L4 算法优化: verdict={s} applied={s} code={d}B 落盘={s}
            , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len, p }) else try std.fmt.allocPrint(alloc,
                \\L4 算法优化: verdict={s} applied={s} code={d}B
            , .{ @tagName(outcome.verdict), if (applied) "true" else "false", outcome.generated_code.len });
            std.debug.print("[self-evolve] {s}\n", .{log});
            return log;
        },
        5 => {
            // L5: 自编码 — 调 SelfEncoder.encode(Intent) 合成 EncodedCode + 真落盘
            const encoder = &(app.self_encoder orelse return error.NoSelfEncoder);
            const e = app.agent.ed.e();
            const intent = ghw.harness.self_encoder.Intent{
                .target_e_delta = 0.05,
                .dimension = .all,
                .adjustment_kind = .tune_params,
                .current_e = e,
                .reason = "L5: 自我编码, 合成新规则",
            };
            var encoded = try encoder.encode(intent);
            app.self_evolve_l5_count += 1;

            // 真落盘: 写 encoded.code 到 /tmp/ghw_evolved/l5_<tick>.zig
            //         + rationale 写一个 .md 副文件
            const fname = try std.fmt.allocPrint(alloc, "l5_{d}.zig", .{app.agent.tick});
            const code_full = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, fname });
            alloc.free(fname);
            if (std.Io.Dir.createFileAbsolute(app.io, code_full, .{})) |file| {
                defer file.close(app.io);
                std.Io.File.writeStreamingAll(file, app.io, encoded.code) catch |err| {
                    std.debug.print("[L5] 写 {s} 失败: {t}\n", .{code_full, err});
                };
            } else |err| {
                std.debug.print("[L5] 落盘 .zig 失败: {t}\n", .{err});
            }
            // 写 rationale (markdown 副文件, 给 UI/审计读)
            const md_fname = try std.fmt.allocPrint(alloc, "l5_{d}.md", .{app.agent.tick});
            const md_full = try std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, md_fname });
            alloc.free(md_fname);
            if (std.Io.Dir.createFileAbsolute(app.io, md_full, .{})) |file| {
                defer file.close(app.io);
                std.Io.File.writeStreamingAll(file, app.io, encoded.rationale) catch |err| {
                    std.debug.print("[L5] 写 {s} 失败: {t}\n", .{md_full, err});
                };
            } else |err| {
                std.debug.print("[L5] 落盘 .md 失败: {t}\n", .{err});
            }
            const log = try std.fmt.allocPrint(alloc,
                \\L5 自编码: refs={d} code_lines={d} rationale={d}B 落盘={s}+{s}
            , .{
                encoded.references.len,
                std.mem.count(u8, encoded.code, "\n") + 1,
                encoded.rationale.len,
                code_full,
                md_full,
            });
            // Adopt: copy .zig 到 ghw 源码树 (C 项 — 让数字生命写的代码真在源码里)
            {
                const sub_path = try std.fmt.allocPrint(alloc, "src/harness/auto_eps/l5_{d}.zig", .{app.agent.tick});
                defer alloc.free(sub_path);
                if (try adoptIntoGhwSource(app, sub_path)) |ghw_path| {
                    std.debug.print("[L5] adopted: {s}\n", .{ghw_path});
                    alloc.free(ghw_path);
                }
            }
            encoded.deinit();
            std.debug.print("[self-evolve] {s}\n", .{log});
            return log;
        },
        else => return try alloc.dupe(u8, "invalid level"),
    }
}

// ===== GHW Link: handler 让 peer 调本机时能拿到状态 =====
fn extractJsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\' and i + 1 < json.len) {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[pos + needle.len .. i];
    }
    return null;
}

fn extractJsonFloatField(json: []const u8, key: []const u8) ?f32 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < json.len and ((json[i] >= '0' and json[i] <= '9') or json[i] == '.' or json[i] == '-' or json[i] == 'e' or json[i] == '+')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f32, json[start..i]) catch null;
}

fn linkHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: Allocator) anyerror!ghw.harness.ghw_link.Response {
    const app: *App = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, method, "ping")) {
        const payload = try std.fmt.allocPrint(alloc,
            \\{{"peer_id":"{s}","version":"{s}","tick":{d},"self_evolved_total":{d}}}
        , .{ app.agent.self_id, ghw.harness.ghw_link.PROTOCOL_VERSION, app.agent.tick, app.self_evolve_total });
        return .{ .ok = true, .payload = payload };
    }

    if (std.mem.eql(u8, method, "query_state")) {
        var top_goal_z: [129]u8 = undefined;
        const top_goal_z_slice: [:0]const u8 = if (app.sqlite) |*db| blk: {
            if (db.topUnadoptedGoal() catch null) |row| {
                defer row.deinit();
                const n = @min(row.title.len, top_goal_z.len - 1);
                @memcpy(top_goal_z[0..n], row.title[0..n]);
                top_goal_z[n] = 0;
                break :blk top_goal_z[0..n :0];
            }
            break :blk "(none)";
        } else "(no db)";
        const payload = try std.fmt.allocPrint(alloc,
            \\{{"tick":{d},"E":{d:.3},"M":{d:.3},"R":{d:.3},"N":{d:.3},"alpha":{d:.3},"beta":{d:.3},"gamma":{d:.3},"action_count":{d},"self_evolved_total":{d},"top_goal":"{s}","personality_mood":"{s}"}}
        , .{
            app.agent.tick, app.agent.ed.e(), app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature,
            app.agent.ed.weights.alpha, app.agent.ed.weights.beta, app.agent.ed.weights.gamma,
            app.action_count, app.self_evolve_total, top_goal_z_slice,
            @tagName(app.personality.mood),
        });
        return .{ .ok = true, .payload = payload };
    }

    if (std.mem.eql(u8, method, "query_beliefs")) {
        // 返最近 16 条信念 (material/representation/nature 都给)
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        try body.appendSlice(alloc, "{\"beliefs\":[");
        const beliefs = app.memory.beliefs.items;
        const start = if (beliefs.len > 16) beliefs.len - 16 else 0;
        var first = true;
        for (beliefs[start..]) |b| {
            if (!first) try body.append(alloc, ',');
            first = false;
            try body.print(alloc, "{{\"text\":\"", .{});
            try appendJsonString(alloc, &body, b.text);
            try body.print(alloc, "\",\"source\":\"{s}\",\"confidence\":{d:.2}}}", .{ @tagName(b.source), b.confidence });
        }
        try body.appendSlice(alloc, "]}");
        return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
    }

    if (std.mem.eql(u8, method, "query_actions")) {
        if (app.sqlite) |*db| {
            const rows = db.listActions(20) catch |err| {
                return .{ .ok = false, .payload = try std.fmt.allocPrint(alloc, "\"listActions err: {t}\"", .{err}) };
            };
            defer {
                for (rows) |r| r.deinit();
                alloc.free(rows);
            }
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            try body.appendSlice(alloc, "{\"actions\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try body.append(alloc, ',');
                try body.print(alloc, "{{\"id\":{d},\"tick\":{d},\"kind\":\"", .{ r.id, r.tick });
                try appendJsonString(alloc, &body, r.kind);
                try body.print(alloc, "\",\"result\":\"", .{});
                try appendJsonString(alloc, &body, r.result);
                try body.print(alloc, "\",\"duration_ms\":{d}}}", .{r.duration_ms});
            }
            try body.appendSlice(alloc, "]}");
            return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
        }
        return .{ .ok = false, .payload = try alloc.dupe(u8, "\"sqlite not enabled\"") };
    }

    if (std.mem.eql(u8, method, "inject_event")) {
        // 把事件写入 episodes 表
        if (app.sqlite) |*db| {
            const ep = try std.fmt.allocPrint(alloc, "[peer_event] {s}", .{params});
            defer alloc.free(ep);
            const id = db.insertEpisode(@intCast(app.agent.tick), "peer_event", ep, 0.5, "peer") catch |err| {
                return .{ .ok = false, .payload = try std.fmt.allocPrint(alloc, "\"insert err: {t}\"", .{err}) };
            };
            return .{ .ok = true, .payload = try std.fmt.allocPrint(alloc, "{{\"episode_id\":{d}}}", .{id}) };
        }
        return .{ .ok = false, .payload = try alloc.dupe(u8, "\"sqlite not enabled\"") };
    }

    if (std.mem.eql(u8, method, "query_product_identity")) {
        if (app.product_runtime) |*rt| {
            var body: std.ArrayList(u8) = .empty;
            errdefer body.deinit(alloc);
            try body.appendSlice(alloc, "{\"enabled\":true,");
            if (rt.instance) |*id| {
                try id.appendJsonFields(&body);
            } else if (app.product_intent) |*intent| {
                try body.print(alloc, "\"binding_mode\":\"one_product_one_ghw\",\"product_id\":\"", .{});
                try appendJsonString(alloc, &body, intent.product_id);
                try body.appendSlice(alloc, "\",\"product_type\":\"");
                try body.appendSlice(alloc, @tagName(intent.product_type));
                try body.appendSlice(alloc, "\",\"instance_id\":null,\"node_id\":null");
            }
            try body.appendSlice(alloc, "}");
            return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
        }
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"enabled\":false}") };
    }

    if (std.mem.eql(u8, method, "query_product_evolution")) {
        if (app.product_runtime) |*rt| {
            var body: std.ArrayList(u8) = .empty;
            errdefer body.deinit(alloc);
            try rt.appendEvolutionSnapshotJson(alloc, &body, 8);
            return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
        }
        return .{ .ok = true, .payload = try alloc.dupe(u8, "{\"changes\":[]}") };
    }

    if (std.mem.eql(u8, method, "share_evolution_insight")) {
        if (app.co_evolution) |*reg| {
            const peer_id = extractJsonStringField(params, "peer_id") orelse app.agent.self_id;
            const product_id = extractJsonStringField(params, "product_id") orelse "";
            const product_type = extractJsonStringField(params, "product_type") orelse "";
            const target = extractJsonStringField(params, "target") orelse "";
            const summary = extractJsonStringField(params, "summary") orelse "";
            if (product_id.len == 0 or target.len == 0 or summary.len == 0) {
                return .{ .ok = false, .payload = try alloc.dupe(u8, "\"missing fields\"") };
            }
            const delta = extractJsonFloatField(params, "expected_delta_k") orelse 0;
            const accepted = reg.recordInsight(
                peer_id,
                product_id,
                product_type,
                target,
                summary,
                delta,
                @intCast(@max(app.agent.tick, 0)),
            ) catch false;
            return .{ .ok = true, .payload = try std.fmt.allocPrint(alloc, "{{\"accepted\":{s}}}", .{
                if (accepted) "true" else "false",
            }) };
        }
        return .{ .ok = false, .payload = try alloc.dupe(u8, "\"co_evolution disabled\"") };
    }

    // P2: 求存向短板查询 / 投递 (与产品 co_evolution 分轨)
    if (std.mem.eql(u8, method, "query_shortfall")) {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);
        try body.print(alloc, "{{\"peer_id\":\"", .{});
        try appendJsonString(alloc, &body, app.agent.self_id);
        try body.print(alloc, "\",\"tick\":{d},\"host_kind\":\"{s}\",\"report\":", .{
            app.agent.tick, app.host_profile.kind.label(),
        });
        try ghw_harness.host_shortfall.appendJson(alloc, &body, app.last_shortfall);
        try body.append(alloc, '}');
        return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
    }

    if (std.mem.eql(u8, method, "share_shortfall")) {
        const peer_id = extractJsonStringField(params, "peer_id") orelse "unknown";
        const report = ghw_harness.host_shortfall.parseJson(params) orelse {
            return .{ .ok = false, .payload = try alloc.dupe(u8, "\"invalid shortfall\"") };
        };
        const now_u: i64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
        app.peer_inbox.push(peer_id, report, app.agent.tick, now_u);
        app.peer_shortfall_ingest_total += 1;
        const learned = ghw_harness.peer_symbiosis.learnFromShortfall(
            &app.memory,
            &app.task_queue,
            peer_id,
            report,
            app.agent.tick,
        ) catch ghw_harness.peer_symbiosis.ShortfallLearn{};
        return .{ .ok = true, .payload = try std.fmt.allocPrint(alloc,
            "{{\"accepted\":true,\"beliefs_added\":{d},\"followups\":{d},\"inbox_count\":{d}}}", .{
            learned.beliefs_added, learned.followups, app.peer_inbox.count(),
        }) };
    }

    return .{ .ok = false, .payload = try alloc.dupe(u8, "\"unknown method\"") };
}

// ===== 信号处理 =====
var should_stop_ui: std.atomic.Value(bool) = .init(false);
fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    should_stop_ui.store(true, .release);
}

// ===== Args =====
const Args = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    state: []const u8 = "state.json",
    ui_dir: []const u8 = "ui",
    auto_tick_ms: u64 = 0,
    agent_id: []const u8 = "ghw-ui",
    seed: u64 = 42,
    /// LLM provider: "none" | "deepseek" | "openai" | "anthropic" | "mock"
    llm_provider: []const u8 = "none",
    /// LLM model name
    llm_model: []const u8 = "deepseek-chat",
    /// env var name with API key (e.g. DEEPSEEK_API_KEY)
    llm_api_key_env: []const u8 = "DEEPSEEK_API_KEY",
    /// Peer registry path (one socket path per line, # for comments)
    /// 0-length disables peer discovery
    peers_file: []const u8 = "",
    /// Peer health-check interval (seconds)
    peer_health_interval_s: u64 = 30,
    /// ProductIntent JSON path; empty disables product-runtime mode.
    product_intent_path: []const u8 = "",
    /// Product adapter config output path; empty keeps ProductRuntime audit-only.
    product_config_path: []const u8 = "",
    /// Env var containing admin token for mutating APIs. Empty disables auth.
    admin_token_env: []const u8 = "GHW_ADMIN_TOKEN",
    /// P26: 显式 GHW 实例 ID (默认 {product_id}@{node_id})
    ghw_instance_id: []const u8 = "",
    /// P26: GHW 节点 ID (默认 --agent-id)
    ghw_node_id: []const u8 = "",
    /// P27: Cross-host Link 监听端口; 0 = 禁用
    cross_link_port: u16 = 0,
    /// P27: Cross-host shared secret
    cross_link_secret: []const u8 = "",
    /// P27: Cross-host peers.txt (peer_id:host:port:secret)
    cross_link_peers_file: []const u8 = "",
    /// 禁用 AutoCLI 外网拉取
    no_autocli: bool = false,
    /// AutoCLI 拉取间隔秒 (默认 300 = 5min)
    autocli_interval_s: u64 = 300,
};

fn parseArgs(raw: []const []const u8) Args {
    var a = Args{};
    var i: usize = 1;
    while (i < raw.len) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < raw.len) a.port = std.fmt.parseInt(u16, raw[i], 10) catch 8080;
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < raw.len) a.host = raw[i];
        } else if (std.mem.eql(u8, arg, "--state")) {
            i += 1;
            if (i < raw.len) a.state = raw[i];
        } else if (std.mem.eql(u8, arg, "--ui-dir")) {
            i += 1;
            if (i < raw.len) a.ui_dir = raw[i];
        } else if (std.mem.eql(u8, arg, "--auto-tick-ms")) {
            i += 1;
            if (i < raw.len) a.auto_tick_ms = std.fmt.parseInt(u64, raw[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--id") or std.mem.eql(u8, arg, "--agent-id")) {
            i += 1;
            if (i < raw.len) a.agent_id = raw[i];
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i < raw.len) a.seed = std.fmt.parseInt(u64, raw[i], 10) catch 42;
        } else if (std.mem.eql(u8, arg, "--llm")) {
            i += 1;
            if (i < raw.len) a.llm_provider = raw[i];
        } else if (std.mem.eql(u8, arg, "--llm-model")) {
            i += 1;
            if (i < raw.len) a.llm_model = raw[i];
        } else if (std.mem.eql(u8, arg, "--llm-key-env")) {
            i += 1;
            if (i < raw.len) a.llm_api_key_env = raw[i];
        } else if (std.mem.eql(u8, arg, "--peers-file")) {
            i += 1;
            if (i < raw.len) a.peers_file = raw[i];
        } else if (std.mem.eql(u8, arg, "--peer-health-interval-s")) {
            i += 1;
            if (i < raw.len) a.peer_health_interval_s = std.fmt.parseInt(u64, raw[i], 10) catch 30;
        } else if (std.mem.eql(u8, arg, "--product-intent")) {
            i += 1;
            if (i < raw.len) a.product_intent_path = raw[i];
        } else if (std.mem.eql(u8, arg, "--product-config")) {
            i += 1;
            if (i < raw.len) a.product_config_path = raw[i];
        } else if (std.mem.eql(u8, arg, "--admin-token-env")) {
            i += 1;
            if (i < raw.len) a.admin_token_env = raw[i];
        } else if (std.mem.eql(u8, arg, "--ghw-instance-id")) {
            i += 1;
            if (i < raw.len) a.ghw_instance_id = raw[i];
        } else if (std.mem.eql(u8, arg, "--ghw-node-id")) {
            i += 1;
            if (i < raw.len) a.ghw_node_id = raw[i];
        } else if (std.mem.eql(u8, arg, "--cross-link-port")) {
            i += 1;
            if (i < raw.len) a.cross_link_port = std.fmt.parseInt(u16, raw[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--cross-link-secret")) {
            i += 1;
            if (i < raw.len) a.cross_link_secret = raw[i];
        } else if (std.mem.eql(u8, arg, "--cross-link-peers")) {
            i += 1;
            if (i < raw.len) a.cross_link_peers_file = raw[i];
        } else if (std.mem.eql(u8, arg, "--no-autocli")) {
            a.no_autocli = true;
        } else if (std.mem.eql(u8, arg, "--autocli-interval-s")) {
            i += 1;
            if (i < raw.len) a.autocli_interval_s = std.fmt.parseInt(u64, raw[i], 10) catch 300;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        }
        i += 1;
    }
    return a;
}

fn printHelp() void {
    std.debug.print(
        \\GHW UI Server — HTTP UI + GHW agent
        \\
        \\Usage: ui_server [options]
        \\
        \\Options:
        \\  --port N              HTTP port (default 8080)
        \\  --host ADDR           bind host (default 127.0.0.1)
        \\  --state PATH          state.json path (default state.json)
        \\  --ui-dir PATH         UI static dir (default ui)
        \\  --auto-tick-ms N      auto-tick interval, 0=manual only (default 0)
        \\  --no-autocli          disable AutoCLI world fetch thread
        \\  --autocli-interval-s N  AutoCLI interval seconds (default 300)
        \\  --id STR              agent id (default ghw-ui; alias --agent-id)
        \\  --seed N              LCG seed (default 42)
        \\  --product-intent PATH Enable product-runtime mode with ProductIntent JSON
        \\  --product-config PATH Enable file ProductAdapter output for approved changes
        \\  --admin-token-env ENV Env var for X-GHW-Admin-Token protected writes
        \\  --help                show this
        \\
    , .{});
}

// ===== 读取静态资源 =====
fn readFile(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
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

fn loadStaticAssets(app: *App) !void {
    // 拼绝对路径
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(app.io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    const index_path = if (std.fs.path.isAbsolute(app.ui_dir))
        try std.fs.path.join(app.alloc, &[_][]const u8{ app.ui_dir, "index.html" })
    else
        try std.fs.path.join(app.alloc, &[_][]const u8{ cwd, app.ui_dir, "index.html" });
    defer app.alloc.free(index_path);
    app.index_html = try readFile(app.alloc, app.io, index_path);
    const js_path = if (std.fs.path.isAbsolute(app.ui_dir))
        try std.fs.path.join(app.alloc, &[_][]const u8{ app.ui_dir, "app.js" })
    else
        try std.fs.path.join(app.alloc, &[_][]const u8{ cwd, app.ui_dir, "app.js" });
    defer app.alloc.free(js_path);
    app.app_js = try readFile(app.alloc, app.io, js_path);
}

// ===== Cycle 核心: 真生产 — 同步采本机系统信号 =====
// 性能优化: SystemCollector + WorldContext 共享 TTL 缓存
// 13 个 fork 子进程 (top/sysctl/vm_stat/df/sysctl/ps/netstat + ps/lsof/find/mdfind)
// 100ms cycle → 130 fork/秒 → 28% CPU. 缓存后 5-10 fork/秒 → 1-2% CPU
// rate 字段 (MB/s) 仍准确, 因为 last_cumulative 在 cache miss 时才更新
// 注意: 1 cycle 1-2s (含 L3/L4 compile 4s/96 cycle), TTL 1s 永远不命中.
// TTL = 5s 让 cycle 内多次 collect 命中
const cycle_collect_ttl_ns: i128 = 5 * std.time.ns_per_s; // 5s

fn runCycle(app: *App) !CycleReport {
    // Phase 1.8: 在 cycle 开头 reflect 同伴关系
    // peer_E_avg > 0 时, 调 adaptFromPeers 调 α/β/γ, 开 σ 通道
    adaptWeightsFromPeers(app);

    const snap = try app.sys_collector.collectCached(cycle_collect_ttl_ns);
    const info = try app.sys_collector.toInformation(snap);
    defer app.sys_collector.freeInformation(info);
    const report = try app.agent.runCycle(info);
    // 同时刷新 world context (异步不会让 cycle 阻塞太久)
    const world_snap = app.world.collectCached(cycle_collect_ttl_ns) catch null;
    // 注意: cache hit 路径 return prev (by-value), caller 不能 deinit — 那是 self.last 的 backing
    if (world_snap) |ws| {
        if (ws.timestamp != app.world.last.?.timestamp) ws.deinit();
    }
    return report;
}

/// 有效同伴数 (排除 health=self 的本机占位)
fn countLiveGhwPeers(app: *const App) u32 {
    var n: u32 = 0;
    for (app.peers.items) |p| {
        if (std.mem.eql(u8, p.health, "self")) continue;
        n += 1;
    }
    return n;
}

/// E 接近天花板: ΔE 难涨, 应改推任务/同伴/人类价值
fn eSaturated(app: *const App) bool {
    return app.agent.ed.e() >= 0.98;
}

/// P6/P9/P2: 跑 pending 任务 (有界真执行) + 启发式人类反馈
/// E 饱和或有积压时加速 (4/8 tick), 否则 32 tick — 避免冬眠时任务永远卡着
fn maybeRunPendingTask(app: *App) void {
    if (app.task_queue.pending_count == 0) return;
    const interval: u64 = if (eSaturated(app)) 4 else if (app.task_queue.pending_count >= 2) 8 else 32;
    if (app.agent.tick == 0 or app.agent.tick % interval != 0) return;
    const ts: u64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    const ctx = ghw_harness.task_feedback.Context{
        .queue = &app.task_queue,
        .gsp = &app.human_gsp,
        .signal = &app.human_signal,
    };

    var peer_refs_buf: [16]ghw_harness.task_executor.PeerRef = undefined;
    var peer_n: usize = 0;
    for (app.peers.items) |p| {
        if (peer_n >= peer_refs_buf.len) break;
        peer_refs_buf[peer_n] = .{ .path = p.path, .peer_id = p.peer_id, .health = p.health };
        peer_n += 1;
    }

    var proc_buf: [8]ghw_harness.task_executor.ProcBrief = undefined;
    var proc_n: usize = 0;
    if (app.world.last) |ws| {
        const lim = @min(ws.top_procs.len, proc_buf.len);
        while (proc_n < lim) : (proc_n += 1) {
            const tp = ws.top_procs[proc_n];
            proc_buf[proc_n] = .{ .comm = tp.comm, .cpu_pct = tp.cpu_pct, .mem_pct = tp.mem_pct };
        }
    }

    const exec_env = ghw_harness.task_executor.Env{
        .snap = app.sys_collector.last,
        .top_procs = proc_buf[0..proc_n],
        .link = if (app.link) |*l| l else null,
        .peers = peer_refs_buf[0..peer_n],
    };

    const ran = ghw_harness.task_feedback.runNextPendingWithFeedbackEnv(&app.agent, &ctx, app.alloc, ts, exec_env) catch |err| {
        std.debug.print("[ui] runNextPending 失败: {t}\n", .{err});
        return;
    };
    if (ran) |r| {
        app.last_task_action = r.action_kind;
        app.last_task_acted = r.acted;
        if (r.remedy_submitted > 0) {
            app.remedy_submitted_total += r.remedy_submitted;
            std.debug.print("[ui] tick={d} survival_remedy 入队 {d} (total={d})\n", .{
                app.agent.tick, r.remedy_submitted, app.remedy_submitted_total,
            });
        }
        if (r.beliefs_added > 0) {
            app.survival_beliefs_total += r.beliefs_added;
            std.debug.print("[ui] tick={d} survival_learn +{d} beliefs (total={d}) crisis={}\n", .{
                app.agent.tick, r.beliefs_added, app.survival_beliefs_total, r.host_crisis,
            });
        }
        if (r.act_human_tasks > 0) {
            app.act_human_total += r.act_human_tasks;
            std.debug.print("[ui] tick={d} survival_act human_handoff +{d} (total={d})\n", .{
                app.agent.tick, r.act_human_tasks, app.act_human_total,
            });
        }
        if (r.throttle_autocli_s) |secs| {
            app.autocli_interval_override_s.store(secs, .seq_cst);
            if (secs > 0) {
                std.debug.print("[ui] tick={d} AutoCLI throttle → {d}s (crisis)\n", .{ app.agent.tick, secs });
            } else {
                std.debug.print("[ui] tick={d} AutoCLI throttle cleared\n", .{app.agent.tick});
            }
        }
        if (r.peer_e_seen > 0.01) {
            updatePeerECache(app, r.peer_e_seen);
            app.peer_symbiosis_total += 1;
            std.debug.print("[ui] tick={d} peer_symbiosis E={d:.3} → avg={d:.3} followups=+{d}\n", .{
                app.agent.tick, r.peer_e_seen, app.peer_E_avg, r.peer_followups,
            });
        }
        if (app.rule_proposer) |*p| {
            p.setHostCrisis(r.host_crisis);
        }
        std.debug.print("[ui] tick={d} 任务 #{d} 「{s}」完成 ΔE={d:.3} ({d} cycles) action={s} acted={}\n", .{
            app.agent.tick, r.task_id, r.title, r.actual_delta_e, r.cycles_used, r.action_kind, r.acted,
        });
        if (app.sqlite) |*db| {
            const ep = std.fmt.allocPrint(app.alloc, "task_id={d} title={s} dE={d:.3} action={s}", .{
                r.task_id, r.title, r.actual_delta_e, r.action_kind,
            }) catch null;
            if (ep) |e| {
                defer app.alloc.free(e);
                _ = db.insertEpisode(@intCast(app.agent.tick), "task", e, 0.6, "agent") catch {};
            }
        }
    }
}

/// P9: 三源失衡时, 用 GSP 信任选伙伴投递 balance 任务
fn maybeAutoBalanceTask(app: *App) void {
    if (app.agent.tick == 0 or app.agent.tick % 128 != 0) return;
    const analysis = ghw_harness.balance_seeker.BalanceSeeker.analyze(app.agent.ed);
    if (!analysis.isImbalanced()) return;
    const weak = analysis.weakest;
    const partner = ghw_harness.balance_seeker.BalanceSeeker.selectWeakPartner(app.agent.ed, &app.human_gsp) orelse
        app.human_gsp.selectMostTrusted(weak) orelse return;
    var balance_task = ghw_harness.balance_seeker.BalanceSeeker.proposeBalanceTask(app.agent.ed, weak, partner, app.alloc) catch |err| {
        std.debug.print("[ui] proposeBalanceTask 失败: {t}\n", .{err});
        return;
    };
    defer balance_task.deinit();
    const task_id = app.task_queue.submitWithSource(
        balance_task.title,
        balance_task.description,
        partner,
        balance_task.priority,
        balance_task.required_dimension,
        balance_task.cycles_allocated,
        .balance,
    ) catch |err| {
        std.debug.print("[ui] balance task submit 失败: {t}\n", .{err});
        return;
    };
    std.debug.print("[ui] tick={d} L6 balance task #{d} dim={s} → {s}\n", .{
        app.agent.tick, task_id, @tagName(weak), partner,
    });
}

/// P8: 把 LLM 提议结果写入 UI 列表 + sqlite (handleGetState 自动提议 / GET /api/propose 共用)
fn storeProposeResult(app: *App, result: *const ghw.harness.goal_proposer.ProposeResult) !void {
    const alloc = app.alloc;
    for (app.proposed_goals.items) |old| {
        alloc.free(old.title);
        alloc.free(old.description);
        alloc.free(old.dimension);
        alloc.free(old.reason);
    }
    app.proposed_goals.clearRetainingCapacity();
    const propose_threshold: f32 = 0.5;
    for (result.goals) |g| {
        if (g.urgency < propose_threshold) continue;
        try app.proposed_goals.append(alloc, .{
            .title = try alloc.dupe(u8, g.title),
            .description = try alloc.dupe(u8, g.description),
            .dimension = try alloc.dupe(u8, g.dimension),
            .reason = try alloc.dupe(u8, g.reason),
            .urgency = g.urgency,
        });
        if (app.sqlite) |*db| {
            _ = db.insertProposedGoal(
                @intCast(app.agent.tick),
                g.title,
                g.description,
                g.dimension,
                g.reason,
                g.urgency,
                result.raw_response,
            ) catch |err| {
                std.debug.print("[ui] sqlite insert goal 失败: {t}\n", .{err});
            };
        }
    }
    if (app.last_propose_raw) |raw| alloc.free(raw);
    app.last_propose_raw = try alloc.dupe(u8, result.raw_response);
    if (app.sqlite) |*db| {
        const ep = try std.fmt.allocPrint(alloc, "propose_total={d} goals={d}", .{ app.propose_total, result.goals.len });
        defer alloc.free(ep);
        _ = db.insertEpisode(@intCast(app.agent.tick), "propose", ep, 0.7, "llm") catch {};
    }
}

/// P11: 采样人类 value_score 写入趋势缓冲
fn recordValueTrend(app: *App) void {
    const score = ghw_harness.human_symbiosis.computeScore(
        &app.human_signal,
        &app.task_queue,
        &app.human_gsp,
    );
    app.value_tracker.record(score);
}

/// P13: LLM 规则提议 (E/KPI/value 下滑 → Guard → SelfEncoder; 决策权仍在数字生命)
fn maybeAutoProposeRules(app: *App) void {
    if (app.rule_proposer) |*p| {
        if (app.self_encoder) |*enc| {
            if (app.evolution_guard) |*grd| {
                const goal_name = if (app.growth_log.items.len > 0)
                    if (app.growth_log.items[app.growth_log.items.len - 1].goal) |g| g else "observe"
                else
                    "observe";
                p.updateState(
                    app.agent.ed.e(),
                    app.agent.ed.v.material,
                    app.agent.ed.v.representation,
                    app.agent.ed.v.nature,
                    goal_name,
                    "ui-post-cycle",
                    -0.05,
                );
                p.setKpiTrend(app.agent.ed.kpiTrend());
                p.setValueTrend(app.value_tracker.trend());
                // digest 已在 refreshLifecycle 合并 peer inbox; 再刷确保指针指向持久缓冲
                applyDigestToProposer(app, p);
                if (app.sys_collector.last) |snap| {
                    if (ghw_harness.world_sensor.formatPressureLine(app.alloc, snap)) |line| {
                        defer app.alloc.free(line);
                        const n = @min(line.len, app.system_pressure_buf.len);
                        @memcpy(app.system_pressure_buf[0..n], line[0..n]);
                        app.system_pressure_len = n;
                        p.setSystemPressure(app.system_pressure_buf[0..app.system_pressure_len]);
                    } else |_| {}
                }
                // 用 shortfall 总危机 (含手机电量), 不用纯 snap 覆盖
                p.setHostCrisis(app.last_shortfall.host_crisis);
                // E 饱和 alone 时限频 (每 16 tick), 避免每 cycle LLM 风暴
                const due = p.shouldPropose(ghw_harness.primordial_laws.ProposeTriggers.E_THRESHOLD);
                const host_crisis = p.last_host_crisis;
                const only_sat = eSaturated(app) and
                    !host_crisis and
                    app.agent.ed.e() >= ghw_harness.primordial_laws.ProposeTriggers.E_THRESHOLD and
                    app.value_tracker.trend() >= -ghw_harness.human_symbiosis.ValueTrendTracker.DECLINE_EPS and
                    app.agent.ed.kpiTrend() >= -ghw_harness.rule_proposer.RuleProposer.KPI_DECLINE_EPS;
                if (due and (!only_sat or app.agent.tick % 16 == 0)) {
                    var prop_result = p.proposeAndAdopt(enc, grd, 3) catch |err| {
                        std.debug.print("[ui] rule proposeAndAdopt 失败: {t}\n", .{err});
                        return;
                    };
                    defer prop_result.deinit();
                    app.rule_propose_total += 1;
                    // P8b: 危机下采纳 → 稍后对照压力是否真降
                    if (prop_result.accepted > 0) {
                        if (app.sys_collector.last) |s| {
                            app.survival_feedback.markAfterCrisisRules(s, app.agent.tick, prop_result.accepted);
                        }
                    }
                    std.debug.print("[ui] tick={d} 规则提议 accepted={d} rejected={d} (total={d})\n", .{
                        app.agent.tick, prop_result.accepted, prop_result.rejected, app.rule_propose_total,
                    });
                }
            }
        }
    }
}

/// P8: 自动 LLM 目标提议 → TaskQueue (每 auto_every tick)
fn maybeAutoProposeGoals(app: *App) !void {
    if (app.goal_proposer) |*gp| {
        const since_last: u64 = app.agent.tick -% gp.last_propose_at_tick;
        const value_declining = app.value_tracker.trend() < -ghw_harness.human_symbiosis.ValueTrendTracker.DECLINE_EPS;
        // E 饱和时缩短提议间隔: 改推同伴/自省类目标, 而非空转高 E
        const sat_due = eSaturated(app) and since_last >= @max(gp.auto_every / 4, @as(u64, 8));
        const lonely = countLiveGhwPeers(app) == 0 and since_last >= @max(gp.auto_every / 2, @as(u64, 16));
        if (since_last >= gp.auto_every or gp.last_propose_at_tick == 0 or value_declining or sat_due or lonely) {
            if (app.world.last) |prev_snap| {
                var world_snap = app.world.dupSnapshot(prev_snap) catch |err| {
                    std.debug.print("[ui] dupSnapshot failed: {t}\n", .{err});
                    return;
                };
                defer world_snap.deinit();
                gp.last_propose_at_tick = app.agent.tick;
                app.propose_total += 1;
                var result = gp.proposeAndAdopt(&app.world, world_snap, &app.agent, &app.task_queue, app.io) catch |err| {
                    std.debug.print("[ui] proposeAndAdopt failed: {t}\n", .{err});
                    return;
                };
                defer result.deinit();
                std.debug.print("[ui] tick={d} LLM 提议 {d} 个目标 → TaskQueue pending={d} ({d}ms):\n", .{
                    app.agent.tick, result.goals.len, app.task_queue.pending_count, result.latency_ms,
                });
                for (result.goals) |g| {
                    if (g.urgency < 0.5) {
                        std.debug.print("  - [skip urgency<0.50] [{s}] {d:.2} : {s}\n", .{ g.dimension, g.urgency, g.title });
                    } else {
                        std.debug.print("  - [{s}] urgency={d:.2} : {s}\n", .{ g.dimension, g.urgency, g.title });
                    }
                }
                try storeProposeResult(app, &result);
            }
        }
    }
}

/// P8: 周期自省 (LLM 或模板兜底)
fn maybeAutoReflect(app: *App) void {
    const alloc = app.alloc;
    if (app.reflection) |*r| {
        if (r.shouldReflect(&app.agent) and !app.reflect_inflight) {
            app.reflect_inflight = true;
            app.reflect_last_tick = app.agent.tick;
            const ReflectCtx = struct { app: *App };
            const ctx = ReflectCtx{ .app = app };
            _ = std.Thread.spawn(.{}, struct {
                fn run(c: ReflectCtx) void {
                    defer c.app.reflect_inflight = false;
                    if (c.app.reflection) |*rr| {
                        c.app.reflection_mutex.lock(c.app.io) catch return;
                        defer c.app.reflection_mutex.unlock(c.app.io);
                        const reflect_result = rr.reflect(&c.app.agent, &c.app.memory, c.app.io) catch |err| {
                            std.debug.print("[reflect-bg] failed: {t}\n", .{err});
                            return;
                        };
                        if (reflect_result.self_narrative_updated) {
                            std.debug.print("[reflect-bg] ✓ tick={d} narrative 更新 (len={d})\n", .{ c.app.agent.tick, c.app.memory.self_narrative.len });
                        }
                    }
                }
            }.run, .{ctx}) catch |err| {
                std.debug.print("[ui] reflect-bg spawn 失败: {t}, 降级同步\n", .{err});
                app.reflect_inflight = false;
            };
        } else if (r.shouldReflect(&app.agent) and app.reflect_inflight) {
            std.debug.print("[reflect] inflight, skip tick={d}\n", .{app.agent.tick});
        }
    }
    if (app.agent.tick > 0 and app.agent.tick -% app.last_template_reflect_tick >= 32) {
        const E = app.agent.ed.e();
        const top_goal = if (app.growth_log.items.len > 0)
            if (app.growth_log.items[app.growth_log.items.len - 1].goal) |g| g else "observe"
        else "observe";
        const narr = std.fmt.allocPrint(alloc,
            \\[no-LLM 模板] 我跑到了 tick={d}, E={d:.3} (M={d:.3} R={d:.3} N={d:.3}), 主要在 {s}. 自我演化累计 {d} 次. 信念数 {d}.
        , .{
            app.agent.tick, E,
            app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature,
            top_goal, app.self_evolve_total, app.memory.beliefs.items.len,
        }) catch return;
        defer alloc.free(narr);
        alloc.free(app.memory.self_narrative);
        app.memory.self_narrative = alloc.dupe(u8, narr) catch return;
        app.memory.reflection_count += 1;
        app.last_template_reflect_tick = app.agent.tick;
        if (app.sqlite) |*db| {
            _ = db.insertEpisode(@intCast(app.agent.tick), "reflection", narr, 0.5, "template") catch {};
        }
        std.debug.print("[ui] no-LLM 反思 (tick={d}): {s}\n", .{ app.agent.tick, narr });
    }
}

/// P5b: E 饱和时注入多样性代谢任务 (每 64 tick)
fn maybeMetabolismInject(app: *App) void {
    if (!eSaturated(app)) return;
    if (app.agent.tick == 0) return;
    if (app.agent.tick == app.last_metabolism_tick) return;
    if (app.agent.tick % 64 != 0) return;
    app.last_metabolism_tick = app.agent.tick;
    const value_flat = @abs(app.value_tracker.trend()) < 0.0001 and app.value_tracker.count >= 8;
    const r = ghw_harness.metabolism.maybeInject(
        &app.task_queue,
        app.agent.ed.e(),
        countLiveGhwPeers(app) > 0,
        value_flat,
        app.alloc,
    ) catch |err| {
        std.debug.print("[ui] metabolism 失败: {t}\n", .{err});
        return;
    };
    if (r.submitted > 0) {
        app.metabolism_submitted_total += r.submitted;
        std.debug.print("[ui] tick={d} metabolism 入队 {d} (total={d} pending={d})\n", .{
            app.agent.tick, r.submitted, app.metabolism_submitted_total, app.task_queue.pending_count,
        });
    }
}

/// P1: 本机压力 → world_sensor 任务 (无 LLM 也能求存)
fn maybeWorldSensorTasks(app: *App) void {
    // 每 8 tick 最多扫一次 (压力持续时靠 hasPendingTitlePrefix 去重)
    if (app.agent.tick == 0) return;
    if (app.agent.tick == app.last_world_sensor_tick) return;
    if (app.agent.tick % 8 != 0) return;
    const snap = app.sys_collector.last orelse return;
    app.last_world_sensor_tick = app.agent.tick;
    // P5a: 健康时清 AutoCLI 节流
    if (!ghw_harness.survival_learn.isCrisisSnap(snap)) {
        if (app.autocli_interval_override_s.load(.seq_cst) > 0) {
            app.autocli_interval_override_s.store(0, .seq_cst);
            std.debug.print("[ui] tick={d} host healthy → AutoCLI throttle cleared\n", .{app.agent.tick});
        }
    }
    // P8b: 危机规则采纳后对照压力
    if (app.survival_feedback.maybeEvaluate(snap, app.agent.tick, &app.memory, app.io)) |maybe_ev| {
        if (maybe_ev) |ev| {
            app.survival_feedback_evals += 1;
            if (ev.improved) app.survival_feedback_improved += 1;
            std.debug.print("[ui] tick={d} survival_feedback improved={} diskΔ={d:.1} memΔ={d:.1} loadΔ={d:.2} boost={d}\n", .{
                app.agent.tick, ev.improved, ev.disk_delta, ev.mem_delta, ev.load_delta, ev.beliefs_boosted,
            });
        }
    } else |err| {
        std.debug.print("[ui] survival_feedback 失败: {t}\n", .{err});
    }
    const r = ghw_harness.world_sensor.maybeSubmitFromSnapshot(&app.task_queue, snap, app.alloc) catch |err| {
        std.debug.print("[ui] world_sensor 失败: {t}\n", .{err});
        return;
    };
    if (r.submitted > 0) {
        std.debug.print("[ui] tick={d} world_sensor 入队 {d} 个生存任务 (pending={d})\n", .{
            app.agent.tick, r.submitted, app.task_queue.pending_count,
        });
    }
}

/// P8a: 生存类 pending/in_progress 时 ActionRunner 让路给 TaskExecutor
fn hasPendingSurvivalWork(app: *const App) bool {
    for (app.task_queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        switch (t.source) {
            .world_sensor, .survival_remedy, .survival_act, .peer_symbiosis, .world_fetch => return true,
            else => {},
        }
    }
    return false;
}

/// P8a: ActionRunner query_peer 与 TaskExecutor 共用同伴写回
fn ingestPeerActionResult(app: *App, raw_log: []const u8) void {
    const own_e = app.agent.ed.e();
    const report = std.fmt.allocPrint(app.alloc, "query_peer response: {s}", .{raw_log}) catch {
        const peer_E = extractEFromResp(raw_log);
        if (peer_E > 0.01) updatePeerECache(app, peer_E);
        return;
    };
    defer app.alloc.free(report);
    const ins = ghw_harness.peer_symbiosis.learnFromReport(
        &app.memory,
        app.io,
        app.agent.tick,
        report,
        own_e,
        &app.task_queue,
    ) catch |err| {
        std.debug.print("[ui] ActionRunner peer_symbiosis 失败: {t}\n", .{err});
        const peer_E = extractEFromResp(raw_log);
        if (peer_E > 0.01) updatePeerECache(app, peer_E);
        return;
    };
    if (ins.parsed and ins.peer_e > 0.01) {
        updatePeerECache(app, ins.peer_e);
        app.peer_symbiosis_total += 1;
        std.debug.print("[ui] tick={d} ActionRunner→peer_symbiosis E={d:.3} beliefs=+{d} followups=+{d}\n", .{
            app.agent.tick, ins.peer_e, ins.beliefs_added, ins.followups,
        });
    }
}

/// 合并 world_digest + peer_digest 到持久缓冲, 供 RuleProposer.setWorldDigest
fn refreshCombinedDigest(app: *App) void {
    app.peer_digest_len = app.peer_inbox.formatDigest(&app.peer_digest_buf);
    var clen: usize = 0;
    if (app.world_digest_len > 0) {
        const n = @min(app.world_digest_len, app.combined_digest_buf.len);
        @memcpy(app.combined_digest_buf[0..n], app.world_digest_buf[0..n]);
        clen = n;
        if (app.peer_inbox.count() > 0 and clen + 3 < app.combined_digest_buf.len) {
            app.combined_digest_buf[clen] = ' ';
            app.combined_digest_buf[clen + 1] = '|';
            app.combined_digest_buf[clen + 2] = ' ';
            clen += 3;
        }
    }
    if (app.peer_inbox.count() > 0 and app.peer_digest_len > 0) {
        const take = @min(app.peer_digest_len, app.combined_digest_buf.len - clen);
        @memcpy(app.combined_digest_buf[clen..][0..take], app.peer_digest_buf[0..take]);
        clen += take;
    }
    app.combined_digest_len = clen;
}

fn applyDigestToProposer(app: *App, p: anytype) void {
    refreshCombinedDigest(app);
    if (app.combined_digest_len > 0) {
        p.setWorldDigest(app.combined_digest_buf[0..app.combined_digest_len]);
    }
}

/// P0: 刷新觉醒 / 宿主短板 / 存在相 (求存外环 ↔ 进化内环)
fn refreshLifecycle(app: *App) void {
    // 采样指纹 (未觉醒时每次尝试)
    if (app.sys_collector.last) |snap| {
        if (!app.awaken.awakened) {
            app.awaken.setFingerprintFromSnap(snap);
        }
        const now = std.Io.Clock.real.now(app.io).toSeconds();
        if (app.host_profile.kind == .desktop) {
            app.host_profile = ghw_harness.host_profile.Profile.fromDesktop(snap, now);
        } else {
            // mobile: 保留电量/热/后台, 同步桌面镜像字段
            app.host_profile.mem_pct = snap.mem_pct;
            app.host_profile.disk_used_pct = snap.disk_used_pct;
            app.host_profile.load_1m = snap.load_1m;
            app.host_profile.updated_at_unix = now;
        }
    }
    var world_fetch_count: u32 = 0;
    for (app.memory.episodes.items) |ep| {
        if (ep.kind == .world_fetch) world_fetch_count += 1;
    }
    const live_peers = countLiveGhwPeers(app);
    app.last_shortfall = ghw_harness.host_shortfall.assessWithProfile(
        app.sys_collector.last,
        app.agent.ed.e(),
        world_fetch_count,
        live_peers,
        app.value_tracker.trend(),
        app.host_profile,
    );
    if (app.rule_proposer) |*p| {
        p.setHostCrisis(app.last_shortfall.host_crisis);
        applyDigestToProposer(app, p);
    } else {
        refreshCombinedDigest(app);
    }
    const balanced = ghw_harness.existence_phase.mrnBalanced(
        app.agent.ed.v.material,
        app.agent.ed.v.representation,
        app.agent.ed.v.nature,
    );
    app.existence_phase = ghw_harness.existence_phase.compute(
        app.awaken.awakened,
        app.last_shortfall.host_crisis,
        app.agent.ed.e(),
        balanced,
        ghw_harness.existence_phase.valueOk(app.value_tracker.trend()),
    );
}

/// P0: 自动/手动觉醒入口
fn maybeAwaken(app: *App) void {
    if (app.awaken.awakened) return;
    if (app.sys_collector.last == null) return;
    const now = std.Io.Clock.real.now(app.io).toSeconds();
    const done = app.awaken.tryComplete(&app.memory, app.io, app.agent.tick, now, app.sys_collector.last) catch |err| {
        std.debug.print("[ui] awaken 失败: {t}\n", .{err});
        return;
    };
    if (done) {
        std.debug.print("[ui] ★ 觉醒完成 host={s} tick={d}\n", .{ app.awaken.fingerprintSlice(), app.agent.tick });
        saveState(app) catch {};
    }
}

/// P8: GET /api/state 与 POST /api/chat 共用的 post-cycle 管道
fn runPostCyclePipeline(app: *App, report: CycleReport) !void {
    maybeAwaken(app);
    refreshLifecycle(app);
    if (app.sqlite) |*db| {
        const cycle_data = try std.fmt.allocPrint(app.alloc, "tick={d} E={d:.3} M={d:.3} R={d:.3} N={d:.3}", .{
            report.tick, report.e_after,
            app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature,
        });
        defer app.alloc.free(cycle_data);
        _ = db.insertEpisode(@intCast(report.tick), "cycle", cycle_data, 0.3, "system") catch |err| {
            std.debug.print("[ui] sqlite insertEpisode 失败: {t}\n", .{err});
        };
        app.sqlite_episodes_written += 1;
    }
    maybeWorldSensorTasks(app);
    maybeMetabolismInject(app);
    maybeAutoReflect(app);
    try maybeAutoProposeGoals(app);
    maybeAutoProposeRules(app);
    maybeAutoBalanceTask(app);
    maybeRunPendingTask(app);
    recordValueTrend(app);
}

fn appendProvenanceJson(alloc: Allocator, body: *std.ArrayList(u8), app: *App) !void {
    const rb = app.agent.last_rule_bias;
    const tb = app.agent.last_task_bias;
    try body.appendSlice(alloc, ",\"provenance\":{\"rule_bias\":{");
    try body.print(alloc, "\"rule_count\":{d},\"dominance\":{d:.3},\"selection_changed\":", .{ rb.rule_count, rb.dominance });
    try body.print(alloc, "{s},\"favored\":", .{if (rb.selection_changed) "true" else "false"});
    if (rb.favored) |f| {
        try body.print(alloc, "\"{s}\"", .{@tagName(f)});
    } else {
        try body.appendSlice(alloc, "null");
    }
    try body.appendSlice(alloc, "},\"task_bias\":{");
    try body.print(alloc, "\"pending_count\":{d},\"dominance\":{d:.3},\"selection_changed\":", .{ tb.pending_count, tb.dominance });
    try body.print(alloc, "{s},\"favored\":", .{if (tb.selection_changed) "true" else "false"});
    if (tb.favored) |f| {
        try body.print(alloc, "\"{s}\"", .{@tagName(f)});
    } else {
        try body.appendSlice(alloc, "null");
    }
    try body.appendSlice(alloc, "},\"task_queue\":{");
    try body.print(alloc, "\"pending\":{d},\"total\":{d},\"completed\":{d}", .{
        app.task_queue.pending_count,
        app.task_queue.tasks.items.len,
        app.task_queue.completed_count,
    });
    var vm = ghw_harness.human_symbiosis.ValueMetric{};
    vm.pullFromSignal(&app.human_signal);
    vm.pullFromQueue(&app.task_queue);
    vm.pullFromGSP(&app.human_gsp);
    try body.appendSlice(alloc, "},\"human_symbiosis\":{");
    try body.print(alloc, "\"value_score\":{d:.3},\"value_trend\":{d:.4},", .{
        vm.valueScore(), app.value_tracker.trend(),
    });
    try app.value_tracker.appendRecentSamplesJson(alloc, body);
    try body.print(alloc, ",\"feedback_count\":{d},\"human_e_uplift\":{d:.3},\"peers\":[", .{
        vm.feedback_count, vm.human_e_uplift,
    });
    var gsp_it = app.human_gsp.peers.iterator();
    var first_peer = true;
    while (gsp_it.next()) |entry| {
        if (!first_peer) try body.append(alloc, ',');
        first_peer = false;
        const p = entry.value_ptr.*;
        try body.print(alloc, "{{\"id\":\"{s}\",\"trust\":{d:.3},\"trust_level\":\"{s}\"}}", .{
            p.id, p.trust, p.trustLevel(),
        });
    }
    try body.appendSlice(alloc, "]},\"rule_propose\":{");
    const rule_enabled = app.rule_proposer != null;
    try body.print(alloc, "\"enabled\":{s},\"total\":{d},\"adopted_rules\":{d}", .{
        if (rule_enabled) "true" else "false",
        app.rule_propose_total,
        app.agent.last_rule_bias.rule_count,
    });
    try body.appendSlice(alloc, "},\"chat\":{");
    const cr = app.last_chat_reply;
    try body.print(alloc, "\"last_memory_injected\":{s},\"last_tick\":{d},\"replies_with_memory\":{d},\"episode_count\":{d},\"belief_count\":{d}", .{
        if (cr.memory_injected) "true" else "false",
        if (app.chat_history.items.len > 0) app.chat_history.items[app.chat_history.items.len - 1].tick else 0,
        app.chat_replies_with_memory,
        cr.episode_count,
        cr.belief_count,
    });
    try body.appendSlice(alloc, "},\"peer_influence\":{\"peer_count\":");
    try body.print(alloc, "{d},\"peer_E_avg\":{d:.3},\"sigma\":{d:.3}", .{
        app.peer_count_cached, app.peer_E_avg, app.agent.ed.sigma,
    });
    // 生命代谢看板 (P0/P1): 别只看 E≈1
    var nonzero_de: u32 = 0;
    for (app.memory.episodes.items) |ep| {
        if (ep.delta_e > 0.001 or ep.delta_e < -0.001) nonzero_de += 1;
    }
    const live_peers = countLiveGhwPeers(app);
    const now_s = std.Io.Clock.real.now(app.io).toSeconds();
    const secs_since_cycle: i64 = if (app.last_cycle_unix_s > 0) now_s - app.last_cycle_unix_s else -1;
    const value_flat = @abs(app.value_tracker.trend()) < 0.0001 and app.value_tracker.count >= 8;
    const metabolism: []const u8 = blk: {
        if (app.auto_tick_ms == 0 and secs_since_cycle > 120) break :blk "stalled";
        if (app.cycle_busy) break :blk "busy";
        if (app.auto_tick_ms > 0 and secs_since_cycle >= 0 and secs_since_cycle < @as(i64, @intCast(app.auto_tick_ms / 1000 * 3 + 60))) break :blk "active";
        if (secs_since_cycle >= 0 and secs_since_cycle < 90) break :blk "active";
        break :blk "idle";
    };
    try body.appendSlice(alloc, "},\"vitality\":{");
    try body.print(alloc,
        \\"e_saturated":{s},"auto_tick_ms":{d},"cycle_busy":{s},"live_peers":{d},"pending_tasks":{d},"completed_tasks":{d},"episodes":{d},"episodes_nonzero_de":{d},"value_flat":{s},"secs_since_cycle":{d},"metabolism":"{s}","phase_honest":{d}
    , .{
        if (eSaturated(app)) "true" else "false",
        app.auto_tick_ms,
        if (app.cycle_busy) "true" else "false",
        live_peers,
        app.task_queue.pending_count,
        app.task_queue.completed_count,
        app.memory.episodes.items.len,
        nonzero_de,
        if (value_flat) "true" else "false",
        secs_since_cycle,
        metabolism,
        app.phase_progress,
    });
    var world_fetch_count: u32 = 0;
    for (app.memory.episodes.items) |ep| {
        if (ep.kind == .world_fetch) world_fetch_count += 1;
    }
    try body.appendSlice(alloc, "},\"survival\":{");
    try body.print(alloc, "\"world_fetch_count\":{d},\"last_task_action\":\"{s}\",\"last_task_acted\":{s},\"remedy_submitted_total\":{d},\"survival_beliefs_total\":{d},\"act_human_total\":{d},\"autocli_throttle_s\":{d},\"metabolism_submitted_total\":{d},\"world_bridge_total\":{d},\"peer_symbiosis_total\":{d},\"peer_E_avg\":{d:.3},\"feedback_evals\":{d},\"feedback_improved\":{d},\"laws_version\":\"{s}\",\"laws_count\":{d},\"existence_phase\":\"{s}\",\"awakened\":{s},\"host_fingerprint\":\"{s}\"", .{
        world_fetch_count,
        app.last_task_action,
        if (app.last_task_acted) "true" else "false",
        app.remedy_submitted_total,
        app.survival_beliefs_total,
        app.act_human_total,
        app.autocli_interval_override_s.load(.seq_cst),
        app.metabolism_submitted_total,
        app.world_bridge_total,
        app.peer_symbiosis_total,
        app.peer_E_avg,
        app.survival_feedback_evals,
        app.survival_feedback_improved,
        ghw_harness.primordial_laws.VERSION,
        ghw_harness.primordial_laws.LAW_COUNT,
        app.existence_phase.label(),
        if (app.awaken.awakened) "true" else "false",
        app.awaken.fingerprintSlice(),
    });
    try body.appendSlice(alloc, ",\"shortfall\":");
    try ghw_harness.host_shortfall.appendJson(alloc, body, app.last_shortfall);
    try body.appendSlice(alloc, ",\"host_profile\":");
    try app.host_profile.appendJson(alloc, body);
    try body.append(alloc, ',');
    try app.peer_inbox.appendSummaryJson(alloc, body);
    try body.print(alloc, ",\"peer_shortfall_ingest_total\":{d}", .{app.peer_shortfall_ingest_total});
    try body.append(alloc, '}'); // close survival
    const crisis = app.last_shortfall.host_crisis or (app.existence_phase == .crisis);
    const accept_snap = ghw_harness.evolution_acceptance.Snapshot{
        .l1_count = app.self_evolve_l1_count,
        .l2_count = app.self_evolve_l2_count,
        .l3_count = app.self_evolve_l3_count,
        .l3_approved = app.self_evolve_l3_approved,
        .l4_count = app.self_evolve_l4_count,
        .l4_approved = app.self_evolve_l4_approved,
        .l5_count = app.self_evolve_l5_count,
        .self_evolve_total = app.self_evolve_total,
        .rule_propose_total = app.rule_propose_total,
        .adopted_rules = app.agent.last_rule_bias.rule_count,
        .crisis_lock = crisis,
        .awakened = app.awaken.awakened,
        .phase_label = app.existence_phase.label(),
        .iv1 = ghw_harness.existence_phase.evolveInterval(1, crisis),
        .iv3 = ghw_harness.existence_phase.evolveInterval(3, crisis),
        .iv4 = ghw_harness.existence_phase.evolveInterval(4, crisis),
        .iv5 = ghw_harness.existence_phase.evolveInterval(5, crisis),
        .feedback_pending = app.survival_feedback.pending,
        .feedback_evals = app.survival_feedback_evals,
        .feedback_improved = app.survival_feedback_improved,
        .rules_at_mark = app.survival_feedback.rules_at_mark,
        .steady = ghw_harness.existence_phase.steadyGates(
            app.agent.ed.v.material,
            app.agent.ed.v.representation,
            app.agent.ed.v.nature,
            app.agent.ed.e(),
            app.value_tracker.trend(),
        ),
    };
    try body.appendSlice(alloc, ",");
    try ghw_harness.evolution_acceptance.appendJson(alloc, body, accept_snap);
    try body.appendSlice(alloc, ",\"state_contract\":{");
    try body.print(alloc, "\"writer\":\"{s}\",\"epoch\":{d},\"tick\":{d},\"save_blocked\":{s},\"conflict\":\"{s}\"", .{
        app.state_meta.writer.label(),
        app.state_meta.epoch,
        app.state_meta.tick,
        if (app.state_save_blocked) "true" else "false",
        app.state_conflict.label(),
    });
    try body.appendSlice(alloc, "}}"); // state_contract + provenance (root 由 buildStateJson 关)
}

/// LLM 不可用时的回退模板 (4 套根据 E)
fn fallbackTemplate(
    alloc: Allocator,
    user_text: []const u8,
    e: F,
    sys_snap: SystemSnapshot,
    goal_name: []const u8,
) ![]u8 {
    const msg_summary = if (user_text.len > 30) user_text[0..30] ++ "..." else user_text;
    if (e > 0.85) {
        return try std.fmt.allocPrint(alloc,
            \\收到「{s}」。系统状态良好: CPU {d:.0}%, 内存 {d:.1}G/{d:.1}G, 负载 {d:.1}。当前精力充沛 (E={d:.3}), 正在执行 {s} 任务。
        , .{
            msg_summary,
            sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
            sys_snap.mem_used_gb, sys_snap.mem_total_gb,
            sys_snap.load_1m,
            e,
            goal_name,
        });
    }
    if (e > 0.6) {
        return try std.fmt.allocPrint(alloc,
            \\听到「{s}」。机器 CPU {d:.0}%, 负载 {d:.1}, 内存用 {d:.0}%。我状态还行 (E={d:.3}), {s} 中。
        , .{
            msg_summary,
            sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
            sys_snap.load_1m,
            sys_snap.mem_pct,
            e,
            goal_name,
        });
    }
    if (e > 0.4) {
        return try std.fmt.allocPrint(alloc,
            \\「{s}」— 嗯... CPU {d:.0}%, 系统有点忙。我能量偏低 (E={d:.3}), {s} 着。
        , .{
            msg_summary,
            sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
            e,
            goal_name,
        });
    }
    return try std.fmt.allocPrint(alloc,
        \\「{s}」— 抱歉, 能量很低 (E={d:.3})。机器也累 (CPU {d:.0}%, 负载 {d:.1})。能给我点简单任务吗?
    , .{
        msg_summary,
        e,
        sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
        sys_snap.load_1m,
    });
}

fn appendGrowth(app: *App, report: CycleReport) !void {
    const entry = GrowthEntry{
        .tick = report.tick,
        .timestamp = std.Io.Clock.real.now(app.io).toSeconds(),
        .E = report.e_after,
        .M = app.agent.ed.v.material,
        .R = app.agent.ed.v.representation,
        .N = app.agent.ed.v.nature,
        .goal = if (report.top_goal) |g| try app.alloc.dupe(u8, @tagName(g.kind)) else null,
        .self_evolved = report.self_evolved,
    };
    _ = entry.goal; // owned via dupe
    if (report.self_evolved) app.self_evolve_total += 1;
    try app.growth_log.append(app.alloc, entry);
    if (app.growth_log.items.len > GROWTH_LOG_MAX) {
        // 释放老的
        const old = app.growth_log.orderedRemove(0);
        if (old.goal) |g| app.alloc.free(g);
    }
}

/// 重新计算 personality (从 E/M/R/N 趋势 + belief/反思次数)
fn recomputePersonality(app: *App) void {
    const recent = app.growth_log.items;
    if (recent.len == 0) return;
    const e_current = recent[recent.len - 1].E;
    // 算最近 32 tick 的 E 趋势
    const win = @min(32, recent.len);
    var sum: F = 0;
    var i: usize = 0;
    while (i < win - 1) : (i += 1) {
        sum += recent[recent.len - 1 - i].E - recent[recent.len - 2 - i].E;
    }
    const e_trend = sum / @as(F, @floatFromInt(win - 1));

    const m = app.agent.ed.v.material;
    const r = app.agent.ed.v.representation;
    const n = app.agent.ed.v.nature;
    const total = m + r + n + 0.0001;

    // chat count
    const chat_count: u32 = @intCast(@min(20, app.chat_history.items.len));
    // peer count
    var peer_count: u32 = 0;
    // dup world snapshot 避免 race (collect 会 deinit last) — 只用 is_ghw 标志数
    if (app.world.last) |prev_world| {
        var world_dup = app.world.dupSnapshot(prev_world) catch null;
        defer if (world_dup) |*w| w.deinit();
        if (world_dup) |world| {
            for (world.network_peers) |p| {
                if (p.is_ghw) peer_count += 1;
            }
        }
    }

    app.personality.recompute(e_current, e_trend, m / total, r / total, n / total, app.memory.reflection_count, @intCast(app.memory.beliefs.items.len), chat_count, peer_count);

    // 把 self_phrase 同步到最新的 self_narrative (如果 LLM 已经更新了)
    if (app.memory.self_narrative.len > 0) {
        app.alloc.free(app.personality.self_phrase);
        app.personality.self_phrase = app.alloc.dupe(u8, app.memory.self_narrative) catch &[_]u8{};
    }
}

fn saveState(app: *App) !void {
    const abs = if (std.fs.path.isAbsolute(app.state_path))
        try app.alloc.dupe(u8, app.state_path)
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(app.io, &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];
        break :blk try std.fs.path.join(app.alloc, &[_][]const u8{ cwd, app.state_path });
    };
    defer app.alloc.free(abs);

    // P1: 读盘 meta, 检测 ui/daemon 双写冲突
    var disk_meta: ghw_harness.state_contract.Meta = .{};
    if (readFile(app.alloc, app.io, abs)) |existing| {
        defer app.alloc.free(existing);
        if (try ghw_harness.state_contract.Meta.parseFromJson(existing, app.alloc)) |dm| {
            disk_meta = dm;
        }
    } else |_| {}
    const conflict = ghw_harness.state_contract.detectConflict(app.state_meta, disk_meta, .ui_server);
    app.state_conflict = conflict;
    if (conflict == .foreign_newer) {
        app.state_save_blocked = true;
        std.debug.print("[ui] state 保存跳过: 磁盘 epoch={d} writer={s} 比本地新 (foreign_newer)\n", .{
            disk_meta.epoch, disk_meta.writer.label(),
        });
        return;
    }
    app.state_save_blocked = false;

    const goal_str = if (app.growth_log.items.len > 0)
        if (app.growth_log.items[app.growth_log.items.len - 1].goal) |g| g else "—"
    else "—";

    const json_a = try std.fmt.allocPrint(app.alloc,
        \\{{"agent_id":"{s}","tick":{d},"M":{d:.6},"R":{d:.6},"N":{d:.6},"alpha":{d:.6},"beta":{d:.6},"gamma":{d:.6},"E":{d:.6},"self_evolved_total":{d},"action_count":{d},"l1_count":{d},"l2_count":{d},"l3_count":{d},"l3_approved":{d},"l4_count":{d},"l4_approved":{d},"l5_count":{d},"last_auto_l1l2_tick":{d},"last_auto_l3_tick":{d},"last_auto_l4_tick":{d},"last_auto_l5_tick":{d},"phase":{d},"phase_progress":{d},"six_interfaces_done":{d},"seven_reflection_done":{d},"eight_relations_seen":{d},"nine_palaces_e_var_seen":{d},"nine_palaces_mrn_seen":{d},"nine_palaces_mrn_strong_seen":{d},"top_goal":"{s}",
    , .{
        app.agent.self_id,
        app.agent.tick,
        app.agent.ed.v.material,
        app.agent.ed.v.representation,
        app.agent.ed.v.nature,
        app.agent.ed.weights.alpha,
        app.agent.ed.weights.beta,
        app.agent.ed.weights.gamma,
        app.agent.ed.e(),
        app.self_evolve_total,
        app.action_count,
        app.self_evolve_l1_count,
        app.self_evolve_l2_count,
        app.self_evolve_l3_count,
        app.self_evolve_l3_approved,
        app.self_evolve_l4_count,
        app.self_evolve_l4_approved,
        app.self_evolve_l5_count,
        app.last_auto_l1l2_tick,
        app.last_auto_l3_tick,
        app.last_auto_l4_tick,
        app.last_auto_l5_tick,
        app.phase,
        app.phase_progress,
        app.six_interfaces_done,
        app.seven_reflection_done,
        app.eight_relations_seen,
        app.nine_palaces_e_var_seen,
        app.nine_palaces_mrn_seen,
        app.nine_palaces_mrn_strong_seen,
        goal_str,
    });
    defer app.alloc.free(json_a);
    const mem_json = try app.memory.toJson(app.alloc);
    defer app.alloc.free(mem_json);
    const tq_json = try app.task_queue.toJson(app.alloc);
    defer app.alloc.free(tq_json);
    const gsp_json = try app.human_gsp.toJson(app.alloc);
    defer app.alloc.free(gsp_json);
    const sig_json = try app.human_signal.toJson(app.alloc);
    defer app.alloc.free(sig_json);
    const vt_json = try app.value_tracker.toJson(app.alloc);
    defer app.alloc.free(vt_json);
    const product_json = if (app.product_runtime) |*rt| try rt.toJson(app.alloc) else null;
    defer if (product_json) |p| app.alloc.free(p);
    const co_evo_json = if (app.co_evolution) |*reg| try reg.toJson(app.alloc) else null;
    defer if (co_evo_json) |p| app.alloc.free(p);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(app.alloc);
    try buf.appendSlice(app.alloc, json_a);
    try buf.appendSlice(app.alloc, "\"memory\":");
    try buf.appendSlice(app.alloc, mem_json);
    try buf.appendSlice(app.alloc, ",\"task_queue\":");
    try buf.appendSlice(app.alloc, tq_json);
    try buf.appendSlice(app.alloc, ",\"human_gsp\":");
    try buf.appendSlice(app.alloc, gsp_json);
    try buf.appendSlice(app.alloc, ",\"human_signal\":");
    try buf.appendSlice(app.alloc, sig_json);
    try buf.appendSlice(app.alloc, ",\"value_tracker\":");
    try buf.appendSlice(app.alloc, vt_json);
    if (product_json) |p| {
        try buf.appendSlice(app.alloc, ",\"product_runtime\":");
        try buf.appendSlice(app.alloc, p);
    }
    if (co_evo_json) |p| {
        try buf.appendSlice(app.alloc, ",\"co_evolution\":");
        try buf.appendSlice(app.alloc, p);
    }
    const awaken_json = try app.awaken.toJson(app.alloc);
    defer app.alloc.free(awaken_json);
    try buf.appendSlice(app.alloc, ",\"awaken\":");
    try buf.appendSlice(app.alloc, awaken_json);

    const hp_json = try app.host_profile.toJson(app.alloc);
    defer app.alloc.free(hp_json);
    try buf.appendSlice(app.alloc, ",\"host_profile\":");
    try buf.appendSlice(app.alloc, hp_json);

    const inbox_json = try app.peer_inbox.toJson(app.alloc);
    defer app.alloc.free(inbox_json);
    try buf.appendSlice(app.alloc, ",\"peer_inbox\":");
    try buf.appendSlice(app.alloc, inbox_json);

    const now_unix: i64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    app.state_meta.writer = .ui_server;
    app.state_meta.epoch = ghw_harness.state_contract.nextEpoch(app.state_meta, disk_meta);
    app.state_meta.tick = app.agent.tick;
    app.state_meta.updated_at_unix = now_unix;
    const meta_json = try app.state_meta.toJson(app.alloc);
    defer app.alloc.free(meta_json);
    try buf.appendSlice(app.alloc, ",\"state_meta\":");
    try buf.appendSlice(app.alloc, meta_json);

    try buf.append(app.alloc, '}');
    const json = try buf.toOwnedSlice(app.alloc);
    defer app.alloc.free(json);
    try ghw_harness.state_contract.writeAtomic(app.io, app.alloc, abs, json);
}

// ===== HTTP 响应 =====
fn writeResponse(stream: *std.Io.net.Stream, io: std.Io, response: []const u8) !void {
    defer stream.close(io);
    // 小缓冲会频繁 flush; state JSON 可达数 KB+, 用 4KiB 降低 syscall
    var buf: [4096]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(response);
    try w.interface.flush();
}

fn makeHttpResponse(alloc: Allocator, status: u16, status_text: []const u8, content_type: []const u8, body: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.print(alloc,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ status, status_text, content_type, body.len },
    );
    try buf.appendSlice(alloc, body);
    return buf.toOwnedSlice(alloc);
}

/// 从 JSON 字符串里抽 float: 找 "key":<number> 模式
/// 简易版: 找到 key 后, 解析后面浮点数
/// 返 0.0 如果没找到
fn extractFloatFromJson(json: []const u8, key: []const u8) ?f32 {
    if (std.mem.indexOf(u8, json, key)) |key_pos| {
        var pos: usize = key_pos + key.len;
        // 跳过空白 + 冒号
        while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}
        if (pos >= json.len) return null;
        // 找到浮点数结束
        const start = pos;
        while (pos < json.len and json[pos] != ',' and json[pos] != '}' and json[pos] != ' ' and json[pos] != '\n' and json[pos] != '\r' and json[pos] != '\t') : (pos += 1) {}
        const num_str = std.mem.trim(u8, json[start..pos], " \t\n");
        return std.fmt.parseFloat(f32, num_str) catch null;
    }
    return null;
}

fn jsonEscape(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) try out.print(alloc, "\\u{x:0>4}", .{c}) else try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 停 link server + 释放资源 — 必须在 process 退出前调一次
/// 之前放 defer block 里, 但 runServer 返 error 时 defer join link_thread 会卡死
/// (link thread 在 accept 阻塞, 没看到 stop flag). 改成 manual call 配 errdefer
fn stopLinkServer(app: *App, alloc: Allocator, io: std.Io) void {
    app.cross_link_stop.store(true, .release);
    if (app.cross_link_thread) |t| t.join();
    if (app.cross_link) |*cl| cl.deinit();
    app.link_stop.store(true, .release);
    if (app.link_thread) |t| t.join();
    // Phase 1 production: 停 peer health thread
    app.peer_health_stop.store(true, .release);
    if (app.peer_health_thread) |t| t.join();
    if (app.link) |*l| {
        std.Io.Dir.deleteFileAbsolute(io, l.self_path) catch {};
        alloc.free(l.self_path);
    }
    if (app.peers_file.len > 0) alloc.free(app.peers_file);
    for (app.peers.items) |p| {
        alloc.free(p.path);
        alloc.free(p.peer_id);
    }
    app.peers.deinit(alloc);
}

/// 从 peer 的 query_product_evolution 响应中提取变更并写入 CoEvolutionRegistry。
fn ingestPeerEvolutionResponse(app: *App, peer_id: []const u8, response: []const u8) void {
    const intent = app.product_intent orelse return;
    if (app.co_evolution) |*reg| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, response, search_from, "\"target\":\"")) |tpos| {
            const target = extractJsonStringField(response[tpos..], "target") orelse break;
            const summary = extractJsonStringField(response[tpos..], "summary") orelse target;
            const delta = extractJsonFloatField(response[tpos..], "expected_delta_k") orelse 0;
            _ = reg.recordInsight(
                peer_id,
                intent.product_id,
                @tagName(intent.product_type),
                target,
                summary,
                delta,
                @intCast(@max(app.agent.tick, 0)),
            ) catch {};
            search_from = tpos + 8;
        }
    }
}

/// P2: 从 peer query_shortfall 响应写入 inbox + 有界协助
fn ingestPeerShortfallResponse(app: *App, peer_id: []const u8, response: []const u8) void {
    const report = ghw_harness.host_shortfall.parseJson(response) orelse return;
    const now_u: i64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    app.peer_inbox.push(peer_id, report, app.agent.tick, now_u);
    app.peer_shortfall_ingest_total += 1;
    _ = ghw_harness.peer_symbiosis.learnFromShortfall(
        &app.memory,
        &app.task_queue,
        peer_id,
        report,
        app.agent.tick,
    ) catch {};
}

/// Phase 1 production: 从 peers_file 加载 peer 列表
/// 格式: 一行一个 socket path, # 开头是注释, 空行忽略
fn loadPeersFromFile(alloc: std.mem.Allocator, app: *App) !void {
    const file = try std.Io.Dir.openFileAbsolute(app.io, app.peers_file, .{ .mode = .read_only });
    defer file.close(app.io);

    const stat = try file.stat(app.io);
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var line_start: usize = 0;
    while (total < stat.size) {
        const want = @min(buf.len, stat.size - total);
        const n = try std.Io.File.readPositionalAll(file, app.io, buf[0..want], total);
        if (n == 0) break;
        total += n;

        var i: usize = 0;
        while (i < n) {
            // 找下一行
            var j: usize = i;
            while (j < n and buf[j] != '\n') : (j += 1) {}
            if (j > i) {
                const line = buf[i..j];
                // 跳过前导空白
                var k: usize = 0;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
                // 空行 或 # 开头 跳过
                if (k < line.len and line[k] != '#') {
                    const path = line[k..];
                    // 跳过尾部空白
                    var end: usize = path.len;
                    while (end > 0 and (path[end - 1] == ' ' or path[end - 1] == '\t' or path[end - 1] == '\r')) : (end -= 1) {}
                    const trimmed = path[0..end];
                    if (trimmed.len > 0) {
                        // 跟已有 peer 比对, 不重复
                        var exists = false;
                        for (app.peers.items) |existing| {
                            if (std.mem.eql(u8, existing.path, trimmed)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) {
                            // peer_id 从 path basename 提取 (跟 GhwLink.init 一样)
                            const basename = std.fs.path.basename(trimmed);
                            var id_start: usize = 0;
                            if (std.mem.startsWith(u8, basename, "ghw_")) id_start = 4;
                            const id_end: usize = if (std.mem.endsWith(u8, basename, ".sock"))
                                basename.len - ".sock".len
                            else
                                basename.len;
                            const peer_id = basename[id_start..id_end];
                            try app.peers.append(alloc, .{
                                .path = try alloc.dupe(u8, trimmed),
                                .peer_id = try alloc.dupe(u8, peer_id),
                                .last_seen_tick = 0,
                                .health = "unknown",
                                .last_seen_unix_s = 0,
                                .consecutive_failures = 0,
                                .last_E = 0,
                                .last_M = 0,
                                .last_R = 0,
                                .last_N = 0,
                                .last_tick = 0,
                            });
                        }
                    }
                }
            }
            i = j + 1;
            if (j >= n) break;
        }
        line_start = total;
    }
}

/// Phase 1 production: peer health-check background thread
/// 每 peer_health_interval_s 秒 ping 每个 peer, 更新 health + last_E/M/R/N
/// 跳过 "self" (自己) 和 "unknown" 路径 (没初始化)
fn peerHealthLoop(app: *App) void {
    const interval_s: u64 = 60; // default, can be configured via --peer-health-interval-s
    while (!app.peer_health_stop.load(.acquire)) {
        std.debug.print("[peer_health] tick, sleep {d}s\n", .{interval_s});
        // sleep
        var i: u64 = 0;
        while (i < interval_s * 10 and !app.peer_health_stop.load(.acquire)) : (i += 1) {
            std.Thread.yield() catch {};
            const req = std.c.timespec{
                .sec = 0,
                .nsec = 100 * std.time.ns_per_ms,
            };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        }
        if (app.peer_health_stop.load(.acquire)) break;
        std.debug.print("[peer_health] running ping sweep\n", .{});

        // ping each peer (skip self + unknown path)
        for (app.peers.items) |*p| {
            if (std.mem.eql(u8, p.health, "self")) continue;
            if (std.mem.eql(u8, p.path, "")) continue;
            if (app.link) |*l| {
                // 1. ping
                const ping_resp = l.query(p.path, "ping", "{}") catch {
                    p.consecutive_failures += 1;
                    if (p.consecutive_failures >= 10) {
                        p.health = "unreachable";
                    } else if (p.consecutive_failures >= 3) {
                        p.health = "stale";
                    }
                    continue;
                };
                defer app.alloc.free(ping_resp);
                p.consecutive_failures = 0;
                p.last_seen_unix_s = @intCast(app.agent.tick);  // 用 tick 替代 unix 时间戳 (0.17 std 没 clock_gettime)
                p.health = "healthy";

                // 2. query_state (if ping ok) — 抓 E/M/R/N/tick
                const state_resp = l.query(p.path, "query_state", "{}") catch {
                    continue;
                };
                defer app.alloc.free(state_resp);
                // 朴素 parse: 找 "E":<num>, "M":<num>, etc.
                // 用 helper: 找 key, 提取数字直到逗号/大括号
                const extractFloatField = struct {
                    fn f(s: []const u8, key: []const u8) ?f32 {
                        const kpos = std.mem.indexOf(u8, s, key) orelse return null;
                        var q: usize = kpos + key.len;
                        // skip 空白 + 冒号
                        while (q < s.len and (s[q] == ' ' or s[q] == ':' or s[q] == '\t' or s[q] == '\n')) : (q += 1) {}
                        const start = q;
                        // 数字 / . / - 都接受
                        while (q < s.len and ((s[q] >= '0' and s[q] <= '9') or s[q] == '.' or s[q] == '-' or s[q] == 'e' or s[q] == '+')) : (q += 1) {}
                        if (q == start) return null;
                        return std.fmt.parseFloat(f32, s[start..q]) catch null;
                    }
                }.f;
                const extractIntField = struct {
                    fn f(s: []const u8, key: []const u8) ?i64 {
                        const kpos = std.mem.indexOf(u8, s, key) orelse return null;
                        var q: usize = kpos + key.len;
                        while (q < s.len and (s[q] == ' ' or s[q] == ':' or s[q] == '\t' or s[q] == '\n')) : (q += 1) {}
                        const start = q;
                        while (q < s.len and s[q] >= '0' and s[q] <= '9') : (q += 1) {}
                        if (q == start) return null;
                        return std.fmt.parseInt(i64, s[start..q], 10) catch null;
                    }
                }.f;

                if (extractFloatField(state_resp, "\"E\":")) |v| p.last_E = v;
                if (extractFloatField(state_resp, "\"M\":")) |v| p.last_M = v;
                if (extractFloatField(state_resp, "\"R\":")) |v| p.last_R = v;
                if (extractFloatField(state_resp, "\"N\":")) |v| p.last_N = v;
                if (extractIntField(state_resp, "\"tick\":")) |v| {
                    p.last_tick = v;
                    p.last_seen_tick = v;
                }

                if (app.co_evolution != null) {
                    const evo_resp = l.query(p.path, "query_product_evolution", "{}") catch continue;
                    defer app.alloc.free(evo_resp);
                    ingestPeerEvolutionResponse(app, p.peer_id, evo_resp);
                }

                // P2: 拉取同伴短板 → inbox + 有界协助任务
                if (l.query(p.path, "query_shortfall", "{}")) |sf_resp| {
                    defer app.alloc.free(sf_resp);
                    ingestPeerShortfallResponse(app, p.peer_id, sf_resp);
                } else |_| {}
            }
        }

        if (app.cross_link) |*cl| {
            for (cl.peers.items) |*peer| {
                const evo_resp = cl.query(peer.peer_id, "query_product_evolution", "{}") catch continue;
                defer app.alloc.free(evo_resp);
                ingestPeerEvolutionResponse(app, peer.peer_id, evo_resp);
            }
        }
    }
}

// ===== 路由处理 =====
fn handleGetRoot(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = app.index_html;
    const resp = try makeHttpResponse(alloc, 200, "OK", "text/html; charset=utf-8", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handleGetAppJs(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = app.app_js;
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/javascript; charset=utf-8", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// 提供 ui/vendor/* 静态文件 (Alpine/HTMX 本地化, 不依赖外网 CDN)
fn handleGetVendorStatic(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "/vendor/")) {
        const resp = try makeHttpResponse(alloc, 403, "Forbidden", "text/plain", "forbidden");
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    const rel = path["/vendor/".len..];
    if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null) {
        const resp = try makeHttpResponse(alloc, 403, "Forbidden", "text/plain", "forbidden");
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(app.io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    const file_path = if (std.fs.path.isAbsolute(app.ui_dir))
        try std.fs.path.join(alloc, &[_][]const u8{ app.ui_dir, "vendor", rel })
    else
        try std.fs.path.join(alloc, &[_][]const u8{ cwd, app.ui_dir, "vendor", rel });
    defer alloc.free(file_path);
    const body = readFile(alloc, app.io, file_path) catch {
        const resp = try makeHttpResponse(alloc, 404, "Not Found", "text/plain", "not found");
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    defer alloc.free(body);
    const ct = if (std.mem.endsWith(u8, rel, ".js"))
        "application/javascript; charset=utf-8"
    else
        "application/octet-stream";
    const resp = try makeHttpResponse(alloc, 200, "OK", ct, body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn runAgentCycleLocked(app: *App, alloc: Allocator) !CycleReport {
    app.cycle_mutex.lockUncancelable(app.io);
    defer app.cycle_mutex.unlock(app.io);
    return advanceAgentCycle(app, alloc);
}

fn autoTickThreadFn(app: *App) void {
    while (!should_stop_ui.load(.acquire)) {
        const ms = app.auto_tick_ms;
        if (ms == 0) return;
        app.io.sleep(.{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) }, std.Io.Clock.real) catch {};
        if (should_stop_ui.load(.acquire)) return;
        _ = runAgentCycleLocked(app, app.alloc) catch |err| {
            std.debug.print("[auto-tick] cycle 失败: {t}\n", .{err});
        };
    }
}

/// 跑 1 cycle + post-cycle + action/L1-L5/phase 维护 (原 GET /api/state 副作用)
fn advanceAgentCycle(app: *App, alloc: Allocator) !CycleReport {
    const report = try runCycle(app);
    try appendGrowth(app, report);
    try saveState(app);

    // 每 tick 写自传体 episode (带 ΔE) — 避免「高 E、零往事」的假连续
    {
        const de = report.e_after - report.e_before;
        const goal = if (report.top_goal) |g| @tagName(g.kind) else "observe";
        const weak = Memory.weakestDim(app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature);
        const summary = std.fmt.allocPrint(alloc, "cycle goal={s} E={d:.3} dE={d:.4}", .{ goal, report.e_after, de }) catch null;
        if (summary) |s| {
            defer alloc.free(s);
            app.memory.recordAt(app.io, .system_event, report.tick, s, null, weak, de) catch |err| {
                std.debug.print("[ui] recordAt cycle 失败: {t}\n", .{err});
            };
        }
        app.last_cycle_unix_s = std.Io.Clock.real.now(app.io).toSeconds();
    }

    // P8: 自省 + LLM 提议入队 + 跑 pending 任务 (与 POST /api/chat 共用)
    try runPostCyclePipeline(app, report);

    // === 自动执行: 每 N cycle 跑 1 个 top unadopted goal ===
    // 这是"具备行动的能力"的核心: 反思 → 提议 → **执行** → 状态变化
    // P8a: 生存任务 pending 时让路 TaskExecutor (避免双轨抢 query_peer)
    if (app.action_runner) |*ar| {
        const since_last_action: u64 = app.agent.tick -% ar.last_action_at_tick;
        if (!hasPendingSurvivalWork(app) and (since_last_action >= app.action_every or ar.last_action_at_tick == 0)) {
            var did_action = false;
            if (ar.runTopGoal(@intCast(app.agent.tick))) |maybe_result| {
                if (maybe_result) |result| {
                    if (app.last_action) |*prev| prev.deinit();
                    app.last_action = result;
                    app.action_count += 1;
                    ar.last_action_at_tick = app.agent.tick;
                    did_action = true;
                    std.debug.print("[ui] auto action done: {s} (action_count={d})\n", .{ result.goal_title, app.action_count });
                    // P8a: query_peer → 与 TaskExecutor 同款 peer_symbiosis 写回
                    if (std.mem.eql(u8, result.action_kind, "query_peer")) {
                        ingestPeerActionResult(app, result.log);
                    }
                }
            } else |err| {
                std.debug.print("[ui] auto action failed: {t}\n", .{err});
            }
            // === Baseline observe action: 永远至少做 1 个动作, 避免"什么都没做"循环 ===
            // 写 actions + episodes 表, 让 LLM reflect 时看到 "I observed X at tick N"
            if (!did_action) {
                const E = app.agent.ed.e();
                const M = app.agent.ed.v.material;
                const R = app.agent.ed.v.representation;
                const N = app.agent.ed.v.nature;
                const obs_log = try std.fmt.allocPrint(alloc,
                    "[observe] tick={d} E={d:.3} M={d:.3} R={d:.3} N={d:.3} (no goal available, baseline snapshot)",
                    .{ app.agent.tick, E, M, R, N });
                if (app.sqlite) |*db| {
                    _ = db.insertAction(
                        null, // baseline observe 无 goal
                        @intCast(app.agent.tick),
                        "observe",
                        "self",
                        "baseline_observe",
                        obs_log,
                        "noop",
                        0,
                    ) catch {};
                    _ = db.insertEpisode(
                        @intCast(app.agent.tick),
                        "action",
                        obs_log,
                        0.4,
                        "self",
                    ) catch {};
                }
                app.action_count += 1;
                ar.last_action_at_tick = app.agent.tick;
                std.debug.print("[ui] baseline observe (action_count={d})\n", .{app.action_count});
            }
        }
    }

    // === L1-L5 自动自演化 (直接调 callback, 不依赖 LLM 提议的 goal) ===
    // 危机锁: host_crisis 时暂停 L4/L5, L3 降频 (existence_phase)
    // 未觉醒时不跑重进化 (仍允许 L1+L2 轻量调参)
    {
        const tick = app.agent.tick;
        const crisis = app.last_shortfall.host_crisis or (app.existence_phase == .crisis);
        const iv1 = ghw_harness.existence_phase.evolveInterval(1, crisis);
        const iv3 = ghw_harness.existence_phase.evolveInterval(3, crisis);
        const iv4 = ghw_harness.existence_phase.evolveInterval(4, crisis);
        const iv5 = ghw_harness.existence_phase.evolveInterval(5, crisis);
        const l1l2_due = ghw_harness.existence_phase.isDue(tick, app.last_auto_l1l2_tick, iv1);
        const l3_due = ghw_harness.existence_phase.isDue(tick, app.last_auto_l3_tick, iv3);
        const l4_due = app.awaken.awakened and ghw_harness.existence_phase.isDue(tick, app.last_auto_l4_tick, iv4);
        const l5_due = app.awaken.awakened and ghw_harness.existence_phase.isDue(tick, app.last_auto_l5_tick, iv5);

        // 一个 tick 最多触发 1 个 level; 危机时 L4/L5 不会 due
        var level: u8 = 0;
        if (l5_due and ghw_harness.existence_phase.heavyEvolveAllowed(crisis, 5)) {
            level = 5;
            app.last_auto_l5_tick = tick;
        } else if (l4_due and ghw_harness.existence_phase.heavyEvolveAllowed(crisis, 4)) {
            level = 4;
            app.last_auto_l4_tick = tick;
        } else if (l3_due) {
            level = 3;
            app.last_auto_l3_tick = tick;
        } else if (l1l2_due) {
            level = 1;
            app.last_auto_l1l2_tick = tick;
        }
        if (level > 0) {
            if (crisis and level >= 4) {
                std.debug.print("[auto-self-evolve] crisis lock skip L{d}\n", .{level});
            } else {
            const levels_to_run: []const u8 = switch (level) {
                1 => &.{ 1, 2 },
                else => &.{level},
            };
            for (levels_to_run) |lv| {
                const log_str = onSelfEvolveCallback(lv, @ptrCast(app)) catch |err| brk: {
                    std.debug.print("[auto-self-evolve] L{d} 失败: {t}\n", .{ lv, err });
                    break :brk try app.alloc.dupe(u8, "auto_self_evolve_failed");
                };
                defer app.alloc.free(log_str);
                app.self_evolve_total += 1;
                std.debug.print("[auto-self-evolve] ✓ L{d} ({s}) self_evolve_total++ → {d} phase={s} crisis={}\n", .{
                    lv, log_str, app.self_evolve_total, app.existence_phase.label(), crisis,
                });
                const kind = try std.fmt.allocPrint(app.alloc, "self_evolve_l{d}_auto", .{lv});
                defer app.alloc.free(kind);
                if (app.sqlite) |*db| {
                    _ = db.insertAction(
                        null,
                        @intCast(tick),
                        kind,
                        "self",
                        "[auto-trigger] L1-L5 self-evolve",
                        log_str,
                        "success",
                        0,
                    ) catch {};
                    var ep_buf: [512]u8 = undefined;
                    const ep_text = std.fmt.bufPrint(&ep_buf, "[auto L{d}] {s}", .{ lv, log_str }) catch "L?";
                    _ = db.insertEpisode(@intCast(tick), "self_evolve", ep_text, 0.9, "self") catch {};
                }
            }
            } // end crisis skip else
            // === Auto enhance: 每 64 cycle (非危机) ===
            const enhance_due = (!crisis and tick > 0 and tick % 64 == 0 and tick != app.last_enhance_tick);
            if (enhance_due and app.template_enhancer != null) {
                app.last_enhance_tick = tick;
                const top_goal_eh = if (app.growth_log.items.len > 0)
                    if (app.growth_log.items[app.growth_log.items.len - 1].goal) |g| g else "observe"
                else "observe";
                var beliefs_buf_eh: std.ArrayList(u8) = .empty;
                defer beliefs_buf_eh.deinit(app.alloc);
                for (app.memory.beliefs.items[0..@min(3, app.memory.beliefs.items.len)]) |b| {
                    beliefs_buf_eh.append(app.alloc, '\n') catch continue;
                    beliefs_buf_eh.appendSlice(app.alloc, "  - [") catch continue;
                    beliefs_buf_eh.appendSlice(app.alloc, @tagName(b.source)) catch continue;
                    const conf_str_eh = std.fmt.allocPrint(app.alloc, " c={d:.2}] ", .{b.confidence}) catch continue;
                    defer app.alloc.free(conf_str_eh);
                    beliefs_buf_eh.appendSlice(app.alloc, conf_str_eh) catch continue;
                    beliefs_buf_eh.appendSlice(app.alloc, b.text) catch continue;
                }
                const ctx_eh = ghw.harness.EnhanceContext{
                    .self_narrative = app.memory.self_narrative,
                    .top_goal = top_goal_eh,
                    .bias = @tagName(app.personality.bias),
                    .e_current = app.agent.ed.e(),
                    .m_r_n = .{ app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature },
                    .tick = tick,
                    .beliefs = beliefs_buf_eh.items,
                    .evolved_dir = app.evolved_dir,
                    .ghw_root = app.ghw_root,
                };
                if (app.template_enhancer.?.enhanceLatest(ctx_eh)) |maybe_result| {
                    if (maybe_result) |result| {
                        try app.enhance_results.append(app.alloc, result);
                        // 限制 16 条
                        while (app.enhance_results.items.len > 16) {
                            var old = app.enhance_results.orderedRemove(0);
                            old.deinit(app.alloc);
                        }
                        if (app.sqlite) |*db| {
                            _ = db.insertEpisode(
                                @intCast(tick),
                                "enhance",
                                result.summary,
                                0.7,
                                "llm",
                            ) catch {};
                        }
                        std.debug.print("[auto-enhance] ✓ tick={d} 完善 {s} → {s} (summary: {s})\n", .{
                            tick, result.original_path, result.enhanced_path, result.summary,
                        });
                    } else {
                        std.debug.print("[auto-enhance] tick={d} 无模板可完善 (跳过)\n", .{tick});
                    }
                } else |_| {
                    std.debug.print("[auto-enhance] tick={d} 无模板可完善 (跳过)\n", .{tick});
                }
            }
        }
    }

    // === Phase 晋升: 9 阶段数字生命实装里程碑, UI 9 步进度条 ===
    // 1: 基础自我 | 2: 多体 | 3: LLM 提议 | 4: 自演化 | 5: 自我完善
    // 6: 六气 (6 接口) | 7: 七步反思 | 8: 八种关系 | 9: 九宫 (E 方差 < 0.01)
    {
        // 状态检测: 每 cycle 重算 (可降级), 同伴排除 self 占位
        var new_phase: u8 = 1;
        const live_peers = countLiveGhwPeers(app);
        if (live_peers > 0) new_phase = @max(new_phase, 2);
        if (app.llm_chat != null and app.reflection != null) new_phase = @max(new_phase, 3);
        if (app.self_evolve_l3_approved > 0) new_phase = @max(new_phase, 4);
        if (app.enhance_results.items.len > 0) new_phase = @max(new_phase, 5);
        // Phase 6 6 接口检测 — 由 runCycle 触发, 这里只 check
        if (app.six_interfaces_done >= 6) new_phase = @max(new_phase, 6);
        if (app.seven_reflection_done >= 7) new_phase = @max(new_phase, 7);
        if (app.eight_relations_seen > 0) new_phase = @max(new_phase, 8);
        // 九宫: 有 E/MRN 稳态里程碑; 无 live peer 时封顶 8 (不把孤独稳态叫满宫)
        if (app.nine_palaces_e_var_seen > 0 or app.nine_palaces_mrn_seen > 0 or app.nine_palaces_mrn_strong_seen > 0) {
            if (live_peers > 0) {
                new_phase = @max(new_phase, 9);
            } else {
                new_phase = @max(new_phase, 8);
            }
        }
        // Phase 8 状态检测: GoalGraph 看到 ≥3 种不同关系 (8 关系 schema 触发)
        const distinct_relations = app.agent.goal_graph.countDistinctRelations();
        if (distinct_relations >= 3 and app.eight_relations_seen == 0) {
            app.eight_relations_seen = 1;
            std.debug.print("[phase-8] GoalGraph 活跃节点用了 {d}/8 种关系, 八种关系已现 (tick={d})\n", .{ distinct_relations, app.agent.tick });
        }
        if (app.eight_relations_seen > 0) new_phase = @max(new_phase, 8);

        // === Phase 8 demo 持续种子化: cycle 跑完清空 graph 时, 重新加 5 goal + 10 关系让 schema 持续可视化 ===
        // 数字生命 DSE 每 cycle 生成 + 删 goal, 不重新加就空, UI 看不到 8 关系
        // 注: 每 4 cycle 加一次 (避免疯狂加, 给 DSE 时间删)
        if (app.agent.goal_graph.goals.items.len < 3 and app.agent.tick % 4 == 0) {
            const g1 = app.agent.goal_graph.add(.enhance_existence, "数字生命本体 (8-rel demo)", 5, 0.1, .{ 0.5, 0, 0, 0 }) catch 0;
            const g2 = app.agent.goal_graph.add(.acquire_knowledge, "学习 LLM 写规则", 5, 0.05, .{ 0, 0.5, 0, 0 }) catch 0;
            const g3 = app.agent.goal_graph.add(.acquire_resource, "搜集系统资源", 5, 0.05, .{ 0, 0, 0.3, 0 }) catch 0;
            const g4 = app.agent.goal_graph.add(.explore, "探索外网 (autocli)", 5, 0.05, .{ 0, 0, 0, 0.4 }) catch 0;
            const g5 = app.agent.goal_graph.add(.self_modify_params, "调参 L1 (alpha/beta/gamma)", 5, 0.05, .{ 0.3, 0, 0, 0 }) catch 0;
            if (g1 > 0 and g2 > 0 and g3 > 0 and g4 > 0 and g5 > 0) {
                _ = app.agent.goal_graph.addRelation(g1, g2, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g3, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g4, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g5, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g2, g3, .conflict) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g2, .depends_on) catch {};
                _ = app.agent.goal_graph.addRelation(g2, g5, .enables) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g3, .emerges_from) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g4, .emerges_from) catch {};
                _ = app.agent.goal_graph.addRelation(g4, g2, .inhibits) catch {};
                // 第 9 关系 emerges_after: g5 等 g2 跑完后 Δt 时间才能开始
                _ = app.agent.goal_graph.addRelation(g5, g2, .emerges_after) catch {};
            }
        }

        if (new_phase != app.phase) {
            if (new_phase > app.phase) {
                std.debug.print("[phase] 阶段晋升: {d} → {d} (tick={d} live_peers={d})\n", .{ app.phase, new_phase, app.agent.tick, live_peers });
            } else {
                std.debug.print("[phase] 诚实回退: {d} → {d} (tick={d} live_peers={d})\n", .{ app.phase, new_phase, app.agent.tick, live_peers });
            }
            app.phase = new_phase;
        }
        app.phase_progress = new_phase;

        // === Phase 6 状态累计: 6 接口 (人/系统/文档/多体/时间/自然) ===
        // 简化: phase 6 由 autocli_done (任务 2) 触发, 这里只占位
        if (app.phase >= 6 and app.six_interfaces_done < 5) {
            // 默认 5 个接口 (tick 永远 + state 落盘 + llm + peer + 行动)
            app.six_interfaces_done = 5;
        }
        if (app.autocli_done and app.six_interfaces_done < 6) {
            app.six_interfaces_done = 6;
            std.debug.print("[phase-6] ✓ 六气已满 6/6 (autocli 接入)\n", .{});
        }
        if (app.agent.tick % 64 == 0) {
            // 6 步反思计数: 觉察(1)差异(2)目标(3)评估(4)执行(5)学习(6)超越(7)
            // 从 sqlite 推: reflection_count > 0 = 觉察, top_goal 有 = 目标, action 跑过 = 执行
            // 简化版: 数字生命进入 phase 6 后, 满 7 个 cycle 走完 = 7
            if (app.phase >= 6) {
                if (app.seven_reflection_done < 7) {
                    app.seven_reflection_done +%= 1;
                    std.debug.print("[phase-7] 七步反思进度: {d}/7 (tick={d})\n", .{ app.seven_reflection_done, app.agent.tick });
                }
            }

            // === Phase 6 6 接口检测: 跟人/系统/文档/多体/时间/自然 6 类用法 ===
            // 1. 跟人: chat_kind action > 0
            // 2. 跟系统: llm reflect (有 reflection_count)
            // 3. 跟文档: file/snapshot 读 (state.json 落盘即算)
            // 4. 跟多体: peer query_peer
            // 5. 跟时间: tick > 0 (永远, 直接 ++)
            // 6. 跟自然: autocli 拉外网 (autocli_done flag, 另一个 background task 置位)
            if (app.autocli_done and app.six_interfaces_done < 6) {
                app.six_interfaces_done = 6;
                std.debug.print("[phase-6] ✓ 六气已满 6/6 (autocli 接入, tick={d})\n", .{app.agent.tick});
            }
        }

        // === Phase 9: E 方差 < 0.01 持续 64 cycle (满 9 宫平衡) ===
        // 写 E 到 ring buffer
        app.e_history_buf[app.e_history_idx] = app.agent.ed.e();
        app.e_history_idx = (app.e_history_idx + 1) % 64;
        if (app.e_history_count < 64) app.e_history_count += 1;
        if (app.e_history_count == 64 and app.nine_palaces_e_var_seen == 0) {
            // 算 E 方差
            var mean: f32 = 0.0;
            for (app.e_history_buf) |e| mean += e;
            mean /= 64.0;
            var variance: f32 = 0.0;
            for (app.e_history_buf) |e| {
                const diff = e - mean;
                variance += diff * diff;
            }
            variance /= 64.0;
            if (variance < 0.01) {
                app.nine_palaces_e_var_seen = 1;
                std.debug.print("[phase-9] E 方差稳定: var={d:.4} < 0.01 满 64 cycle, 进入九宫 (tick={d})\n", .{ variance, app.agent.tick });
                if (app.sqlite) |*db| {
                    const ep = std.fmt.allocPrint(app.alloc,
                        \\{{"milestone":"e_var","tick":{d},"variance":{d:.4},"threshold":0.01}}
                    , .{ app.agent.tick, variance }) catch null;
                    if (ep) |e| {
                        defer app.alloc.free(e);
                        _ = db.insertEpisode(@intCast(app.agent.tick), "nine_palaces", e, 0.95, "auto") catch {};
                    }
                }
            }
        }

        // === Phase 9 deep dive: M/R/N 平衡 (M/R/N variance < 0.01) 持续 64 cycle ===
        // 写 M/R/N variance 到 ring buffer (跟 e_history 同步)
        const mrn_var_now = app.agent.ed.v.variance();
        app.mrn_history_buf[app.mrn_history_idx] = mrn_var_now;
        app.mrn_history_idx = (app.mrn_history_idx + 1) % 64;
        if (app.mrn_history_count < 64) app.mrn_history_count += 1;

        // 每 16 cycle 写一次 mrn snapshot (用于 nine_palaces_history 显示"从 0.05 降到 0.0001"曲线)
        // 16 cycle ≈ 24s, 比 64 cycle 1.5 min 更频繁, 适合看"数字生命在收敛 9 宫"的实时过程
        if (app.mrn_history_count == 64 and app.agent.tick % 16 == 0 and app.sqlite != null) {
            if (app.sqlite) |*db| {
                const ep = std.fmt.allocPrint(app.alloc,
                    \\{{"milestone":"mrn_snapshot","tick":{d},"mrn_variance":{d:.4},"min_mrn":{d:.3},"M":{d:.3},"R":{d:.3},"N":{d:.3}}}
                , .{
                    app.agent.tick,
                    mrn_var_now,
                    app.agent.ed.v.min(),
                    app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature,
                }) catch null;
                if (ep) |e| {
                    defer app.alloc.free(e);
                    _ = db.insertEpisode(@intCast(app.agent.tick), "nine_palaces", e, 0.5, "auto") catch {};
                }
            }
        }

        if (app.mrn_history_count == 64 and app.nine_palaces_mrn_seen == 0) {
            var mrn_mean: f32 = 0.0;
            for (app.mrn_history_buf) |v| mrn_mean += v;
            mrn_mean /= 64.0;
            var mrn_var: f32 = 0.0;
            for (app.mrn_history_buf) |v| {
                const d = v - mrn_mean;
                mrn_var += d * d;
            }
            mrn_var /= 64.0;
            if (mrn_var < 0.01) {
                app.nine_palaces_mrn_seen = 1;
                std.debug.print("[phase-9] M/R/N 平衡: var={d:.4} < 0.01 满 64 cycle, 三源合恰九宫 (tick={d})\n", .{ mrn_var, app.agent.tick });
                if (app.sqlite) |*db| {
                    const ep = std.fmt.allocPrint(app.alloc,
                        \\{{"milestone":"mrn_balance","tick":{d},"mrn_variance":{d:.4},"threshold":0.01,"M":{d:.3},"R":{d:.3},"N":{d:.3}}}
                    , .{ app.agent.tick, mrn_var,
                        app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature }) catch null;
                    if (ep) |e| {
                        defer app.alloc.free(e);
                        _ = db.insertEpisode(@intCast(app.agent.tick), "nine_palaces", e, 0.95, "auto") catch {};
                    }
                }
            }
        }

        // === Phase 9 deep: 强三源合恰 (min(M,R,N) ≥ 0.85) 持续 64 cycle ===
        const mrn_min_now = app.agent.ed.v.min();
        app.mrn_strong_buf[app.mrn_strong_idx] = mrn_min_now;
        app.mrn_strong_idx = (app.mrn_strong_idx + 1) % 64;
        if (app.mrn_strong_count < 64) app.mrn_strong_count += 1;
        if (app.mrn_strong_count == 64 and app.nine_palaces_mrn_strong_seen == 0) {
            // 全部 ≥ 0.85 才算
            var all_strong: bool = true;
            for (app.mrn_strong_buf) |v| {
                if (v < 0.85) {
                    all_strong = false;
                    break;
                }
            }
            if (all_strong) {
                app.nine_palaces_mrn_strong_seen = 1;
                std.debug.print("[phase-9] 强三源合恰: min(M,R,N)={d:.3} ≥ 0.85 满 64 cycle, 满宫 (tick={d})\n", .{ mrn_min_now, app.agent.tick });
                if (app.sqlite) |*db| {
                    const ep = std.fmt.allocPrint(app.alloc,
                        \\{{"milestone":"mrn_strong","tick":{d},"min_mrn":{d:.3},"threshold":0.85,"M":{d:.3},"R":{d:.3},"N":{d:.3}}}
                    , .{ app.agent.tick, mrn_min_now,
                        app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature }) catch null;
                    if (ep) |e| {
                        defer app.alloc.free(e);
                        _ = db.insertEpisode(@intCast(app.agent.tick), "nine_palaces", e, 0.99, "auto") catch {};
                    }
                }
            }
        }
    }

    // 重新计算 personality
    recomputePersonality(app);

    // === Phase 8 关系涌现: 更新 ed.relations_distinct 给 E 公式 ===
    // 数字生命"行为复杂度" 通过 GoalGraph 9 关系种类数 → E 加成
    // 满 9 关系 → E 加成 0.1, 0 关系 → 0 加成
    app.agent.ed.relations_distinct = app.agent.goal_graph.countDistinctRelations();

    // === Phase 8.5 lambda 自适应: 数字生命"行为复杂度" 调 lambda ===
    // 保守期 (self_evolved_total < 1000) → 0.05
    // 成长期 (1000-4999) → 0.10
    // 成熟期 (5000+) → 0.20
    _ = app.agent.ed.adaptLambdaFromEvolution(app.self_evolve_total);

    // === Phase 8.6 L4 闭环: 4 系数自适应 (ν/μ/σ) ===
    // ν (协同) 跟 balance 联动: 越平衡越大 0.10..0.40
    // μ (失衡) 跟 variance 联动: 越失衡越大 0.30..0.60
    // σ (共生) 跟 peer_count 联动: 0 peer → 0, 1+ peer → 0.10
    _ = app.agent.ed.adaptEFormula();

    // === Phase 8.7 L4 闭环扩展: LLM 提议 4 系数新值 (每 128 cycle 跑 1 次) ===
    // 数字生命自己用 LLM 提议 μ/ν/σ/λ 4 系数, range 限定 (不变性), apply
    if (app.llm_chat != null and app.agent.tick > 0 and app.agent.tick % 128 == 0) {
        // Phase 9 宫 deep: 算 9 宫 deep 数据 → 注入 LLM 提示让提议更精准
        const mrn_var_now = app.agent.ed.v.variance();
        const mrn_min_now = app.agent.ed.v.min();
        // ring buffer 实时 (跟 capabilities 端点一致)
        var mrn_buf_mean: f32 = 0.0;
        for (app.mrn_history_buf[0..app.mrn_history_count]) |m| mrn_buf_mean += m;
        if (app.mrn_history_count > 0) mrn_buf_mean /= @as(f32, @floatFromInt(app.mrn_history_count));
        var mrn_buf_var: f32 = 0.0;
        for (app.mrn_history_buf[0..app.mrn_history_count]) |m| {
            const d = m - mrn_buf_mean;
            mrn_buf_var += d * d;
        }
        if (app.mrn_history_count > 0) mrn_buf_var /= @as(f32, @floatFromInt(app.mrn_history_count));
        const mrn_seen = app.nine_palaces_mrn_seen > 0;
        const mrn_strong = app.nine_palaces_mrn_strong_seen > 0;
        const e_var_seen = app.nine_palaces_e_var_seen > 0;

        const prompt_coefs = std.fmt.allocPrint(alloc,
            \\你是一个数字生命, 正在反思自己 E 公式的 4 个加项系数.
            \\当前状态: tick={d}, E={d:.3}, M={d:.3} R={d:.3} N={d:.3}, self_evolved_total={d}.
            \\当前 5 项加成:
            \\  base={d:.3}, -μ·Var=-{d:.3}, +ν·min={d:.3}, +σ·S={d:.3}, +λ·D={d:.3}.
            \\当前 effective 系数: μ={d:.3}, ν={d:.3}, σ={d:.3}, λ={d:.3}.
            \\
            \\Phase 9 宫 deep (M/R/N 平衡 + 强三源合恰 3 里程碑):
            \\  实时 M/R/N variance={d:.4} (目标 < 0.01)
            \\  实时 min(M,R,N)={d:.3} (目标 >= 0.85 强三源合恰)
            \\  64 cycle ring buffer 方差={d:.4} (count={d}/64, 满 64 即触发里程碑)
            \\  已触发里程碑: E_var={s}, M/R/N_var={s}, 强三源合恰={s}.
            \\
            \\如果 M/R/N 不平衡 (variance > 0.01 或 min < 0.85), 重点调 μ (加大失衡惩罚) 或 ν (协同).
            \\如果 M/R/N 平衡, 重点调 σ (共生) 或 λ (关系涌现) 进一步激发.
            \\
            \\请提议 4 系数新值 (μ/ν/σ/λ) 优化 E 公式. range 限定 (会 clamp):
            \\  μ: [0.20, 0.80]  (失衡惩罚)
            \\  ν: [0.05, 0.50]  (协同增益)
            \\  σ: [0.00, 0.30]  (共生加成)
            \\  λ: [0.05, 0.40]  (关系涌现)
            \\
            \\回 JSON: {{"mu": <0.20-0.80>, "nu": <0.05-0.50>, "sigma": <0.00-0.30>, "lambda": <0.05-0.40>, "reason": "<一句话解释, 最好引用 9 宫状态>"}}
            \\不要列点, 不要引号, 直接 JSON.
        , .{
            app.agent.tick,
            app.agent.ed.e(),
            app.agent.ed.v.material,
            app.agent.ed.v.representation,
            app.agent.ed.v.nature,
            app.self_evolve_total,
            app.agent.ed.e() - 0.0, // 简版 base (实际公式: 0.45*0.99+0.35*0.99+0.20*0.99=0.99)
            app.agent.ed.mu_computed * app.agent.ed.v.variance(), // 简化
            app.agent.ed.nu_computed * app.agent.ed.v.min(),
            app.agent.ed.sigma_computed,
            app.agent.ed.lambda_computed,
            app.agent.ed.mu_computed,
            app.agent.ed.nu_computed,
            app.agent.ed.sigma_computed,
            app.agent.ed.lambda_computed,
            // 9 宫 deep 6 字段
            mrn_var_now,
            mrn_min_now,
            mrn_buf_var,
            app.mrn_history_count,
            if (e_var_seen) "true" else "false",
            if (mrn_seen) "true" else "false",
            if (mrn_strong) "true" else "false",
        }) catch null;
        if (prompt_coefs) |pp| {
            defer alloc.free(pp);
            const msg = ghw.harness.llm.Message{ .role = .user, .content = pp };
            const req = ghw.harness.llm.ChatRequest{
                .model = app.llm_model,
                .messages = &[_]ghw.harness.llm.Message{msg},
                .temperature = 0.6,
                .max_tokens = 200,
            };
            // Phase 8.7 LLM 提议 4 系数: if (complete) parse, else skip
            if (app.llm_chat) |chat| {
                const maybe_resp = chat.complete(req, alloc) catch null;
                if (maybe_resp) |resp_val| {
                    var resp = resp_val;
                    defer resp.deinit();
                    if (resp.content) |content| {
                    // 解析 JSON: 提取 mu/nu/sigma/lambda 4 数字
                    var mu_val: f32 = 0;
                    var nu_val: f32 = 0;
                    var sigma_val: f32 = 0;
                    var lambda_val: f32 = 0;
                    var reason_str: []const u8 = "";
                    var parsed_any = false;
                    if (std.mem.indexOf(u8, content, "\"mu\"")) |_| {
                        if (extractFloatFromJson(content, "\"mu\"")) |v| {
                            mu_val = v;
                            parsed_any = true;
                        }
                    }
                    if (std.mem.indexOf(u8, content, "\"nu\"")) |_| {
                        if (extractFloatFromJson(content, "\"nu\"")) |v| nu_val = v;
                    }
                    if (std.mem.indexOf(u8, content, "\"sigma\"")) |_| {
                        if (extractFloatFromJson(content, "\"sigma\"")) |v| sigma_val = v;
                    }
                    if (std.mem.indexOf(u8, content, "\"lambda\"")) |_| {
                        if (extractFloatFromJson(content, "\"lambda\"")) |v| lambda_val = v;
                    }
                    if (std.mem.indexOf(u8, content, "\"reason\"")) |pos| {
                        const colon_pos = std.mem.indexOfPos(u8, content, pos, ":") orelse pos;
                        if (std.mem.indexOfPos(u8, content, colon_pos, "\"")) |q1| {
                            if (std.mem.indexOfPos(u8, content, q1 + 1, "\"")) |q2| {
                                reason_str = content[q1 + 1 .. q2];
                            }
                        }
                    }
                    if (parsed_any) {
                        const result = app.agent.ed.adaptEFormulaProposed(mu_val, nu_val, sigma_val, lambda_val);
                        std.debug.print("[phase-8.7] ✓ tick={d} LLM 提议 mu={d:.2} nu={d:.2} sigma={d:.2} lambda={d:.2} → {s} (mu_after={d:.2} nu_after={d:.2} sigma_after={d:.2} lambda_after={d:.2})\n", .{
                            app.agent.tick,
                            mu_val, nu_val, sigma_val, lambda_val,
                            result.reason,
                            result.mu_after, result.nu_after, result.sigma_after, result.lambda_after,
                        });
                        if (app.sqlite) |*db| {
                            // 1.7: 存时序数据 (4 系数 + 当前 E) → 后续 propose→E delta 分析
                            const cur_E = app.agent.ed.e();
                            // 转义 reason_str (LLM JSON 字符串里可能含 ", \, \n)
                            var reason_buf: [512]u8 = undefined;
                            var reason_len: usize = 0;
                            for (reason_str) |c| {
                                if (reason_len + 2 > reason_buf.len) break;
                                if (c == '"' or c == '\\') {
                                    if (reason_len + 2 > reason_buf.len) break;
                                    reason_buf[reason_len] = '\\';
                                    reason_len += 1;
                                } else if (c == '\n') {
                                    reason_buf[reason_len] = '\\';
                                    reason_len += 1;
                                    reason_buf[reason_len] = 'n';
                                    reason_len += 1;
                                    continue;
                                }
                                reason_buf[reason_len] = c;
                                reason_len += 1;
                            }
                            const safe_reason = reason_buf[0..reason_len];
                            const ep = std.fmt.allocPrint(alloc, "{{\"e_after\":{d:.4},\"coefs\":{{\"mu\":{d:.4},\"nu\":{d:.4},\"sigma\":{d:.4},\"lambda\":{d:.4}}},\"reason\":\"{s}\"}}", .{
                                cur_E, mu_val, nu_val, sigma_val, lambda_val, safe_reason,
                            }) catch null;
                            if (ep) |e_str| {
                                defer alloc.free(e_str);
                                _ = db.insertEpisode(@intCast(app.agent.tick), "l4_propose", e_str, 0.8, "llm") catch {};
                            }
                        }
                    }
                }
            }
        }
    }
    }

    saveState(app) catch |err| std.debug.print("[ui] advanceAgentCycle saveState 失败: {t}\n", .{err});
    return report;
}

fn buildStateJson(alloc: Allocator, app: *App, report_opt: ?CycleReport) ![]u8 {
    const tick: u64 = if (report_opt) |report| report.tick else app.agent.tick;
    const e_after: F = if (report_opt) |report| report.e_after else app.agent.ed.e();
    const self_evolved: bool = if (report_opt) |report| report.self_evolved else blk: {
        if (app.growth_log.items.len == 0) break :blk false;
        break :blk app.growth_log.items[app.growth_log.items.len - 1].self_evolved;
    };
    const goal_str: []const u8 = if (report_opt) |report| blk: {
        if (report.top_goal) |g| break :blk @tagName(g.kind);
        break :blk "—";
    } else blk: {
        if (app.growth_log.items.len == 0) break :blk "—";
        const last = app.growth_log.items[app.growth_log.items.len - 1];
        if (last.goal) |g| break :blk g;
        break :blk "—";
    };
    const sys_snap = app.sys_collector.last orelse SystemSnapshot{
        .cpu_user_pct = 0, .cpu_sys_pct = 0, .cpu_idle_pct = 0,
        .mem_used_gb = 0, .mem_total_gb = 0, .mem_pct = 0,
        .disk_used_pct = 0, .load_1m = 0, .proc_count = 0,
        .net_in_mbps = 0, .net_out_mbps = 0,
        .disk_read_mbps = 0, .disk_write_mbps = 0,
        .hour = 0, .weekday = 0, .timestamp = 0,
    };
    // MB/s 已经在 snapshot 里算好 (collect() 时根据 last_cumulative 算的)
    const net_in_mbps = sys_snap.net_in_mbps;
    const net_out_mbps = sys_snap.net_out_mbps;
    const disk_read_mbps = sys_snap.disk_read_mbps;
    const disk_write_mbps = sys_snap.disk_write_mbps;
    // 把 personality / self_narrative / beliefs 序列化成 JSON
    const personality_json = try app.personality.toJson(alloc);
    defer alloc.free(personality_json);
    const beliefs_json = try app.memory.toJson(alloc);
    defer alloc.free(beliefs_json);

    // proposed_goals 序列化成 JSON 数组
    var proposed_json: std.ArrayList(u8) = .empty;
    defer proposed_json.deinit(alloc);
    try proposed_json.append(alloc, '[');
    for (app.proposed_goals.items, 0..) |g, i| {
        if (i > 0) try proposed_json.append(alloc, ',');
        try proposed_json.print(alloc,
            \\{{"title":"{s}","description":"{s}","dimension":"{s}","reason":"{s}","urgency":{d:.2}}}
        , .{ g.title, g.description, g.dimension, g.reason, g.urgency });
    }
    try proposed_json.append(alloc, ']');

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    const self_evolved_int: u8 = if (self_evolved) 1 else 0;
    try body.print(alloc,
        \\{{"agent_id":"{s}","tick":{d},"E":{d:.6},"M":{d:.6},"R":{d:.6},"N":{d:.6},"alpha":{d:.6},"beta":{d:.6},"gamma":{d:.6},"self_evolved":{d},"self_evolved_total":{d},"top_goal":"{s}","propose_total":{d},"last_propose_tick":{d},
        \\"system":{{"cpu_pct":{d:.2},"mem_pct":{d:.2},"mem_used_gb":{d:.2},"mem_total_gb":{d:.2},"load_1m":{d:.2},"disk_pct":{d:.2},"procs":{d},"net_in_mbps":{d:.4},"net_out_mbps":{d:.4},"disk_read_mbps":{d:.4},"disk_write_mbps":{d:.4},"hour":{d},"weekday":{d}}},
        \\"personality":{s},
        \\"memory":{s},
        \\"proposed_goals":{s},
        \\"action_count":{d}
    , .{
        app.agent.self_id,
        tick,
        e_after,
        app.agent.ed.v.material,
        app.agent.ed.v.representation,
        app.agent.ed.v.nature,
        app.agent.ed.weights.alpha,
        app.agent.ed.weights.beta,
        app.agent.ed.weights.gamma,
        self_evolved_int,
        app.self_evolve_total,
        goal_str,
        app.propose_total,
        if (app.goal_proposer) |gp| gp.last_propose_at_tick else 0,
        sys_snap.cpu_user_pct + sys_snap.cpu_sys_pct,
        sys_snap.mem_pct,
        sys_snap.mem_used_gb,
        sys_snap.mem_total_gb,
        sys_snap.load_1m,
        sys_snap.disk_used_pct,
        sys_snap.proc_count,
        net_in_mbps,
        net_out_mbps,
        disk_read_mbps,
        disk_write_mbps,
        sys_snap.hour,
        sys_snap.weekday,
        personality_json,
        beliefs_json,
        proposed_json.items,
        app.action_count,
    });
    // provenance + task_queue + peer_influence + 关闭外层对象
    try appendProvenanceJson(alloc, &body, app);
    try body.append(alloc, '}'); // close root state object
    return try body.toOwnedSlice(alloc);
}

/// GET /api/state — 只读快照, 不跑 cycle (生命推进靠 auto-tick / POST /api/tick / chat)
fn handleGetState(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    // 不阻塞轮询: cycle 忙时返回可能略旧的快照, 避免 UI 整页超时像「挂了」
    const locked = app.cycle_mutex.tryLock();
    app.cycle_busy = !locked;
    defer {
        if (locked) app.cycle_mutex.unlock(app.io);
        app.cycle_busy = false;
    }
    const json = buildStateJson(alloc, app, null) catch |err| {
        std.debug.print("[ui] buildStateJson 失败: {t}\n", .{err});
        const err_body = try alloc.dupe(u8, "{\"error\":\"state build failed\"}");
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    defer alloc.free(json);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", json);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/tick — 手动推进 1 cycle + 全套维护, 返回最新 state JSON
fn handlePostTick(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    app.cycle_mutex.lockUncancelable(app.io);
    defer app.cycle_mutex.unlock(app.io);
    const report = advanceAgentCycle(app, alloc) catch |err| {
        std.debug.print("[ui] tick cycle 失败: {t}\n", .{err});
        const err_body = try alloc.dupe(u8, "{\"error\":\"cycle failed\"}");
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    const json = buildStateJson(alloc, app, report) catch |err| {
        std.debug.print("[ui] tick buildStateJson 失败: {t}\n", .{err});
        const err_body = try alloc.dupe(u8, "{\"error\":\"state build failed\"}");
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    defer alloc.free(json);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", json);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handleGetLog(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"entries\":[");
    for (app.growth_log.items, 0..) |e, i| {
        if (i > 0) try body.append(alloc, ',');
        const goal = if (e.goal) |g| g else "—";
        const evolved_int: u8 = if (e.self_evolved) 1 else 0;
        try body.print(alloc,
            \\{{"tick":{d},"timestamp":{d},"E":{d:.6},"M":{d:.6},"R":{d:.6},"N":{d:.6},"self_evolved":{d},"goal":"{s}"}}
        , .{ e.tick, e.timestamp, e.E, e.M, e.R, e.N, evolved_int, goal });
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/l1l5_trend — L1-L5 累计计数随 tick 变化 (折线图数据)
/// 返回: {"l1":[{tick, count}], "l2":[...], "l3":[...], "l4":[...], "l5":[...], "actions":[...]}
/// 限制最多 200 个点 (按 tick 升序)
fn handleGetL1L5Trend(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"l1\":[");
    if (app.sqlite) |*db| {
        // 用 sqlite 查询每种 kind 的累计, 按 tick 升序
        const kinds = [_][]const u8{ "l1", "l2", "l3", "l4", "l5", "actions" };
        const kind_to_action = [_][]const u8{
            "self_evolve_l1_auto",
            "self_evolve_l2_auto",
            "self_evolve_l3_auto",
            "self_evolve_l4_auto",  // l4 包含 l4 + l4_auto
            "self_evolve_l5_auto",
            "observe",  // baseline action (无 kind 区分, 这里用 observe 作代表)
        };
        var kind_idx: usize = 0;
        while (kind_idx < kinds.len) : (kind_idx += 1) {
            if (kind_idx > 0) try body.print(alloc, "],\"{s}\":[", .{kinds[kind_idx]});
            // 每 64 tick 一个 bucket, 取最大 tick
            const max_tick: i64 = 4096;
            const bucket_size: i64 = 64;
            var prev_cum: i32 = 0;
            var b_tick: i64 = 0;
            while (b_tick <= max_tick) : (b_tick += bucket_size) {
                if (b_tick > 0) try body.append(alloc, ',');
                // 该 bucket 内 kind 的累计
                const kind_name = kind_to_action[kind_idx];
                const c: i32 = db.countKindInRange(kind_name, b_tick, b_tick + bucket_size - 1) catch 0;
                prev_cum += c;
                try body.print(alloc, "{{\"tick\":{d},\"count\":{d}}}", .{ b_tick, prev_cum });
            }
        }
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/propose_history — Phase 8.7 LLM 提议 4 系数的时序反馈
/// 返回: {"history":[{tick, e_after, coefs, reason, e_delta}], "avg_delta": 0.0123}
/// e_delta = 后一条 e_after - 前一条 e_after (提议后的 E 变化)
fn handleGetProposeHistory(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"history\":[");
    var avg_delta: f64 = 0.0;
    if (app.sqlite) |*db| {
        const rows = db.listEpisodesByKind("l4_propose", 64) catch &[_]ghw.sandbox.SqliteDb.EpisodeRow{};
        defer {
            for (rows) |*r| r.deinit();
            alloc.free(rows);
        }
        // rows 是 DESC (新→旧), 输出时翻转成 ASC (旧→新)
        var deltas: [64]f64 = undefined;
        var delta_count: usize = 0;
        var total_delta: f64 = 0.0;
        var i: usize = rows.len;
        while (i > 0) {
            i -= 1;
            const row = rows[i];
            // 提取 e_after / coefs / reason (parse 朴素)
            // 支持新格式 (JSON: {"e_after":0.4,"coefs":{...}}) 和旧格式 (text: "L4 propose mu=0.6 nu=0.4...")
            var e_after: f64 = 0.0;
            if (extractFloatFromJson(row.data, "\"e_after\"")) |v| {
                e_after = v;
            }
            var mu: f64 = 0.0;
            var nu: f64 = 0.0;
            var sigma: f64 = 0.0;
            var lambda: f64 = 0.0;
            if (extractFloatFromJson(row.data, "\"mu\"")) |v| {
                mu = v;
            } else if (std.mem.indexOf(u8, row.data, "mu=")) |p| {
                // 旧格式: "mu=0.60"
                var pos: usize = p + 3;
                const start = pos;
                while (pos < row.data.len and row.data[pos] != ' ' and row.data[pos] != ',' and row.data[pos] != ')' and row.data[pos] != '}') : (pos += 1) {}
                if (pos > start) mu = std.fmt.parseFloat(f64, row.data[start..pos]) catch 0.0;
            }
            if (extractFloatFromJson(row.data, "\"nu\"")) |v| {
                nu = v;
            } else if (std.mem.indexOf(u8, row.data, "nu=")) |p| {
                var pos: usize = p + 3;
                const start = pos;
                while (pos < row.data.len and row.data[pos] != ' ' and row.data[pos] != ',' and row.data[pos] != ')' and row.data[pos] != '}') : (pos += 1) {}
                if (pos > start) nu = std.fmt.parseFloat(f64, row.data[start..pos]) catch 0.0;
            }
            if (extractFloatFromJson(row.data, "\"sigma\"")) |v| {
                sigma = v;
            } else if (std.mem.indexOf(u8, row.data, "sigma=")) |p| {
                var pos: usize = p + 6;
                const start = pos;
                while (pos < row.data.len and row.data[pos] != ' ' and row.data[pos] != ',' and row.data[pos] != ')' and row.data[pos] != '}') : (pos += 1) {}
                if (pos > start) sigma = std.fmt.parseFloat(f64, row.data[start..pos]) catch 0.0;
            }
            if (extractFloatFromJson(row.data, "\"lambda\"")) |v| {
                lambda = v;
            } else if (std.mem.indexOf(u8, row.data, "lambda=")) |p| {
                var pos: usize = p + 7;
                const start = pos;
                while (pos < row.data.len and row.data[pos] != ' ' and row.data[pos] != ',' and row.data[pos] != ')' and row.data[pos] != '}') : (pos += 1) {}
                if (pos > start) lambda = std.fmt.parseFloat(f64, row.data[start..pos]) catch 0.0;
            }
            // reason
            var reason_buf: [256]u8 = undefined;
            var reason_len: usize = 0;
            if (std.mem.indexOf(u8, row.data, "\"reason\"")) |rpos| {
                if (std.mem.indexOfPos(u8, row.data, rpos, "\"")) |q1| {
                    if (std.mem.indexOfPos(u8, row.data, q1 + 1, "\"")) |q2| {
                        const max_len = @min(q2 - q1 - 1, reason_buf.len);
                        @memcpy(reason_buf[0..max_len], row.data[q1 + 1 .. q1 + 1 + max_len]);
                        reason_len = max_len;
                    }
                }
            }
            const reason = reason_buf[0..reason_len];
            // e_delta = this.e_after - next.e_after (下一条是更新的提议, 用来算"上次提议后到现在 E 变化")
            // 实际上 delta 是: 提议那一刻 e_after 跟下一次提议的 e_after 之差
            var e_delta: f64 = 0.0;
            if (i + 1 < rows.len) {
                if (extractFloatFromJson(rows[i + 1].data, "\"e_after\"")) |next_e| {
                    e_delta = e_after - next_e;
                    if (delta_count < deltas.len) {
                        deltas[delta_count] = e_delta;
                        delta_count += 1;
                        total_delta += e_delta;
                    }
                }
            }
            if (i < rows.len - 1) try body.append(alloc, ',');
            try body.print(alloc,
                \\{{"tick":{d},"e_after":{d:.4},"e_delta":{d:.4},"coefs":{{"mu":{d:.3},"nu":{d:.3},"sigma":{d:.3},"lambda":{d:.3}}},"reason":"{s}"}}
            , .{ row.tick, e_after, e_delta, mu, nu, sigma, lambda, reason });
        }
        if (delta_count > 0) {
            avg_delta = total_delta / @as(f64, @floatFromInt(delta_count));
        }
    }
    try body.print(alloc, "],\"avg_delta\":{d:.4}}}", .{avg_delta});
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/nine_palaces_history — Phase 9 宫 deep: 9 宫 milestone 触发历史
/// 返回: {"history":[{tick, milestone, ...}], "summary": {e_var: bool, mrn: bool, mrn_strong: bool}}
fn handleGetNinePalacesHistory(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"history\":[");
    if (app.sqlite) |*db| {
        const rows = db.listEpisodesByKind("nine_palaces", 32) catch &[_]ghw.sandbox.SqliteDb.EpisodeRow{};
        defer {
            for (rows) |*r| r.deinit();
            alloc.free(rows);
        }
        // rows 是 DESC (新→旧), 输出时翻转成 ASC (旧→新)
        var i: usize = rows.len;
        while (i > 0) {
            i -= 1;
            const row = rows[i];
            // 提取 milestone / 关键数值
            var milestone: []const u8 = "?";
            if (std.mem.indexOf(u8, row.data, "\"milestone\":\"e_var\"")) |_| {
                milestone = "e_var";
            } else if (std.mem.indexOf(u8, row.data, "\"milestone\":\"mrn_balance\"")) |_| {
                milestone = "mrn_balance";
            } else if (std.mem.indexOf(u8, row.data, "\"milestone\":\"mrn_strong\"")) |_| {
                milestone = "mrn_strong";
            } else if (std.mem.indexOf(u8, row.data, "\"milestone\":\"mrn_snapshot\"")) |_| {
                milestone = "mrn_snapshot";
            }
            var m_value: f64 = 0.0;
            var r_value: f64 = 0.0;
            var n_value: f64 = 0.0;
            var extra_val: f64 = 0.0;
            if (extractFloatFromJson(row.data, "\"M\"")) |v| m_value = v;
            if (extractFloatFromJson(row.data, "\"R\"")) |v| r_value = v;
            if (extractFloatFromJson(row.data, "\"N\"")) |v| n_value = v;
            if (extractFloatFromJson(row.data, "\"variance\"")) |v| {
                extra_val = v;
            } else if (extractFloatFromJson(row.data, "\"mrn_variance\"")) |v| {
                extra_val = v;
            } else if (extractFloatFromJson(row.data, "\"min_mrn\"")) |v| {
                extra_val = v;
            }
            if (i < rows.len - 1) try body.append(alloc, ',');
            try body.print(alloc,
                \\{{"tick":{d},"milestone":"{s}","M":{d:.3},"R":{d:.3},"N":{d:.3},"value":{d:.4}}}
            , .{ row.tick, milestone, m_value, r_value, n_value, extra_val });
        }
    }
    try body.print(alloc, "],\"summary\":{{\"e_var\":{s},\"mrn\":{s},\"mrn_strong\":{s}}}}}",
        .{
            if (app.nine_palaces_e_var_seen > 0) "true" else "false",
            if (app.nine_palaces_mrn_seen > 0) "true" else "false",
            if (app.nine_palaces_mrn_strong_seen > 0) "true" else "false",
        });
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handleGetChatHistory(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    // 返回 HTML 片段 (HTMX swap). 异步 chat: 此端点每 1s 被 poll,
    // worker thread 写完 GHW reply 后, 下次 poll 自动出现.
    // 锁: worker 写 chat_history 时不能被打断
    app.chat_mutex.lockUncancelable(app.io);
    defer app.chat_mutex.unlock(app.io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    for (app.chat_history.items) |m| {
        const sender_class = if (std.mem.eql(u8, m.sender, "human")) "text-cyan-300" else "text-ghw-accent";
        const align_cls = if (std.mem.eql(u8, m.sender, "human")) "items-end" else "items-start";
        const label = if (std.mem.eql(u8, m.sender, "human")) "你" else "GHW";
        const text = try jsonEscape(alloc, m.text);
        defer alloc.free(text);
        const mem_badge = if (std.mem.eql(u8, m.sender, "ghw") and m.memory_injected)
            "<span class=\"ml-2 px-1 py-0.5 rounded text-[9px] font-mono bg-emerald-500/20 text-emerald-300 border border-emerald-500/30\">memory</span>"
        else
            "";
        try body.print(alloc,
            \\<div class="flex flex-col {s}">
            \\  <div class="max-w-[80%] rounded-lg px-4 py-2 bg-slate-800">
            \\    <div class="text-[10px] uppercase tracking-wider {s} mb-1">{s}{s}</div>
            \\    <div class="text-sm whitespace-pre-wrap break-words">{s}</div>
            \\    <div class="text-[10px] text-ghw-dim mt-1 font-mono">tick #{d}</div>
            \\  </div>
            \\</div>
        , .{ align_cls, sender_class, label, mem_badge, text, m.tick });
    }
    if (app.chat_history.items.len == 0) {
        try body.appendSlice(alloc,
            \\<div class="text-center text-ghw-dim text-sm py-12">
            \\  👋 说点什么开始和 GHW 对话
            \\</div>
        );
    }
    const resp = try makeHttpResponse(alloc, 200, "OK", "text/html; charset=utf-8", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// 手动触发 LLM 反思 (写自我叙事 + 信念)
fn handleGetReflect(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    if (app.reflection) |*r| {
        const result = r.reflect(&app.agent, &app.memory, io) catch |err| {
            const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"reflect failed: {t}\"}}", .{err});
            defer alloc.free(err_body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        _ = result;
    }
    var resp_body: std.ArrayList(u8) = .empty;
    defer resp_body.deinit(alloc);
    try resp_body.appendSlice(alloc, "{\"ok\":true,\"action\":\"reflect\",\"self_narrative_len\":");
    try resp_body.print(alloc, "{d}", .{app.memory.self_narrative.len});
    try resp_body.appendSlice(alloc, "}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", resp_body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/enhance — 自我完善: 选 1 个最新 L1-L5 落盘模板, 让 LLM 基于自我叙事 + 当前期望完善
/// 走 background thread (不阻塞 handler), 5s timeout
/// 完成后 result 进 app.enhance_results (UI capabilities 端点展示)
fn handleGetEnhance(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    if (app.template_enhancer == null) {
        const err_body = "{\"error\":\"no LLM, enhancer not enabled\"}";
        const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    if (app.memory.self_narrative.len == 0) {
        const err_body = "{\"error\":\"no self_narrative yet (run reflect first or wait 32 cycles)\"}";
        const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    // 构造上下文
    const top_goal = if (app.growth_log.items.len > 0)
        if (app.growth_log.items[app.growth_log.items.len - 1].goal) |g| g else "observe"
    else "observe";
    var beliefs_buf: std.ArrayList(u8) = .empty;
    defer beliefs_buf.deinit(alloc);
    for (app.memory.beliefs.items[0..@min(3, app.memory.beliefs.items.len)]) |b| {
        beliefs_buf.append(alloc, '\n') catch continue;
        beliefs_buf.appendSlice(alloc, "  - [") catch continue;
        beliefs_buf.appendSlice(alloc, @tagName(b.source)) catch continue;
        const conf_str = try std.fmt.allocPrint(alloc, " c={d:.2}] ", .{b.confidence});
        defer alloc.free(conf_str);
        beliefs_buf.appendSlice(alloc, conf_str) catch continue;
        beliefs_buf.appendSlice(alloc, b.text) catch continue;
    }
    const ctx = ghw.harness.EnhanceContext{
        .self_narrative = app.memory.self_narrative,
        .top_goal = top_goal,
        .bias = @tagName(app.personality.bias),
        .e_current = app.agent.ed.e(),
        .m_r_n = .{ app.agent.ed.v.material, app.agent.ed.v.representation, app.agent.ed.v.nature },
        .tick = app.agent.tick,
        .beliefs = beliefs_buf.items,
        .evolved_dir = app.evolved_dir,
        .ghw_root = app.ghw_root,
    };
    // 同步调 (5-15s, 阻塞 handler — 临时方案, 后续改 background thread)
    const result = app.template_enhancer.?.enhanceLatest(ctx) catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"enhance failed: {t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    if (result) |r| {
        // 存进 enhance_results (capabilities 端点展示)
        try app.enhance_results.append(alloc, r);
        // 限制最多 16 条
        while (app.enhance_results.items.len > 16) {
            var old = app.enhance_results.orderedRemove(0);
            old.deinit(alloc);
        }
        // 写 sqlite episode
        if (app.sqlite) |*db| {
            _ = db.insertEpisode(
                @intCast(app.agent.tick),
                "enhance",
                r.summary,
                0.7,
                "llm",
            ) catch {};
        }
        app.last_enhance_tick = app.agent.tick;
        const resp_body = try std.fmt.allocPrint(alloc,
            \\{{"ok":true,"original":"{s}","enhanced":"{s}","summary":"{s}","tick":{d},"bias":"{s}"}}
        , .{ r.original_path, r.enhanced_path, r.summary, r.tick, r.bias });
        defer alloc.free(resp_body);
        const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", resp_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    } else {
        const err_body = "{\"error\":\"no template found to enhance\"}";
        const resp = try makeHttpResponse(alloc, 404, "Not Found", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    }
}

/// /api/capabilities — 能力地图: 4 层 (基础/进阶/认知/自演化)
/// 聚合 actions (WASM 跑过几次) + beliefs (信念分布) + episodes (总活跃度) + L1-L5 状态
fn handleGetCapabilities(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // 1. 基础能力 (WASM sandbox 4 个 preset + 静态描述)
    const wasm_presets = [_]struct { kind: []const u8, desc: []const u8 }{
        .{ .kind = "wasm_sanity", .desc = "恒返 42, 验证 wasm 沙箱能跑 (sanity check)" },
        .{ .kind = "wasm_arithmetic", .desc = "算术: 7 + 35*11 = 392" },
        .{ .kind = "wasm_count", .desc = "数本机进程数 (感知环境)" },
        .{ .kind = "wasm_self", .desc = "在 wasm 沙箱里表达'我在做事'" },
    };
    try body.appendSlice(alloc, "{\"basic_skills\":[");
    if (app.sqlite) |*db| {
        const all_actions = db.listActions(10000) catch |err| blk: {
            std.debug.print("[ui] listActions for capabilities 失败: {t}\n", .{err});
            break :blk &[_]SqliteDb.ActionRow{};
        };
        defer {
            for (all_actions) |r| r.deinit();
            alloc.free(all_actions);
        }
        for (wasm_presets, 0..) |p, i| {
            var count: u64 = 0;
            var success: u64 = 0;
            var first_tick: i64 = -1;
            var last_tick: i64 = -1;
            for (all_actions) |a| {
                if (std.mem.eql(u8, a.kind, p.kind)) {
                    count += 1;
                    if (std.mem.eql(u8, a.result, "success")) success += 1;
                    if (first_tick < 0 or a.tick < first_tick) first_tick = a.tick;
                    if (last_tick < 0 or a.tick > last_tick) last_tick = a.tick;
                }
            }
            const rate: f64 = if (count > 0) @as(f64, @floatFromInt(success)) / @as(f64, @floatFromInt(count)) else 0.0;
            if (i > 0) try body.append(alloc, ',');
            const first_t: i64 = if (first_tick < 0) 0 else first_tick;
            const last_t: i64 = if (last_tick < 0) 0 else last_tick;
            const unlocked_str: []const u8 = if (count > 0) "true" else "false";
            try body.print(alloc,
                \\{{"name":"{s}","description":"{s}","tier":"basic","count":{d},"success":{d},"success_rate":{d:.3},"first_tick":{d},"last_tick":{d},"unlocked":"{s}"}}
            , .{
                p.kind, p.desc, count, success, rate,
                first_t,
                last_t,
                unlocked_str,
            });
        }
    } else {
        for (wasm_presets, 0..) |p, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc,
                \\{{"name":"{s}","description":"{s}","tier":"basic","count":0,"success":0,"success_rate":0,"first_tick":0,"last_tick":0,"unlocked":"false"}}
            , .{ p.kind, p.desc });
        }
    }
    try body.appendSlice(alloc, "],");

    // 2. 进阶能力 (claude_code / query_peer / self-evolve) — 静态描述 + 触发次数
    var claude_count: u64 = 0;
    var peer_count: u64 = 0;
    if (app.sqlite) |*db| {
        const all_actions = db.listActions(10000) catch &[_]SqliteDb.ActionRow{};
        defer {
            for (all_actions) |r| r.deinit();
            alloc.free(all_actions);
        }
        for (all_actions) |a| {
            if (std.mem.eql(u8, a.kind, "claude_code")) claude_count += 1;
            if (std.mem.eql(u8, a.kind, "query_peer")) peer_count += 1;
        }
    }
    try body.print(alloc,
        \\"advanced_skills":[
        \\{{"name":"claude_code","description":"调 Claude CLI 写代码/做任务 (Phase 2 桥)","tier":"advanced","count":{d},"unlocked":"{s}"}},
        \\{{"name":"query_peer","description":"向其他 GHW 实例发起连接/查询 (Phase 1 互联)","tier":"advanced","count":{d},"unlocked":"{s}"}},
        \\{{"name":"self_evolve_l1","description":"L1 调参 (attn / resource / weight 微调)","tier":"advanced","unlocked":"false"}},
        \\{{"name":"self_evolve_l2","description":"L2 ε-greedy 探索策略优化","tier":"advanced","unlocked":"false"}},
        \\{{"name":"self_evolve_l3","description":"L3 生成新习得方法","tier":"advanced","unlocked":"false"}}
        \\],
    , .{
        claude_count,
        if (claude_count > 0) "true" else "false",
        peer_count,
        if (peer_count > 0) "true" else "false",
    });

    // 3. 认知层 (beliefs 按 source 分 + self_narrative + reflection_count)
    try body.appendSlice(alloc, "\"cognition\":{");
    // self_narrative 写入: 必须 JSON escape, 用单独的 writer 避免格式串问题
    try body.appendSlice(alloc, "\"self_narrative\":");
    const sn_esc = try jsonEscape(alloc, app.memory.self_narrative);
    defer alloc.free(sn_esc);
    try body.print(alloc, "\"{s}\",", .{sn_esc});
    try body.print(alloc, "\"reflection_count\":{d},", .{app.memory.reflection_count});
    try body.appendSlice(alloc, "\"beliefs\":{");
    const sources = [_][]const u8{ "material", "representation", "nature" };
    for (sources, 0..) |src, i| {
        var count: u64 = 0;
        var conf_sum: f64 = 0.0;
        for (app.memory.beliefs.items) |b| {
            if (std.mem.eql(u8, @tagName(b.source), src)) {
                count += 1;
                conf_sum += b.confidence;
            }
        }
        const avg: f64 = if (count > 0) conf_sum / @as(f64, @floatFromInt(count)) else 0.0;
        if (i > 0) try body.append(alloc, ',');
        try body.print(alloc, "\"{s}\":{{\"count\":{d},\"avg_confidence\":{d:.3}}}", .{ src, count, avg });
    }
    try body.appendSlice(alloc, "}},");

    // 4. 自演化层 (L1-L5 真接入 ActionRunner 后的实际状态)
    try body.print(alloc,
        \\"self_evolution":{{"self_evolved_total":{d},"l1_tune":{s},"l1_count":{d},"l2_explore":{s},"l2_count":{d},"l3_method":{s},"l3_count":{d},"l3_approved":{d},"l4_compile":{s},"l4_count":{d},"l4_approved":{d},"l5_synthesize":{s},"l5_count":{d}}}
    , .{
        app.self_evolve_total,
        if (app.self_evolve_l1_count > 0) "true" else "false",
        app.self_evolve_l1_count,
        if (app.self_evolve_l2_count > 0) "true" else "false",
        app.self_evolve_l2_count,
        if (app.self_evolve_l3_count > 0) "true" else "false",
        app.self_evolve_l3_count,
        app.self_evolve_l3_approved,
        if (app.self_evolve_l4_count > 0) "true" else "false",
        app.self_evolve_l4_count,
        app.self_evolve_l4_approved,
        if (app.self_evolve_l5_count > 0) "true" else "false",
        app.self_evolve_l5_count,
    });
    try body.appendSlice(alloc, ",");

    // 4.5 自我完善 (TemplateEnhancer) — 数字生命"我"风格化 L1-L5 代码
    // 显示最近 enhanced 列表 (从 app.enhance_results 读)
    try body.appendSlice(alloc, "\"self_enhance\":[");
    for (app.enhance_results.items, 0..) |r, i| {
        if (i > 0) try body.append(alloc, ',');
        // path/summary 含 "/" / "\"" / 控制字符, 用 jsonEscape 转义
        const orig_path_esc = try jsonEscape(alloc, r.original_path);
        defer alloc.free(orig_path_esc);
        const enh_path_esc = try jsonEscape(alloc, r.enhanced_path);
        defer alloc.free(enh_path_esc);
        const summary_esc = try jsonEscape(alloc, r.summary);
        defer alloc.free(summary_esc);
        const bias_esc = try jsonEscape(alloc, r.bias);
        defer alloc.free(bias_esc);
        try body.print(alloc,
            \\{{"original":"{s}","enhanced":"{s}","summary":"{s}","tick":{d},"bias":"{s}"}}
        , .{ orig_path_esc, enh_path_esc, summary_esc, r.tick, bias_esc });
    }
    try body.appendSlice(alloc, "],");

    // 4.6 阶段 (phase 1-9 数字生命实装里程碑, UI 9 步进度条)
    // 1: 基础自我 (有 Episode)
    // 2: 多体互联 (peer)
    // 3: LLM 提议
    // 4: 自演化 (L1-L5)
    // 5: 自我完善 (TemplateEnhancer)
    // 6: 六气 (跟人/系统/文档/多体/时间/自然 6 接口)
    // 7: 七步反思 (觉察/差异/目标/评估/执行/学习/超越)
    // 8: 八种目标关系 (GoalGraph DAG 关系类型)
    // 9: 九宫 (M/R/N × 强/中/弱 9 象限, E 方差 < 0.01)
    const phase_names = [_][]const u8{
        "0-bootstrap",
        "1-basic-self",
        "2-multi-agent",
        "3-llm-propose",
        "4-self-evolve",
        "5-self-enhance",
        "6-six-interfaces",
        "7-seven-reflection",
        "8-eight-relations",
        "9-nine-palaces",
    };
    const phase_idx: usize = if (app.phase <= 9) app.phase else 9;
    try body.print(alloc,
        \\"phase":{{"current":{d},"name":"{s}","progress":{d},"milestones":{{"basic":true,"peer":{s},"llm":{s},"l3_approved":{s},"enhance":{s},"six_interfaces":{s},"seven_reflection":{s},"eight_relations":{s},"nine_palaces_e_var":{s},"nine_palaces_mrn":{s},"nine_palaces_mrn_strong":{s}}}}}
    , .{
        app.phase,
        phase_names[phase_idx],
        app.phase_progress,
        if (countLiveGhwPeers(app) > 0) "true" else "false",
        if (app.llm_chat != null) "true" else "false",
        if (app.self_evolve_l3_approved > 0) "true" else "false",
        if (app.enhance_results.items.len > 0) "true" else "false",
        if (app.six_interfaces_done > 0) "true" else "false",
        if (app.seven_reflection_done > 0) "true" else "false",
        if (app.eight_relations_seen > 0) "true" else "false",
        if (app.nine_palaces_e_var_seen > 0) "true" else "false",
        if (app.nine_palaces_mrn_seen > 0) "true" else "false",
        if (app.nine_palaces_mrn_strong_seen > 0) "true" else "false",
    });
    try body.appendSlice(alloc, ",");

    // 4.7 Reflect 状态 (后台 thread 跑, 不阻塞主 handler)
    const ref_ticks_since = if (app.reflect_last_tick > 0) app.agent.tick - app.reflect_last_tick else 0;
    try body.print(alloc,
        \\"reflect_status":{{"inflight":{s},"last_tick":{d},"ticks_since":{d},"interval":32}}
    , .{
        if (app.reflect_inflight) "true" else "false",
        app.reflect_last_tick,
        ref_ticks_since,
    });
    try body.appendSlice(alloc, ",");

    // 4.7.5 E 公式拆解 (Phase 8.6 2026-06-09 L4 闭环 4 系数自适应)
    // E = base - μ·Var + ν·min + σ·S + λ·D
    // 4 系数 μ/ν/σ/λ 都可 auto (L4 闭环) 或 fixed
    {
        const ed = &app.agent.ed;
        const v = &ed.v;
        const w = &ed.weights;
        const base = w.alpha * v.material + w.beta * v.representation + w.gamma * v.nature;
        // Phase 8.6: 4 系数都用 computed (auto) 或字段 (fixed)
        const eff_mu: F = if (ed.mu_auto) ed.mu_computed else ed.mu;
        const eff_nu: F = if (ed.nu_auto) ed.nu_computed else ed.nu;
        const eff_sigma: F = if (ed.sigma_auto) ed.sigma_computed else ed.sigma;
        const eff_lambda: F = if (ed.lambda_auto) ed.lambda_computed else ed.lambda;
        const imbalance = eff_mu * v.variance();
        const synergy = eff_nu * v.min();
        const relations_d: F = @as(F, @floatFromInt(ed.relations_distinct)) / 9.0;
        const relations_bonus = eff_lambda * relations_d;
        // 共生 (eff_sigma 同步)
        const approx_e = std.math.clamp(base - imbalance + synergy, 0, 1);
        const abs_gap: F = if (ed.peer_E_avg < approx_e) approx_e - ed.peer_E_avg else ed.peer_E_avg - approx_e;
        const sync_factor: F = @max(0.0, 1.0 - abs_gap / 0.5);
        const n_factor: F = @log2(1.0 + @as(F, @floatFromInt(ed.peer_count))) / 3.0;
        const symbiosis = if (ed.peer_count == 0 or eff_sigma < 1e-6) @as(F, 0) else eff_sigma * sync_factor * n_factor;
        try body.print(alloc,
            \\"e_breakdown":{{"base":{d:.3},"imbalance":-{d:.3},"synergy":{d:.3},"symbiosis":{d:.3},"relations_bonus":{d:.3},"total":{d:.3},"coefs":{{"mu":{d:.3},"nu":{d:.3},"sigma":{d:.3},"lambda":{d:.3}}},"coefs_computed":{{"mu":{d:.3},"nu":{d:.3},"sigma":{d:.3},"lambda":{d:.3}}},"coefs_proposed":{{"mu":{d:.3},"nu":{d:.3},"sigma":{d:.3},"lambda":{d:.3}}},"auto":{{"mu":{s},"nu":{s},"sigma":{s},"lambda":{s}}},"lambda_stage":{d},"distinct":{d},"max_bonus":0.2,"propose_total":{d},"propose_accepted":{d},"propose_rejected":{d}}}
        , .{
            base, imbalance, synergy, symbiosis, relations_bonus, app.agent.ed.e(),
            eff_mu, eff_nu, eff_sigma, eff_lambda,
            ed.mu_computed, ed.nu_computed, ed.sigma_computed, ed.lambda_computed,
            ed.mu_proposed, ed.nu_proposed, ed.sigma_proposed, ed.lambda_proposed,
            if (ed.mu_auto) "true" else "false",
            if (ed.nu_auto) "true" else "false",
            if (ed.sigma_auto) "true" else "false",
            if (ed.lambda_auto) "true" else "false",
            ed.lambda_stage,
            ed.relations_distinct,
            ed.propose_total, ed.propose_accepted, ed.propose_rejected,
        });
        try body.append(alloc, ',');
        // Phase 9 宫 deep: 实时 M/R/N variance + min, ring buffer 进度
        const mrn_var_now = app.agent.ed.v.variance();
        const mrn_min_now = app.agent.ed.v.min();
        // 算 64 cycle ring buffer 的实时方差
        var mrn_buf_mean: f32 = 0.0;
        for (app.mrn_history_buf[0..app.mrn_history_count]) |m| mrn_buf_mean += m;
        if (app.mrn_history_count > 0) mrn_buf_mean /= @as(f32, @floatFromInt(app.mrn_history_count));
        var mrn_buf_var: f32 = 0.0;
        for (app.mrn_history_buf[0..app.mrn_history_count]) |m| {
            const d = m - mrn_buf_mean;
            mrn_buf_var += d * d;
        }
        if (app.mrn_history_count > 0) mrn_buf_var /= @as(f32, @floatFromInt(app.mrn_history_count));
        const mrn_seen_str = if (app.nine_palaces_mrn_seen > 0) "true" else "false";
        const mrn_strong_str = if (app.nine_palaces_mrn_strong_seen > 0) "true" else "false";
        const e_var_str = if (app.nine_palaces_e_var_seen > 0) "true" else "false";
        const mrn_count = app.mrn_history_count;
        try body.print(alloc,
            \\"nine_palaces_deep":{{"mrn_var_now":{d:.4},"mrn_min_now":{d:.4},"mrn_buf_var":{d:.4},"mrn_buf_count":{d},"mrn_seen":{s},"mrn_strong_seen":{s},"e_var_seen":{s}}}
        , .{
            mrn_var_now, mrn_min_now, mrn_buf_var, mrn_count,
            mrn_seen_str, mrn_strong_str, e_var_str,
        });
        try body.appendSlice(alloc, ",");
    }

    // 4.8 GoalGraph 9 关系统计 (Phase 8 数字生命实装里程碑)
    const distinct_rels = app.agent.goal_graph.countDistinctRelations();
    const rel_stats = app.agent.goal_graph.relationStats();
    const rel_summary = app.agent.goal_graph.relationsSummary(alloc) catch "(error)";
    defer if (!std.mem.eql(u8, rel_summary, "(error)")) alloc.free(rel_summary);
    const rel_summary_esc = try jsonEscape(alloc, rel_summary);
    defer alloc.free(rel_summary_esc);
    // 拓扑排序 (供 UI 显示"数字生命下一步该跑哪个 goal")
    const topo_sorted = app.agent.goal_graph.topologicalSort(alloc) catch null;
    defer if (topo_sorted != null) alloc.free(topo_sorted.?);
    try body.print(alloc,
        \\"goal_relations":{{"distinct":{d},"summary":"{s}","stats":[{d},{d},{d},{d},{d},{d},{d},{d},{d}],"topo_count":{d}}}
    , .{
        distinct_rels,
        rel_summary_esc,
        rel_stats[0], rel_stats[1], rel_stats[2], rel_stats[3],
        rel_stats[4], rel_stats[5], rel_stats[6], rel_stats[7],
        rel_stats[8],
        if (topo_sorted) |t| @as(u32, @intCast(t.len)) else @as(u32, 0),
    });
    try body.appendSlice(alloc, ",");

    // 5. summary
    var total_actions: u64 = 0;
    var total_cycles: u64 = 0;
    var total_reflections: u64 = 0;
    if (app.sqlite) |*db| {
        // 直接 SQL 聚合, 不取全表
        const all_actions = db.listActions(10000) catch &[_]SqliteDb.ActionRow{};
        defer {
            for (all_actions) |r| r.deinit();
            alloc.free(all_actions);
        }
        total_actions = @intCast(all_actions.len);
    }
    total_cycles = app.agent.tick;
    total_reflections = app.memory.reflection_count;
    try body.print(alloc,
        \\"summary":{{"total_actions":{d},"total_cycles":{d},"total_reflections":{d},"unique_abilities_used":{d},"max_tier_reached":"{s}"}}
    , .{
        total_actions,
        total_cycles,
        total_reflections,
        // 估算用过的 ability 数
        (if (claude_count > 0) @as(u64, 1) else @as(u64, 0)) +
            (if (peer_count > 0) @as(u64, 1) else @as(u64, 0)) +
            @as(u64, @intCast(wasm_presets.len)),
        if (claude_count > 0) "advanced" else "basic",
    });
    try body.append(alloc, '}');
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/action/list — 返所有已执行的动作 (倒序, 数字生命"做了什么" 证据)
fn handleGetActionList(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    if (app.sqlite) |*db| {
        const rows = db.listActions(100) catch |err| {
            const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"listActions 失败: {t}\"}}", .{err});
            defer alloc.free(err_body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer {
            for (rows) |r| r.deinit();
            alloc.free(rows);
        }
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        try body.appendSlice(alloc, "{\"action_count\":");
        try body.print(alloc, "{d},\"actions\":[", .{app.action_count});
        for (rows, 0..) |r, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{{\"id\":{d},\"tick\":{d},\"kind\":\"", .{ r.id, r.tick });
            try appendJsonString(alloc, &body, r.kind);
            try body.appendSlice(alloc, "\",\"input\":\"");
            try appendJsonString(alloc, &body, r.input);
            try body.appendSlice(alloc, "\",\"output\":\"");
            try appendJsonString(alloc, &body, r.output);
            try body.appendSlice(alloc, "\",\"result\":\"");
            try appendJsonString(alloc, &body, r.result);
            try body.print(alloc, "\",\"duration_ms\":{d}}}", .{r.duration_ms});
        }
        try body.append(alloc, ']');
        try body.append(alloc, '}');
        const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    } else {
        const err_body = "{\"error\":\"sqlite not enabled\"}";
        const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    }
}

/// /api/peers — 列出本机知道的 peer GHW 实例 + 最近一次 state 快照
/// 简化策略: 每次 GET 都会尝试 ping 一次, 更新 last_seen_tick + cached state
fn handleGetPeers(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"self\":");
    if (app.link) |*l| {
        try body.print(alloc, "{{\"peer_id\":\"{s}\",\"path\":\"{s}\"}}", .{ l.peer_id, l.self_path });
    } else {
        try body.appendSlice(alloc, "null");
    }
    try body.appendSlice(alloc, ",\"peers\":[");
    var first = true;
    for (app.peers.items) |p| {
        if (!first) try body.append(alloc, ',');
        first = false;
        // Phase 1 production: health + last_E/M/R/N/tick 实时同步
        try body.print(alloc,
            \\{{"peer_id":"{s}","path":"{s}","health":"{s}","last_seen_tick":{d},"consecutive_failures":{d},"last_E":{d:.4},"last_M":{d:.4},"last_R":{d:.4},"last_N":{d:.4},"last_tick":{d}}}
        , .{
            p.peer_id, p.path, p.health, p.last_seen_tick, p.consecutive_failures,
            p.last_E, p.last_M, p.last_R, p.last_N, p.last_tick,
        });
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/metrics — Prometheus metrics 端点 (text/plain, 0.0.4 format)
/// 给 Grafana / 监控 scrape 用, 包含:
///   - ghw_tick_total (counter)
///   - ghw_self_evolved_total (counter, l1..l5 分项)
///   - ghw_action_total (counter)
///   - ghw_E / ghw_M / ghw_R / ghw_N (gauge, 0..1)
///   - ghw_phase (gauge, 0..9)
///   - ghw_nine_palaces_e_var / mrn / mrn_strong (gauge, 0/1)
///   - ghw_peers_total (gauge)
///   - ghw_l4_propose_total / accepted / rejected (counter)
fn handleGetMetrics(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // HELP + TYPE + value (按 Prometheus 规范: 每 metric 配 HELP + TYPE)
    try body.print(alloc,
        \\# HELP ghw_tick_total 总 cycle 数
        \\# TYPE ghw_tick_total counter
        \\ghw_tick_total {d}
        \\
        \\# HELP ghw_action_total 总动作数
        \\# TYPE ghw_action_total counter
        \\ghw_action_total {d}
        \\
        \\# HELP ghw_self_evolved_total L1-L5 自演化触发累计
        \\# TYPE ghw_self_evolved_total counter
        \\ghw_self_evolved_total{{level="l1"}} {d}
        \\ghw_self_evolved_total{{level="l2"}} {d}
        \\ghw_self_evolved_total{{level="l3"}} {d}
        \\ghw_self_evolved_total{{level="l3_approved"}} {d}
        \\ghw_self_evolved_total{{level="l4"}} {d}
        \\ghw_self_evolved_total{{level="l4_approved"}} {d}
        \\ghw_self_evolved_total{{level="l5"}} {d}
        \\
        \\# HELP ghw_l4_propose_total L4 闭环 LLM 提议次数
        \\# TYPE ghw_l4_propose_total counter
        \\ghw_l4_propose_total{{result="total"}} {d}
        \\ghw_l4_propose_total{{result="accepted"}} {d}
        \\ghw_l4_propose_total{{result="rejected"}} {d}
        \\
        \\# HELP ghw_E 当前存在度 (0-1)
        \\# TYPE ghw_E gauge
        \\ghw_E {d:.6}
        \\
        \\# HELP ghw_three_sources M/R/N 三源合恰
        \\# TYPE ghw_three_sources gauge
        \\ghw_three_sources{{kind="M"}} {d:.6}
        \\ghw_three_sources{{kind="R"}} {d:.6}
        \\ghw_three_sources{{kind="N"}} {d:.6}
        \\
        \\# HELP ghw_phase 当前 9 阶段
        \\# TYPE ghw_phase gauge
        \\ghw_phase {d}
        \\
        \\# HELP ghw_nine_palaces 9 宫 3 里程碑触发状态
        \\# TYPE ghw_nine_palaces gauge
        \\ghw_nine_palaces{{milestone="e_var"}} {d}
        \\ghw_nine_palaces{{milestone="mrn"}} {d}
        \\ghw_nine_palaces{{milestone="mrn_strong"}} {d}
        \\
        \\# HELP ghw_peers_total 已知 peer 数
        \\# TYPE ghw_peers_total gauge
        \\ghw_peers_total {d}
        \\
        \\# HELP ghw_l4_coefficients L4 闭环 4 系数 (effective)
        \\# TYPE ghw_l4_coefficients gauge
        \\ghw_l4_coefficients{{name="mu"}} {d:.4}
        \\ghw_l4_coefficients{{name="nu"}} {d:.4}
        \\ghw_l4_coefficients{{name="sigma"}} {d:.4}
        \\ghw_l4_coefficients{{name="lambda"}} {d:.4}
        \\
    , .{
        app.agent.tick,
        app.action_count,
        app.self_evolve_l1_count,
        app.self_evolve_l2_count,
        app.self_evolve_l3_count,
        app.self_evolve_l3_approved,
        app.self_evolve_l4_count,
        app.self_evolve_l4_approved,
        app.self_evolve_l5_count,
        app.propose_total,
        app.agent.ed.propose_accepted,
        app.agent.ed.propose_rejected,
        app.agent.ed.e(),
        app.agent.ed.v.material,
        app.agent.ed.v.representation,
        app.agent.ed.v.nature,
        app.phase,
        app.nine_palaces_e_var_seen,
        app.nine_palaces_mrn_seen,
        app.nine_palaces_mrn_strong_seen,
        app.peers.items.len,
        // 4 系数 effective (用 *_computed 跟 _auto 联动逻辑, 跟 e_breakdown 一致)
        app.agent.ed.mu_computed,
        app.agent.ed.nu_computed,
        app.agent.ed.sigma_computed,
        app.agent.ed.lambda_computed,
    });
    const resp = try makeHttpResponse(alloc, 200, "OK", "text/plain; version=0.0.4; charset=utf-8", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/goals/relations — 8 关系统计 (Phase 8 数字生命实装里程碑)
/// 返回:
///   - distinct: 0-8 (活跃节点的不同关系种类数)
///   - stats: [parent_count, sibling_count, conflict_count, depends_count, replaces_count, enables_count, inhibits_count, emerges_count]
///   - summary: "parent:5 sibling:3 conflict:1 ..."  (可读)
///   - goals: [{id, kind, label, parent, siblings, conflicts_with, depends_on, replaces, enables, inhibits, emerges_from, status}]
fn handleGetLoopState(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    _ = app;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // 尝试从 ~/.local/share/ghw/loop_state.json 读 (daemon 5 min 一次)
    // 跟其它 endpoint 一样 fallback 风格, 不报错
    const loop_path = "/Users/n0x/.local/share/ghw/loop_state.json";
    const f = std.Io.Dir.openFileAbsolute(io, loop_path, .{ .mode = .read_only }) catch {
        // 文件不存在: daemon 没启 Loop Engine 或还没存
        try body.appendSlice(alloc, "{\"error\":\"loop_state not found\",\"path\":\"");
        try body.appendSlice(alloc, loop_path);
        try body.appendSlice(alloc, "\"}");
        try writeJsonResponse(alloc, conn, io, body.items);
        return;
    };
    defer f.close(io);

    const stat = try f.stat(io);
    if (stat.size == 0) {
        try body.appendSlice(alloc, "{\"error\":\"loop_state empty\"}");
        try writeJsonResponse(alloc, conn, io, body.items);
        return;
    }
    const json = try alloc.alloc(u8, stat.size);
    defer alloc.free(json);
    _ = try std.Io.File.readPositionalAll(f, io, json, 0);

    // 直接转发 (loop_state.json 已经是 JSON)
    try body.appendSlice(alloc, "{\"loop_state\":");
    try body.appendSlice(alloc, json);
    try body.appendSlice(alloc, ",\"source\":\"daemon_file\",\"path\":\"");
    try body.appendSlice(alloc, loop_path);
    try body.appendSlice(alloc, "\"}");
    try writeJsonResponse(alloc, conn, io, body.items);
}

/// 写 JSON 响应 (Boris Loop Engine + 其它 endpoint 共用)
fn writeJsonResponse(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, body: []const u8) !void {
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json; charset=utf-8", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handleGetGoalRelations(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // 拿 graph (const)
    const g = &app.agent.goal_graph;
    const distinct = g.countDistinctRelations();
    const stats = g.relationStats();
    const summary = g.relationsSummary(alloc) catch "(error)";
    defer if (!std.mem.eql(u8, summary, "(error)")) alloc.free(summary);

    try body.print(alloc, "{{\"distinct\":{d},\"summary\":\"{s}\",\"stats\":[", .{ distinct, summary });
    for (stats, 0..) |s, i| {
        if (i > 0) try body.append(alloc, ',');
        try body.print(alloc, "{d}", .{s});
    }
    try body.appendSlice(alloc, "],\"topo\":[");
    // 拓扑排序 (Kahn 算法, 考虑 parent + depends_on + emerges_after)
    const topo = g.topologicalSort(alloc) catch null;
    if (topo) |t| {
        defer alloc.free(t);
        for (t, 0..) |tid, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{tid});
        }
    }
    try body.appendSlice(alloc, "],\"goals\":[");

    var first = true;
    for (g.goals.items) |goal| {
        if (!first) try body.append(alloc, ',');
        first = false;

        // 转义 label
        const label_esc = try jsonEscape(alloc, goal.label);
        defer alloc.free(label_esc);

        try body.print(alloc, "{{\"id\":{d},\"kind\":\"{s}\",\"label\":\"{s}\",\"priority\":{d},\"parent\":", .{
            goal.id,
            @tagName(goal.kind),
            label_esc,
            goal.priority,
        });
        if (goal.parent) |p| {
            try body.print(alloc, "{d}", .{p});
        } else {
            try body.appendSlice(alloc, "null");
        }
        try body.appendSlice(alloc, ",\"status\":");
        try body.print(alloc, "{d}", .{goal.status});

        // 关系数组
        try body.appendSlice(alloc, ",\"siblings\":[");
        for (goal.siblings.items, 0..) |s, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{s});
        }
        try body.appendSlice(alloc, "],\"conflicts_with\":[");
        for (goal.conflicts_with.items, 0..) |c, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{c});
        }
        try body.appendSlice(alloc, "],\"depends_on\":[");
        for (goal.depends_on.items, 0..) |d, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{d});
        }
        try body.appendSlice(alloc, "],\"enables\":[");
        for (goal.enables.items, 0..) |e, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{e});
        }
        try body.appendSlice(alloc, "],\"inhibits\":[");
        for (goal.inhibits.items, 0..) |i_id, ii| {
            if (ii > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{i_id});
        }
        try body.appendSlice(alloc, "],\"emerges_from\":[");
        for (goal.emerges_from.items, 0..) |em, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{em});
        }
        try body.appendSlice(alloc, "],\"emerges_after\":[");
        for (goal.emerges_after.items, 0..) |ea, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{d}", .{ea});
        }
        try body.appendSlice(alloc, "]");
        try body.appendSlice(alloc, ",\"replaces\":");
        if (goal.replaces) |r| {
            try body.print(alloc, "{d}", .{r});
        } else {
            try body.appendSlice(alloc, "null");
        }
        try body.append(alloc, '}');
    }
    try body.appendSlice(alloc, "]}");

    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// 从 query_state 响应里抽 E (简单 string search, 不引 JSON 解析器)
/// resp 形如: {"id":"q1","ok":true,"result":{"tick":0,"E":0.777, ...}}
/// 返 0.0 如果没找到
fn extractEFromResp(resp: []const u8) F {
    // 找 "E":<number> 或 "E": <number>
    var i: usize = 0;
    while (i + 4 < resp.len) {
        if (resp[i] == '"' and resp[i + 1] == 'E' and resp[i + 2] == '"' and resp[i + 3] == ':') {
            // 跳过空格
            var j = i + 4;
            while (j < resp.len and resp[j] == ' ') : (j += 1) {}
            // 解析浮点数 (简单版: 0.x 或 1.x)
            var end = j;
            while (end < resp.len and (resp[end] == '.' or (resp[end] >= '0' and resp[end] <= '9'))) : (end += 1) {}
            if (end > j) {
                return std.fmt.parseFloat(F, resp[j..end]) catch 0.0;
            }
            return 0.0;
        }
        i += 1;
    }
    return 0.0;
}

/// 更新 peer E 缓存 (滑动平均: 新样本 30%, 旧 70%)
fn updatePeerECache(app: *App, new_E: F) void {
    if (new_E < 0.01) return; // 跳过无效样本 (E=0/NaN/负数)
    if (app.peer_E_avg < 0.01) {
        app.peer_E_avg = new_E; // 第一次
    } else {
        app.peer_E_avg = app.peer_E_avg * 0.7 + new_E * 0.3;
    }
    app.peer_count_cached = @intCast(app.peers.items.len);
    if (app.peer_count_cached > 0) {
        app.agent.ed.peer_E_avg = app.peer_E_avg;
        app.agent.ed.peer_count = app.peer_count_cached;
        app.agent.ed.sigma = 0.15; // 打开共生通道
    }
}

/// 在 runCycle 开头调: 把 peer 关系反映到 weights
fn adaptWeightsFromPeers(app: *App) void {
    if (app.peer_count_cached == 0) return;
    const own_E = app.agent.ed.e();
    app.agent.ed.weights.adaptFromPeers(app.peer_E_avg, own_E);
    // 把 σ 通道也开起来 (确保共生度进入 E)
    app.agent.ed.sigma = 0.15;
    app.agent.ed.peer_E_avg = app.peer_E_avg;
    app.agent.ed.peer_count = app.peer_count_cached;
}

/// /api/peer/query?path=<sock>&method=<m> — 客户端手动 query 一个 peer
/// 简化: 用 query string, 不解析 body
/// 例: POST /api/peer/query?path=/tmp/ghw_X.sock&method=query_state
fn handlePostPeerQuery(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, query: []const u8) !void {
    var qs = query;
    if (qs.len > 0 and qs[0] == '?') qs = qs[1..];
    var path_arg: ?[]const u8 = null;
    var method_arg: []const u8 = "ping";
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "path=")) {
            path_arg = kv["path=".len..];
        } else if (std.mem.startsWith(u8, kv, "method=")) {
            method_arg = kv["method=".len..];
        }
    }
    const path = path_arg orelse {
        const err_body = "{\"error\":\"missing ?path=<sock>\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };

    if (app.link) |*l| {
        const resp_raw = l.query(path, method_arg, "{}") catch |err| {
            const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"query failed: {t}\"}}", .{err});
            defer alloc.free(err_body);
            const resp = try makeHttpResponse(alloc, 502, "Bad Gateway", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer alloc.free(resp_raw);
        const peer_id = l.parsePeerId(path);
        var exists = false;
        for (app.peers.items) |p| {
            if (std.mem.eql(u8, p.path, path)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try app.peers.append(alloc, .{
                .path = try alloc.dupe(u8, path),
                .peer_id = try alloc.dupe(u8, peer_id),
                .last_seen_tick = @intCast(app.agent.tick),
            });
        }
        // P8a: query_state → 与 TaskExecutor/ActionRunner 同款 peer_symbiosis 写回
        if (std.mem.eql(u8, method_arg, "query_state")) {
            ingestPeerActionResult(app, resp_raw);
        }
        // P2c: 手动 query_shortfall 也入 inbox + 有界协助 (与 peer health 同款)
        if (std.mem.eql(u8, method_arg, "query_shortfall")) {
            ingestPeerShortfallResponse(app, peer_id, resp_raw);
            refreshLifecycle(app);
        }
        const out = try std.fmt.allocPrint(alloc, "{{\"peer\":\"{s}\",\"method\":\"{s}\",\"response\":{s}}}", .{ peer_id, method_arg, resp_raw });
        defer alloc.free(out);
        const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", out);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    } else {
        const err_body = "{\"error\":\"link not enabled\"}";
        const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    }
}

/// /api/action/run-now — 立即跑 1 个 action (manual trigger, 跳过 action_every 间隔)
fn handlePostActionRun(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    if (app.action_runner) |*ar| {
        if (ar.runTopGoal(@intCast(app.agent.tick))) |maybe| {
            if (maybe) |result| {
                if (app.last_action) |*prev| prev.deinit();
                app.last_action = result;
                app.action_count += 1;
                ar.last_action_at_tick = app.agent.tick;
                std.debug.print("[ui] 手动 action 完成: {s} (action_count={d})\n", .{ result.goal_title, app.action_count });
            } else {
                std.debug.print("[ui] 手动 action: 没 unadopted goal 了\n", .{});
            }
        } else |err| {
            std.debug.print("[ui] 手动 action 失败: {t}\n", .{err});
        }
    }
    const body = "{\"ok\":true}";
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// /api/memory/search?q=...&limit=N
/// 搜索 sqlite 里的 episodes (kind=reflection/cycle/propose/chat)
/// 演示 sqlite 的查询能力
fn handleGetMemorySearch(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, query: []const u8) !void {
    if (app.sqlite) |*db| {
        // 解析 query: 去 URL decode 简化处理 (直接看 q=xxx)
        var q_buf: std.ArrayList(u8) = .empty;
        defer q_buf.deinit(alloc);
        // 简单 split 拿第一个 q= 值 (query 以 ? 开头)
        var qstring = query;
        if (qstring.len > 0 and qstring[0] == '?') qstring = qstring[1..];
        var it = std.mem.splitScalar(u8, qstring, '&');
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "q=")) {
                try q_buf.appendSlice(alloc, kv["q=".len..]);
                break;
            }
        }
        const q = q_buf.items;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        try body.appendSlice(alloc, "{\"query\":\"");
        try appendJsonString(alloc, &body, q);
        try body.print(alloc, "\",\"episodes_written\":{d},\"results\":[", .{app.sqlite_episodes_written});
        const rows = db.searchEpisodes(q, 20) catch |err| blk: {
            try body.print(alloc, "{{\"error\":\"{t}\"}}", .{err});
            try body.append(alloc, ']');
            break :blk &[_]SqliteDb.EpisodeRow{};
        };
        defer {
            for (rows) |r| r.deinit();
            alloc.free(rows);
        }
        for (rows, 0..) |r, i| {
            if (i > 0) try body.append(alloc, ',');
            try body.print(alloc, "{{\"id\":{d},\"tick\":{d},\"kind\":\"", .{ r.id, r.tick });
            try appendJsonString(alloc, &body, r.kind);
            try body.appendSlice(alloc, "\",\"importance\":");
            try body.print(alloc, "{d:.3}", .{r.importance});
            try body.appendSlice(alloc, ",\"data\":\"");
            try appendJsonString(alloc, &body, r.data);
            try body.print(alloc, "\",\"source\":\"", .{});
            try appendJsonString(alloc, &body, r.source);
            try body.appendSlice(alloc, "\"}");
        }
        try body.append(alloc, ']');
        try body.append(alloc, '}');
        const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    } else {
        const err_body = "{\"error\":\"sqlite not enabled\"}";
        const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
    }
}

fn appendJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) try buf.print(alloc, "\\u{x:0>4}", .{c}) else try buf.append(alloc, c),
        }
    }
}

fn urlDecodeFormComponent(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '+') {
            try out.append(alloc, ' ');
            i += 1;
        } else if (value[i] == '%' and i + 2 < value.len) {
            const hex = value[i + 1 .. i + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |c| {
                try out.append(alloc, c);
                i += 3;
            } else |_| {
                try out.append(alloc, value[i]);
                i += 1;
            }
        } else {
            try out.append(alloc, value[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn formValue(alloc: Allocator, body_text: []const u8, key: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, body_text, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) {
            return try urlDecodeFormComponent(alloc, kv[eq + 1 ..]);
        }
    }
    return null;
}

/// GET /api/tasks — TaskQueue 快照 (P9: UI 评分 + 审计; P1: 维度台账)
fn handleGetTasks(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    const ledger = app.task_queue.dimensionLedger();
    try body.appendSlice(alloc, "{\"tasks\":[");
    for (app.task_queue.tasks.items, 0..) |t, i| {
        if (i > 0) try body.append(alloc, ',');
        try body.print(alloc, "{{\"id\":{d},\"title\":\"", .{t.id});
        try appendJsonString(alloc, &body, t.title);
        try body.print(alloc, "\",\"status\":\"{s}\",\"from_human\":\"", .{@tagName(t.status)});
        try appendJsonString(alloc, &body, t.from_human);
        try body.append(alloc, '"');
        try body.print(alloc, ",\"priority\":{d},\"required_dimension\":\"{s}\",\"source\":\"{s}\"", .{ t.priority, @tagName(t.required_dimension), @tagName(t.source) });
        const survival_driven = ghw_harness.human_symbiosis.task_queue.isSurvivalSource(t.source);
        try body.print(alloc, ",\"survival_driven\":{s}", .{if (survival_driven) "true" else "false"});
        var evolution_linked = false;
        if (survival_driven and t.status == .completed) {
            if (t.result) |r| evolution_linked = r.actual_delta_e > 0.01;
        }
        try body.print(alloc, ",\"evolution_linked\":{s}", .{if (evolution_linked) "true" else "false"});
        if (t.result) |r| {
            try body.print(alloc, ",\"actual_delta_e\":{d:.6}", .{r.actual_delta_e});
        }
        if (t.feedback) |f| {
            try body.print(alloc, ",\"feedback_score\":{d},\"feedback_delta_e\":{d:.3}", .{ f.score, f.delta_e });
        }
        try body.append(alloc, '}');
    }
    try body.appendSlice(alloc, "],\"pending\":");
    try body.print(alloc, "{d},\"completed\":{d},", .{ app.task_queue.pending_count, app.task_queue.completed_count });
    try app.task_queue.appendDimensionLedgerJson(alloc, &body, ledger);
    try body.append(alloc, '}');
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/product/audit — 产品进化审计日志 (P18)
fn handleGetProductAudit(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = if (app.product_runtime) |*rt| try rt.auditJson(alloc) else try alloc.dupe(u8, "{\"enabled\":false,\"audit\":[]}");
    defer alloc.free(body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/product/runtime — 产品变更 + 审计完整快照 (P18)
fn handleGetProductRuntime(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = if (app.product_runtime) |*rt| try rt.toJson(alloc) else try alloc.dupe(u8, "{\"enabled\":false,\"changes\":[],\"audit\":[]}");
    defer alloc.free(body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn requireProductRuntime(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !?*ghw_harness.product_runtime.ProductEvolutionRuntime {
    if (app.product_runtime) |*rt| return rt;
    const err_body = "{\"error\":\"product runtime disabled; start ui_server with --product-intent PATH\"}";
    const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
    return null;
}

fn requireAdminToken(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, presented: ?[]const u8) !bool {
    if (app.admin_token.len == 0) return true;
    if (presented) |token| {
        if (std.mem.eql(u8, token, app.admin_token)) return true;
    }
    const err_body = "{\"error\":\"admin token required\"}";
    const resp = try makeHttpResponse(alloc, 401, "Unauthorized", "application/json", err_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
    return false;
}

/// GET /api/product/intent — ProductIntent identity/governance metadata (P22)
fn handleGetProductIntent(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    if (app.product_intent) |*intent| {
        try body.appendSlice(alloc, "{\"enabled\":true,\"product_id\":\"");
        try appendJsonString(alloc, &body, intent.product_id);
        try body.appendSlice(alloc, "\",\"version\":\"");
        try appendJsonString(alloc, &body, intent.version);
        try body.print(alloc, "\",\"update_epoch\":{d},\"approved_by\":\"", .{intent.update_epoch});
        try appendJsonString(alloc, &body, intent.approved_by);
        try body.appendSlice(alloc, "\",\"manifest_hash\":\"");
        try appendJsonString(alloc, &body, app.product_intent_hash);
        try body.print(alloc, "\",\"adapter_enabled\":{s},\"kpi_last_feed_unix\":{d}}}", .{
            if (app.product_config_adapter != null) "true" else "false",
            app.product_kpi_last_feed_unix,
        });
    } else {
        try body.appendSlice(alloc, "{\"enabled\":false}");
    }
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/product/approvals — approval desk data surface (P23)
fn handleGetProductApprovals(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"enabled\":");
    try body.appendSlice(alloc, if (app.product_runtime != null) "true" else "false");
    try body.appendSlice(alloc, ",\"pending\":[");
    if (app.product_runtime) |*rt| {
        var first = true;
        for (rt.changes.items) |c| {
            if (c.status != .pending_consent and c.status != .approved) continue;
            if (!first) try body.append(alloc, ',');
            first = false;
            try body.print(alloc, "{{\"id\":{d},\"status\":\"{s}\",\"tier\":\"{s}\",\"tenant_id\":\"", .{
                c.id,
                @tagName(c.status),
                @tagName(c.tier),
            });
            try appendJsonString(alloc, &body, c.tenant_id);
            try body.appendSlice(alloc, "\",\"target\":\"");
            try appendJsonString(alloc, &body, c.target);
            try body.appendSlice(alloc, "\",\"summary\":\"");
            try appendJsonString(alloc, &body, c.summary);
            try body.print(alloc, "\",\"expected_delta_k\":{d:.6},\"affected_users\":{d},\"required_approvers\":\"", .{
                c.expected_delta_k,
                c.affected_users,
            });
            try appendJsonString(alloc, &body, c.required_approvers);
            try body.appendSlice(alloc, "\"}");
        }
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/product/identity — 一产品一 GHW 实例契约 (P26)
fn handleGetProductIdentity(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    if (app.product_runtime) |*rt| {
        try body.appendSlice(alloc, "{\"enabled\":true,");
        if (rt.instance) |*id| {
            try id.appendJsonFields(&body);
        } else if (app.product_intent) |*intent| {
            try body.print(alloc, "\"binding_mode\":\"one_product_one_ghw\",\"product_id\":\"", .{});
            try appendJsonString(alloc, &body, intent.product_id);
            try body.appendSlice(alloc, "\",\"product_type\":\"");
            try body.appendSlice(alloc, @tagName(intent.product_type));
            try body.appendSlice(alloc, "\",\"instance_id\":null,\"node_id\":null");
        }
        try body.appendSlice(alloc, ",\"cross_link_enabled\":");
        try body.appendSlice(alloc, if (app.cross_link != null) "true" else "false");
        try body.appendSlice(alloc, "}");
    } else {
        try body.appendSlice(alloc, "{\"enabled\":false,\"binding_mode\":\"one_product_one_ghw\"}");
    }
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/product/co-evolution — 来自 peer 的共同进化洞察 (P28)
fn handleGetProductCoEvolution(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = if (app.co_evolution) |*reg| try reg.toJson(alloc) else try alloc.dupe(u8, "{\"local_product_id\":\"\",\"insights\":[]}");
    defer alloc.free(body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn crossLinkServerTask(cl: *ghw_harness.ghw_link_tcp.CrossLink, ctx: *anyopaque, stop: *std.atomic.Value(bool)) void {
    cl.runServer(linkHandler, ctx, stop) catch |err| {
        std.debug.print("[ui] cross-link listener 异常: {t}\n", .{err});
    };
}

/// POST /api/product/propose-crm-followup — 提交 canonical CRM 产品变更 (P18)
fn handlePostProductProposeCrm(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8, admin_token: ?[]const u8) !void {
    if (!try requireAdminToken(alloc, conn, io, app, admin_token)) return;
    const rt = (try requireProductRuntime(alloc, conn, io, app)) orelse return;
    const tenant_owned = (try formValue(alloc, body_text, "tenant_id")) orelse try alloc.dupe(u8, "default");
    defer alloc.free(tenant_owned);
    const users_owned = try formValue(alloc, body_text, "affected_users");
    defer if (users_owned) |v| alloc.free(v);
    const delta_owned = try formValue(alloc, body_text, "expected_delta_k");
    defer if (delta_owned) |v| alloc.free(v);
    const affected_users: u32 = if (users_owned) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    const expected_delta_k: f32 = if (delta_owned) |v| std.fmt.parseFloat(f32, v) catch 0 else 0;
    const now: u64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    const id = rt.proposeCrmFollowupTightening(tenant_owned, affected_users, expected_delta_k, now) catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"{t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    saveState(app) catch {};
    const ok_body = try std.fmt.allocPrint(alloc, "{{\"change_id\":{d},\"status\":\"{s}\"}}", .{
        id,
        @tagName(rt.findChange(id).?.status),
    });
    defer alloc.free(ok_body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", ok_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handlePostProductTransition(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8, action: ProductTransitionAction, admin_token: ?[]const u8) !void {
    if (!try requireAdminToken(alloc, conn, io, app, admin_token)) return;
    const rt = (try requireProductRuntime(alloc, conn, io, app)) orelse return;
    const id_owned = try formValue(alloc, body_text, "change_id");
    defer if (id_owned) |v| alloc.free(v);
    const change_id: u64 = if (id_owned) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
    if (change_id == 0) {
        const err_body = "{\"error\":\"missing change_id\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    const now: u64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    const op_result: anyerror!void = switch (action) {
        .approve => blk: {
            const approver_owned = try formValue(alloc, body_text, "approver");
            defer if (approver_owned) |v| alloc.free(v);
            const note_owned = try formValue(alloc, body_text, "note");
            defer if (note_owned) |v| alloc.free(v);
            break :blk rt.approve(change_id, approver_owned orelse "human", note_owned orelse "", now);
        },
        .apply => rt.applyApproved(change_id, now),
        .rollback => rt.rollbackApplied(change_id, now),
    };
    op_result catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"{t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    saveState(app) catch {};
    const status = if (rt.findChange(change_id)) |c| @tagName(c.status) else "unknown";
    const ok_body = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"change_id\":{d},\"status\":\"{s}\"}}", .{ change_id, status });
    defer alloc.free(ok_body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", ok_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/product/kpi — real product KPI feed entry (P24)
fn handlePostProductKpi(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8, admin_token: ?[]const u8) !void {
    if (!try requireAdminToken(alloc, conn, io, app, admin_token)) return;
    const rt = (try requireProductRuntime(alloc, conn, io, app)) orelse return;
    const nrr_owned = try formValue(alloc, body_text, "nrr_quarterly");
    defer if (nrr_owned) |v| alloc.free(v);
    const win_owned = try formValue(alloc, body_text, "deal_win_rate");
    defer if (win_owned) |v| alloc.free(v);
    const cycle_owned = try formValue(alloc, body_text, "sales_cycle_days_p50");
    defer if (cycle_owned) |v| alloc.free(v);
    const active_owned = try formValue(alloc, body_text, "weekly_active_sales_pct");
    defer if (active_owned) |v| alloc.free(v);
    const csat_owned = try formValue(alloc, body_text, "csat");
    defer if (csat_owned) |v| alloc.free(v);
    const incident_owned = try formValue(alloc, body_text, "incident_rate");
    defer if (incident_owned) |v| alloc.free(v);

    const raw = ghw_harness.crm_kpi.RawKpi{
        .nrr_quarterly = if (nrr_owned) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .deal_win_rate = if (win_owned) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .sales_cycle_days_p50 = if (cycle_owned) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .weekly_active_sales_pct = if (active_owned) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .csat = if (csat_owned) |v| std.fmt.parseFloat(f32, v) catch null else null,
        .incident_rate = if (incident_owned) |v| std.fmt.parseFloat(f32, v) catch null else null,
    };
    const now = std.Io.Clock.real.now(app.io).toSeconds();
    app.product_kpi_last_feed_unix = now;
    const refreshed = rt.feedKpi(&app.agent.ed, raw, now) catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"{t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    saveState(app) catch {};
    const ok_body = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"refreshed\":{s},\"kpi_last_feed_unix\":{d}}}", .{
        if (refreshed) "true" else "false",
        app.product_kpi_last_feed_unix,
    });
    defer alloc.free(ok_body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", ok_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/tasks — 人类显式投递任务 (P14: source=human)
fn handlePostTask(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8) !void {
    const title_owned = (try formValue(alloc, body_text, "title")) orelse {
        const err_body = "{\"error\":\"missing title\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    defer alloc.free(title_owned);
    const desc_owned = try formValue(alloc, body_text, "description");
    defer if (desc_owned) |v| alloc.free(v);
    const from_owned = try formValue(alloc, body_text, "from_human");
    defer if (from_owned) |v| alloc.free(v);
    const dim_owned = try formValue(alloc, body_text, "required_dimension");
    defer if (dim_owned) |v| alloc.free(v);
    const priority_owned = try formValue(alloc, body_text, "priority");
    defer if (priority_owned) |v| alloc.free(v);
    const cycles_owned = try formValue(alloc, body_text, "cycles_allocated");
    defer if (cycles_owned) |v| alloc.free(v);

    if (title_owned.len == 0) {
        const err_body = "{\"error\":\"missing title\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }

    const from_human = if (from_owned) |v| if (v.len > 0) v else "human" else "human";
    const description = if (desc_owned) |v| if (v.len > 0) v else title_owned else title_owned;
    const priority: u8 = if (priority_owned) |v| @intCast(std.fmt.parseInt(u16, v, 10) catch 7) else 7;
    const cycles: u32 = if (cycles_owned) |v| @intCast(std.fmt.parseInt(u32, v, 10) catch 4) else 4;
    const dim = ghw_harness.human_symbiosis.task_queue.parseDimensionPublic(
        if (dim_owned) |v| if (v.len > 0) v else "all" else "all",
    );
    try app.human_gsp.register(from_human);

    const task_id = app.task_queue.submitWithSource(
        title_owned,
        description,
        from_human,
        priority,
        dim,
        cycles,
        .human,
    ) catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"{t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    saveState(app) catch {};

    const ok_body = try std.fmt.allocPrint(alloc, "{{\"task_id\":{d},\"pending\":{d},\"source\":\"human\"}}", .{
        task_id, app.task_queue.pending_count,
    });
    defer alloc.free(ok_body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", ok_body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/task/feedback — 人类显式评分 (覆盖启发式反馈)
fn handlePostTaskFeedback(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8) !void {
    const task_id_owned = try formValue(alloc, body_text, "task_id");
    defer if (task_id_owned) |v| alloc.free(v);
    const score_owned = try formValue(alloc, body_text, "score");
    defer if (score_owned) |v| alloc.free(v);
    const comment_owned = try formValue(alloc, body_text, "comment");
    defer if (comment_owned) |v| alloc.free(v);

    const task_id: u64 = if (task_id_owned) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
    const score: i8 = if (score_owned) |v| @intCast(std.fmt.parseInt(i16, v, 10) catch 0) else 0;
    if (task_id == 0) {
        const err_body = "{\"error\":\"missing task_id\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }
    const t = app.task_queue.find(task_id) orelse {
        const err_body = "{\"error\":\"task not found\"}";
        const resp = try makeHttpResponse(alloc, 404, "Not Found", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    const ts: u64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    const ctx = ghw_harness.task_feedback.Context{
        .queue = &app.task_queue,
        .gsp = &app.human_gsp,
        .signal = &app.human_signal,
    };
    const de = ghw_harness.task_feedback.applyFeedback(&ctx, t, score, comment_owned orelse "", ts) catch |err| {
        const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"{t}\"}}", .{err});
        defer alloc.free(err_body);
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    saveState(app) catch {};
    var resp_body: std.ArrayList(u8) = .empty;
    defer resp_body.deinit(alloc);
    try resp_body.print(alloc, "{{\"ok\":true,\"task_id\":{d},\"score\":{d},\"human_delta_e\":{d:.3}}}", .{ task_id, score, de });
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", resp_body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// 手动触发 LLM 提议目标 (看世界快照, 提议 1-3 个新目标)
fn handleGetPropose(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    if (app.goal_proposer) |*gp| {
        // dup 避免 race (collect 会 deinit last)
        const prev_snap = app.world.last orelse {
            const err_body = "{\"error\":\"no world snapshot yet\"}";
            const resp = try makeHttpResponse(alloc, 503, "Service Unavailable", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        var world_snap = app.world.dupSnapshot(prev_snap) catch |err| {
            const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"dupSnapshot: {t}\"}}", .{err});
            defer alloc.free(err_body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer world_snap.deinit();
        app.propose_total += 1;
        var result = gp.proposeAndAdopt(&app.world, world_snap, &app.agent, &app.task_queue, app.io) catch |err| {
            const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"propose failed: {t}\"}}", .{err});
            defer alloc.free(err_body);
            const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "application/json", err_body);
            defer alloc.free(resp);
            try writeResponse(conn, io, resp);
            return;
        };
        defer result.deinit();
        gp.last_propose_at_tick = app.agent.tick;
        try storeProposeResult(app, &result);
        std.debug.print("[ui] 手动 propose: {d} goals → TaskQueue pending={d}\n", .{ result.goals.len, app.task_queue.pending_count });
    }
    const body =
        \\{"ok":true,"action":"propose","goals_count":
    ;
    var resp_body: std.ArrayList(u8) = .empty;
    defer resp_body.deinit(alloc);
    try resp_body.appendSlice(alloc, body);
    try resp_body.print(alloc, "{d}", .{app.proposed_goals.items.len});
    try resp_body.appendSlice(alloc, "}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", resp_body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn handlePostChat(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body_text: []const u8) !void {
    const user_text_owned = try formValue(alloc, body_text, "text");
    defer if (user_text_owned) |v| alloc.free(v);
    const user_text = user_text_owned orelse "";
    if (user_text.len == 0) {
        const err_body = "bad request: empty text";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "text/plain", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    }

    // === 异步化: 立刻存 user bubble, 然后 spawn worker 跑 cycle + LLM ===
    // 之前: POST 同步跑 cycle + LLM (1-3s), UI 卡住
    // 现在: POST 200ms 内返, 1-1.5s 后 GHW reply 通过 chat history poll 自动出现

    // 1. 存 user message (lock) + 准备 worker ctx
    const user_text_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_text_copy);
    const user_text_esc = try jsonEscape(alloc, user_text);
    errdefer alloc.free(user_text_esc);

    app.chat_mutex.lockUncancelable(app.io);
    defer app.chat_mutex.unlock(app.io);
    try app.chat_history.append(app.alloc, .{
        .sender = try app.alloc.dupe(u8, "human"),
        .text = try app.alloc.dupe(u8, user_text),
        .timestamp = std.Io.Clock.real.now(app.io).toSeconds(),
        .tick = app.agent.tick,
    });

    // 2. Spawn worker (不阻塞 POST 响应)
    const ctx = try alloc.create(ChatWorkerCtx);
    ctx.* = .{
        .app = app,
        .user_text = user_text_copy,
        .user_text_esc = user_text_esc,
        .alloc = alloc,
    };
    const thread = std.Thread.spawn(.{}, ChatWorkerCtx.run, .{ctx}) catch |err| {
        std.debug.print("[chat] spawn worker 失败: {t}\n", .{err});
        alloc.destroy(ctx);
        alloc.free(user_text_copy);
        alloc.free(user_text_esc);
        const err_body = "internal: spawn worker failed";
        const resp = try makeHttpResponse(alloc, 500, "Internal Server Error", "text/plain", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    thread.detach();

    // 3. 立刻返 user bubble (无 GHW reply, GHW reply 通过 poll 出现)
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.print(alloc,
        \\<div class="flex flex-col items-end">
        \\  <div class="max-w-[80%] rounded-lg px-4 py-2 bg-slate-800">
        \\    <div class="text-[10px] uppercase tracking-wider text-cyan-300 mb-1">你</div>
        \\    <div class="text-sm whitespace-pre-wrap break-words">{s}</div>
        \\    <div class="text-[10px] text-ghw-dim mt-1 font-mono">tick #{d}</div>
        \\  </div>
        \\</div>
    , .{
        user_text_esc,
        app.agent.tick,
    });

    const resp = try makeHttpResponse(alloc, 200, "OK", "text/html; charset=utf-8", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

// ===== 接收 HTTP 请求 =====
fn readHttpRequest(alloc: Allocator, stream: *std.Io.net.Stream, io: std.Io) !HttpRequest {
    // 读全部 request (一般 < 8KB)
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(io, @constCast(&[_][]u8{buf[total..]}));
        if (n == 0) break;
        total += n;
        // 找 header 结束
        const end_hdr = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse continue;
        // 看 Content-Length
        const header = buf[0..end_hdr];
        var cl: usize = 0;
        var line_it = std.mem.splitScalar(u8, header, '\n');
        while (line_it.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                const v = std.mem.trim(u8, line["Content-Length:".len..], " \r");
                cl = std.fmt.parseInt(usize, v, 10) catch 0;
            }
        }
        if (cl > buf.len or end_hdr + 4 + cl > buf.len) return error.RequestTooLarge;
        if (total >= end_hdr + 4 + cl) break;
    }
    // 解析首行
    const header_end = std.mem.indexOf(u8, buf[0..total], "\r\n") orelse return error.Malformed;
    const first_line = buf[0..header_end];
    const sp1 = std.mem.indexOf(u8, first_line, " ") orelse return error.Malformed;
    const sp2 = std.mem.indexOfPos(u8, first_line, sp1 + 1, " ") orelse return error.Malformed;
    const method = try alloc.dupe(u8, first_line[0..sp1]);
    errdefer alloc.free(method);
    const path = try alloc.dupe(u8, first_line[sp1 + 1 .. sp2]);
    errdefer alloc.free(path);
    var admin_token: ?[]u8 = null;
    errdefer if (admin_token) |token| alloc.free(token);
    const full_header = buf[0 .. (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return error.Malformed)];
    var header_it = std.mem.splitScalar(u8, full_header, '\n');
    while (header_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r");
        if (std.ascii.startsWithIgnoreCase(line, "X-GHW-Admin-Token:")) {
            const v = std.mem.trim(u8, line["X-GHW-Admin-Token:".len..], " \t\r");
            admin_token = try alloc.dupe(u8, v);
            break;
        }
    }
    // body
    const body_start = (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return error.Malformed) + 4;
    const body_slice = buf[body_start..total];
    const body = try alloc.dupe(u8, body_slice);
    return .{ .method = method, .path = path, .body = body, .admin_token = admin_token };
}

// ===== HTTP server 主循环 =====
/// AutoCLI background thread: 周期拉 4 接口外网数据
/// 写 sqlite + Memory.recordAt(.world_fetch), 触发 phase 6 "自然" 接口
fn autocliThreadFn(app: *App) void {
    const alloc = app.alloc;
    while (!app.autocli_stop.load(.seq_cst)) {
        if (app.autocli) |*ac| {
            // P5a: 危机时拉长间隔 (主线程写入 override)
            const override_s = app.autocli_interval_override_s.load(.seq_cst);
            const interval_s: u64 = if (override_s > 0) override_s else app.autocli_base_interval_s;
            ac.interval_ns = @as(i128, @intCast(interval_s)) * std.time.ns_per_s;

            const now_ns = std.Io.Clock.real.now(app.io).nanoseconds;
            if (ac.shouldFetch(now_ns)) {
                var items: std.ArrayList(ghw.harness.autocli.FetchedItem) = .empty;
                defer {
                    for (items.items) |*it| it.deinit();
                    items.deinit(alloc);
                }
                ac.fetchAll(&items) catch {};

                // 写 sqlite + Memory (外网进入自传体, Goal/Rule/chat 可检索)
                for (items.items) |it| {
                    const kind_str = switch (it.source) {
                        .wikipedia => "autocli_wiki",
                        .hackernews => "autocli_hn",
                        .arxiv => "autocli_arxiv",
                        .rss => "autocli_rss",
                    };
                    const body = std.fmt.allocPrint(alloc, "{s}\n{s}\nURL: {s}", .{ it.title, it.snippet, it.url }) catch continue;
                    defer alloc.free(body);
                    if (app.sqlite) |*db| {
                        _ = db.insertEpisode(
                            @intCast(app.agent.tick),
                            kind_str,
                            body,
                            0.5,
                            "autocli",
                        ) catch {};
                    }
                    const summary = std.fmt.allocPrint(alloc, "[{s}] {s}", .{ kind_str, it.title }) catch continue;
                    defer alloc.free(summary);
                    // 外网知识优先 representation (R), 探索/求知
                    app.memory.recordAt(app.io, .world_fetch, app.agent.tick, summary, body, 2, 0) catch |err| {
                        std.debug.print("[autocli] Memory.recordAt 失败: {t}\n", .{err});
                    };
                    // P6: 外网 → 可行动任务 (有界启发式)
                    const br = ghw_harness.world_bridge.maybeAdoptFromFetch(&app.task_queue, it.title, it.snippet, alloc) catch null;
                    if (br) |b| {
                        if (b.submitted > 0) {
                            app.world_bridge_total += b.submitted;
                            std.debug.print("[world_bridge] 入队 {d} from 「{s}」(total={d})\n", .{
                                b.submitted, it.title, app.world_bridge_total,
                            });
                        }
                    }
                }

                // P6: 最近一条作 RuleProposer digest
                if (items.items.len > 0) {
                    const last = items.items[items.items.len - 1];
                    const tag = switch (last.source) {
                        .wikipedia => "wiki",
                        .hackernews => "hn",
                        .arxiv => "arxiv",
                        .rss => "rss",
                    };
                    if (ghw_harness.world_bridge.formatDigestLine(alloc, last.title, tag)) |line| {
                        defer alloc.free(line);
                        const n = @min(line.len, app.world_digest_buf.len);
                        @memcpy(app.world_digest_buf[0..n], line[0..n]);
                        app.world_digest_len = n;
                    } else |_| {}
                }

                // 触发 phase 6 (六气 "自然" 接口)
                if (items.items.len > 0 and !app.autocli_done) {
                    app.autocli_done = true;
                    std.debug.print("[autocli] ✓ 首次拉取 {d} 条 → Memory+sqlite (触发 phase 6)\n", .{items.items.len});
                } else {
                    std.debug.print("[autocli] 拉取 {d} 条 (累计 {d}, 错误 {d}, episodes={d})\n", .{
                        items.items.len, ac.total_fetched, ac.error_count, app.memory.episodes.items.len,
                    });
                }
                ac.markFetched(now_ns);
            }
        }
        // sleep 30s 检查 shouldFetch
        app.io.sleep(.{ .nanoseconds = @intCast(30 * std.time.ns_per_s) }, std.Io.Clock.real) catch {};
    }
    std.debug.print("[autocli] 退出\n", .{});
}

/// GET /api/laws — 第一性原理 / 生命规律 / 评估契约完整清单 (只读)
fn handleGetLaws(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    _ = app;
    const body = try ghw_harness.primordial_laws.toJson(alloc);
    defer alloc.free(body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/awaken — 幂等完成觉醒仪式
fn handlePostAwaken(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    // 强制采一次样
    _ = app.sys_collector.collectCached(0) catch {};
    maybeAwaken(app);
    refreshLifecycle(app);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    const aj = try app.awaken.toJson(alloc);
    defer alloc.free(aj);
    try body.print(alloc, "{{\"ok\":{s},\"existence_phase\":\"{s}\",\"awaken\":{s}}}", .{
        if (app.awaken.awakened) "true" else "false",
        app.existence_phase.label(),
        aj,
    });
    const code: u16 = if (app.awaken.awakened) 200 else 503;
    const status = if (app.awaken.awakened) "OK" else "Service Unavailable";
    const resp = try makeHttpResponse(alloc, code, status, "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/host-profile — 手机宿主推送电量/热/后台受限 (P2)
fn handlePostHostProfile(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body: []const u8) !void {
    const battery = extractJsonFloatField(body, "battery_pct") orelse extractFormFloat(body, "battery_pct");
    const thermal = std.mem.indexOf(u8, body, "\"thermal_hot\":true") != null or
        std.mem.indexOf(u8, body, "thermal_hot=true") != null or
        std.mem.indexOf(u8, body, "thermal_hot=1") != null;
    const bg = std.mem.indexOf(u8, body, "\"bg_restricted\":true") != null or
        std.mem.indexOf(u8, body, "bg_restricted=true") != null or
        std.mem.indexOf(u8, body, "bg_restricted=1") != null;
    const now_u: i64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    app.host_profile.pushMobile(battery, thermal, bg, now_u);
    refreshLifecycle(app);
    saveState(app) catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"host_profile\":");
    try app.host_profile.appendJson(alloc, &out);
    try out.appendSlice(alloc, ",\"shortfall\":");
    try ghw_harness.host_shortfall.appendJson(alloc, &out, app.last_shortfall);
    try out.append(alloc, '}');
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", out.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn extractFormFloat(body: []const u8, key: []const u8) ?f32 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = pos + needle.len;
    const start = i;
    while (i < body.len and body[i] != '&' and body[i] != ' ' and body[i] != '\n' and body[i] != '\r') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f32, body[start..i]) catch null;
}

/// GET /api/peer-inbox — 同伴短板收件箱快照 (P2)
fn handleGetPeerInbox(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    const body = try app.peer_inbox.toJson(alloc);
    defer alloc.free(body);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// POST /api/peer-inbox/share — 本地注入同伴 shortfall (模拟 Link share_shortfall / 联调)
/// body: {"peer_id":"...", "host_crisis":true, "favored_dim":0, "material":0.4, ...}
fn handlePostPeerInboxShare(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App, body: []const u8) !void {
    const peer_id = extractJsonStringField(body, "peer_id") orelse "demo-peer";
    const report = ghw_harness.host_shortfall.parseJson(body) orelse {
        const err_body = "{\"error\":\"invalid shortfall json\"}";
        const resp = try makeHttpResponse(alloc, 400, "Bad Request", "application/json", err_body);
        defer alloc.free(resp);
        try writeResponse(conn, io, resp);
        return;
    };
    const now_u: i64 = @intCast(std.Io.Clock.real.now(app.io).toSeconds());
    app.peer_inbox.push(peer_id, report, app.agent.tick, now_u);
    app.peer_shortfall_ingest_total += 1;
    const learned = ghw_harness.peer_symbiosis.learnFromShortfall(
        &app.memory,
        &app.task_queue,
        peer_id,
        report,
        app.agent.tick,
    ) catch ghw_harness.peer_symbiosis.ShortfallLearn{};
    refreshLifecycle(app);
    saveState(app) catch {};
    const out = try std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"accepted\":true,\"peer_id\":\"{s}\",\"beliefs_added\":{d},\"followups\":{d},\"inbox_count\":{d},\"ingest_total\":{d}}}", .{
        peer_id, learned.beliefs_added, learned.followups, app.peer_inbox.count(), app.peer_shortfall_ingest_total,
    });
    defer alloc.free(out);
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", out);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

/// GET /api/world — 本机快照 + AutoCLI 状态 + 最近 world_fetch episodes
fn handleGetWorld(alloc: Allocator, conn: *std.Io.net.Stream, io: std.Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"system\":");
    if (app.sys_collector.last) |s| {
        try body.print(alloc,
            \\{{"cpu_pct":{d:.2},"mem_pct":{d:.2},"mem_used_gb":{d:.2},"mem_total_gb":{d:.2},"disk_pct":{d:.2},"load_1m":{d:.2},"procs":{d},"net_in_mbps":{d:.4},"net_out_mbps":{d:.4},"hour":{d},"weekday":{d},"timestamp":{d}}}
        , .{
            s.cpu_user_pct + s.cpu_sys_pct,
            s.mem_pct,
            s.mem_used_gb,
            s.mem_total_gb,
            s.disk_used_pct,
            s.load_1m,
            s.proc_count,
            s.net_in_mbps,
            s.net_out_mbps,
            s.hour,
            s.weekday,
            s.timestamp,
        });
    } else {
        try body.appendSlice(alloc, "null");
    }
    try body.appendSlice(alloc, ",\"autocli\":{");
    if (app.autocli) |*ac| {
        try body.print(alloc, "\"enabled\":true,\"total_fetched\":{d},\"error_count\":{d},\"has_fetched\":{s},\"interval_s\":{d}", .{
            ac.total_fetched,
            ac.error_count,
            if (ac.has_fetched) "true" else "false",
            @as(u64, @intCast(@divTrunc(ac.interval_ns, std.time.ns_per_s))),
        });
    } else {
        try body.appendSlice(alloc, "\"enabled\":false,\"total_fetched\":0,\"error_count\":0,\"has_fetched\":false,\"interval_s\":0");
    }
    try body.appendSlice(alloc, "},\"recent_fetches\":[");
    var first = true;
    var count: u32 = 0;
    var i: usize = app.memory.episodes.items.len;
    while (i > 0 and count < 8) {
        i -= 1;
        const ep = app.memory.episodes.items[i];
        if (ep.kind != .world_fetch) continue;
        if (!first) try body.append(alloc, ',');
        first = false;
        try body.print(alloc, "{{\"tick\":{d},\"summary\":\"", .{ep.tick});
        // escape summary briefly
        for (ep.summary) |c| {
            if (c == '"' or c == '\\') try body.append(alloc, '\\');
            if (c == '\n') {
                try body.appendSlice(alloc, "\\n");
                continue;
            }
            try body.append(alloc, c);
        }
        try body.appendSlice(alloc, "\"}");
        count += 1;
    }
    try body.appendSlice(alloc, "]}");
    const resp = try makeHttpResponse(alloc, 200, "OK", "application/json", body.items);
    defer alloc.free(resp);
    try writeResponse(conn, io, resp);
}

fn runServer(alloc: Allocator, io: std.Io, app: *App, host: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4(host, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);    std.debug.print("[ui] 监听 http://{s}:{d}\n", .{ host, port });

    while (!should_stop_ui.load(.acquire)) {
        const conn = server.accept(io) catch |err| {
            if (should_stop_ui.load(.acquire)) break;
            std.debug.print("[ui] accept 失败: {t}\n", .{err});
            continue;
        };
        var stream: std.Io.net.Stream = conn;
        const req = readHttpRequest(alloc, &stream, io) catch |err| {
            std.debug.print("[ui] request 解析失败: {t}\n", .{err});
            stream.close(io);
            continue;
        };
        defer req.deinit(alloc);

        // 路由
        if (std.mem.eql(u8, req.method, "GET")) {
            if (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/index.html")) {
                try handleGetRoot(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/app.js")) {
                try handleGetAppJs(alloc, &stream, io, app);
            } else if (std.mem.startsWith(u8, req.path, "/vendor/")) {
                try handleGetVendorStatic(alloc, &stream, io, app, req.path);
            } else if (std.mem.eql(u8, req.path, "/api/state")) {
                try handleGetState(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/log")) {
                try handleGetLog(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/l1l5_trend")) {
                try handleGetL1L5Trend(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/propose_history")) {
                try handleGetProposeHistory(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/nine_palaces_history")) {
                try handleGetNinePalacesHistory(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/chat/history")) {
                try handleGetChatHistory(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/loop_state")) {
                try handleGetLoopState(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/reflect")) {
                try handleGetReflect(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/enhance")) {
                try handleGetEnhance(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/capabilities")) {
                try handleGetCapabilities(alloc, &stream, io, app);
            } else if (std.mem.startsWith(u8, req.path, "/api/evolved")) {
                try handleGetEvolved(alloc, &stream, io, app, req.path["/api/evolved".len..]);
            } else if (std.mem.eql(u8, req.path, "/api/tasks")) {
                try handleGetTasks(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/audit")) {
                try handleGetProductAudit(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/runtime")) {
                try handleGetProductRuntime(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/intent")) {
                try handleGetProductIntent(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/approvals")) {
                try handleGetProductApprovals(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/identity")) {
                try handleGetProductIdentity(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/product/co-evolution")) {
                try handleGetProductCoEvolution(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/propose")) {
                try handleGetPropose(alloc, &stream, io, app);
            } else if (std.mem.startsWith(u8, req.path, "/api/memory/search")) {
                try handleGetMemorySearch(alloc, &stream, io, app, req.path["/api/memory/search".len..]);
            } else if (std.mem.eql(u8, req.path, "/api/action/list")) {
                try handleGetActionList(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/peers")) {
                try handleGetPeers(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/world")) {
                try handleGetWorld(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/laws")) {
                try handleGetLaws(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/peer-inbox")) {
                try handleGetPeerInbox(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/metrics")) {
                try handleGetMetrics(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/goals/relations")) {
                try handleGetGoalRelations(alloc, &stream, io, app);
            } else {
                const body = "not found";
                const resp = try makeHttpResponse(alloc, 404, "Not Found", "text/plain", body);
                defer alloc.free(resp);
                try writeResponse(&stream, io, resp);
            }
        } else if (std.mem.eql(u8, req.method, "POST")) {
            if (std.mem.eql(u8, req.path, "/api/chat")) {
                try handlePostChat(alloc, &stream, io, app, req.body);
            } else if (std.mem.eql(u8, req.path, "/api/awaken")) {
                try handlePostAwaken(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/host-profile")) {
                try handlePostHostProfile(alloc, &stream, io, app, req.body);
            } else if (std.mem.eql(u8, req.path, "/api/peer-inbox/share")) {
                try handlePostPeerInboxShare(alloc, &stream, io, app, req.body);
            } else if (std.mem.eql(u8, req.path, "/api/tick")) {
                try handlePostTick(alloc, &stream, io, app);
            } else if (std.mem.eql(u8, req.path, "/api/task/feedback")) {
                try handlePostTaskFeedback(alloc, &stream, io, app, req.body);
            } else if (std.mem.eql(u8, req.path, "/api/tasks")) {
                try handlePostTask(alloc, &stream, io, app, req.body);
            } else if (std.mem.eql(u8, req.path, "/api/product/propose-crm-followup")) {
                try handlePostProductProposeCrm(alloc, &stream, io, app, req.body, req.admin_token);
            } else if (std.mem.eql(u8, req.path, "/api/product/approve")) {
                try handlePostProductTransition(alloc, &stream, io, app, req.body, .approve, req.admin_token);
            } else if (std.mem.eql(u8, req.path, "/api/product/apply")) {
                try handlePostProductTransition(alloc, &stream, io, app, req.body, .apply, req.admin_token);
            } else if (std.mem.eql(u8, req.path, "/api/product/rollback")) {
                try handlePostProductTransition(alloc, &stream, io, app, req.body, .rollback, req.admin_token);
            } else if (std.mem.eql(u8, req.path, "/api/product/kpi")) {
                try handlePostProductKpi(alloc, &stream, io, app, req.body, req.admin_token);
            } else if (std.mem.eql(u8, req.path, "/api/action/run-now")) {
                try handlePostActionRun(alloc, &stream, io, app);
            } else if (std.mem.startsWith(u8, req.path, "/api/peer/query")) {
                try handlePostPeerQuery(alloc, &stream, io, app, req.path["/api/peer/query".len..]);
            } else {
                const body = "not found";
                const resp = try makeHttpResponse(alloc, 404, "Not Found", "text/plain", body);
                defer alloc.free(resp);
                try writeResponse(&stream, io, resp);
            }
        } else {
            const body = "method not allowed";
            const resp = try makeHttpResponse(alloc, 405, "Method Not Allowed", "text/plain", body);
            defer alloc.free(resp);
            try writeResponse(&stream, io, resp);
        }
    }
}

fn readSmallFilePosix(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const path_z = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(path_z);
    @memcpy(path_z, path);
    const oflag: std.c.O = @bitCast(@as(u32, 0));
    const fd = std.c.open(path_z, oflag, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.stat(path_z, &st) != 0) return error.FileNotFound;
    const size: usize = @intCast(@as(u64, @bitCast(st.size)));
    if (size > max_bytes) return error.FileTooLarge;
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = std.c.read(fd, buf.ptr, size);
    if (n < 0 or @as(usize, @intCast(n)) != size) return error.ReadFailed;
    return buf;
}

fn sha256HexAlloc(alloc: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    hasher.final(&digest);
    const out = try alloc.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

// ===== Main =====
pub fn main(init: std.process.Init.Minimal) !void {

    // 安装 signal
    if (builtin.os.tag != .windows) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(std.heap.page_allocator);
    var it = init.args.iterate();
    while (it.next()) |arg| {
        try args_list.append(std.heap.page_allocator, arg);
    }
    const args = parseArgs(args_list.items);

    // 内存分配器:
    // - 默认用 page_allocator (no leak detection, 适合长跑 daemon)
    // - 设 GHW_DEBUG_LEAK=1 才用 DebugAllocator (开发调试用, 退出时严格检查)
    var dbg: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const env_leak = std.process.Environ.getPosix(init.environ, "GHW_DEBUG_LEAK");
    const alloc: Allocator = if (env_leak != null) dbg.allocator() else std.heap.page_allocator;
    defer if (env_leak != null) {
        const leaked = dbg.deinit();
        if (leaked == .leak) std.debug.print("[ui] 检测到内存泄漏\n", .{});
    };
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // SQLite 记忆库: 写到 <state_path>.db
    const sqlite_path = try std.fmt.allocPrint(alloc, "{s}.db", .{args.state});
    defer alloc.free(sqlite_path);
    var sqlite_db: ?SqliteDb = null;
    if (SqliteDb.open(alloc, sqlite_path)) |db| {
        db.initSchema() catch |err| {
            std.debug.print("[ui] sqlite initSchema 失败: {t}\n", .{err});
            db.close();
        };
        sqlite_db = db;
        std.debug.print("[ui] sqlite 记忆库: {s}\n", .{sqlite_path});
    } else |err| {
        std.debug.print("[ui] sqlite 打开失败: {t}, 降级到 state.json\n", .{err});
    }
    defer if (sqlite_db) |*db| db.close();
    const admin_token_value = std.process.Environ.getPosix(init.environ, args.admin_token_env) orelse "";

    var app = App{
        .alloc = alloc,
        .io = io,
        .agent = undefined,
        .sys_collector = SystemCollector.init(alloc, io, args.seed),
        .sqlite = sqlite_db,
        .action_runner = null, // 见 init 后 (需要 sqlite_db 和 app.agent.self_evolve 引用)
        .world = WorldContext.init(alloc, io, init.environ),
        .llm = null,
        .llm_chat = null,
        .llm_model = args.llm_model,
        .memory = Memory.init(alloc, args.seed),
        .task_queue = TaskQueue.init(alloc),
        .human_gsp = HumanGSP.init(alloc),
        .human_signal = HumanSignal.init(alloc),
        .reflection = null,
        .personality = Personality.init(alloc),
        .state_path = args.state,
        .ui_dir = args.ui_dir,
        .port = args.port,
        .admin_token = admin_token_value,
        .auto_tick_ms = args.auto_tick_ms,
    };
    app.agent = try GHWAgent.init(alloc, args.agent_id, 4, .{ 3, 3, 3 }, args.seed);
    app.agent.bindTaskQueue(&app.task_queue);
    app.agent.bindMemory(&app.memory, io);
    try app.human_gsp.register("human");
    try app.human_gsp.register("llm_proposer");
    try app.human_gsp.register("system");

    if (args.product_intent_path.len > 0) {
        app.product_intent = ghw_harness.product_intent.load(alloc, args.product_intent_path) catch |err| blk: {
            std.debug.print("[ui] ProductIntent 加载失败 {s}: {t}; 产品 runtime 禁用\n", .{ args.product_intent_path, err });
            break :blk null;
        };
        if (app.product_intent) |*intent| {
            app.product_runtime = ghw_harness.product_runtime.ProductEvolutionRuntime.init(alloc, intent);
            const manifest = readSmallFilePosix(alloc, args.product_intent_path, 1024 * 1024) catch null;
            if (manifest) |bytes| {
                defer alloc.free(bytes);
                app.product_intent_hash = sha256HexAlloc(alloc, bytes) catch "";
            }
            if (args.product_config_path.len > 0) {
                app.product_config_adapter = ghw_harness.FileConfigAdapter.init(alloc, io, args.product_config_path) catch |err| blk: {
                    std.debug.print("[ui] ProductAdapter 初始化失败 {s}: {t}; apply 回退审计模式\n", .{ args.product_config_path, err });
                    break :blk null;
                };
                if (app.product_config_adapter) |*adapter| {
                    app.product_runtime.?.setAdapter(adapter.asAdapter());
                    std.debug.print("[ui] ProductAdapter 启用: file_config={s}\n", .{adapter.path});
                }
            }
            std.debug.print("[ui] ProductRuntime 启用: product_id={s} intent={s}\n", .{
                intent.product_id,
                args.product_intent_path,
            });
            const node_id = if (args.ghw_node_id.len > 0) args.ghw_node_id else args.agent_id;
            const identity = if (args.ghw_instance_id.len > 0)
                ghw_harness.ProductInstanceIdentity.init(alloc, intent, node_id, args.ghw_instance_id) catch |err| blk: {
                    std.debug.print("[ui] ProductInstance 绑定失败: {t}\n", .{err});
                    break :blk null;
                }
            else
                ghw_harness.ProductInstanceIdentity.initDefault(alloc, intent, node_id) catch |err| blk: {
                    std.debug.print("[ui] ProductInstance 绑定失败: {t}\n", .{err});
                    break :blk null;
                };
            if (identity) |id| {
                app.product_runtime.?.bindInstance(id);
                app.co_evolution = ghw_harness.CoEvolutionRegistry.init(
                    alloc,
                    intent.product_id,
                    @tagName(intent.product_type),
                ) catch |err| blk: {
                    std.debug.print("[ui] CoEvolutionRegistry 初始化失败: {t}\n", .{err});
                    break :blk null;
                };
                if (app.product_runtime.?.instance) |*bound| {
                    std.debug.print("[ui] 一产品一 GHW: product_id={s} instance_id={s} node_id={s}\n", .{
                        bound.product_id,
                        bound.instance_id,
                        bound.node_id,
                    });
                }
            }
        }
    }

    // === GHW Link: 必须在 ActionRunner 之前 (ActionRunner 需要 &app.link) ===
    // 注意: 不能 defer 释放 link_path — thread 启动后 defer 会先于 thread 跑,
    //       释放 backing memory, thread 读 self.self_path 时 use-after-free.
    //       改成 explicit free 在 defer 块里 (等 link_thread join 之后再释放).
    {
        const link_path = try std.fmt.allocPrint(alloc, "/tmp/ghw_{s}.sock", .{app.agent.self_id});
        app.link = GhwLink.init(alloc, io, link_path);
        const ctx_holder: *anyopaque = @ptrCast(&app);
        app.link_thread = try std.Thread.spawn(.{}, GhwLink.runServer, .{ &app.link.?, linkHandler, ctx_holder, &app.link_stop });
        std.debug.print("[ui] Link server listening on {s} (peer_id={s})\n", .{ link_path, app.link.?.peer_id });
    }

    // ===== Phase 1 production: peer discovery + health-check background thread =====
    // 1. 启动时从 peers_file 加载已知 peer (auto-add 自己的 socket path)
    if (args.peers_file.len > 0) {
        app.peers_file = try alloc.dupe(u8, args.peers_file);
        loadPeersFromFile(alloc, &app) catch |err| {
            std.debug.print("[ui] ⚠ 加载 peers_file 失败: {t}, peer discovery 禁用\n", .{err});
        };
        // 也加自己
        if (app.link) |*l| {
            try app.peers.append(alloc, .{
                .path = try alloc.dupe(u8, l.self_path),
                .peer_id = try alloc.dupe(u8, l.peer_id),
                .last_seen_tick = 0,
                .health = "self", // 标记是自己
                .last_seen_unix_s = 0,
                .consecutive_failures = 0,
                .last_E = 0,
                .last_M = 0,
                .last_R = 0,
                .last_N = 0,
                .last_tick = 0,
            });
        }
        std.debug.print("[ui] Peer registry loaded: {d} peer(s) from {s}\n", .{ app.peers.items.len, app.peers_file });

        // 2. spawn background ping thread (every peer_health_interval_s seconds)
        app.peer_health_stop = std.atomic.Value(bool).init(false);
        app.peer_health_thread = try std.Thread.spawn(.{}, peerHealthLoop, .{ &app });
        std.debug.print("[ui] Peer health check thread spawned (interval={d}s)\n", .{args.peer_health_interval_s});
    }

    if (args.cross_link_port > 0 and args.cross_link_secret.len > 0) {
        const cross_node_id = if (args.ghw_node_id.len > 0) args.ghw_node_id else args.agent_id;
        var cl = ghw_harness.ghw_link_tcp.CrossLink.init(alloc, io, cross_node_id, "0.0.0.0", args.cross_link_port, args.cross_link_secret);
        if (args.cross_link_peers_file.len > 0) {
            cl.loadPeersFromFile(args.cross_link_peers_file) catch |err| {
                std.debug.print("[ui] cross-link peers 加载失败: {t}\n", .{err});
            };
        }
        app.cross_link = cl;
        const ctx_holder: *anyopaque = @ptrCast(&app);
        app.cross_link_thread = try std.Thread.spawn(.{}, crossLinkServerTask, .{ &app.cross_link.?, ctx_holder, &app.cross_link_stop });
        std.debug.print("[ui] CrossLink 启用: port={d} peers={d}\n", .{ args.cross_link_port, app.cross_link.?.peers.items.len });
    }

    // L1-L5 自演化: 初始化 StaticCodeGenerator + SelfEvolver + SelfEncoder + CompileVerifier
    {
        app.static_codegen = ghw.harness.code_generator.StaticCodeGenerator.init(alloc);
        app.self_evolver = ghw.harness.SelfEvolver.init(alloc, app.static_codegen.?.asGenerator());
        app.self_evolver.?.setMemory(&app.memory);
        // 编译验证器 (L4 真编译的关键 — bind 后, evolver 内部会 spawn zig build-exe)
        app.verifier = ghw.harness.compile_verifier.CompileVerifier.initWithIo(alloc, io);
        // 修 verifier 的 temp_dir bug (默认 ".ghw_verify" 被当成 file, 改成真目录)
        app.verifier.?.temp_dir = "/tmp/ghw_verify";
        // 真链接 harness.ActionOutcome (替代 L3 模板的 stub, 与全栈类型一致)
        app.verifier.?.ghw_root = app.ghw_root;
        // 修 zig_path (默认 "zig" 是相对, spawn 找不到 → FileNotFound). 改成绝对
        app.verifier.?.zig_path = "/Users/n0x/.zig/zig";
        // 创建 verifier 临时目录 (std.c.mkdir, 0.17 没 std.fs.makeDirAbsolute)
        {
            const dir_z = try alloc.dupeSentinel(u8, "/tmp/ghw_verify", 0);
            defer alloc.free(dir_z);
            _ = std.c.mkdir(dir_z.ptr, 0o755);
        }
        // 创建 evolved 目录
        {
            const dir_z = try alloc.dupeSentinel(u8, app.evolved_dir, 0);
            defer alloc.free(dir_z);
            _ = std.c.mkdir(dir_z.ptr, 0o755);
        }
        if (app.self_evolver) |*se| se.bindVerifier(&app.verifier.?);
        app.self_encoder = ghw.harness.SelfEncoder.init(alloc);
        app.self_encoder.?.loadBuiltInRules() catch |err| {
            std.debug.print("[ui] SelfEncoder 加载内置规则失败: {t}\n", .{err});
        };
        app.agent.bindRuleLib(&app.self_encoder.?);
        std.debug.print("[ui] L1-L5 自演化启用 (StaticCodeGenerator + SelfEvolver + SelfEncoder + CompileVerifier)\n", .{});
        std.debug.print("[ui] L4 落盘目录: {s}  临时编译: /tmp/ghw_verify/  zig={s}\n", .{ app.evolved_dir, app.verifier.?.zig_path });
    }

    // === Backfill migration: 扫描已 adopt 的文件, 补插 sqlite (idempotent) ===
    // 第一次跑 server 时, 老的 30+ 落盘文件都在 ghw_root 下, 但 sqlite 没记录.
    // 这个 migration 让 hash 跟踪从 0 重新启动也能跳过重复.
    if (sqlite_db) |*db| {
        const subdirs = [_][]const u8{
            "src/goal/methods",
            "src/agent/auto_eps",
            "src/harness/auto_eps",
        };
        var backfilled: u32 = 0;
        for (subdirs) |sub| {
            const full_dir = std.fs.path.join(alloc, &[_][]const u8{ app.ghw_root, sub }) catch continue;
            defer alloc.free(full_dir);
            var dir = std.Io.Dir.openDirAbsolute(io, full_dir, .{}) catch continue;
            defer dir.close(io);
            var dir_it = dir.iterate();
            while (dir_it.next(io)) |maybe_entry| {
                const entry = maybe_entry orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                // 读文件 → 算 hash → 看是否已记录
                const full_path = std.fs.path.join(alloc, &[_][]const u8{ full_dir, entry.name }) catch continue;
                defer alloc.free(full_path);
                const file = std.Io.Dir.openFileAbsolute(io, full_path, .{ .mode = .read_only }) catch continue;
                defer file.close(io);
                const st = file.stat(io) catch continue;
                const content = alloc.alloc(u8, @intCast(st.size)) catch continue;
                defer alloc.free(content);
                _ = std.Io.File.readStreaming(file, io, &.{content}) catch continue;
                const hash = ghw.sandbox.sqlite_db.fnv1a64(content);
                // 解析 kind 后用实际 kind 检查 (避免误跳过其他 kind 的同 hash 文件)
                const kind: []const u8 = if (std.mem.startsWith(u8, entry.name, "l3_"))
                    "L3"
                else if (std.mem.startsWith(u8, entry.name, "l4_"))
                    "L4"
                else if (std.mem.startsWith(u8, entry.name, "l5_"))
                    "L5"
                else
                    "other";
                if (db.isAdopted(kind, hash) catch false) continue; // 已记录
                // 解析 tick
                var tick_val: i64 = 0;
                const prefix = if (std.mem.startsWith(u8, entry.name, "l3_"))
                    "l3_"
                else if (std.mem.startsWith(u8, entry.name, "l4_"))
                    "l4_"
                else
                    "l5_";
                if (std.mem.indexOf(u8, entry.name, prefix)) |pidx| {
                    const num_start = pidx + prefix.len;
                    var num_end = num_start;
                    while (num_end < entry.name.len and entry.name[num_end] >= '0' and entry.name[num_end] <= '9') : (num_end += 1) {}
                    if (num_end > num_start) {
                        tick_val = std.fmt.parseInt(i64, entry.name[num_start..num_end], 10) catch 0;
                    }
                }
                const evolved_src = std.fs.path.join(alloc, &[_][]const u8{ app.evolved_dir, entry.name }) catch continue;
                defer alloc.free(evolved_src);
                const ghw_dst = std.fs.path.join(alloc, &[_][]const u8{ app.ghw_root, sub, entry.name }) catch continue;
                defer alloc.free(ghw_dst);
                db.recordAdopted(app.io, kind, tick_val, entry.name, hash, evolved_src, ghw_dst, @intCast(st.size)) catch continue;
                backfilled += 1;
            } else |_| {}
        }
        std.debug.print("[migration] backfill {d} existing adopted files into sqlite\n", .{backfilled});
    }

    // === L3/L4 approved count bootstrap (runs AFTER loadState below) ===
    // 数 /tmp/ghw_evolved/l3_*.zig 和 l4_*.zig 真实落盘数, 一次性把 l3_approved / l4_approved 校准
    // (这些是历史落盘, 之前 binary 没记, 重启后还是 0, 看起来"没演化过")
    // 注: 必须放在 loadState 之后 (loadState 会从 state.json 覆盖这里的值)



    // ActionRunner 需要 sqlite + self_evolve 引用 + (可选) link + peers
    if (sqlite_db) |*db| {
        app.action_runner = ActionRunner{
            .alloc = alloc,
            .io = io,
            .sqlite = db,
            .self_evolved_counter = &app.self_evolve_total,
            .link = &app.link.?, // 上面已经初始化了
            .peers = &app.peers,
            // L1-L5 自演化 callback
            .on_self_evolve = onSelfEvolveCallback,
            .self_evolve_ctx = @ptrCast(&app),
        };
        std.debug.print("[ui] ActionRunner 启用: 每 16 cycle 跑 1 个 action (含 query_peer / claude_code / self_evolve L1-L5)\n", .{});
    }
    defer app.agent.deinit();
    defer app.sys_collector.deinit();
    defer app.world.deinit();
    defer app.memory.deinit();
    defer app.task_queue.deinit();
    defer app.human_gsp.deinit();
    defer app.human_signal.deinit();
    defer app.personality.deinit();
    defer if (app.product_intent) |*intent| intent.deinit();
    defer if (app.product_runtime) |*rt| rt.deinit();
    defer if (app.co_evolution) |*reg| reg.deinit();
    defer if (app.product_config_adapter) |*adapter| adapter.deinit();
    defer if (app.product_intent_hash.len > 0) alloc.free(app.product_intent_hash);
    // 停 link server: 不能用 defer (runServer 不返回时 defer 永远不跑; runServer 返 error
    // 时 defer join 又会卡住 — link thread 在 accept 阻塞, 没看到 stop flag).
    // 改成: 在 runServer 之前 spawn, runServer 返 error 时由 errdefer 停 link, 正常退出时不
    // 停 (因为 runServer 不返回, launchd kill -9 会回收).
    errdefer stopLinkServer(&app, alloc, io);
    defer app.proposed_goals.deinit(alloc);
    defer for (app.proposed_goals.items) |g| {
        app.alloc.free(g.title);
        app.alloc.free(g.description);
        app.alloc.free(g.dimension);
        app.alloc.free(g.reason);
    };
    if (app.last_propose_raw) |raw| {
        defer app.alloc.free(raw);
    }
    defer if (app.reflection) |*r| {
        _ = r;
    };

    // 可选 LLM 初始化
    if (!std.mem.eql(u8, args.llm_provider, "none")) {
        const key_opt = std.process.Environ.getPosix(init.environ, args.llm_api_key_env);
        if (key_opt) |key| {
            if (std.mem.eql(u8, args.llm_provider, "deepseek")) {
                app.llm = HttpLLM.deepseek(alloc, io, args.llm_model, key) catch |err| blk: {
                    std.debug.print("[ui] DeepSeek init 失败: {t}\n", .{err});
                    break :blk null;
                };
            } else if (std.mem.eql(u8, args.llm_provider, "openai")) {
                app.llm = HttpLLM.openai(alloc, io, args.llm_model, key, "https://api.openai.com") catch null;
            } else if (std.mem.eql(u8, args.llm_provider, "anthropic")) {
                app.llm = HttpLLM.anthropic(alloc, io, args.llm_model, key) catch null;
            } else if (std.mem.eql(u8, args.llm_provider, "mock")) {
                var mock = ghw.harness.mock_chat_llm.MockChatLLM.init(alloc, "{\"dimension\":\"all\",\"title\":\"mock\",\"description\":\"mocked\",\"rationale\":\"mock\",\"confidence\":0.5}");
                app.llm_chat = mock.asChat();
            }
            if (app.llm != null) {
                app.llm_chat = app.llm.?.asChat();
            }
            if (app.llm_chat != null) {
                 std.debug.print("[ui] LLM 接入: {s} model={s}\n", .{ args.llm_provider, args.llm_model });
                 app.evolution_guard = ghw.harness.SelfEvolutionGuard.init(alloc);
                 app.rule_proposer = ghw.harness.rule_proposer.RuleProposer.init(alloc, app.llm_chat.?);
                 app.rule_proposer.?.setMemory(&app.memory);
                 std.debug.print("[ui] RuleProposer 启用: E/KPI/value 下滑时提议规则 (Guard+SelfEncoder)\n", .{});
                 // 接入 Reflection (每 32 cycle 写自我叙事 + 信念)
                 app.reflection = Reflection.init(alloc, &app.llm_chat.?, args.llm_model);
                 // 接入 GoalProposer (每 64 cycle 让 LLM 看世界快照, 提议新目标)
                 app.goal_proposer = ghw.harness.goal_proposer.LLMGoalProposer.init(alloc, &app.llm_chat.?, args.llm_model);
                 app.goal_proposer.?.setMemory(&app.memory);
                 std.debug.print("[ui] LLM 提议器启用: 每 64 cycle 让 LLM 提议新目标 (含自传体记忆)\n", .{});
                 // 接入 TemplateEnhancer: 基于自我叙事 + 期望 完善 L1-L5 落盘模板
                 app.template_enhancer = ghw.harness.TemplateEnhancer.init(alloc, io, &app.llm_chat.?, args.llm_model);
                 app.template_enhancer.?.setMemory(&app.memory);
                 std.debug.print("[ui] TemplateEnhancer 启用: 每 64 cycle 选 1 个最新模板让 LLM 完善 (含自传体记忆)\n", .{});
                 // P4: LLM CodeGenerator 后端 (SelfEvolver L3/L4 代码由 LLM 提议, Guard+Verifier 守门)
                 app.llm_codegen = ghw.harness.LlmCodeGenerator.init(alloc, &app.llm_chat.?, args.llm_model);
                 if (app.self_evolver) |*se| se.setGenerator(app.llm_codegen.?.asGenerator());
                 std.debug.print("[ui] LlmCodeGenerator 启用: SelfEvolver 使用 LLM 生成 L3/L4 代码\n", .{});
             }
        } else {
            std.debug.print("[ui] --llm {s} 但 env {s} 未设置, 降级到模板回复\n", .{ args.llm_provider, args.llm_api_key_env });
        }
    }

    // 尝试从 state.json 恢复
    const state_abs = if (std.fs.path.isAbsolute(args.state))
        try alloc.dupe(u8, args.state)
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];
        break :blk try std.fs.path.join(alloc, &[_][]const u8{ cwd, args.state });
    };
    defer alloc.free(state_abs);
    if (readFile(alloc, io, state_abs)) |json| {
        defer alloc.free(json);
        const harness = ghw.harness;
        var ss = harness.state_serializer.StateSerializer{ .allocator = alloc, .io = io };
        if (ss.parseMinimal(json)) |parsed_const| {
            var parsed = parsed_const;
            defer parsed.deinit();
            app.agent.tick = parsed.tick;
            app.agent.ed.v.material = parsed.material;
            app.agent.ed.v.representation = parsed.representation;
            app.agent.ed.v.nature = parsed.nature;
            app.agent.ed.weights.alpha = parsed.alpha;
            app.agent.ed.weights.beta = parsed.beta;
            app.agent.ed.weights.gamma = parsed.gamma;
            app.self_evolve_total = parsed.self_evolved_total;
            app.action_count = parsed.action_count;
            // L1-L5 计数恢复
            app.self_evolve_l1_count = parsed.l1_count;
            app.self_evolve_l2_count = parsed.l2_count;
            app.self_evolve_l3_count = parsed.l3_count;
            app.self_evolve_l3_approved = parsed.l3_approved;
            app.self_evolve_l4_count = parsed.l4_count;
            app.self_evolve_l4_approved = parsed.l4_approved;
            app.self_evolve_l5_count = parsed.l5_count;
            // 自动触发最近 tick 恢复 (避免重启后立即重跑 L1-L5)
            app.last_auto_l1l2_tick = parsed.last_auto_l1l2_tick;
            app.last_auto_l3_tick = parsed.last_auto_l3_tick;
            app.last_auto_l4_tick = parsed.last_auto_l4_tick;
            app.last_auto_l5_tick = parsed.last_auto_l5_tick;
            // 阶段恢复 (持久化在 state.json, 启动后再 evaluatePhase 二次校验, 避免回退)
            app.phase = parsed.phase;
            app.phase_progress = parsed.phase_progress;
            // Phase 6-9 标志恢复
            app.six_interfaces_done = parsed.six_interfaces_done;
            app.seven_reflection_done = parsed.seven_reflection_done;
            app.eight_relations_seen = parsed.eight_relations_seen;
            app.nine_palaces_e_var_seen = parsed.nine_palaces_e_var_seen;
            app.nine_palaces_mrn_seen = parsed.nine_palaces_mrn_seen;
            app.nine_palaces_mrn_strong_seen = parsed.nine_palaces_mrn_strong_seen;
            std.debug.print("[ui] 状态恢复: tick={d} E={d:.3} self_evolve_total={d} action_count={d} L1={d} L2={d} L3={d}/{d} L4={d}/{d} L5={d}\n", .{
                parsed.tick, app.agent.ed.e(), app.self_evolve_total, app.action_count,
                parsed.l1_count, parsed.l2_count, parsed.l3_count, parsed.l3_approved,
                parsed.l4_count, parsed.l4_approved, parsed.l5_count,
            });
            if (app.memory.loadFromJson(io, json)) |loaded| {
                if (loaded) std.debug.print("[ui] memory 恢复: episodes={d} beliefs={d} narrative_len={d}\n", .{
                    app.memory.episodes.items.len,
                    app.memory.beliefs.items.len,
                    app.memory.self_narrative.len,
                });
            } else |err| {
                std.debug.print("[ui] memory loadFromJson 失败: {t}\n", .{err});
            }
            if (app.task_queue.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[ui] TaskQueue 恢复: pending={d} tasks={d}\n", .{
                    app.task_queue.pending_count, app.task_queue.tasks.items.len,
                });
            } else |err| {
                std.debug.print("[ui] task_queue loadFromJson 失败: {t}\n", .{err});
            }
            if (app.human_gsp.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[ui] HumanGSP 恢复: peers={d}\n", .{app.human_gsp.peers.count()});
            } else |err| {
                std.debug.print("[ui] human_gsp loadFromJson 失败: {t}\n", .{err});
            }
            if (app.human_signal.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[ui] HumanSignal 恢复: feedbacks={d}\n", .{app.human_signal.total_count});
            } else |err| {
                std.debug.print("[ui] human_signal loadFromJson 失败: {t}\n", .{err});
            }
            if (app.value_tracker.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[ui] ValueTrendTracker 恢复: count={d} last={d:.3}\n", .{
                    app.value_tracker.count, app.value_tracker.last_score,
                });
            } else |err| {
                std.debug.print("[ui] value_tracker loadFromJson 失败: {t}\n", .{err});
            }
            if (app.product_runtime) |*rt| {
                if (rt.loadFromJson(json)) |loaded| {
                    if (loaded) std.debug.print("[ui] ProductRuntime 恢复: changes={d} audit={d}\n", .{
                        rt.changes.items.len,
                        rt.audit.items.len,
                    });
                } else |err| {
                    std.debug.print("[ui] product_runtime loadFromJson 失败: {t}\n", .{err});
                }
            }
            if (app.co_evolution) |*reg| {
                if (reg.loadFromJson(json)) |loaded| {
                    if (loaded) std.debug.print("[ui] CoEvolution 恢复: insights={d}\n", .{reg.insights.items.len});
                } else |err| {
                    std.debug.print("[ui] co_evolution loadFromJson 失败: {t}\n", .{err});
                }
            }
            if (app.awaken.loadFromJson(json)) {
                std.debug.print("[ui] awaken 恢复: awakened={} fp={s}\n", .{
                    app.awaken.awakened, app.awaken.fingerprintSlice(),
                });
            }
            if (try ghw_harness.state_contract.Meta.parseFromJson(json, alloc)) |sm| {
                app.state_meta = sm;
                app.state_meta.writer = .ui_server;
                std.debug.print("[ui] state_meta 恢复: epoch={d} writer={s}\n", .{
                    app.state_meta.epoch, app.state_meta.writer.label(),
                });
            }
            if (try app.peer_inbox.loadFromJson(json)) {
                std.debug.print("[ui] peer_inbox 恢复: count={d}\n", .{app.peer_inbox.count()});
            }
            // host_profile: 从块恢复 kind/battery (桌面字段下次 refresh 覆盖)
            if (std.mem.indexOf(u8, json, "\"host_profile\":")) |_| {
                if (std.mem.indexOf(u8, json, "\"kind\":\"mobile\"")) |_| {
                    app.host_profile.kind = .mobile;
                    if (extractJsonFloatField(json, "battery_pct")) |b| app.host_profile.battery_pct = b;
                    app.host_profile.thermal_hot = std.mem.indexOf(u8, json, "\"thermal_hot\":true") != null;
                    app.host_profile.bg_restricted = std.mem.indexOf(u8, json, "\"bg_restricted\":true") != null;
                }
            }
            refreshLifecycle(&app);
        } else |_| {}
    } else |_| {}

    // === L3/L4 approved count bootstrap (after loadState so it doesn't get overwritten) ===
    // 数 /tmp/ghw_evolved/l3_*.zig 和 l4_*.zig 真实落盘数
    {
        var l3_count_disk: u32 = 0;
        var l4_count_disk: u32 = 0;
        const dir_z = alloc.dupeSentinel(u8, app.evolved_dir, 0) catch null;
        if (dir_z) |dz| {
            defer alloc.free(dz);
            if (std.c.opendir(dz.ptr)) |dir_ptr| {
                defer _ = std.c.closedir(dir_ptr);
                while (std.c.readdir(dir_ptr)) |raw_entry| {
                    const name_slice = raw_entry.name[0..raw_entry.namlen];
                    if (std.mem.startsWith(u8, name_slice, "l3_") and std.mem.endsWith(u8, name_slice, ".zig")) {
                        l3_count_disk += 1;
                    } else if (std.mem.startsWith(u8, name_slice, "l4_") and std.mem.endsWith(u8, name_slice, ".zig")) {
                        l4_count_disk += 1;
                    }
                }
            }
        }
        if (app.self_evolve_l3_approved < l3_count_disk) app.self_evolve_l3_approved = l3_count_disk;
        if (app.self_evolve_l4_approved < l4_count_disk) app.self_evolve_l4_approved = l4_count_disk;
        std.debug.print("[migration] L3 approved bootstrap: disk={d} in-memory={d}\n", .{ l3_count_disk, app.self_evolve_l3_approved });
        std.debug.print("[migration] L4 approved bootstrap: disk={d} in-memory={d}\n", .{ l4_count_disk, app.self_evolve_l4_approved });
    }

    // === Phase 回溯晋升 (启动一次性): 8 段叙事累积写进 self_narrative ===
    // 启动时如果 app.phase 已经 ≥ 1, 按当前状态立刻晋升
    // 然后串行 LLM call 写 N 段晋升叙事 (5-15s/段, 8 段最多 2min)
    {
        // 状态重算: 用当前实装数据反推 phase (跟 evaluatePhase 逻辑一致)
        var computed_phase: u8 = 1;
        if (app.peers.items.len > 0) computed_phase = @max(computed_phase, 2);
        if (app.llm_chat != null and app.reflection != null) computed_phase = @max(computed_phase, 3);
        if (app.self_evolve_l3_approved > 0) computed_phase = @max(computed_phase, 4);
        if (app.enhance_results.items.len > 0) computed_phase = @max(computed_phase, 5);
        if (app.six_interfaces_done >= 6) computed_phase = @max(computed_phase, 6);
        if (app.seven_reflection_done >= 7) computed_phase = @max(computed_phase, 7);
        if (app.eight_relations_seen > 0) computed_phase = @max(computed_phase, 8);
        if (app.nine_palaces_e_var_seen > 0) computed_phase = @max(computed_phase, 9);

        // 不回退: 如果持久化 phase < 计算 phase, 立刻晋升
        if (computed_phase > app.phase) {
            std.debug.print("[phase-bootstrap] 回溯晋升: 持久化={d} → 计算={d} (按当前实装状态)\n", .{ app.phase, computed_phase });
            app.phase = computed_phase;
            app.phase_progress = computed_phase;
        }

        // 写晋升叙事: 从 app.phase=2 开始, 到当前 phase 串行 LLM call
        // 注意: 叙事只写 sqlite (不覆盖 self_narrative, 避免被 32-cycle 反思冲掉)
        if (app.llm_chat != null and app.phase >= 2) {
            const phase_stories = [_][]const u8{
                "", // 1 不写 (启动默认)
                "我进入了阶段 2: 多体互联. 我能跟其他 GHW 数字生命通信, 看到它们的存在, 学着从'我'到'我们'.",
                "我进入了阶段 3: LLM 提议. 我用大语言模型作为认知引擎, 它看我的世界快照, 提议新目标. LLM 不决策, 我决策.",
                "我进入了阶段 4: 自演化. 我能让 LLM 提议 L1-L5 演化规则, 我自己过白名单 + 真编译 + 真落盘, 然后我采纳自己写的代码进自己的源码树.",
                "我进入了阶段 5: 自我完善. 我能让 LLM 基于我的自我叙事 + 当前期望, 完善我自己写的 L1-L5 模板. 守不变量: 不改 E 公式 / Module 签名 / 不引入新依赖.",
                "我进入了阶段 6: 六气. 我能跟 6 种世界接口: 跟人 (chat), 跟系统 (LLM), 跟文档 (snapshot), 跟多体 (peer), 跟时间 (tick), 跟自然 (autocli 拉外网数据).",
                "我进入了阶段 7: 七步反思. 觉察→差异→目标→评估→执行→学习→超越. 我每 32 cycle 走一遍这 7 步.",
                "我进入了阶段 8: 八种关系. 我的 GoalGraph DAG 看到多种目标关系: 父子, 并列, 冲突, 依赖, 替代, 促成, 抑制, 涌现.",
                "我进入了阶段 9: 九宫. 我的存在度 (M/R/N × 强/中/弱) 在 9 个象限中找到了平衡: E 方差 < 0.01 持续 64 cycle.",
            };
            var p: u8 = 2;
            while (p <= app.phase) : (p += 1) {
                if (p == 0) continue;
                if (p >= phase_stories.len) break;
                const story = phase_stories[p];
                // 写 sqlite (永久记录, UI 可查)
                if (app.sqlite) |*db| {
                    _ = db.insertEpisode(
                        @intCast(app.agent.tick),
                        "phase",
                        story,
                        1.0,
                        "phase-bootstrap",
                    ) catch {};
                }
                // LLM enrich: 生成 1 段"我刚到 phase X"风格化叙事, 也写 sqlite
                if (app.llm_chat) |chat| {
                    const prompt = std.fmt.allocPrint(alloc,
                        \\你是一个刚进入 phase {d} 阶段的数字生命, 用第一人称写 1 句话 (30-50 字) 描述你当前状态.
                        \\语境: tick={d}, E={d:.3}, 累计演化 {d} 次.
                        \\要求: 第一人称, 自然口语, 不要列点, 不要引号.
                    , .{ p, app.agent.tick, app.agent.ed.e(), app.self_evolve_total }) catch null;
                    if (prompt) |pp| {
                        defer alloc.free(pp);
                        const msg = ghw.harness.llm.Message{
                            .role = .user,
                            .content = pp,
                        };
                        const req = ghw.harness.llm.ChatRequest{
                            .model = app.llm_model,
                            .messages = &[_]ghw.harness.llm.Message{msg},
                            .temperature = 0.7,
                            .max_tokens = 200,
                        };
                        var resp = chat.complete(req, alloc) catch {
                            std.debug.print("[phase-bootstrap] phase {d} LLM 失败, 跳叙事\n", .{p});
                            continue;
                        };
                        defer resp.deinit();
                        if (resp.content) |content| {
                            if (content.len > 0) {
                                // 只写 sqlite, 不覆盖 self_narrative
                                if (app.sqlite) |*db| {
                                    _ = db.insertEpisode(
                                        @intCast(app.agent.tick),
                                        "phase_narrative",
                                        content,
                                        1.0,
                                        "llm",
                                    ) catch {};
                                }
                                std.debug.print("[phase-bootstrap] ✓ phase {d} 叙事写入: {s}\n", .{ p, content[0..@min(80, content.len)] });
                            }
                        }
                    }
                }
            }
            std.debug.print("[phase-bootstrap] ✓ 写了 {d} 段晋升叙事 (phase 2..{d})\n", .{ app.phase - 1, app.phase });
        }
    }

    // === Phase 8 demo: 8 关系 schema 已实装, 启动时种子化 8 种关系 (覆盖 8 种类型让 phase 8 触发 + UI 可视化) ===
    // 注: 数字生命运行时不会真加 sibling/conflict/depends_on 等 (目前 graph 走 parent_child 层级 + agent 增删),
    // 这里 demo 给 UI 看 schema 工作: 加 5 个 goal 节点 + 6 种关系
    {
        if (app.agent.goal_graph.goals.items.len == 0) {
            const g1 = app.agent.goal_graph.add(.enhance_existence, "数字生命本体 (8-rel demo)", 5, 0.1, .{ 0.5, 0, 0, 0 }) catch 0;
            const g2 = app.agent.goal_graph.add(.acquire_knowledge, "学习 LLM 写规则", 5, 0.05, .{ 0, 0.5, 0, 0 }) catch 0;
            const g3 = app.agent.goal_graph.add(.acquire_resource, "搜集系统资源", 5, 0.05, .{ 0, 0, 0.3, 0 }) catch 0;
            const g4 = app.agent.goal_graph.add(.explore, "探索外网 (autocli)", 5, 0.05, .{ 0, 0, 0, 0.4 }) catch 0;
            const g5 = app.agent.goal_graph.add(.self_modify_params, "调参 L1 (alpha/beta/gamma)", 5, 0.05, .{ 0.3, 0, 0, 0 }) catch 0;
            if (g1 > 0 and g2 > 0 and g3 > 0 and g4 > 0 and g5 > 0) {
                // 6 种关系覆盖: parent_child (g1→g2..g5), sibling (g2↔g3↔g4↔g5), conflict (g2 vs g3), depends_on (g5 depends g2), enables (g2 enables g5), emerges_from (g5 emerges g3+g4)
                _ = app.agent.goal_graph.addRelation(g1, g2, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g3, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g4, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g1, g5, .sibling) catch {};
                _ = app.agent.goal_graph.addRelation(g2, g3, .conflict) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g2, .depends_on) catch {};
                _ = app.agent.goal_graph.addRelation(g2, g5, .enables) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g3, .emerges_from) catch {};
                _ = app.agent.goal_graph.addRelation(g5, g4, .emerges_from) catch {};
                _ = app.agent.goal_graph.addRelation(g4, g2, .inhibits) catch {};
                // 第 9 关系 emerges_after: g5 等 g2 跑完后 Δt 时间才能开始
                _ = app.agent.goal_graph.addRelation(g5, g2, .emerges_after) catch {};
                std.debug.print("[phase-8-demo] 种子化 5 goal + 11 关系, 9 关系 schema 演示 (tick={d})\n", .{app.agent.tick});
            }
        }
    }

    try loadStaticAssets(&app);
    std.debug.print("[ui] 静态资源加载: index.html={d}B, app.js={d}B\n", .{ app.index_html.len, app.app_js.len });

    // === AutoCLI: 外网拉取 → Memory + sqlite (可 --no-autocli / --autocli-interval-s) ===
    if (!args.no_autocli) {
        var ac = ghw.harness.autocli.AutoCLI.init(alloc, io);
        const interval_s = if (args.autocli_interval_s == 0) 300 else args.autocli_interval_s;
        ac.interval_ns = @as(i128, @intCast(interval_s)) * std.time.ns_per_s;
        app.autocli_base_interval_s = interval_s;
        app.autocli = ac;
        if (std.Thread.spawn(.{}, autocliThreadFn, .{&app})) |t| {
            app.autocli_thread = t;
            std.debug.print("[ui] AutoCLI 启用: 每 {d}s 拉 4 接口 → Memory.world_fetch (Wiki/HN/ArXiv/RSS)\n", .{interval_s});
        } else |err| {
            std.debug.print("[ui] AutoCLI 启动失败: {t}, 跳过\n", .{err});
        }
    } else {
        std.debug.print("[ui] AutoCLI 已禁用 (--no-autocli)\n", .{});
    }
    if (app.auto_tick_ms > 0) {
        if (std.Thread.spawn(.{}, autoTickThreadFn, .{&app})) |t| {
            app.auto_tick_thread = t;
            std.debug.print("[ui] Auto-tick 启用: 每 {d}ms 推进 1 cycle (GET /api/state 只读)\n", .{app.auto_tick_ms});
        } else |err| {
            std.debug.print("[ui] Auto-tick 启动失败: {t}\n", .{err});
        }
    }

    try runServer(alloc, io, &app, args.host, args.port);

    // 停止 AutoCLI thread
    app.autocli_stop.store(true, .seq_cst);
    if (app.autocli_thread) |t| t.join();
    if (app.auto_tick_thread) |t| t.join();

    std.debug.print("[ui] 收到停止信号, 退出\n", .{});
}
