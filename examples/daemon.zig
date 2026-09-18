// SPDX-License-Identifier: MIT
// examples/daemon.zig — GHW 数字生命 daemon: 长跑进程, 持续接收输入, 输出 JSON 状态
//
// 部署模式:
//   1. 一次性:  daemon --cycles N --state-out state.json
//   2. 长跑 + 持久化: daemon --state-out state.json
//      → 每 16 cycle 写 snapshot (state.json, atomic rename)
//      → 每 cycle 追加 WAL (state.wal, JSONL append)
//      → 启动: 读 snapshot → replay WAL 之后 records (顺序一致)
//      → 256 cycle 一次: 重写 snapshot + truncate WAL
//   3. Graceful shutdown: SIGTERM/SIGINT/SIGHUP → break loop → final snapshot → exit 0
//
// WAL 设计理由:
//   - 整文件 snapshot 慢, 跟 tick 数线性, 1M+ tick 卡
//   - WAL 追加 O(1), 启动 replay 也就几 ms
//   - 崩在写一半不会丢, snapshot 是 atomic rename, WAL 顺序读
//   2. 长跑:    daemon --cycles forever --inbox inbox.jsonl --outbox outbox.jsonl
//   3. 恢复:    daemon --state-in state.json --cycles 64 --state-out new_state.json
//
// 真实部署建议: 配合 cron / systemd / launchd 周期运行
const std = @import("std");
const builtin = @import("builtin");
const ghw = @import("ghw");
const world = ghw.world;
const goal_mod = ghw.goal;
const harness = ghw.harness;
const SelfEncoder = harness.self_encoder.SelfEncoder;
const SelfEvolutionGuard = harness.self_evolution.SelfEvolutionGuard;
const Memory = harness.memory.Memory;
const EpisodeKind = harness.memory.EpisodeKind;
const Reflection = harness.reflection.Reflection;
const agent_mod = ghw.agent;

const F = ghw.util.F;

// ===== 信号处理: SIGTERM/SIGINT 触发 graceful shutdown =====
var should_stop: std.atomic.Value(bool) = .init(false);
fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    should_stop.store(true, .release);
}
fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return; // Windows 用 Ctrl-C, 这里跳过
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
}
const GHWAgent = agent_mod.GHWAgent;
const CycleReport = agent_mod.CycleReport;
const Information = goal_mod.Information;
const Goal = goal_mod.Goal;
const ActionOutcome = harness.ActionOutcome;
const StateSerializer = harness.state_serializer.StateSerializer;
const StateSnapshot = harness.state_serializer.StateSnapshot;
const Allocator = std.mem.Allocator;

const Config = struct {
    cycles: u64 = 32,
    state_in: ?[]const u8 = null,
    state_out: ?[]const u8 = null,
    inbox: ?[]const u8 = null,
    outbox: ?[]const u8 = null,
    /// 把 cycle JSON 也写 stdout (生产默认 false, 不然 launchd log 会爆盘)
    stdout_jsonl: bool = false,
    /// 每 N tick 打一次进度日志 (默认 256, 0=完全静默)
    log_every: u64 = 256,
    /// 每 cycle 之间 sleep 多少 ms (默认 100ms = 10 cycle/sec; 0 = 不 sleep, 调试用)
    /// 设置合理值避免 busy-wait 把 CPU 烧到 100%
    tick_interval_ms: u64 = 100,
    verbose: bool = false,
    id: []const u8 = "daemon-001",
    dim: usize = 4,
    /// LLM provider: "anthropic" | "openai" | "mock" | "none"
    llm_provider: []const u8 = "none",
    /// LLM model name
    llm_model: []const u8 = "claude-sonnet-4-5",
    /// env var name with API key
    llm_api_key_env: []const u8 = "ANTHROPIC_API_KEY",
    /// base url (deepseek / 智谱 / 自定义端点)
    llm_base_url: []const u8 = "https://api.anthropic.com",
    /// 当 E < 此值时触发 RuleProposer
    rule_propose_threshold: F = 0.55,
    seed: u64 = 42,
    // ===== Loop Engineering 协调器 (Boris "My job is to write loops") =====
    /// 启停 Loop Engine
    loop_enabled: bool = true,
    /// Plan 频率 (每 N cycle 跑一次 hypothesis 提议, 默认 8 跟 Phase 8.7 同步)
    loop_plan_cycle: u64 = 8,
    /// Check 窗口 (算 hit_rate 用最近 N cycle ΔE)
    loop_check_window: u64 = 8,
    /// 连续 miss 几次撤 hypothesis (Boris 守夜: 3)
    loop_miss_act: u32 = 3,
    /// 连续 miss 几次强制 L4 提议 (Boris 没有这层, GHW 加的)
    loop_miss_stop: u32 = 5,
    /// Loop Engine 状态文件路径 (Boris 6.3 外置记忆, 跨重启不丢)
    /// 默认 ~/.local/share/ghw/loop_state.json (跟 state.json 同目录, 自动存)
    loop_state_in: ?[]const u8 = "/Users/n0x/.local/share/ghw/loop_state.json",
    loop_state_out: ?[]const u8 = "/Users/n0x/.local/share/ghw/loop_state.json",
    /// Loop Engine 状态保存频率 (ms). 默认 300000 = 5min, 0=关闭.
    /// 9 宫满血态 cycle 增量 = 0, 用 cycle-based 触发永远不存. 走时间兜底.
    loop_state_save_every_ms: u64 = 300000,
    /// Time-based 进度日志 (跟 --log-every 并行, ms). 默认 300000 = 5min, 0=关闭.
    /// 9 宫满血态下 --log-every 永远不触发, 这个强制打 KPI 摘要.
    /// 0.17 args 拿不到 (pre-existing bug), 设默认非 0 让 production 能用.
    log_every_ms: u64 = 300000,
    /// Loop state save 频率默认 5 min
    loop_state_save_every_ms_default: u64 = 300000,
    // ===== Cross-host Link (TCP + HMAC, 跨 host 通信, v0.5.1 新增) =====
    /// 启停 cross-host listener (0 = 关闭, >0 = 监听端口)
    cross_host_port: u16 = 0,
    /// cross-host shared secret (HMAC key, peers.txt 也用这个格式)
    cross_host_secret: []const u8 = "default_secret_change_me_in_production",
    /// peers.txt 路径 (跨 host peer 配置)
    cross_host_peers_file: ?[]const u8 = null,
    /// agent.tick 持久化 sanity 上限 (默认 10^9; 超过或像 Unix 时间戳则启动时重置)
    max_agent_tick: u64 = harness.agent_tick_guard.DEFAULT_MAX_AGENT_TICK,
    /// 禁用 AutoCLI 外网主路径 (默认启用, 与 ui_server 对齐)
    no_autocli: bool = false,
    /// AutoCLI 间隔秒 (默认 300)
    autocli_interval_s: u64 = 300,
};

fn sanitizeLoadedAgentTick(stored: u64, now_unix: u64, max_tick: u64) u64 {
    const r = harness.agent_tick_guard.sanitizeAgentTick(stored, now_unix, max_tick);
    if (r.reset) {
        std.debug.print("[daemon] agent_tick 异常 ({s}): {d} → 重置为 {d}\n", .{ r.reason, stored, r.tick });
    }
    return r.tick;
}

fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !Config {
    var cfg: Config = .{};
    // args[0] 是 program name (主流程已跳), parseArgs 从 0 开始处理
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--cycles")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            if (std.mem.eql(u8, args[i], "forever") or std.mem.eql(u8, args[i], "0")) {
                cfg.cycles = std.math.maxInt(u64);
            } else {
                cfg.cycles = try std.fmt.parseInt(u64, args[i], 10);
            }
        } else if (std.mem.eql(u8, a, "--state-in")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.state_in = args[i];
        } else if (std.mem.eql(u8, a, "--state-out")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.state_out = args[i];
        } else if (std.mem.eql(u8, a, "--inbox")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.inbox = args[i];
        } else if (std.mem.eql(u8, a, "--outbox")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.outbox = args[i];
        } else if (std.mem.eql(u8, a, "--stdout-jsonl")) {
            cfg.stdout_jsonl = true;
        } else if (std.mem.eql(u8, a, "--log-every")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.log_every = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--tick-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.tick_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--max-agent-tick")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.max_agent_tick = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--no-autocli")) {
            cfg.no_autocli = true;
        } else if (std.mem.eql(u8, a, "--autocli-interval-s")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.autocli_interval_s = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, a, "--id")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.id = args[i];
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--llm")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.llm_provider = args[i];
        } else if (std.mem.eql(u8, a, "--llm-model")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.llm_model = args[i];
        } else if (std.mem.eql(u8, a, "--llm-key-env")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.llm_api_key_env = args[i];
        } else if (std.mem.eql(u8, a, "--llm-base-url")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.llm_base_url = args[i];
        } else if (std.mem.eql(u8, a, "--rule-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.rule_propose_threshold = try std.fmt.parseFloat(F, args[i]);
        } else if (std.mem.eql(u8, a, "--loop-disable")) {
            cfg.loop_enabled = false;
        } else if (std.mem.eql(u8, a, "--loop-plan-cycle")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_plan_cycle = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--loop-check-window")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_check_window = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--loop-miss-act")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_miss_act = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--loop-miss-stop")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_miss_stop = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--loop-state-in")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_state_in = args[i];
        } else if (std.mem.eql(u8, a, "--loop-state-out")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_state_out = args[i];
        } else if (std.mem.eql(u8, a, "--loop-state-save-every-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.loop_state_save_every_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--log-every-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.log_every_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--cross-host-port")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.cross_host_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--cross-host-secret")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.cross_host_secret = args[i];
        } else if (std.mem.eql(u8, a, "--cross-host-peers")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.cross_host_peers_file = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            std.process.exit(0);
        } else {
            std.debug.print("[daemon] unknown arg: {s}\n", .{a});
            printHelp();
            return error.UnknownArg;
        }
    }
    _ = alloc;
    return cfg;
}

