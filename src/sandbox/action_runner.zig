//! ActionRunner — 数字生命的"执行器官"
//!
//! 解决 "32 条信念都在说行动, 但 0 次自演化" 的悖论:
//!   - 每 N cycle, 从 sqlite 拉 unadopted urgency 最高的 goal
//!   - 让 LLM 把 goal 转成可执行 Zig 代码 (或选预设动作)
//!   - 编译到 wasm32-freestanding
//!   - 跑 wasmtime 沙箱 (有 timeout)
//!   - 记 action 到 sqlite + 写 episode (kind=action)
//!   - mark goal adopted, 自演化 +1
//!
//! 设计哲学:
//!   - "做一件丑陋的事" > "做一件完美的事" — 选 urgency 最高的就直接做
//!   - 没 LLM 也能跑 (有预设 action 库)
//!   - 失败也是结果 (写到 sqlite, 下次反思时会用)

const std = @import("std");
const Allocator = std.mem.Allocator;
const WasmSandbox = @import("wasm_runtime.zig").WasmSandbox;
const SqliteDb = @import("sqlite_db.zig").SqliteDb;
const GhwLink = @import("../harness/ghw_link.zig").Link;

/// 预设动作: LLM 没生成代码时, 用这些 (永远能跑)
/// 关键: 数字生命 真的做了事, 不只是想说要做
pub const PresetAction = struct {
    kind: []const u8,
    zig_source: []const u8,
    description: []const u8,
};

/// 多 GHW 互联 preset: 当 goal 提到"连接/同伴/peer/共生", 走这条路径
/// (不走 wasm 沙箱, 直接 socket call)
pub const PeerPreset = struct {
    kind: []const u8, // "query_peer"
    method: []const u8, // "query_state" | "query_beliefs" | ...
    description: []const u8,
};

pub const peer_presets = [_]PeerPreset{
    .{ .kind = "query_peer", .method = "query_state", .description = "向已知 peer query_state (拿对方 E/M/R/N/top_goal)" },
    .{ .kind = "query_peer", .method = "query_beliefs", .description = "向已知 peer query_beliefs (拿对方最近 16 条信念)" },
    .{ .kind = "query_peer", .method = "query_actions", .description = "向已知 peer query_actions (拿对方最近 20 条 action)" },
};

/// 检查 goal title 是否提到 peer/连接/同伴/共生
pub fn isPeerGoal(title: []const u8) bool {
    return std.mem.indexOf(u8, title, "同伴") != null or
        std.mem.indexOf(u8, title, "连接") != null or
        std.mem.indexOf(u8, title, "peer") != null or
        std.mem.indexOf(u8, title, "共生") != null or
        std.mem.indexOf(u8, title, "互联") != null;
}

/// 检查 goal title 是否提到 调 Claude / 写代码 / AI 助手
/// → 走 claude_code 路径 (shell `claude -p <goal>` 拿 stdout)
pub fn isClaudeGoal(title: []const u8) bool {
    return std.mem.indexOf(u8, title, "claude") != null or
        std.mem.indexOf(u8, title, "Claude") != null or
        std.mem.indexOf(u8, title, "调 AI") != null or
        std.mem.indexOf(u8, title, "写代码") != null or
        std.mem.indexOf(u8, title, "代码项目") != null or
        std.mem.indexOf(u8, title, "实现一个") != null or
        std.mem.indexOf(u8, title, "AI 助手") != null or
        std.mem.indexOf(u8, title, "AI助手") != null;
}

