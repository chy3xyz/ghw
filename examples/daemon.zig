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
};

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

    // ===== L3 真应用: state_in → 实际恢复 agent 状态 =====
    var snapshot_tick: u64 = 0;
    if (cfg.state_in) |path| {
        std.debug.print("[daemon] 加载状态: {s}\n", .{path});
        if (readFile(alloc, io, path)) |json| {
            defer alloc.free(json);
            var ss = StateSerializer{ .allocator = alloc, .io = io };
            if (ss.parseMinimal(json)) |parsed_const| {
                var parsed = parsed_const;
                defer parsed.deinit();
                // 真应用回 agent
                agent.tick = parsed.tick;
                agent.ed.v.material = parsed.material;
                agent.ed.v.representation = parsed.representation;
                agent.ed.v.nature = parsed.nature;
                agent.ed.weights.alpha = parsed.alpha;
                agent.ed.weights.beta = parsed.beta;
                agent.ed.weights.gamma = parsed.gamma;
                snapshot_tick = parsed.tick;
                std.debug.print(
                    "[daemon] 状态恢复: tick={d} M={d:.3} R={d:.3} N={d:.3} α={d:.3} β={d:.3} γ={d:.3}\n",
                    .{ parsed.tick, parsed.material, parsed.representation, parsed.nature, parsed.alpha, parsed.beta, parsed.gamma },
                );
            } else |err| {
                std.debug.print("[daemon] state parse 失败: {t}, 用默认\n", .{err});
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
                if (last.tick > snapshot_tick) {
                    // WAL 有 snapshot 之后的新 records, 补回
                    agent.tick = last.tick;
                    agent.ed.v.material = last.M;
                    agent.ed.v.representation = last.R;
                    agent.ed.v.nature = last.N;
                    // self_evolve_count 是累加, 从 0 重新算 OK (小误差)
                    std.debug.print(
                        "[daemon] WAL replay: tick={d} M={d:.3} R={d:.3} N={d:.3} (从 snapshot tick={d} 之后)\n",
                        .{ last.tick, last.M, last.R, last.N, snapshot_tick },
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

    // 主循环
    var tick: u64 = 0;
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
        // 启 listener thread (复用 serverHandler mock for now, 真正 Phase 10+ 接 L4/L5)
        const cross_thread = try std.Thread.spawn(.{}, crossHostListener, .{ &cl, &cross_link_stop });
        cross_thread.detach();
        cross_link_opt = cl;
        std.debug.print("[daemon] cross-host listener 启 on port {d} (id={s}, peers={d})\n", .{ cfg.cross_host_port, ch_id, cl.peers.items.len });
    } else {
        std.debug.print("[daemon] cross-host disabled (--cross-host-port 0)\n", .{});
    }
    defer if (cross_link_opt) |*cl| {
        cross_link_stop.store(true, .release);
        cl.deinit();
    };

    // 可选: LLM 提议器 (仅当 --llm=anthropic/openai 时启用)
    var http_llm_opt: ?harness.http_llm.HttpLLM = null;
    var proposer_opt: ?harness.rule_proposer.RuleProposer = null;
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
            var enc = SelfEncoder.init(alloc);
            enc.loadBuiltInRules() catch {};
            encoder_opt = enc;
            const grd = SelfEvolutionGuard.init(alloc);
            guard_opt = grd;
            proposer_opt = harness.rule_proposer.RuleProposer.init(alloc, http_llm.asChat());
            std.debug.print("[daemon] LLM enabled: anthropic {s}\n", .{cfg.llm_model});
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
            var enc = SelfEncoder.init(alloc);
            enc.loadBuiltInRules() catch {};
            encoder_opt = enc;
            const grd = SelfEvolutionGuard.init(alloc);
            guard_opt = grd;
            proposer_opt = harness.rule_proposer.RuleProposer.init(alloc, http_llm.asChat());
            std.debug.print("[daemon] LLM enabled: openai {s}\n", .{cfg.llm_model});
        }
    }

    while (true) : (tick += 1) {
        // 跑完指定 cycles 退出 (cycles=0 永远跑)
        if (cfg.cycles != 0 and tick >= cfg.cycles) break;
        // 收到 SIGTERM/SIGINT/SIGHUP → graceful shutdown
        if (should_stop.load(.acquire)) {
            std.debug.print("[daemon] 收到停止信号, 进入 graceful shutdown\n", .{});
            break;
        }

        const info_stream = [_]Information{
            .{ .id = tick * 5 + 0, .label = "msg-A", .features = .{ 0.5, 0.6, 0.3, 0.4 } },
            .{ .id = tick * 5 + 1, .label = "msg-B", .features = .{ 0.7, 0.4, 0.8, 0.2 } },
            .{ .id = tick * 5 + 2, .label = "msg-C", .features = .{ 0.3, 0.5, 0.2, 0.6 } },
            .{ .id = tick * 5 + 3, .label = "msg-D", .features = .{ 0.8, 0.7, 0.6, 0.3 } },
            .{ .id = tick * 5 + 4, .label = "msg-E", .features = .{ 0.4, 0.5, 0.4, 0.5 } },
        };

        const report = agent.runCycle(&info_stream) catch |err| {
            std.debug.print("[daemon] cycle {d} 失败: {t}\n", .{ tick, err });
            continue;
        };

        if (report.self_evolved) self_evolve_count += 1;

        // ===== Loop Engine 4-phase PDCA (Boris) =====
        if (loop_engine_opt) |*le| {
            // Plan: tick % kPlanCycle == 0 → 触发 hypothesis 提议
            if (le.shouldPlan(tick)) {
                // Boris PR 守夜简化版: 基于 E + ΔE 提 hypothesis
                // 跟 LLM 提议不冲突, 这是更轻的 coordinator 视角
                // 真正的 LLM 提议 (Phase 8.7) 在下面独立分支跑
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
                const new_id = le.addHypothesis(tick, plan_claim, plan_reason, 0.6, .llm_propose) catch 0;
                le.markPlan(tick);
                if (cfg.log_every != 0 and cfg.log_every <= 8 and tick > 0 and tick % cfg.log_every == 0) {
                    std.debug.print("[daemon] Loop Plan tick={d} hyp_id={d} claim={s}\n", .{ tick, new_id, plan_claim });
                }
            }
            // Do: 记录 ΔE 和 M/R/N
            le.recordDo();
            le.recordEDelta(report.e_after - report.e_before);
            le.recordMrn(agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature);
            // Check: 算 hit_rate (Boris 6.6 外部机制, 纯数学)
            const is_hit = le.check();
            if (is_hit) le.recordHit() else le.recordMiss();
            // Act: 连续 miss 触发 retire / force_l4 (Boris 6.5 退出条件)
            const act_result = le.act();
            switch (act_result) {
                .force_l4 => {
                    // 强制 L4 提议: 给数字生命一个 boost, 让它跑 self_evolver
                    if (cfg.log_every != 0) {
                        std.debug.print("[daemon] Loop Act=force_l4 tick={d} miss_streak={d} → 触发 L4 提议\n", .{
                            tick, le.kpi.consecutive_miss,
                        });
                    }
                    // 复用现有 LLM propose 触发逻辑
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
                                }
                            }
                        }
                    }
                },
                .retire => {
                    if (cfg.log_every != 0) {
                        std.debug.print("[daemon] Loop Act=retire tick={d} → 撤当前 hypothesis, 重新 Plan\n", .{tick});
                    }
                },
                .promote => {
                    if (cfg.log_every != 0) {
                        std.debug.print("[daemon] Loop Act=promote tick={d} → 当前 hypothesis 升为长期\n", .{tick});
                    }
                },
                .keep, .none => {},
            }
        }

        if (cfg.verbose) {
            std.debug.print("[daemon] tick={d} E={d:.3}->{d:.3} goal={?s} self_evolved={}\n", .{
                tick,
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

            // 2. 每 16 cycle 写 snapshot
            if (tick > 0 and tick % 16 == 0) {
                writeSnapshot(alloc, io, &agent, path, agent.tick, self_evolve_count) catch |err| {
                    if (cfg.log_every != 0) std.debug.print("[daemon] snapshot 失败: {t}\n", .{err});
                };

                // 3. 每 256 cycle truncate WAL (snapshot 已含)
                if (tick % 256 == 0) {
                    // Zig 0.17 std.Io.File 没有 truncate, 用 deleteFileAbsolute 删了重建
                    std.Io.Dir.deleteFileAbsolute(io, wal_path) catch {};
                    if (cfg.log_every != 0) std.debug.print("[daemon] WAL truncated at tick={d}\n", .{tick});
                }
            }
        }

        // 周期性进度日志 (默认每 256 tick, --log-every 0 关闭)
        if (cfg.log_every != 0 and tick > 0 and tick % cfg.log_every == 0) {
            std.debug.print("[daemon] tick={d} E={d:.3} self_evolved_total={d} self_evolution_rate={d:.4}\n", .{
                tick,
                agent.ed.e(),
                self_evolve_count,
                @as(f64, @floatFromInt(self_evolve_count)) / @as(f64, @floatFromInt(tick)),
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
                std.debug.print("[daemon] TIME tick={d} E={d:.3} self_evolved_total={d}\n", .{
                    tick,
                    agent.ed.e(),
                    self_evolve_count,
                });
                // Loop Engine KPI 摘要 (跟 exit 时一样, time-based 触发)
                if (loop_engine_opt) |*le| {
                    std.debug.print("  LoopEngine: tick={d} plan={d} do={d} act={d} hit_rate={d:.3} miss_streak={d} avg_de_8={d:.3}\n", .{
                        le.kpi.loop_tick,
                        le.kpi.plan_count,
                        le.kpi.do_count,
                        le.kpi.act_count,
                        le.kpi.current_hit_rate,
                        le.kpi.consecutive_miss,
                        le.kpi.avg_delta_e_8cycle,
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

        // LLM 提议触发: 当 E 跌穿阈值, 让 LLM 提议新规则
        if (proposer_opt != null and agent.ed.e() < cfg.rule_propose_threshold) {
            if (proposer_opt) |*p| {
                if (encoder_opt) |*enc| {
                    if (guard_opt) |*grd| {
                        p.updateState(agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, "explore", "llm-propose-trigger", -0.05);
                        var prop_result = p.proposeAndAdopt(enc, grd, 3) catch |err| {
                            std.debug.print("[daemon] proposeAndAdopt failed: {t}\n", .{err});
                            continue;
                        };
                        defer prop_result.deinit();
                        std.debug.print("[daemon] LLM propose at tick {d}: accepted={d} rejected={d}\n", .{
                            tick,
                            prop_result.accepted,
                            prop_result.rejected,
                        });
                        llm_propose_count += 1;
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
        writeSnapshot(alloc, io, &agent, path, agent.tick, self_evolve_count) catch |err| {
            std.debug.print("[daemon] 退出前 snapshot 失败: {t}\n", .{err});
        };
    }

    std.debug.print("[daemon] 退出 — 总 tick={d} 最终 E={d:.3} 自演化触发 {d} 次\n", .{
        tick,
        agent.ed.e(),
        self_evolve_count,
    });

    // ===== Loop Engine 退出摘要 (Boris 6.6 评估机制) =====
    if (loop_engine_opt) |*le| {
        std.debug.print("\n========== Loop Engine 摘要 (Boris) ==========\n", .{});
        std.debug.print("LoopEngine: tick={d} plan={d} do={d} check={d} act={d}\n", .{
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

// ===== Cross-host listener (v0.5.1 新增, TCP + HMAC 跨 host 通信) =====
/// 简化版 server handler: 返 mock response, Phase 10+ 接 L4/L5 真实 handler
fn crossHostHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!harness.ghw_link.Response {
    _ = params;
    _ = ctx;
    if (std.mem.eql(u8, method, "ping")) {
        const payload = try alloc.dupe(u8, "{\"pong\":true}");
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "hello")) {
        const fake_challenge = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const payload = try std.fmt.allocPrint(alloc, "{{\"challenge\":\"{s}\",\"ts\":0}}", .{fake_challenge});
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "query_state")) {
        const payload = try alloc.dupe(u8, "{\"tick\":0,\"E\":1.0,\"cross_host\":true}");
        return .{ .ok = true, .payload = payload };
    }
    const payload = try alloc.dupe(u8, "{\"unknown\":true}");
    return .{ .ok = false, .payload = payload };
}

fn crossHostListener(cl: *harness.ghw_link_tcp.CrossLink, stop: *std.atomic.Value(bool)) void {
    cl.runServer(crossHostHandler, undefined, stop) catch |err| {
        std.debug.print("[daemon] cross-host listener 异常: {t}\n", .{err});
    };
}

// 写 snapshot 到 path (L3 持久化: 写 tmp 然后 rename, 防止崩溃时写一半)
fn writeSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent: *GHWAgent,
    path: []const u8,
    tick: u64,
    success_count: u32,
) !void {
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
    const json = try ss_mut.serialize(snap);
    defer alloc.free(json);
    // 0.17 没有原子 rename, 直接 writeFile 覆盖 (极端情况可能不一致但 0 损失)
    try writeFile(io, path, json);
    std.debug.print("[daemon] snapshot: {s} ({d} bytes)\n", .{ path, json.len });
}