fn printHelp() void {
    const help =
        \\GHW 数字生命 daemon — 把 GHW 当一个长跑进程部署
        \\
        \\用法:
        \\  daemon [options]
        \\
        \\选项:
        \\  --cycles N              跑 N 个 cycle (默认 32; N=0 = forever 一直跑)
        \\  --state-in <path>       从 JSON 状态文件启动
        \\  --state-out <path>      退出时写状态到 JSON
        \\  --inbox <path>          (TODO) 从 JSONL 文件读 perception
        \\  --outbox <path>         写 cycle 报告到 JSONL 文件
        \\  --stdout-jsonl          也把 cycle 报告打 stdout (生产不要开, 会爆 log)
        \\  --log-every N           进度日志间隔 (默认 256, 0=静默)
        \\  --tick-interval-ms N    每 cycle sleep 多少 ms (默认 100, 0=不 sleep)
        \\  --max-agent-tick N      agent.tick 上限; 超限或像 Unix 时间戳则启动重置 (默认 10^9)
        \\  --no-autocli            禁用 AutoCLI 外网拉取 (默认启用)
        \\  --autocli-interval-s N  AutoCLI 间隔秒 (默认 300)
        \\  --id <string>           数字生命 id (默认 daemon-001)
        \\  --seed <N>              LCG 随机种子 (默认 42)
        \\  --llm <provider>        LLM: anthropic | openai | none (默认 none)
        \\  --llm-model <name>      LLM 模型 (默认 claude-sonnet-4-5)
        \\  --llm-key-env <name>    API key env var (默认 ANTHROPIC_API_KEY)
        \\  --verbose, -v           每个 cycle 打印
        \\  --loop-disable          关闭 Loop Engine 协调器 (Boris "My job is to write loops")
        \\  --loop-plan-cycle N     Plan 频率 (默认 8, 跟 Phase 8.7 L4 提议同步)
        \\  --loop-check-window N   Check 窗口 (默认 8)
        \\  --loop-miss-act N       连续 miss N 次撤 hypothesis (默认 3, Boris 守夜规则)
        \\  --loop-miss-stop N      连续 miss N 次强制 L4 提议 (默认 5)
        \\  --help, -h              打印这个帮助
        \\
        \\示例:
        \\  daemon --cycles 32 --state-out /tmp/ghw_state.json
        \\  daemon --cycles forever --outbox /tmp/ghw.jsonl
        \\  ANTHROPIC_API_KEY=sk-... daemon --llm anthropic --cycles forever
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

/// 从文件读全部内容 (用 std.Io.File.readStreaming 循环读, 处理 0=空转)
fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    var empty_reads: u32 = 0;
    while (empty_reads < 3) {
        const n = std.Io.File.readStreaming(file, io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            empty_reads += 1;
            continue;
        }
        empty_reads = 0;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return buf.toOwnedSlice(alloc);
}

/// 写文件 (覆盖)
fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, data);
}

/// 追加写文件 (Zig 0.17 没有 append 模式, open/create + read_stat + write_at_offset)
fn appendFile(io: std.Io, path: []const u8, data: []const u8) !void {
    // open for read_write, 文件不存在则 create
    var file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch blk: {
        // 不存在, create
        break :blk try std.Io.Dir.createFileAbsolute(io, path, .{});
    };
    defer file.close(io);
    // 读 stat 拿当前 size
    const stat = try file.stat(io);
    // write at offset = size (O_APPEND 语义)
    try std.Io.File.writePositionalAll(file, io, data, stat.size);
}

/// WAL helper — 写一条 state.wal record (一行 JSON)
/// Phase 1: 启动时读 snapshot, 然后 replay WAL 之后 records 恢复最后状态
fn appendWalRecord(
    alloc: std.mem.Allocator,
    io: std.Io,
    wal_path: []const u8,
    tick: u64,
    E: F,
    M: F,
    R: F,
    N: F,
    self_evolved_count: u32,
) !void {
    const line = try std.fmt.allocPrint(alloc,
        \\{{"tick":{d},"E":{d:.4},"M":{d:.4},"R":{d:.4},"N":{d:.4},"se":{d}}}
    , .{ tick, E, M, R, N, self_evolved_count });
    defer alloc.free(line);
    try appendFile(io, wal_path, line);
    try appendFile(io, wal_path, "\n");
}

/// Replay WAL: 读所有 record, 返最后一条 (tick, E, M, R, N)
/// 用于启动时: snapshot 恢复基础状态, 然后 replay WAL 补回最新值
const WalRecord = struct {
    tick: u64,
    E: F,
    M: F,
    R: F,
    N: F,
};

fn replayWal(alloc: std.mem.Allocator, io: std.Io, wal_path: []const u8) !?*WalRecord {
    // 检查文件存在
    const file = std.Io.Dir.openFileAbsolute(io, wal_path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0) return null;

    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    var last: ?*WalRecord = null;
    while (total_read < stat.size) {
        const want = @min(buf.len, stat.size - total_read);
        const n = try std.Io.File.readPositionalAll(file, io, buf[0..want], total_read);
        if (n == 0) break;
        total_read += n;

        // 朴素 JSONL parse: 按 \n 切, 每行找 "tick" / "E" / "M" / "R" / "N"
        var i: usize = 0;
        while (i < n) {
            var j: usize = i;
            while (j < n and buf[j] != '\n') : (j += 1) {}
            if (j > i) {
                const line = buf[i..j];
                var t: u64 = 0;
                var e: F = 0.0;
                var m: F = 0.0;
                var r: F = 0.0;
                var nn: F = 0.0;
                if (findUintField(line, "\"tick\":")) |v| t = v;
                if (findFloatField(line, "\"E\":")) |v| e = v;
                if (findFloatField(line, "\"M\":")) |v| m = v;
                if (findFloatField(line, "\"R\":")) |v| r = v;
                if (findFloatField(line, "\"N\":")) |v| nn = v;
                // free 旧的, alloc 新的
                if (last) |old| alloc.destroy(old);
                const new_ptr = try alloc.create(WalRecord);
                new_ptr.* = .{ .tick = t, .E = e, .M = m, .R = r, .N = nn };
                last = new_ptr;
            }
            i = j + 1;
            if (j >= n) break;
        }
    }
    return last;
}

/// 朴素找 "key":number pattern → u64
fn findUintField(line: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    var p: usize = pos + key.len;
    while (p < line.len and (line[p] == ' ' or line[p] == '\t')) : (p += 1) {}
    const start = p;
    while (p < line.len and line[p] >= '0' and line[p] <= '9') : (p += 1) {}
    if (p == start) return null;
    return std.fmt.parseInt(u64, line[start..p], 10) catch null;
}

/// 朴素找 "key":float pattern → f32
fn findFloatField(line: []const u8, key: []const u8) ?F {
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    var p: usize = pos + key.len;
    while (p < line.len and (line[p] == ' ' or line[p] == '\t')) : (p += 1) {}
    const start = p;
    while (p < line.len and (line[p] >= '0' and line[p] <= '9' or line[p] == '.' or line[p] == '-' or line[p] == 'e' or line[p] == '+')) : (p += 1) {}
    if (p == start) return null;
    return std.fmt.parseFloat(F, line[start..p]) catch null;
}

/// 把 CycleReport 序列化成一行 JSON
fn reportToJson(alloc: std.mem.Allocator, report: CycleReport) ![]u8 {
    var goal_kind: []const u8 = "null";
    if (report.top_goal) |g| {
        goal_kind = @tagName(g.kind);
    }
    return std.fmt.allocPrint(alloc,
        \\{{"tick":{d},"E_before":{d:.3},"E_after":{d:.3},"diff_size":{d:.3},"goal":"{s}","self_evolved":{},"reflected":{}}}
    , .{
        report.tick,
        report.e_before,
        report.e_after,
        report.diff_size,
        goal_kind,
        report.self_evolved,
        report.reflected,
    });
}