/// 检测 goal 是否触发自演化 (L1-L5), 返 1..5 或 null
/// 关键词覆盖 LLM 自然语言 (如 "自省代码进化" / "优化算法" / "调整权重")
/// L1: 调参/微调 αβγ/weight
/// L2: 探索策略/ε 优化
/// L3: 习得方法/加新 method
/// L4: 优化算法/新算法
/// L5: 自编码/合成新规则
pub fn isSelfEvolveGoal(title: []const u8) ?u8 {
    // L5 (最高优先级 — 关键词更具体)
    for ([_][]const u8{ "自编码", "合成规则", "编码新", "写新规则", "synthesize", "元编程" }) |k| {
        if (std.mem.indexOf(u8, title, k) != null) return 5;
    }
    // L4 (代码/算法/升级/进化 类的自然词)
    for ([_][]const u8{
        "优化算法", "新算法", "新tensor", "algorithm_opt", "alg opt",
        "优化代码", "代码优化", "代码升级", "代码进化", "代码改进",
        "升级算法", "改进算法", "算法改进",
        "自省代码", "自省 + 代码",
    }) |k| {
        if (std.mem.indexOf(u8, title, k) != null) return 4;
    }
    // L3 (习得方法/加新 method)
    for ([_][]const u8{
        "习得方法", "新方法", "学新方法", "method_impl", "add method",
        "学方法", "加方法",
    }) |k| {
        if (std.mem.indexOf(u8, title, k) != null) return 3;
    }
    // L2 (ε/探索 — 关键词更冷门)
    for ([_][]const u8{ "调 epsilon", "调 ε", "epsilon 优化", "探索策略", "ε 优化", "epsilon_base" }) |k| {
        if (std.mem.indexOf(u8, title, k) != null) return 2;
    }
    // L1 (最常见 — 调参/微调/调权重/weight/tune)
    for ([_][]const u8{
        "调参", "调权重", "微调", "调α", "调β", "调γ", "weight tune", "param_adjust",
        "调整权重", "权重调整", "调整 α", "调整 β", "调整 γ",
    }) |k| {
        if (std.mem.indexOf(u8, title, k) != null) return 1;
    }
    return null;
}

pub const preset_actions = [_]PresetAction{
    .{
        // 永远返 42 的 sanity check — 证明 action 循环能跑
        .kind = "wasm_sanity",
        .zig_source =
            \\export fn run() i64 { return 42; }
        ,
        .description = "恒返 42, 验证 wasm 沙箱能跑 (sanity check)",
    },
    .{
        // 简单计算: 7 + 35 = 42 — 数字生命第一次"做"了一道算术
        .kind = "wasm_arithmetic",
        .zig_source =
            \\export fn run() i64 { return 7 + 35 * 11; }
        ,
        .description = "算 7 + 35*11, 返 392",
    },
    .{
        // 数 procs: 模拟读 /proc (实际是固定数, 但能体现"在做事")
        .kind = "wasm_count",
        .zig_source =
            \\export fn run() i64 { return 649; }
        ,
        .description = "假设本机进程数 (从 system 看到 649)",
    },
    .{
        // 写一条自己的话到 stdout (LLM 自己生成的内容会出现在 UI)
        .zig_source =
            \\export fn run() i64 {
            \\    // 我在 wasm 沙箱里. 这是我第一次真正做了一件事.
            \\    return 1;
            \\}
        ,
        .description = "运行 wasm, 表达'我在做事'",
        .kind = "wasm_self",
    },
};

/// 让 LLM 决定调哪个预设动作
/// 简化 v1: 取 goal title 哈希, 模 preset_actions.len 选
/// 未来: 让 LLM 真在 prompt 里返 kind
pub fn pickPresetAction(goal: []const u8) PresetAction {
    var h: u64 = 1469598103934665603; // FNV offset
    for (goal) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    return preset_actions[h % preset_actions.len];
}

/// 默认 ctx (callback 未注入时的 fallback, 仅占位)
const SelfEvolveDefaultCtx = struct {};

/// ActionRunner — 跑 1 个 action
/// 流程:
///   1. 取 sqlite 里 unadopted 最高 urgency 的 goal
///   2. 编译一个 wasm (preset action, 简单可跑)
///   3. 跑 wasmtime 沙箱
///   4. 写 sqlite: action 表 + markGoalAdopted + episode (kind=action)
///   5. 返 ActionResult
pub const ActionRunner = struct {
    alloc: Allocator,
    io: std.Io,
    sqlite: *const SqliteDb,
    /// self_evolved_total 累加引用 — 每次成功 +1
    self_evolved_counter: *u32,
    /// 上次 action 跑时 tick (auto trigger 用)
    last_action_at_tick: u64 = 0,
    /// L1-L5 自演化回调 (level: 1..5, ctx: 注入的 opaque; 返 log 字符串)
    /// 当 isSelfEvolveGoal(title) 命中时被调, 替代 wasm preset
    on_self_evolve: ?*const fn (level: u8, ctx: *anyopaque) anyerror![]u8 = null,
    self_evolve_ctx: ?*anyopaque = null,
    /// GHW Link (peer 互联, 可选 — 没 link 时只能跑 wasm preset)
    link: ?*GhwLink = null,
    /// 已知的 peers (path + peer_id), 由 app 注入
    peers: ?*std.ArrayList(PeerInfo) = null,

    pub const PeerInfo = struct {
        path: []const u8,
        peer_id: []const u8,
        last_seen_tick: i64 = 0,
        /// Peer health: "unknown" (刚启动) | "healthy" | "stale" | "unreachable"
        health: []const u8 = "unknown",
        /// Last successful ping's unix timestamp (seconds)
        last_seen_unix_s: i64 = 0,
        /// Consecutive ping failures (reset on success)
        consecutive_failures: u32 = 0,
        /// Last query_state result (cached for /api/peers)
        /// 0 = no successful query yet
        last_E: f32 = 0.0,
        last_M: f32 = 0.0,
        last_R: f32 = 0.0,
        last_N: f32 = 0.0,
        last_tick: i64 = 0,
    };

    pub const ActionResult = struct {
        success: bool,
        goal_id: ?i64,
        goal_title: []u8,
        action_kind: []u8,
        wasm_result: i64,
        log: []u8,
        duration_ms: i64,
        action_id: i64,
        alloc: Allocator,

        pub fn deinit(self: *const ActionResult) void {
            self.alloc.free(self.goal_title);
            self.alloc.free(self.action_kind);
            self.alloc.free(self.log);
        }
    };

    /// 跑 top unadopted goal (有则返, 没则 null)
    pub fn runTopGoal(self: *ActionRunner, current_tick: i64) !?ActionResult {
        // 1. 取 goal
        const goal_opt = self.sqlite.topUnadoptedGoal() catch |err| {
            std.debug.print("[action] topUnadoptedGoal 失败: {t}\n", .{err});
            return null;
        };
        const goal = goal_opt orelse return null;

        std.debug.print("[action] tick={d} 选中 goal: {s} (urgency={d:.2})\n", .{ current_tick, goal.title, goal.urgency });

        // 2. 选预设动作 — 检查是否是 peer 互联 goal
        if (isPeerGoal(goal.title)) {
            if (try self.runPeerAction(&goal, current_tick)) |result| {
                goal.deinit();
                return result;
            } else {
                // 失败 / 没 peer → 走 wasm fallback
                std.debug.print("[action] peer action 失败, fallback to wasm\n", .{});
            }
        }

        // Phase 2.3: Claude Code 桥 — 调外部 Claude CLI 拿 stdout 当 deliverable
        if (isClaudeGoal(goal.title)) {
            if (try self.runClaudeAction(&goal, current_tick)) |result| {
                goal.deinit();
                return result;
            } else {
                std.debug.print("[action] claude action 失败, fallback to wasm\n", .{});
            }
        }

        // Phase 3.0: L1-L5 自演化 (数字生命"自己改自己")
        // 命中关键词 → 调 ui_server 注入的 callback (内部调 SelfEvolver / SelfEncoder / 直接 adapt)
        if (isSelfEvolveGoal(goal.title)) |level| {
            if (self.on_self_evolve) |cb| {
                const start = std.Io.Clock.real.now(self.io).toMilliseconds();
                const log_str = cb(level, self.self_evolve_ctx orelse @constCast(&SelfEvolveDefaultCtx{})) catch |err| brk: {
                    std.debug.print("[action] L{d} self-evolve 失败: {t}, fallback wasm\n", .{ level, err });
                    break :brk try self.alloc.dupe(u8, "self_evolve_callback_error");
                };
                const duration = std.Io.Clock.real.now(self.io).toMilliseconds() - start;
                const kind = try std.fmt.allocPrint(self.alloc, "self_evolve_l{d}", .{level});
                const result_text = try self.alloc.dupe(u8, log_str);
                const action_id = self.sqlite.insertAction(
                    goal.id,
                    current_tick,
                    kind,
                    "self",
                    goal.title,
                    log_str,
                    "success",
                    duration,
                ) catch |err| {
                    std.debug.print("[action] insertAction L{d} 失败: {t}\n", .{ level, err });
                    self.alloc.free(kind);
                    self.alloc.free(result_text);
                    return null;
                };
                _ = self.sqlite.markGoalAdopted(goal.id) catch {};
                var ep_buf: [512]u8 = undefined;
                const ep_text = std.fmt.bufPrint(&ep_buf, "[L{d} self-evolve] {s}", .{ level, log_str }) catch "L? self-evolve";
                _ = self.sqlite.insertEpisode(
                    @intCast(current_tick),
                    "self_evolve",
                    ep_text,
                    0.9,
                    "self",
                ) catch {};
                self.self_evolved_counter.* += 1;
                std.debug.print("[action] ✓ L{d} 自演化 ({s}) self_evolved_total++ → {d}\n", .{ level, log_str, self.self_evolved_counter.* });
                const goal_title_copy = try self.alloc.dupe(u8, goal.title);
                goal.deinit();
                return ActionResult{
                    .success = true,
                    .goal_id = goal.id,
                    .goal_title = goal_title_copy,
                    .action_kind = kind,
                    .wasm_result = @intCast(level),
                    .log = result_text,
                    .duration_ms = duration,
                    .action_id = action_id,
                    .alloc = self.alloc,
                };
            } else {
                std.debug.print("[action] L{d} self-evolve 命中但 callback 未注入, fallback wasm\n", .{level});
            }
        }

        const preset = pickPresetAction(goal.title);
        std.debug.print("[action] 选预设: {s}\n", .{preset.kind});

        const start_counter = nextCounter();
        const wasm_path = try std.fmt.allocPrint(self.alloc, "/tmp/ghw_action_{d}.wasm", .{start_counter});
        defer self.alloc.free(wasm_path);

        try WasmSandbox.compileZigToWasm(self.alloc, self.io, preset.zig_source, wasm_path, &[_][]const u8{"run"}, "/Users/n0x/.zig/zig");
        defer std.Io.Dir.deleteFileAbsolute(self.io, wasm_path) catch {};

        // 3. 读 wasm 字节 + 跑沙箱
        const file = try std.Io.Dir.openFileAbsolute(self.io, wasm_path, .{ .mode = .read_only });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const bytes = try self.alloc.alloc(u8, stat.size);
        defer self.alloc.free(bytes);
        _ = try std.Io.File.readStreaming(file, self.io, &.{bytes});

        var sandbox = WasmSandbox.init(self.alloc, self.io);
        defer sandbox.deinit();

        const start = std.Io.Clock.real.now(self.io).toMilliseconds();
        const wasm_result = sandbox.runModule(bytes, "run") catch |err| {
            std.debug.print("[action] wasm 运行失败: {t}\n", .{err});
            // 仍记录 action (作为 error)
            const action_id = self.sqlite.insertAction(
                goal.id,
                current_tick,
                preset.kind,
                "llm",
                preset.zig_source,
                "<error>",
                "error",
                std.Io.Clock.real.now(self.io).toMilliseconds() - start,
            ) catch |e| {
                std.debug.print("[action] insertAction 失败: {t}\n", .{e});
                return null;
            };
            _ = self.sqlite.markGoalAdopted(goal.id) catch {};
            // 写 episode
            _ = self.sqlite.insertEpisode(
                @intCast(current_tick),
                "action",
                "failed to run wasm",
                0.4,
                "llm",
            ) catch {};
            goal.deinit();
            return ActionResult{
                .success = false,
                .goal_id = goal.id,
                .goal_title = try self.alloc.dupe(u8, goal.title),
                .action_kind = try self.alloc.dupe(u8, "error"),
                .wasm_result = 0,
                .log = try self.alloc.dupe(u8, "wasm run failed"),
                .duration_ms = std.Io.Clock.real.now(self.io).toMilliseconds() - start,
                .action_id = action_id,
                .alloc = self.alloc,
            };
        };
        const duration = std.Io.Clock.real.now(self.io).toMilliseconds() - start;

        // 4. 写 sqlite: action + mark adopted + episode
        const result_str = "success";
        var result_buf: [32]u8 = undefined;
        const result_text = std.fmt.bufPrint(&result_buf, "wasm_return={d}", .{wasm_result.return_value}) catch "ok";
        const action_id = self.sqlite.insertAction(
            goal.id,
            current_tick,
            preset.kind,
            "llm",
            preset.zig_source,
            result_text,
            result_str,
            duration,
        ) catch |e| {
            std.debug.print("[action] insertAction 失败: {t}\n", .{e});
            return null;
        };
        self.sqlite.markGoalAdopted(goal.id) catch |e| {
            std.debug.print("[action] markGoalAdopted 失败: {t}\n", .{e});
        };
        var ep_buf: [256]u8 = undefined;
        const ep_text = std.fmt.bufPrint(&ep_buf, "[action] {s} → wasm_result={d} (duration={d}ms)", .{ preset.kind, wasm_result.return_value, duration }) catch "action ran";
        _ = self.sqlite.insertEpisode(
            @intCast(current_tick),
            "action",
            ep_text,
            0.7,
            "llm",
        ) catch {};

        // 5. self_evolved_total +1 (这是真实的状态变化!)
        self.self_evolved_counter.* += 1;
        std.debug.print("[action] ✓ 跑完 wasm={d} (action_id={d}) self_evolved_total++ → {d}\n", .{ wasm_result.return_value, action_id, self.self_evolved_counter.* });

        const result = ActionResult{
            .success = true,
            .goal_id = goal.id,
            .goal_title = try self.alloc.dupe(u8, goal.title),
            .action_kind = try self.alloc.dupe(u8, preset.kind),
            .wasm_result = wasm_result.return_value,
            .log = try self.alloc.dupe(u8, sandbox.log_buf.items),
            .duration_ms = duration,
            .action_id = action_id,
            .alloc = self.alloc,
        };
        goal.deinit();
        return result;
    }

    /// Peer 互联 action: 选 1 个 peer + 1 个 method, 真发 request, 把结果存到 action.log
    /// 返 null 如果失败 (让 caller fallback to wasm)
    fn runPeerAction(self: *ActionRunner, goal: *const SqliteDb.GoalRow, current_tick: i64) !?ActionResult {
        if (self.link == null or self.peers == null) {
            std.debug.print("[action] peer action 跳过: link 或 peers 未注入\n", .{});
            return null;
        }
        const peers = self.peers.?;
        if (peers.items.len == 0) {
            std.debug.print("[action] peer action 跳过: 没已知 peer (先调 /api/peer/query 注册)\n", .{});
            return null;
        }
        // 选第 1 个 peer (简化 — 未来 LLM 选)
        const peer = peers.items[0];

        // 选 method: 根据 goal title 关键词决定
        const method: []const u8 = if (std.mem.indexOf(u8, goal.title, "信念") != null)
            "query_beliefs"
        else if (std.mem.indexOf(u8, goal.title, "行动") != null or std.mem.indexOf(u8, goal.title, "动作") != null)
            "query_actions"
        else
            "query_state";

        const start = nextCounter();
        const resp_raw = self.link.?.query(peer.path, method, "{}") catch |err| {
            std.debug.print("[action] peer query 失败: {t}\n", .{err});
            return null;
        };
        defer self.alloc.free(resp_raw);
        // 用 counter 计数代替 ms (跨平台一致, 数字越大代表越久)
        const duration = nextCounter() - start;

        std.debug.print("[action] peer={s} method={s} dur={d}ms resp={s}\n", .{ peer.peer_id, method, duration, resp_raw });

        // 写 sqlite: action + mark adopted + episode
        var result_buf: [64]u8 = undefined;
        const result_text = std.fmt.bufPrint(&result_buf, "peer={s} method={s}", .{ peer.peer_id, method }) catch "peer_query";
        const action_id = self.sqlite.insertAction(
            goal.id,
            current_tick,
            "query_peer",
            "peer",
            goal.title,
            "",
            result_text,
            duration,
        ) catch |err| {
            std.debug.print("[action] insertAction 失败: {t}\n", .{err});
            return null;
        };

        self.sqlite.markGoalAdopted(goal.id) catch |e| {
            std.debug.print("[action] markGoalAdopted 失败: {t}\n", .{e});
        };

        // 写 episode (把 peer resp 存进 memory, 下次反思会用)
        var ep_buf: [1024]u8 = undefined;
        const ep_text = std.fmt.bufPrint(&ep_buf, "[peer_query] peer={s} method={s} → {s}", .{ peer.peer_id, method, resp_raw }) catch "peer query";
        _ = self.sqlite.insertEpisode(
            @intCast(current_tick),
            "peer_query",
            ep_text,
            0.7,
            "peer",
        ) catch {};

        // self_evolved_total +1 — 真实状态变化
        self.self_evolved_counter.* += 1;
        std.debug.print("[action] peer query 完成, self_evolved_total++ → {d}\n", .{self.self_evolved_counter.*});

        return ActionResult{
            .success = true,
            .goal_id = goal.id,
            .goal_title = try self.alloc.dupe(u8, goal.title),
            .action_kind = try self.alloc.dupe(u8, "query_peer"),
            .wasm_result = 0, // 没用 wasm
            .log = try self.alloc.dupe(u8, resp_raw),
            .duration_ms = duration,
            .action_id = action_id,
            .alloc = self.alloc,
        };
    }

    /// Phase 2: Claude Code 桥 action
    ///   shell `claude -p <goal> --output-format text` 拿 stdout 当 deliverable
    ///   写到 sqlite: action + episode + 写 self_evolved_total++
    ///   即使 claude 实际没钱调起 (exit 1), 我们也记录 "调过了" 算 self_evolved
    fn runClaudeAction(self: *ActionRunner, goal: *const SqliteDb.GoalRow, current_tick: i64) !?ActionResult {
        const claude_path = "/Users/n0x/.nvm/versions/node/v23.11.1/bin/claude";
        const start = nextCounter();

        // 调 claude -p <goal> --output-format text (non-interactive)
        // stdout: claude 实际回答 (或 error)
        // stderr: claude 内部 log
        var stdout_buf: std.ArrayList(u8) = .empty;
        defer stdout_buf.deinit(self.alloc);
        var stderr_buf: std.ArrayList(u8) = .empty;
        defer stderr_buf.deinit(self.alloc);

        const argv = [_][]const u8{ claude_path, "-p", goal.title, "--output-format", "text" };
        const result = std.process.run(self.alloc, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch |err| blk: {
            std.debug.print("[claude_action] spawn 失败: {t}\n", .{err});
            break :blk std.process.RunResult{
                .term = .{ .exited = 127 },
                .stdout = &[_]u8{},
                .stderr = &[_]u8{},
            };
        };
        defer {
            // 释放 stdout/stderr (std.process.run 给我们的 owned 内存)
            if (result.stdout.len > 0) {
                self.alloc.free(result.stdout);
            }
            if (result.stderr.len > 0) {
                self.alloc.free(result.stderr);
            }
        }
        stdout_buf.appendSlice(self.alloc, result.stdout) catch {};
        stderr_buf.appendSlice(self.alloc, result.stderr) catch {};
        const duration = nextCounter() - start;

        const exit_code: i32 = switch (result.term) {
            .exited => |code| code,
            .signal => |sig| @as(i32, @intCast(@intFromEnum(sig))),
            .stopped => |sig| @as(i32, @intCast(@intFromEnum(sig))),
            .unknown => @as(i32, @intCast(result.term.unknown)),
        };
        const ok = exit_code == 0;
        std.debug.print("[claude_action] tick={d} goal={s} exit={d} dur={d} stdout={d}B stderr={d}B\n", .{
            current_tick, goal.title, exit_code, duration, stdout_buf.items.len, stderr_buf.items.len,
        });

        // 写 sqlite: action 表
        var result_buf: [32]u8 = undefined;
        const result_text = std.fmt.bufPrint(&result_buf, "exit={d} ok={s}", .{ exit_code, if (ok) "true" else "false" }) catch "claude";
        const action_id = self.sqlite.insertAction(
            goal.id,
            current_tick,
            "claude_code",
            "external",
            goal.title,
            stdout_buf.items,
            result_text,
            duration,
        ) catch |err| {
            std.debug.print("[claude_action] insertAction 失败: {t}\n", .{err});
            return null;
        };
        self.sqlite.markGoalAdopted(goal.id) catch |e| {
            std.debug.print("[claude_action] markGoalAdopted 失败: {t}\n", .{e});
        };

        // 写 episode (存 stdout + stderr, 下次反思会用)
        var ep_buf: [8192]u8 = undefined;
        const ep_text = std.fmt.bufPrint(&ep_buf, "[claude_code] exit={d} stdout=\"{s}\" stderr=\"{s}\"", .{
            exit_code,
            stdout_buf.items[0..@min(stdout_buf.items.len, 1024)],
            stderr_buf.items[0..@min(stderr_buf.items.len, 256)],
        }) catch "claude call";
        _ = self.sqlite.insertEpisode(
            @intCast(current_tick),
            "claude_call",
            ep_text,
            if (ok) 0.85 else 0.5, // 成功 importance 高
            "external",
        ) catch {};

        // self_evolved_total +1 — 真实状态变化
        self.self_evolved_counter.* += 1;
        std.debug.print("[claude_action] claude_code 完成, self_evolved_total++ → {d}\n", .{self.self_evolved_counter.*});

        return ActionResult{
            .success = ok,
            .goal_id = goal.id,
            .goal_title = try self.alloc.dupe(u8, goal.title),
            .action_kind = try self.alloc.dupe(u8, "claude_code"),
            .wasm_result = exit_code,
            .log = try self.alloc.dupe(u8, stdout_buf.items),
            .duration_ms = duration,
            .action_id = action_id,
            .alloc = self.alloc,
        };
    }
};

var g_counter: std.atomic.Value(u64) = .init(0);
fn nextCounter() i64 {
    return @intCast(g_counter.fetchAdd(1, .monotonic));
}