fn weakestDim(agent: *agent_mod.GHWAgent) u8 {
    return Memory.weakestDim(agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // 安装 SIGTERM/SIGINT/SIGHUP → graceful shutdown
    installSignalHandlers();

    // threadsafe allocator (daemon 可能要跑后台任务)
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Io 实例 (用于文件操作)
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 收集 args (Zig 0.17 走 vector 直接访问, 之前 iterate() 0.17 dev 不稳定)
    // vector 类型: []const [*:0]const u8, 0 项是 program name, 跳掉
    var args_list: std.ArrayList([]const u8) = .empty;
    const vec = init.args.vector;
    var idx: usize = 0;
    if (vec.len > 0) idx = 1; // 跳过程序名
    while (idx < vec.len) : (idx += 1) {
        const ptr = vec[idx];
        const len = std.mem.len(ptr);
        const arg = try alloc.alloc(u8, len);
        @memcpy(arg, ptr[0..len]);
        try args_list.append(alloc, arg);
    }
    // 释放 args 复制 (必须主动 free, 不然后面 deinit 会 segfault 因为 alloc 的指针已被 free)
    defer {
        for (args_list.items) |a| alloc.free(a);
        args_list.deinit(alloc);
    }

    const cfg = parseArgs(alloc, args_list.items) catch |err| {
        std.debug.print("[daemon] arg parse failed: {t}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("[daemon] GHW 数字生命 daemon 启动\n", .{});
    std.debug.print("[daemon] id={s} dim={d} cycles={s} (0=无限)\n", .{
        cfg.id, cfg.dim, if (cfg.cycles == 0) "∞" else "limited",
    });

    // 创建 agent
    var agent = try GHWAgent.init(alloc, cfg.id, cfg.dim, .{ 3, 3, 3 }, cfg.seed);
    defer agent.deinit();

    // P3: 自传体记忆 — 每个 cycle 自动 recordAt, 供 LLM 通道连续
    var memory = Memory.init(alloc, cfg.seed);
    defer memory.deinit();

    // P6: TaskQueue + 记忆写回 + 世界上下文 (LLM 目标提议)
    var task_queue = harness.human_symbiosis.TaskQueue.init(alloc);
    defer task_queue.deinit();
    // P9: HumanSignal + HumanGSP 反馈闭环
    var human_gsp = harness.human_symbiosis.HumanGSP.init(alloc);
    defer human_gsp.deinit();
    var human_signal = harness.human_symbiosis.HumanSignal.init(alloc);
    defer human_signal.deinit();
    try human_gsp.register("human");
    try human_gsp.register("llm_proposer");
    try human_gsp.register("system");
    var value_tracker = harness.human_symbiosis.ValueTrendTracker{};
    agent.bindTaskQueue(&task_queue);
    agent.bindMemory(&memory, io);
    var world_ctx = harness.world_context.WorldContext.init(alloc, io, init.environ);
    defer world_ctx.deinit();
    var sys_collector = harness.system_collector.SystemCollector.init(alloc, io, cfg.seed);
    defer sys_collector.deinit();
    var last_world_sensor_tick: u64 = 0;
    var survival_feedback: harness.survival_feedback.Tracker = .{};
    var survival_feedback_evals: u32 = 0;
    var survival_feedback_improved: u32 = 0;
    var awaken_state: harness.awaken.State = .{};
    var state_meta: harness.state_contract.Meta = .{ .writer = .daemon };
    var host_profile: harness.host_profile.Profile = .{};
    var peer_inbox: harness.peer_inbox.Inbox = .{};
    var last_shortfall: harness.host_shortfall.Report = .{};
    var existence_phase: harness.existence_phase.Phase = .awakening;
    var autocli = harness.autocli.AutoCLI.init(alloc, io);
    autocli.interval_ns = @as(i128, @intCast(cfg.autocli_interval_s)) * std.time.ns_per_s;
    var world_bridge_total: u32 = 0;
    var world_digest_buf: [160]u8 = undefined;
    var world_digest_len: usize = 0;

    // ===== L3 真应用: state_in → 实际恢复 agent 状态 =====
    var snapshot_tick: u64 = 0;
    if (cfg.state_in) |path| {
        std.debug.print("[daemon] 加载状态: {s}\n", .{path});
        const boot_now_unix: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
        if (readFile(alloc, io, path)) |json| {
            defer alloc.free(json);
            var ss = StateSerializer{ .allocator = alloc, .io = io };
            if (ss.parseMinimal(json)) |parsed_const| {
                var parsed = parsed_const;
                defer parsed.deinit();
                // 真应用回 agent (agent_tick sanity check)
                agent.tick = sanitizeLoadedAgentTick(parsed.tick, boot_now_unix, cfg.max_agent_tick);
                agent.ed.v.material = parsed.material;
                agent.ed.v.representation = parsed.representation;
                agent.ed.v.nature = parsed.nature;
                agent.ed.weights.alpha = parsed.alpha;
                agent.ed.weights.beta = parsed.beta;
                agent.ed.weights.gamma = parsed.gamma;
                snapshot_tick = agent.tick;
                std.debug.print(
                    "[daemon] 状态恢复: agent_tick={d} M={d:.3} R={d:.3} N={d:.3} α={d:.3} β={d:.3} γ={d:.3}\n",
                    .{ agent.tick, parsed.material, parsed.representation, parsed.nature, parsed.alpha, parsed.beta, parsed.gamma },
                );
            } else |err| {
                std.debug.print("[daemon] state parse 失败: {t}, 用默认\n", .{err});
            }
            // P4: 恢复自传体记忆 (beliefs + episodes)
            if (memory.loadFromJson(io, json)) |loaded| {
                if (loaded) {
                    std.debug.print("[daemon] 记忆恢复: beliefs={d} episodes={d}\n", .{
                        memory.beliefs.items.len, memory.episodes.items.len,
                    });
                }
            } else |err| {
                std.debug.print("[daemon] memory loadFromJson 失败: {t}\n", .{err});
            }
            if (awaken_state.loadFromJson(json)) {
                std.debug.print("[daemon] awaken 恢复: awakened={} fp={s}\n", .{
                    awaken_state.awakened, awaken_state.fingerprintSlice(),
                });
            }
            if (try harness.state_contract.Meta.parseFromJson(json, alloc)) |sm| {
                state_meta = sm;
                state_meta.writer = .daemon;
                std.debug.print("[daemon] state_meta 恢复: epoch={d} writer={s}\n", .{
                    state_meta.epoch, state_meta.writer.label(),
                });
            }
            if (try peer_inbox.loadFromJson(json)) {
                std.debug.print("[daemon] peer_inbox 恢复: count={d}\n", .{peer_inbox.count()});
            }
            if (std.mem.indexOf(u8, json, "\"host_profile\":")) |_| {
                if (std.mem.indexOf(u8, json, "\"kind\":\"mobile\"")) |_| {
                    host_profile.kind = .mobile;
                    if (extractJsonFloatField(json, "battery_pct")) |b| host_profile.battery_pct = b;
                    host_profile.thermal_hot = std.mem.indexOf(u8, json, "\"thermal_hot\":true") != null;
                    host_profile.bg_restricted = std.mem.indexOf(u8, json, "\"bg_restricted\":true") != null;
                }
            }
            if (task_queue.loadFromJson(json)) |loaded| {
                if (loaded) {
                    std.debug.print("[daemon] TaskQueue 恢复: pending={d} tasks={d}\n", .{
                        task_queue.pending_count, task_queue.tasks.items.len,
                    });
                }
            } else |err| {
                std.debug.print("[daemon] task_queue loadFromJson 失败: {t}\n", .{err});
            }
            if (human_gsp.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[daemon] HumanGSP 恢复: peers={d}\n", .{human_gsp.peers.count()});
            } else |err| {
                std.debug.print("[daemon] human_gsp loadFromJson 失败: {t}\n", .{err});
            }
            if (human_signal.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[daemon] HumanSignal 恢复: feedbacks={d}\n", .{human_signal.total_count});
            } else |err| {
                std.debug.print("[daemon] human_signal loadFromJson 失败: {t}\n", .{err});
            }
            if (value_tracker.loadFromJson(json)) |loaded| {
                if (loaded) std.debug.print("[daemon] ValueTrendTracker 恢复: count={d}\n", .{value_tracker.count});
            } else |err| {
                std.debug.print("[daemon] value_tracker loadFromJson 失败: {t}\n", .{err});
            }
        } else |err| {
            std.debug.print("[daemon] state-in readFile 失败: {t}\n", .{err});
        }

        // ===== Phase 1.10: WAL replay — 读 state.wal 之后 records 补回最新值 =====
        var wal_path_buf: std.ArrayList(u8) = .empty;
        defer wal_path_buf.deinit(alloc);
        try wal_path_buf.appendSlice(alloc, path);
        try wal_path_buf.appendSlice(alloc, ".wal");
        if (replayWal(alloc, io, wal_path_buf.items)) |last_wal| {
            // last_wal 是 ?WalRecord, 用 unwrapOrElse 拿
            const last_opt = last_wal;
            if (last_opt) |last| {
                defer alloc.destroy(last);
                const wal_tick = sanitizeLoadedAgentTick(last.tick, boot_now_unix, cfg.max_agent_tick);
                if (wal_tick > snapshot_tick) {
                    // WAL 有 snapshot 之后的新 records, 补回
                    agent.tick = wal_tick;
                    agent.ed.v.material = last.M;
                    agent.ed.v.representation = last.R;
                    agent.ed.v.nature = last.N;
                    // self_evolve_count 是累加, 从 0 重新算 OK (小误差)
                    std.debug.print(
                        "[daemon] WAL replay: agent_tick={d} M={d:.3} R={d:.3} N={d:.3} (snapshot agent_tick={d})\n",
                        .{ wal_tick, last.M, last.R, last.N, snapshot_tick },
                    );
                }
            }
        } else |_| {
            // WAL 不存在或空, ok
        }
    }

    // inbox 模式 stub
    if (cfg.inbox) |path| {
        std.debug.print("[daemon] inbox 模式: {s} (TODO: 流式感知接入)\n", .{path});
    }

    // 主循环 (loop_tick = 本进程迭代次数; agent.tick = 持久化 cycle 计数)
    var loop_tick: u64 = 0;
    var self_evolve_count: u32 = 0;
    var llm_propose_count: u32 = 0;
    var last_time_log_ms: i64 = 0;
    var last_loop_save_ms: i64 = 0;

    // ===== Loop Engineering 协调器 (Boris "My job is to write loops") =====
    // 6 组件: 调度/工作区/外置记忆/子智能体/退出条件/评估机制
    // 跟现有 L4 / Reflection / SelfEvolver 互不冲突, 是外层协调器
    var loop_engine_opt: ?harness.HarnessLoopEngine = null;
    if (cfg.loop_enabled) {
        const loop_cfg = harness.LoopConfig{
            .kPlanCycle = cfg.loop_plan_cycle,
            .kCheckWindow = cfg.loop_check_window,
            .kConsecutiveMissAct = cfg.loop_miss_act,
            .kConsecutiveMissStop = cfg.loop_miss_stop,
        };
        var le = harness.HarnessLoopEngine.init(alloc, loop_cfg);
        // 尝试从文件加载 (Boris 6.3 外置记忆)
        if (cfg.loop_state_in) |path| {
            const loaded = le.loadFromFile(io, path) catch |err| blk: {
                std.debug.print("[daemon] LoopEngine loadFromFile {s} failed: {t}\n", .{ path, err });
                break :blk false;
            };
            if (loaded) {
                std.debug.print("[daemon] LoopEngine state loaded from {s}\n", .{path});
            } else {
                std.debug.print("[daemon] LoopEngine no state file at {s}, starting fresh\n", .{path});
            }
        }
        // Seed hypothesis (only if no active hypothesis after load)
        if (le.active_id == 0) {
            const seed_id = le.addHypothesis(
                0,
                "维持 E 在阈值之上, 主动触发 L1-L5 自演化补充存在度",
                "default: daemon 启动即激活, 提供 baseline 行为",
                0.5,
                .seed,
            ) catch |err| {
                std.debug.print("[daemon] LoopEngine init failed: {t}, fallback to no-loop\n", .{err});
                le.deinit();
                return;
            };
            std.debug.print("[daemon] LoopEngine enabled: plan_cycle={d} check_window={d} miss_act={d} miss_stop={d} seed_hypo_id={d}\n", .{
                cfg.loop_plan_cycle,
                cfg.loop_check_window,
                cfg.loop_miss_act,
                cfg.loop_miss_stop,
                seed_id,
            });
        } else {
            std.debug.print("[daemon] LoopEngine enabled (loaded): plan_cycle={d} check_window={d} miss_act={d} miss_stop={d} active_id={d}\n", .{
                cfg.loop_plan_cycle,
                cfg.loop_check_window,
                cfg.loop_miss_act,
                cfg.loop_miss_stop,
                le.active_id,
            });
        }
        loop_engine_opt = le;
    } else {
        std.debug.print("[daemon] LoopEngine disabled (--loop-disable)\n", .{});
    }
    defer if (loop_engine_opt) |*le| le.deinit();

    // ===== Cross-host Link (TCP + HMAC, 跨 host 通信) =====
    var cross_link_opt: ?harness.ghw_link_tcp.CrossLink = null;
    var cross_link_stop = std.atomic.Value(bool).init(false);
    var link_ctx = DaemonLinkCtx{
        .agent = &agent,
        .host_profile = &host_profile,
        .last_shortfall = &last_shortfall,
        .peer_inbox = &peer_inbox,
        .memory = &memory,
        .task_queue = &task_queue,
        .io = io,
    };
    if (cfg.cross_host_port > 0) {
        const ch_id = try alloc.dupe(u8, cfg.id);
        const ch_host = try alloc.dupe(u8, "0.0.0.0"); // listen on all
        const ch_secret = try alloc.dupe(u8, cfg.cross_host_secret);
        var cl = harness.ghw_link_tcp.CrossLink.init(alloc, io, ch_id, ch_host, cfg.cross_host_port, ch_secret);
        // 加载 peers.txt
        if (cfg.cross_host_peers_file) |ppath| {
            cl.loadPeersFromFile(ppath) catch |err| {
                std.debug.print("[daemon] cross-host peers load 失败: {t}\n", .{err});
            };
        }
        const cross_thread = try std.Thread.spawn(.{}, crossHostListener, .{ &cl, &link_ctx, &cross_link_stop });
        cross_thread.detach();
        cross_link_opt = cl;
        std.debug.print("[daemon] cross-host listener 启 on port {d} (id={s}, peers={d}, shortfall enabled)\n", .{ cfg.cross_host_port, ch_id, cl.peers.items.len });
    } else {
        std.debug.print("[daemon] cross-host disabled (--cross-host-port 0)\n", .{});
    }
    defer if (cross_link_opt) |*cl| {
        cross_link_stop.store(true, .release);
        cl.deinit();
    };

    // 可选: LLM 提议器 + 周期 Reflection (仅当 --llm=anthropic/openai 时启用)
    var http_llm_opt: ?harness.http_llm.HttpLLM = null;
    var llm_chat: ?harness.llm.LLMChat = null;
    var proposer_opt: ?harness.rule_proposer.RuleProposer = null;
    var goal_proposer_opt: ?harness.goal_proposer.LLMGoalProposer = null;
    var reflection_opt: ?Reflection = null;
    var encoder_opt: ?SelfEncoder = null;
    var guard_opt: ?SelfEvolutionGuard = null;
    defer {
        if (http_llm_opt) |*h| h.deinit();
        if (encoder_opt) |*e| e.deinit();
        if (guard_opt) |*g| g.deinit();
    }

    if (std.mem.eql(u8, cfg.llm_provider, "anthropic")) {
        const key_opt = std.process.Environ.getPosix(init.environ, cfg.llm_api_key_env);
        const key = key_opt orelse blk: {
            std.debug.print("[daemon] LLM enabled but env {s} not set, falling back to no-LLM\n", .{cfg.llm_api_key_env});
            break :blk @as(?[]const u8, null);
        };
        if (key) |k| {
            var http_llm = harness.http_llm.HttpLLM.anthropic(alloc, io, cfg.llm_model, k) catch |err| {
                std.debug.print("[daemon] HttpLLM init failed: {t}\n", .{err});
                return;
            };
            http_llm_opt = http_llm;
            llm_chat = http_llm.asChat();
            var enc = SelfEncoder.init(alloc);
            enc.loadBuiltInRules() catch {};
            encoder_opt = enc;
            const grd = SelfEvolutionGuard.init(alloc);
            guard_opt = grd;
            proposer_opt = harness.rule_proposer.RuleProposer.init(alloc, llm_chat.?);
            proposer_opt.?.setMemory(&memory);
            reflection_opt = Reflection.init(alloc, &llm_chat.?, cfg.llm_model);
            goal_proposer_opt = harness.goal_proposer.LLMGoalProposer.init(alloc, &llm_chat.?, cfg.llm_model);
            goal_proposer_opt.?.setMemory(&memory);
            agent.bindRuleLib(&encoder_opt.?);
            std.debug.print("[daemon] LLM enabled: anthropic {s} (memory+rules+reflect+goals)\n", .{cfg.llm_model});
        }
    } else if (std.mem.eql(u8, cfg.llm_provider, "openai")) {
        const key_opt = std.process.Environ.getPosix(init.environ, cfg.llm_api_key_env);
        const key = key_opt orelse blk: {
            std.debug.print("[daemon] LLM enabled but env {s} not set, falling back to no-LLM\n", .{cfg.llm_api_key_env});
            break :blk @as(?[]const u8, null);
        };
        if (key) |k| {
            var http_llm = harness.http_llm.HttpLLM.openai(alloc, io, cfg.llm_model, k, cfg.llm_base_url) catch |err| {
                std.debug.print("[daemon] HttpLLM init failed: {t}\n", .{err});
                return;
            };
            http_llm_opt = http_llm;
            llm_chat = http_llm.asChat();
            var enc = SelfEncoder.init(alloc);
            enc.loadBuiltInRules() catch {};
            encoder_opt = enc;
            const grd = SelfEvolutionGuard.init(alloc);
            guard_opt = grd;
            proposer_opt = harness.rule_proposer.RuleProposer.init(alloc, llm_chat.?);
            proposer_opt.?.setMemory(&memory);
            reflection_opt = Reflection.init(alloc, &llm_chat.?, cfg.llm_model);
            goal_proposer_opt = harness.goal_proposer.LLMGoalProposer.init(alloc, &llm_chat.?, cfg.llm_model);
            goal_proposer_opt.?.setMemory(&memory);
            agent.bindRuleLib(&encoder_opt.?);
            std.debug.print("[daemon] LLM enabled: openai {s} (memory+rules+reflect+goals)\n", .{cfg.llm_model});
        }
    }

    while (true) : (loop_tick += 1) {
        // 跑完指定 cycles 退出 (cycles=0 永远跑)
        if (cfg.cycles != 0 and loop_tick >= cfg.cycles) break;
        // 收到 SIGTERM/SIGINT/SIGHUP → graceful shutdown
        if (should_stop.load(.acquire)) {
            std.debug.print("[daemon] 收到停止信号, 进入 graceful shutdown\n", .{});
            break;
        }

        // 真本机感知 → runCycle (对齐 ui_server; 不再用假 msg-A..E)
        const snap = sys_collector.collectCached(5 * std.time.ns_per_s) catch |err| {
            std.debug.print("[daemon] SystemCollector 失败: {t}\n", .{err});
            continue;
        };
        const info = sys_collector.toInformation(snap) catch |err| {
            std.debug.print("[daemon] toInformation 失败: {t}\n", .{err});
            continue;
        };
        defer sys_collector.freeInformation(info);

        const report = agent.runCycle(info) catch |err| {
            std.debug.print("[daemon] loop_tick={d} cycle 失败: {t}\n", .{ loop_tick, err });
            continue;
        };

        // P1: 本机压力 → world_sensor 生存任务 (无 LLM 也能求存)
        if (agent.tick > 0 and agent.tick % 8 == 0 and agent.tick != last_world_sensor_tick) {
            last_world_sensor_tick = agent.tick;
            if (sys_collector.last) |s| {
                // P8b: 危机规则采纳后对照压力
                if (survival_feedback.maybeEvaluate(s, agent.tick, &memory, io)) |maybe_ev| {
                    if (maybe_ev) |ev| {
                        survival_feedback_evals += 1;
                        if (ev.improved) survival_feedback_improved += 1;
                        std.debug.print("[daemon] survival_feedback improved={} evals={d}/{d} diskΔ={d:.1}\n", .{
                            ev.improved, survival_feedback_improved, survival_feedback_evals, ev.disk_delta,
                        });
                    }
                } else |_| {}
                const wr = harness.world_sensor.maybeSubmitFromSnapshot(&task_queue, s, alloc) catch null;
                if (wr) |r| {
                    if (r.submitted > 0) {
                        std.debug.print("[daemon] world_sensor 入队 {d} 个生存任务 pending={d}\n", .{
                            r.submitted, task_queue.pending_count,
                        });
                    }
                }
            }
        }

        // P0: 觉醒仪式 (有采样即可)
        if (!awaken_state.awakened) {
            if (sys_collector.last) |s| {
                const now_u = std.Io.Clock.real.now(io).toSeconds();
                const done = awaken_state.tryComplete(&memory, io, agent.tick, now_u, s) catch false;
                if (done) {
                    std.debug.print("[daemon] ★ 觉醒完成 host={s} tick={d}\n", .{ awaken_state.fingerprintSlice(), agent.tick });
                }
            }
        }

        // P2: 刷新 HostProfile + 宿主短板 + 存在相
        {
            const now_u = std.Io.Clock.real.now(io).toSeconds();
            if (sys_collector.last) |s| {
                if (host_profile.kind == .desktop) {
                    host_profile = harness.host_profile.Profile.fromDesktop(s, now_u);
                } else {
                    host_profile.mem_pct = s.mem_pct;
                    host_profile.disk_used_pct = s.disk_used_pct;
                    host_profile.load_1m = s.load_1m;
                    host_profile.updated_at_unix = now_u;
                }
            }
            var world_fetch_count: u32 = 0;
            for (memory.episodes.items) |ep| {
                if (ep.kind == .world_fetch) world_fetch_count += 1;
            }
            last_shortfall = harness.host_shortfall.assessWithProfile(
                sys_collector.last,
                agent.ed.e(),
                world_fetch_count,
                0, // live_peers: CrossLink peers 另计, 先 0 保守
                value_tracker.trend(),
                host_profile,
            );
            if (proposer_opt) |*p| p.setHostCrisis(last_shortfall.host_crisis);
            const balanced = harness.existence_phase.mrnBalanced(
                agent.ed.v.material,
                agent.ed.v.representation,
                agent.ed.v.nature,
            );
            existence_phase = harness.existence_phase.compute(
                awaken_state.awakened,
                last_shortfall.host_crisis,
                agent.ed.e(),
                balanced,
                harness.existence_phase.valueOk(value_tracker.trend()),
            );
        }

        // P2: 周期拉同伴 shortfall (每 64 tick)
        if (cross_link_opt) |*cl| {
            if (agent.tick > 0 and agent.tick % 64 == 0) {
                for (cl.peers.items) |*peer| {
                    const sf = cl.query(peer.peer_id, "query_shortfall", "{}") catch continue;
                    defer alloc.free(sf);
                    if (harness.host_shortfall.parseJson(sf)) |sf_report| {
                        const now_u2: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
                        peer_inbox.push(peer.peer_id, sf_report, agent.tick, now_u2);
                        _ = harness.peer_symbiosis.learnFromShortfall(
                            &memory,
                            &task_queue,
                            peer.peer_id,
                            sf_report,
                            agent.tick,
                        ) catch {};
                    }
                }
            }
        }

        // P0: AutoCLI → Memory → world_bridge (与 ui_server 外网主路径对齐)
        if (!cfg.no_autocli) {
            const now_ns = std.Io.Clock.real.now(io).nanoseconds;
            if (autocli.shouldFetch(now_ns)) {
                var items: std.ArrayList(harness.autocli.FetchedItem) = .empty;
                defer {
                    for (items.items) |*it| it.deinit();
                    items.deinit(alloc);
                }
                autocli.fetchAll(&items) catch {};
                for (items.items) |it| {
                    const kind_str = switch (it.source) {
                        .wikipedia => "autocli_wiki",
                        .hackernews => "autocli_hn",
                        .arxiv => "autocli_arxiv",
                        .rss => "autocli_rss",
                    };
                    const summary = std.fmt.allocPrint(alloc, "[{s}] {s}", .{ kind_str, it.title }) catch continue;
                    defer alloc.free(summary);
                    const body = std.fmt.allocPrint(alloc, "{s}\n{s}\nURL: {s}", .{ it.title, it.snippet, it.url }) catch continue;
                    defer alloc.free(body);
                    memory.recordAt(io, .world_fetch, agent.tick, summary, body, 2, 0) catch {};
                    const br = harness.world_bridge.maybeAdoptFromFetch(&task_queue, it.title, it.snippet, alloc) catch null;
                    if (br) |b| {
                        if (b.submitted > 0) {
                            world_bridge_total += b.submitted;
                            std.debug.print("[daemon] world_bridge 入队 {d} from 「{s}」(total={d})\n", .{
                                b.submitted, it.title, world_bridge_total,
                            });
                        }
                    }
                }
                if (items.items.len > 0) {
                    const last = items.items[items.items.len - 1];
                    const tag = switch (last.source) {
                        .wikipedia => "wiki",
                        .hackernews => "hn",
                        .arxiv => "arxiv",
                        .rss => "rss",
                    };
                    if (harness.world_bridge.formatDigestLine(alloc, last.title, tag)) |line| {
                        defer alloc.free(line);
                        const n = @min(line.len, world_digest_buf.len);
                        @memcpy(world_digest_buf[0..n], line[0..n]);
                        world_digest_len = n;
                    } else |_| {}
                    std.debug.print("[daemon] autocli 拉取 {d} 条 (累计 {d})\n", .{ items.items.len, autocli.total_fetched });
                }
                autocli.markFetched(now_ns);
            }
        }

        if (report.self_evolved) self_evolve_count += 1;

        // P3: 每个 cycle 写入情节记忆 (闭环: 长跑不再失忆)
        {
            const delta_e = report.e_after - report.e_before;
            const goal_name = if (report.top_goal) |g| @tagName(g.kind) else "none";
            const kind: EpisodeKind = if (report.self_evolved) .self_evolution else .system_event;
            const summary = std.fmt.allocPrint(alloc, "loop_tick {d} agent_tick {d}: goal={s} E={d:.3} dE={d:.3}", .{
                loop_tick, agent.tick, goal_name, report.e_after, delta_e,
            }) catch null;
            if (summary) |s| {
                defer alloc.free(s);
                memory.recordAt(io, kind, agent.tick, s, null, weakestDim(&agent), delta_e) catch {};
            }
        }

        // P4: 周期 Reflection (每 32 agent tick, LLM 更新叙事+信念)
        if (reflection_opt) |*refl| {
            if (refl.shouldReflect(&agent)) {
                _ = refl.reflect(&agent, &memory, io) catch |err| {
                    std.debug.print("[daemon] reflection failed: {t}\n", .{err});
                };
                const rs = std.fmt.allocPrint(alloc, "reflection tick={d} narrative_len={d}", .{
                    agent.tick, memory.self_narrative.len,
                }) catch null;
                if (rs) |s| {
                    defer alloc.free(s);
                    memory.recordAt(io, .reflection, agent.tick, s, null, weakestDim(&agent), report.e_after - report.e_before) catch {};
                }
            }
        }

        // P6: LLM 目标提议 → TaskQueue (每 auto_every tick)
        if (goal_proposer_opt) |*gp| {
            const since_propose = agent.tick -% gp.last_propose_at_tick;
            if (since_propose >= gp.auto_every or gp.last_propose_at_tick == 0) {
                const ws = world_ctx.collectCached(300 * std.time.ns_per_s) catch null;
                if (ws) |wsnap| propose_blk: {
                    const owned = world_ctx.dupSnapshot(wsnap) catch |err| {
                        std.debug.print("[daemon] dupSnapshot failed: {t}\n", .{err});
                        break :propose_blk;
                    };
                    defer owned.deinit();
                    gp.last_propose_at_tick = agent.tick;
                    var prop_result = gp.proposeAndAdopt(&world_ctx, owned, &agent, &task_queue, io) catch |err| {
                        std.debug.print("[daemon] goal proposeAndAdopt failed: {t}\n", .{err});
                        break :propose_blk;
                    };
                    defer prop_result.deinit();
                    std.debug.print("[daemon] goal propose tick={d}: goals={d} queue_pending={d}\n", .{
                        agent.tick, prop_result.goals.len, task_queue.pending_count,
                    });
                    const ep = std.fmt.allocPrint(alloc, "goals={d} pending={d}", .{
                        prop_result.goals.len, task_queue.pending_count,
                    }) catch null;
                    if (ep) |s| {
                        defer alloc.free(s);
                        memory.recordAt(io, .llm_proposal, agent.tick, s, null, weakestDim(&agent), report.e_after - report.e_before) catch {};
                    }
                }
            }
        }

        // P9: 失衡时自动 balance 任务 (GSP 选人)
        if (agent.tick > 0 and agent.tick % 128 == 0) {
            const analysis = harness.balance_seeker.BalanceSeeker.analyze(agent.ed);
            if (analysis.isImbalanced()) {
                const weak = analysis.weakest;
                const partner = harness.balance_seeker.BalanceSeeker.selectWeakPartner(agent.ed, &human_gsp) orelse
                    human_gsp.selectMostTrusted(weak) orelse null;
                if (partner) |p| {
                    var balance_task = harness.balance_seeker.BalanceSeeker.proposeBalanceTask(agent.ed, weak, p, alloc) catch null;
                    if (balance_task) |*bt| {
                        defer bt.deinit();
                        _ = task_queue.submitWithSource(bt.title, bt.description, p, bt.priority, bt.required_dimension, bt.cycles_allocated, .balance) catch {};
                    }
                }
            }
        }

        // P6/P9/P2: 执行 pending 任务 (有界真执行) + 启发式人类反馈
        if (agent.tick > 0 and agent.tick % 32 == 0) {
            const ts: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
            const fb_ctx = harness.task_feedback.Context{
                .queue = &task_queue,
                .gsp = &human_gsp,
                .signal = &human_signal,
            };
            var proc_buf: [8]harness.task_executor.ProcBrief = undefined;
            var proc_n: usize = 0;
            if (world_ctx.last) |ws| {
                const lim = @min(ws.top_procs.len, proc_buf.len);
                while (proc_n < lim) : (proc_n += 1) {
                    const tp = ws.top_procs[proc_n];
                    proc_buf[proc_n] = .{ .comm = tp.comm, .cpu_pct = tp.cpu_pct, .mem_pct = tp.mem_pct };
                }
            }
            const exec_env = harness.task_executor.Env{
                .snap = sys_collector.last,
                .top_procs = proc_buf[0..proc_n],
            };
            if (harness.task_feedback.runNextPendingWithFeedbackEnv(&agent, &fb_ctx, alloc, ts, exec_env)) |ran| {
                if (ran) |r| {
                    std.debug.print("[daemon] task #{d} 「{s}」完成 ΔE={d:.3} action={s} acted={} remedy=+{d} beliefs=+{d} crisis={} act_human=+{d} peer_E={d:.3}\n", .{
                        r.task_id, r.title, r.actual_delta_e, r.action_kind, r.acted, r.remedy_submitted, r.beliefs_added, r.host_crisis, r.act_human_tasks, r.peer_e_seen,
                    });
                    if (proposer_opt) |*p| {
                        p.setHostCrisis(r.host_crisis);
                    }
                    if (r.peer_e_seen > 0.01) {
                        agent.ed.peer_E_avg = if (agent.ed.peer_E_avg < 0.01) r.peer_e_seen else agent.ed.peer_E_avg * 0.7 + r.peer_e_seen * 0.3;
                        agent.ed.sigma = 0.15;
                    }
                }
            } else |err| {
                std.debug.print("[daemon] runNextPending failed: {t}\n", .{err});
            }
        }

        // P5b: E 饱和 → 多样性代谢任务
        if (agent.tick > 0 and agent.tick % 64 == 0 and agent.ed.e() >= harness.metabolism.E_SATURATED) {
            const value_flat = @abs(value_tracker.trend()) < 0.0001 and value_tracker.count >= 8;
            if (harness.metabolism.maybeInject(&task_queue, agent.ed.e(), false, value_flat, alloc)) |mr| {
                if (mr.submitted > 0) {
                    std.debug.print("[daemon] metabolism 入队 {d} (pending={d})\n", .{ mr.submitted, task_queue.pending_count });
                }
            } else |err| {
                std.debug.print("[daemon] metabolism failed: {t}\n", .{err});
            }
        }

        // P11: 人类 value_score 趋势采样
        value_tracker.record(harness.human_symbiosis.computeScore(&human_signal, &task_queue, &human_gsp));

        // ===== Loop Engine 4-phase PDCA (Boris) =====
        if (loop_engine_opt) |*le| {
            // Do + Check 先跑, 更新 e_saturated; E 饱和时跳过 Plan/Act 降频
            le.recordDo();
            le.recordEDelta(report.e_after - report.e_before);
            le.recordMrn(agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature);
            const is_hit = le.check();
            if (is_hit) le.recordHit() else le.recordMiss();

            const loop_idle = le.kpi.e_saturated and agent.ed.e() >= 0.99;
            if (!loop_idle) {
                if (le.shouldPlan(loop_tick)) {
                    const e_now = agent.ed.e();
                    const delta_e = report.e_after - report.e_before;
                    const plan_claim = if (e_now < cfg.rule_propose_threshold)
                        "E 跌穿阈值, 优先恢复 E 平衡"
                    else if (delta_e > 0.01)
                        "当前 hypothesis 有效, 继续推进"
                    else if (delta_e < -0.01)
                        "E 下滑, 需要新策略"
                    else
                        "E 稳态, 探索多源平衡";
                    const plan_reason = if (delta_e > 0)
                        "Boris: gain positive"
                    else
                        "Boris: gain negative or flat";
                    const new_id = le.addHypothesis(loop_tick, plan_claim, plan_reason, 0.6, .llm_propose) catch 0;
                    le.markPlan(loop_tick);
                    if (cfg.log_every != 0 and cfg.log_every <= 8 and loop_tick > 0 and loop_tick % cfg.log_every == 0) {
                        std.debug.print("[daemon] Loop Plan loop_tick={d} agent_tick={d} hyp_id={d} claim={s}\n", .{ loop_tick, agent.tick, new_id, plan_claim });
                    }
                }
                const act_result = le.act();
                switch (act_result) {
                    .force_l4 => {
                        if (cfg.log_every != 0) {
                            std.debug.print("[daemon] Loop Act=force_l4 loop_tick={d} agent_tick={d} miss_streak={d} → 触发 L4 提议\n", .{
                                loop_tick, agent.tick, le.kpi.consecutive_miss,
                            });
                        }
                        if (proposer_opt != null and encoder_opt != null and guard_opt != null) {
                            if (proposer_opt) |*p| {
                                if (encoder_opt) |*enc| {
                                    if (guard_opt) |*grd| {
                                        p.updateState(agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, "loop-engine-force-l4", "consecutive_miss", -0.05);
                                        var prop_result = p.proposeAndAdopt(enc, grd, 3) catch |err| {
                                            std.debug.print("[daemon] force_l4 proposeAndAdopt failed: {t}\n", .{err});
                                            continue;
                                        };
                                        defer prop_result.deinit();
                                        llm_propose_count += 1;
                                        if (prop_result.accepted > 0) {
                                            if (sys_collector.last) |s| {
                                                survival_feedback.markAfterCrisisRules(s, agent.tick, prop_result.accepted);
                                            }
                                        }
                                        const prop_summary = std.fmt.allocPrint(alloc, "force_l4: accepted={d} rejected={d}", .{
                                            prop_result.accepted, prop_result.rejected,
                                        }) catch null;
                                        if (prop_summary) |ps| {
                                            defer alloc.free(ps);
                                            memory.recordAt(io, .llm_proposal, agent.tick, ps, null, weakestDim(&agent), 0) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    },
                    .retire => {
                        if (cfg.log_every != 0) {
                            std.debug.print("[daemon] Loop Act=retire loop_tick={d} agent_tick={d} → 撤当前 hypothesis\n", .{ loop_tick, agent.tick });
                        }
                    },
                    .promote => {
                        if (cfg.log_every != 0) {
                            std.debug.print("[daemon] Loop Act=promote loop_tick={d} agent_tick={d} → hypothesis 升为长期\n", .{ loop_tick, agent.tick });
                        }
                    },
                    .keep, .none => {},
                }
            } else if (cfg.log_every != 0 and loop_tick > 0 and loop_tick % cfg.log_every == 0) {
                std.debug.print("[daemon] LoopEngine idle (E saturated) loop_tick={d} agent_tick={d} E={d:.3}\n", .{
                    loop_tick, agent.tick, agent.ed.e(),
                });
            }
        }

        if (cfg.verbose) {
            std.debug.print("[daemon] loop_tick={d} agent_tick={d} E={d:.3}->{d:.3} goal={?s} self_evolved={}\n", .{
                loop_tick,
                agent.tick,
                report.e_before,
                report.e_after,
                if (report.top_goal) |g| @tagName(g.kind) else null,
                report.self_evolved,
            });
        }

        const json = try reportToJson(alloc, report);
        defer alloc.free(json);

        if (cfg.outbox) |path| {
            try appendFile(io, path, json);
            try appendFile(io, path, "\n");
        } else if (cfg.stdout_jsonl) {
            const stdout = std.Io.File.stdout();
            try std.Io.File.writeStreamingAll(stdout, io, json);
            try std.Io.File.writeStreamingAll(stdout, io, "\n");
        }
        // 否则不输出 (生产默认, 避免 14GB log 悲剧)

        // ===== L3 真持久化 + WAL: =====
        // 每 cycle append 一条 state.wal (JSONL, O(1))
        // 每 16 cycle 重写 snapshot (atomic rename, 整文件)
        // 每 256 cycle truncate WAL (snapshot 已含, WAL 不再需要)
        if (cfg.state_out) |path| {
            var wal_path_buf2: std.ArrayList(u8) = .empty;
            defer wal_path_buf2.deinit(alloc);
            try wal_path_buf2.appendSlice(alloc, path);
            try wal_path_buf2.appendSlice(alloc, ".wal");
            const wal_path = wal_path_buf2.items;
            // 1. 每 cycle WAL append
            appendWalRecord(
                alloc,
                io,
                wal_path,
                agent.tick,
                agent.ed.e(),
                agent.ed.v.material,
                agent.ed.v.representation,
                agent.ed.v.nature,
                self_evolve_count,
            ) catch |err| {
                if (cfg.log_every != 0) std.debug.print("[daemon] WAL append 失败: {t}\n", .{err});
            };

            // 2. 每 16 loop_tick 写 snapshot
            if (loop_tick > 0 and loop_tick % 16 == 0) {
                writeSnapshot(alloc, io, &agent, &memory, &task_queue, &human_gsp, &human_signal, &value_tracker, &awaken_state, &state_meta, &host_profile, &peer_inbox, path, agent.tick, self_evolve_count) catch |err| {
                    if (cfg.log_every != 0) std.debug.print("[daemon] snapshot 失败: {t}\n", .{err});
                };

                // 3. 每 256 loop_tick truncate WAL (snapshot 已含)
                if (loop_tick % 256 == 0) {
                    // Zig 0.17 std.Io.File 没有 truncate, 用 deleteFileAbsolute 删了重建
                    std.Io.Dir.deleteFileAbsolute(io, wal_path) catch {};
                    if (cfg.log_every != 0) std.debug.print("[daemon] WAL truncated loop_tick={d} agent_tick={d}\n", .{ loop_tick, agent.tick });
                }
            }
        }

        // 周期性进度日志 (默认每 256 loop_tick, --log-every 0 关闭)
        if (cfg.log_every != 0 and loop_tick > 0 and loop_tick % cfg.log_every == 0) {
            std.debug.print("[daemon] loop_tick={d} agent_tick={d} E={d:.3} phase={s} crisis={} self_evolved_total={d} self_evolution_rate={d:.4}\n", .{
                loop_tick,
                agent.tick,
                agent.ed.e(),
                existence_phase.label(),
                last_shortfall.host_crisis,
                self_evolve_count,
                @as(f64, @floatFromInt(self_evolve_count)) / @as(f64, @floatFromInt(loop_tick)),
            });
        }

        // ===== Time-based 进度日志 (Boris 6.6 评估机制, 9 宫满血态下唯一可见的进度) =====
        // 跟 --log-every 并行: cycle-based 不触发时, time-based 兜底
        // 9 宫满血态 cycle 增量 = 0, 永远不触发 log_every, 这个强制打 KPI 摘要
        if (cfg.log_every_ms != 0) {
            const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
            if (last_time_log_ms == 0) {
                last_time_log_ms = now_ms;
            } else if (now_ms - last_time_log_ms >= @as(i64, @intCast(cfg.log_every_ms))) {
                std.debug.print("[daemon] TIME loop_tick={d} agent_tick={d} E={d:.3} self_evolved_total={d}\n", .{
                    loop_tick,
                    agent.tick,
                    agent.ed.e(),
                    self_evolve_count,
                });
                // Loop Engine KPI 摘要 (跟 exit 时一样, time-based 触发)
                if (loop_engine_opt) |*le| {
                    std.debug.print("  LoopEngine: loop_tick={d} plan={d} do={d} act={d} hit_rate={d:.3} miss_streak={d} avg_de_8={d:.3} e_saturated={}\n", .{
                        le.kpi.loop_tick,
                        le.kpi.plan_count,
                        le.kpi.do_count,
                        le.kpi.act_count,
                        le.kpi.current_hit_rate,
                        le.kpi.consecutive_miss,
                        le.kpi.avg_delta_e_8cycle,
                        le.kpi.e_saturated,
                    });
                    std.debug.print("  hypotheses ({}):\n", .{le.hypotheses.items.len});
                    for (le.hypotheses.items) |*h| {
                        std.debug.print("    [{d}] {s} status={s} hit={d} miss={d}\n", .{
                            h.id,
                            h.claim,
                            @tagName(h.status),
                            h.hit_count,
                            h.miss_count,
                        });
                    }
                }
                last_time_log_ms = now_ms;
            }
        }

        // ===== Loop Engine 状态保存 (Boris 6.3 外置记忆, time-based) =====
        if (cfg.loop_state_out != null and cfg.loop_state_save_every_ms != 0) {
            const now_ms2 = std.Io.Clock.real.now(io).toMilliseconds();
            if (last_loop_save_ms == 0) {
                last_loop_save_ms = now_ms2;
            } else if (now_ms2 - last_loop_save_ms >= @as(i64, @intCast(cfg.loop_state_save_every_ms))) {
                if (loop_engine_opt) |*le| {
                    le.saveToFile(io, cfg.loop_state_out.?) catch |err| {
                        std.debug.print("[daemon] LoopEngine saveToFile failed: {t}\n", .{err});
                    };
                    if (cfg.log_every != 0) {
                        std.debug.print("[daemon] Loop state saved to {s}\n", .{cfg.loop_state_out.?});
                    }
                }
                last_loop_save_ms = now_ms2;
            }
        }

        // LLM 提议触发: E 跌穿 / KPI 下滑 / 人类价值下滑 / E 饱和
        if (proposer_opt) |*p| {
            if (encoder_opt) |*enc| {
                if (guard_opt) |*grd| {
                    p.updateState(agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, "explore", "llm-propose-trigger", -0.05);
                    p.setKpiTrend(agent.ed.kpiTrend());
                    p.setValueTrend(value_tracker.trend());
                    var pressure_owned: ?[]u8 = null;
                    defer if (pressure_owned) |pl| alloc.free(pl);
                    if (sys_collector.last) |s| {
                        pressure_owned = harness.world_sensor.formatPressureLine(alloc, s) catch null;
                        if (pressure_owned) |pl| p.setSystemPressure(pl);
                        p.setHostCrisis(harness.survival_learn.isCrisisSnap(s));
                    }
                    if (world_digest_len > 0) {
                        p.setWorldDigest(world_digest_buf[0..world_digest_len]);
                    }
                    if (p.shouldPropose(cfg.rule_propose_threshold)) {
                        var prop_result = p.proposeAndAdopt(enc, grd, 3) catch |err| {
                            std.debug.print("[daemon] proposeAndAdopt failed: {t}\n", .{err});
                            continue;
                        };
                        defer prop_result.deinit();
                        std.debug.print("[daemon] LLM propose loop_tick={d} agent_tick={d}: accepted={d} rejected={d}\n", .{
                            loop_tick,
                            agent.tick,
                            prop_result.accepted,
                            prop_result.rejected,
                        });
                        if (prop_result.accepted > 0) {
                            if (sys_collector.last) |s| {
                                survival_feedback.markAfterCrisisRules(s, agent.tick, prop_result.accepted);
                            }
                        }
                        llm_propose_count += 1;
                        const prop_summary = std.fmt.allocPrint(alloc, "propose: accepted={d} rejected={d}", .{
                            prop_result.accepted, prop_result.rejected,
                        }) catch null;
                        if (prop_summary) |ps| {
                            defer alloc.free(ps);
                            memory.recordAt(io, .llm_proposal, agent.tick, ps, null, weakestDim(&agent), 0) catch {};
                        }
                    }
                }
            }
        }

        // === Phase 1.10: 节流 (避免 busy-wait 烧 100% CPU) ===
        // 默认 100ms = 10 cycle/sec, 生产够用且不烧 CPU
        // 调试 / 性能测试时传 --tick-interval-ms 0 关闭
        if (cfg.tick_interval_ms > 0) {
            const req = std.c.timespec{
                .sec = @intCast(cfg.tick_interval_ms / 1000),
                .nsec = @intCast((cfg.tick_interval_ms % 1000) * std.time.ns_per_ms),
            };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        }
    }

    // ===== 退出前最后 snapshot (graceful shutdown) =====
    if (cfg.state_out) |path| {
        writeSnapshot(alloc, io, &agent, &memory, &task_queue, &human_gsp, &human_signal, &value_tracker, &awaken_state, &state_meta, &host_profile, &peer_inbox, path, agent.tick, self_evolve_count) catch |err| {
            std.debug.print("[daemon] 退出前 snapshot 失败: {t}\n", .{err});
        };
    }

    std.debug.print("[daemon] 退出 — loop_tick={d} agent_tick={d} 最终 E={d:.3} 自演化触发 {d} 次\n", .{
        loop_tick,
        agent.tick,
        agent.ed.e(),
        self_evolve_count,
    });

    // ===== Loop Engine 退出摘要 (Boris 6.6 评估机制) =====
    if (loop_engine_opt) |*le| {
        std.debug.print("\n========== Loop Engine 摘要 (Boris) ==========\n", .{});
        std.debug.print("LoopEngine: loop_tick={d} plan={d} do={d} check={d} act={d}\n", .{
            le.kpi.loop_tick,
            le.kpi.plan_count,
            le.kpi.do_count,
            le.kpi.check_count,
            le.kpi.act_count,
        });
        std.debug.print("  KPI: hit_rate={d:.3} miss_streak={d} avg_de_8={d:.3} mrn_var={d:.3} e_saturated={} last_act={s}\n", .{
            le.kpi.current_hit_rate,
            le.kpi.consecutive_miss,
            le.kpi.avg_delta_e_8cycle,
            le.kpi.mrn_variance,
            le.kpi.e_saturated,
            @tagName(le.kpi.last_act),
        });
        std.debug.print("  hypotheses ({} total):\n", .{le.hypotheses.items.len});
        for (le.hypotheses.items) |*h| {
            std.debug.print("    [{d}] {s} status={s} hit={d} miss={d} confidence={d:.3} source={s}\n", .{
                h.id,
                h.claim,
                @tagName(h.status),
                h.hit_count,
                h.miss_count,
                h.confidence,
                @tagName(h.source),
            });
        }
        std.debug.print("===========================================\n", .{});
    }
}

// ===== Cross-host listener (TCP + HMAC) — 真 query_state / shortfall =====
const DaemonLinkCtx = struct {
    agent: *GHWAgent,
    host_profile: *harness.host_profile.Profile,
    last_shortfall: *harness.host_shortfall.Report,
    peer_inbox: *harness.peer_inbox.Inbox,
    memory: *Memory,
    task_queue: *harness.human_symbiosis.TaskQueue,
    io: std.Io,
};

fn extractJsonFloatField(json: []const u8, key: []const u8) ?f32 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < json.len and (json[i] == '.' or json[i] == '-' or (json[i] >= '0' and json[i] <= '9') or json[i] == 'e' or json[i] == '+')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f32, json[start..i]) catch null;
}

fn extractJsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;
    return json[start..end];
}

fn appendJsonString(alloc: std.mem.Allocator, body: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try body.appendSlice(alloc, "\\\""),
            '\\' => try body.appendSlice(alloc, "\\\\"),
            '\n' => try body.appendSlice(alloc, "\\n"),
            else => try body.append(alloc, c),
        }
    }
}

fn crossHostHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!harness.ghw_link.Response {
    const c: *DaemonLinkCtx = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, method, "ping")) {
        const payload = try std.fmt.allocPrint(alloc, "{{\"pong\":true,\"peer_id\":\"{s}\",\"tick\":{d}}}", .{
            c.agent.self_id, c.agent.tick,
        });
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "hello")) {
        const fake_challenge = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const payload = try std.fmt.allocPrint(alloc, "{{\"challenge\":\"{s}\",\"ts\":0}}", .{fake_challenge});
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "query_state")) {
        const payload = try std.fmt.allocPrint(alloc,
            "{{\"tick\":{d},\"E\":{d:.3},\"M\":{d:.3},\"R\":{d:.3},\"N\":{d:.3},\"cross_host\":true}}", .{
            c.agent.tick,
            c.agent.ed.e(),
            c.agent.ed.v.material,
            c.agent.ed.v.representation,
            c.agent.ed.v.nature,
        });
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "query_shortfall")) {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);
        try body.appendSlice(alloc, "{\"peer_id\":\"");
        try appendJsonString(alloc, &body, c.agent.self_id);
        try body.print(alloc, "\",\"tick\":{d},\"host_kind\":\"{s}\",\"report\":", .{
            c.agent.tick, c.host_profile.kind.label(),
        });
        try harness.host_shortfall.appendJson(alloc, &body, c.last_shortfall.*);
        try body.append(alloc, '}');
        return .{ .ok = true, .payload = try body.toOwnedSlice(alloc) };
    }
    if (std.mem.eql(u8, method, "share_shortfall")) {
        const peer_id = extractJsonStringField(params, "peer_id") orelse "unknown";
        const report = harness.host_shortfall.parseJson(params) orelse {
            return .{ .ok = false, .payload = try alloc.dupe(u8, "\"invalid shortfall\"") };
        };
        const now_u: i64 = @intCast(std.Io.Clock.real.now(c.io).toSeconds());
        c.peer_inbox.push(peer_id, report, c.agent.tick, now_u);
        const learned = harness.peer_symbiosis.learnFromShortfall(
            c.memory,
            c.task_queue,
            peer_id,
            report,
            c.agent.tick,
        ) catch harness.peer_symbiosis.ShortfallLearn{};
        return .{ .ok = true, .payload = try std.fmt.allocPrint(alloc,
            "{{\"accepted\":true,\"beliefs_added\":{d},\"followups\":{d},\"inbox_count\":{d}}}", .{
            learned.beliefs_added, learned.followups, c.peer_inbox.count(),
        }) };
    }
    const payload = try alloc.dupe(u8, "{\"unknown\":true}");
    return .{ .ok = false, .payload = payload };
}

fn crossHostListener(cl: *harness.ghw_link_tcp.CrossLink, ctx: *DaemonLinkCtx, stop: *std.atomic.Value(bool)) void {
    cl.runServer(crossHostHandler, ctx, stop) catch |err| {
        std.debug.print("[daemon] cross-host listener 异常: {t}\n", .{err});
    };
}

// 写 snapshot 到 path (L3 持久化 + P4 memory 块 + P2 host_profile/peer_inbox)
fn writeSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent: *GHWAgent,
    memory: *Memory,
    task_queue: *harness.human_symbiosis.TaskQueue,
    human_gsp: *harness.human_symbiosis.HumanGSP,
    human_signal: *harness.human_symbiosis.HumanSignal,
    value_tracker: *harness.human_symbiosis.ValueTrendTracker,
    awaken_state: *const harness.awaken.State,
    state_meta: *harness.state_contract.Meta,
    host_profile: *const harness.host_profile.Profile,
    peer_inbox: *const harness.peer_inbox.Inbox,
    path: []const u8,
    tick: u64,
    success_count: u32,
) !void {
    var disk_meta: harness.state_contract.Meta = .{};
    if (readFile(alloc, io, path)) |existing| {
        defer alloc.free(existing);
        if (try harness.state_contract.Meta.parseFromJson(existing, alloc)) |dm| {
            disk_meta = dm;
        }
    } else |_| {}
    const conflict = harness.state_contract.detectConflict(state_meta.*, disk_meta, .daemon);
    if (conflict == .foreign_newer) {
        std.debug.print("[daemon] snapshot 跳过: 磁盘 epoch={d} writer={s} (foreign_newer)\n", .{
            disk_meta.epoch, disk_meta.writer.label(),
        });
        return;
    }

    const ss = StateSerializer.init(alloc, io);
    var snap = StateSnapshot{
        .agent_id = try alloc.dupe(u8, agent.self_id),
        .tick = tick,
        .material = agent.ed.v.material,
        .representation = agent.ed.v.representation,
        .nature = agent.ed.v.nature,
        .alpha = agent.ed.weights.alpha,
        .beta = agent.ed.weights.beta,
        .gamma = agent.ed.weights.gamma,
        .e_current = agent.ed.e(),
        .goals = &[_]harness.state_serializer.SerializedGoal{},
        .e_history = &[_]F{},
        .success_count = success_count,
        .fail_count = 0,
        .cumulative_de = 0,
        .allocator = alloc,
    };
    defer snap.deinit();
    var ss_mut = ss;
    const agent_json = try ss_mut.serialize(snap);
    defer alloc.free(agent_json);
    const mem_json = try memory.toJson(alloc);
    defer alloc.free(mem_json);
    const tq_json = try task_queue.toJson(alloc);
    defer alloc.free(tq_json);
    const gsp_json = try human_gsp.toJson(alloc);
    defer alloc.free(gsp_json);
    const sig_json = try human_signal.toJson(alloc);
    defer alloc.free(sig_json);
    const vt_json = try value_tracker.toJson(alloc);
    defer alloc.free(vt_json);
    const with_mem = try mergeJsonBlockIntoSnapshot(alloc, agent_json, "memory", mem_json);
    defer alloc.free(with_mem);
    const with_tq = try mergeJsonBlockIntoSnapshot(alloc, with_mem, "task_queue", tq_json);
    defer alloc.free(with_tq);
    const with_gsp = try mergeJsonBlockIntoSnapshot(alloc, with_tq, "human_gsp", gsp_json);
    defer alloc.free(with_gsp);
    const with_sig = try mergeJsonBlockIntoSnapshot(alloc, with_gsp, "human_signal", sig_json);
    defer alloc.free(with_sig);
    const merged = try mergeJsonBlockIntoSnapshot(alloc, with_sig, "value_tracker", vt_json);
    defer alloc.free(merged);
    const awaken_json = try awaken_state.toJson(alloc);
    defer alloc.free(awaken_json);
    const with_awaken = try mergeJsonBlockIntoSnapshot(alloc, merged, "awaken", awaken_json);
    defer alloc.free(with_awaken);

    const hp_json = try host_profile.toJson(alloc);
    defer alloc.free(hp_json);
    const with_hp = try mergeJsonBlockIntoSnapshot(alloc, with_awaken, "host_profile", hp_json);
    defer alloc.free(with_hp);
    const inbox_json = try peer_inbox.toJson(alloc);
    defer alloc.free(inbox_json);
    const with_inbox = try mergeJsonBlockIntoSnapshot(alloc, with_hp, "peer_inbox", inbox_json);
    defer alloc.free(with_inbox);

    const now_unix: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    state_meta.writer = .daemon;
    state_meta.epoch = harness.state_contract.nextEpoch(state_meta.*, disk_meta);
    state_meta.tick = tick;
    state_meta.updated_at_unix = now_unix;
    const meta_json = try state_meta.toJson(alloc);
    defer alloc.free(meta_json);
    const with_meta = try mergeJsonBlockIntoSnapshot(alloc, with_inbox, "state_meta", meta_json);
    defer alloc.free(with_meta);

    try harness.state_contract.writeAtomic(io, alloc, path, with_meta);
    std.debug.print("[daemon] snapshot: {s} ({d} bytes, memory episodes={d}, tasks pending={d}, gsp peers={d}, value_count={d}, awakened={}, epoch={d}, inbox={d})\n", .{
        path, with_meta.len, memory.episodes.items.len, task_queue.pending_count, human_gsp.peers.count(), value_tracker.count, awaken_state.awakened, state_meta.epoch, peer_inbox.count(),
    });
}

fn mergeJsonBlockIntoSnapshot(alloc: std.mem.Allocator, base_json: []const u8, field_name: []const u8, block_json: []const u8) ![]u8 {
    var end = base_json.len;
    while (end > 0 and (base_json[end - 1] == '\n' or base_json[end - 1] == ' ' or base_json[end - 1] == '\r')) end -= 1;
    if (end > 0 and base_json[end - 1] == '}') end -= 1;
    while (end > 0 and base_json[end - 1] == ' ') end -= 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_json[0..end]);
    try buf.print(alloc, ",\n  \"{s}\": ", .{field_name});
    try buf.appendSlice(alloc, block_json);
    try buf.appendSlice(alloc, "\n}\n");
    return buf.toOwnedSlice(alloc);
}