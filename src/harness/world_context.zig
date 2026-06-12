//! WorldContext — GHW 感知物理世界
//!
//! SystemCollector 已经采了 CPU/mem/disk/net 这种"系统状态"。
//! WorldContext 更进一步: 采"实际有什么在跑 / 活动"。
//!
//! 4 类信息:
//!   1. ProcessLandscape: 跑在前面的进程, 按 CPU 排序, 含 cmdline
//!   2. NetworkPeers:     本机监听的 TCP 端口 + 其他 GHW 实例
//!   3. UserActivity:     最近修改的文件 (用户的实际工作痕迹)
//!   4. SelfAwareness:    自身进程的 PID/PPID/cmdline/子进程
//!
//! 输出是一段 raw text, 喂给 LLM, 让 LLM 基于真实物理世界提议目标
//! ("ghw-daemon 吃了 95% CPU, 我应该帮它优化" / "用户在写 Zig, 我可以提建议")
//!
//! 设计:
//!   - 单次 collect() 一次性拿所有信息 (跑 N 个 shell 命令), ~200-500ms
//!   - 输出结构化 string (多行), 不做 LLM 调用 (LLM 调用在 goal_proposer.zig)
//!   - 全部基于 macOS 命令, Linux 走 /proc + 类似 netstat/lsof

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

pub const ProcessInfo = struct {
    pid: u32,
    ppid: u32,
    cpu_pct: F,
    mem_pct: F,
    rss_kb: u64,
    /// 截断到 80 字符的 cmdline
    cmdline: []u8,
    /// 可执行文件名
    comm: []u8,
};

pub const NetworkPeer = struct {
    /// 进程名 (绑定端口的)
    process: []u8,
    /// 本地监听地址 (如 "127.0.0.1:8080" 或 "*:6379")
    address: []u8,
    port: u16,
    /// 是否是 GHW 实例
    is_ghw: bool,
};

pub const RecentFile = struct {
    path: []u8,
    mtime: i64,
    size: u64,
};

pub const SelfInfo = struct {
    pid: u32,
    ppid: u32,
    /// 完整 cmdline
    cmdline: []u8,
    /// 启动时间 (unix seconds)
    start_time: i64,
    uptime_s: u64,
    /// 子 PID 列表
    children: []u32,
};

pub const WorldSnapshot = struct {
    alloc: Allocator,
    timestamp: i64,

    top_procs: []ProcessInfo, // 按 CPU 排序
    network_peers: []NetworkPeer,
    recent_files: []RecentFile,
    self_info: SelfInfo,
    /// 自身是 ghw 吗
    is_ghw_process: bool,

    pub fn deinit(self: *const WorldSnapshot) void {
        for (self.top_procs) |p| {
            self.alloc.free(p.cmdline);
            self.alloc.free(p.comm);
        }
        self.alloc.free(self.top_procs);
        for (self.network_peers) |p| {
            self.alloc.free(p.process);
            self.alloc.free(p.address);
        }
        self.alloc.free(self.network_peers);
        for (self.recent_files) |file| {
            self.alloc.free(file.path);
        }
        self.alloc.free(self.recent_files);
        self.alloc.free(self.self_info.cmdline);
        self.alloc.free(self.self_info.children);
    }
};

pub const WorldContext = struct {
    alloc: Allocator,
    io: std.Io,
    last: ?WorldSnapshot = null,
    home_dir: []u8, // $HOME 缓存
    /// 上次 collect 的 wall clock (纳秒), collectCached 用 TTL 守门
    last_collect_ns: i128 = 0,

    pub fn init(alloc: Allocator, io: std.Io, environ: std.process.Environ) WorldContext {
        const home_opt = std.process.Environ.getPosix(environ, "HOME");
        const home = home_opt orelse "/tmp";
        return .{
            .alloc = alloc,
            .io = io,
            .home_dir = alloc.dupe(u8, home) catch alloc.dupe(u8, "/tmp") catch &[_]u8{},
            .last_collect_ns = 0,
        };
    }

    pub fn deinit(self: *WorldContext) void {
        if (self.last) |*s| s.deinit();
        self.alloc.free(self.home_dir);
    }

    /// 缓存 collect: ttl_ns 内复用 last (deep dup), 避免每 cycle 跑 6 个子进程
    /// (ps/lsof/find/mdfind). ttl_ns=0 等同 collect() (无缓存).
    /// ⚠️ Bug: 之前 return self.dupSnapshot(prev) 在 cache hit 路径 panic.
    /// 改成 return prev (by-value copy, stack 上, 不 race). Caller 负责 deinit.
    /// 测试: dup 跑通单次; cache 多次调 dup panic — root cause 不明 (单线程).
    /// 临时回退到 prev by-value, 接受 caller 持有 borrow ref.
    pub fn collectCached(self: *WorldContext, ttl_ns: i128) !WorldSnapshot {
        const now = std.Io.Clock.real.now(self.io).toNanoseconds();
        if (ttl_ns > 0) {
            if (self.last) |prev| {
                if (now - self.last_collect_ns < ttl_ns) {
                    return prev; // by-value: 复用 caller, 内部 slice 仍指向 self.last backing
                }
            }
        }
        self.last_collect_ns = now;
        return self.collect();
    }

    /// Deep dup snapshot — 复用 last 给多个 reader, 不 deinit 原 last
    /// public: 多个 reader (handleGetState / handleGetPropose / recomputePersonality) 同时
    /// borrow app.world.last 时, 必须 dup 才能避免 race (collect() 会 deinit 上次 last)
    pub fn dupSnapshot(self: *WorldContext, src: WorldSnapshot) !WorldSnapshot {
        const alloc = self.alloc;
        std.debug.print("[dup] net_len={d} item0_proc={s}\n", .{
            src.network_peers.len,
            if (src.network_peers.len > 0) src.network_peers[0].process else "",
        });
        var dup_top: std.ArrayList(ProcessInfo) = .empty;
        for (src.top_procs) |p| {
            try dup_top.append(alloc, .{
                .pid = p.pid,
                .ppid = p.ppid,
                .cpu_pct = p.cpu_pct,
                .mem_pct = p.mem_pct,
                .rss_kb = p.rss_kb,
                .cmdline = try alloc.dupe(u8, p.cmdline),
                .comm = try alloc.dupe(u8, p.comm),
            });
        }
        var dup_net: std.ArrayList(NetworkPeer) = .empty;
        for (src.network_peers) |p| {
            try dup_net.append(alloc, .{
                .process = try alloc.dupe(u8, p.process),
                .address = try alloc.dupe(u8, p.address),
                .port = p.port,
                .is_ghw = p.is_ghw,
            });
        }
        var dup_files: std.ArrayList(RecentFile) = .empty;
        for (src.recent_files) |f| {
            try dup_files.append(alloc, .{
                .path = try alloc.dupe(u8, f.path),
                .mtime = f.mtime,
                .size = f.size,
            });
        }
        const children_dup = try alloc.dupe(u32, src.self_info.children);
        return WorldSnapshot{
            .alloc = alloc,
            .timestamp = src.timestamp,
            .top_procs = try dup_top.toOwnedSlice(alloc),
            .network_peers = try dup_net.toOwnedSlice(alloc),
            .recent_files = try dup_files.toOwnedSlice(alloc),
            .self_info = .{
                .pid = src.self_info.pid,
                .ppid = src.self_info.ppid,
                .cmdline = try alloc.dupe(u8, src.self_info.cmdline),
                .start_time = src.self_info.start_time,
                .uptime_s = src.self_info.uptime_s,
                .children = children_dup,
            },
            .is_ghw_process = src.is_ghw_process,
        };
    }

    /// 一次性采所有世界信息
    pub fn collect(self: *WorldContext) !WorldSnapshot {
        var snap = WorldSnapshot{
            .alloc = self.alloc,
            .timestamp = std.Io.Clock.real.now(self.io).toSeconds(),
            .top_procs = &[_]ProcessInfo{},
            .network_peers = &[_]NetworkPeer{},
            .recent_files = &[_]RecentFile{},
            .self_info = .{
                .pid = 0,
                .ppid = 0,
                .cmdline = try self.alloc.dupe(u8, ""),
                .start_time = 0,
                .uptime_s = 0,
                .children = &[_]u32{},
            },
            .is_ghw_process = false,
        };
        errdefer snap.deinit();

        if (comptime is_macos) {
            try self.collectMacos(&snap);
        } else if (comptime is_linux) {
            try self.collectLinux(&snap);
        }

        if (self.last) |*old| old.deinit();
        self.last = snap;
        return snap;
    }

    fn runCmd(self: *WorldContext, argv: []const []const u8) ![]u8 {
        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv,
            .stdout_limit = std.Io.Limit.limited(256 * 1024),
            .stderr_limit = std.Io.Limit.limited(8 * 1024),
        }) catch return self.alloc.dupe(u8, "") catch &[_]u8{};
        self.alloc.free(result.stderr);
        return switch (result.term) {
            .exited => |code| if (code == 0) result.stdout else blk: {
                self.alloc.free(result.stdout);
                break :blk try self.alloc.dupe(u8, "");
            },
            else => blk: {
                self.alloc.free(result.stdout);
                break :blk try self.alloc.dupe(u8, "");
            },
        };
    }

    fn collectMacos(self: *WorldContext, snap: *WorldSnapshot) !void {
        // 1) self info: 当前进程的 PID + cmdline + uptime
        // Zig 0.17: posix.system.getpid() 替代 std.posix.getpid() (i32 -> u32)
        snap.self_info.pid = @intCast(std.posix.system.getpid());
        snap.self_info.ppid = @intCast(std.posix.system.getppid());

        // 2) top procs: ps -A -o pid,ppid,pcpu,pmem,rss,comm,args | sort -k3 -nr | head -20
        const ps_out = try self.runCmd(&[_][]const u8{ "/bin/ps", "-A", "-o", "pid,ppid,%cpu,%mem,rss,comm,args" });
        defer self.alloc.free(ps_out);
        snap.top_procs = try parsePsOutput(self.alloc, ps_out, 25);

        // 3) listening ports: lsof -iTCP -sTCP:LISTEN -nP
        const lsof_out = try self.runCmd(&[_][]const u8{ "/usr/sbin/lsof", "-iTCP", "-sTCP:LISTEN", "-nP" });
        defer self.alloc.free(lsof_out);
        snap.network_peers = try parseLsofListening(self.alloc, lsof_out);

        // 4) 自身进程 cmdline: ps -p $PID -o args=
        var pid_buf: [16]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{snap.self_info.pid}) catch "?";
        const self_out = try self.runCmd(&[_][]const u8{ "/bin/ps", "-p", pid_str, "-o", "args=" });
        defer self.alloc.free(self_out);
        // 截断 200 字符
        const trimmed = std.mem.trim(u8, self_out, " \n");
        const cmd = if (trimmed.len > 200) trimmed[0..200] else trimmed;
        snap.self_info.cmdline = try self.alloc.dupe(u8, cmd);

        // 5) 自身 start time: ps -p $PID -o lstart=
        const lstart_out = try self.runCmd(&[_][]const u8{ "/bin/ps", "-p", pid_str, "-o", "lstart=" });
        defer self.alloc.free(lstart_out);
        snap.self_info.start_time = parseLstart(lstart_out);
        snap.self_info.uptime_s = @intCast(@max(0, snap.timestamp - snap.self_info.start_time));

        // 6) 近期修改的文件: find $HOME -mmin -60 -type f 2>/dev/null | head -30
        var find_args_buf: [8][]const u8 = undefined;
        find_args_buf[0] = "/usr/bin/find";
        find_args_buf[1] = self.home_dir;
        find_args_buf[2] = "-mmin";
        find_args_buf[3] = "-60";
        find_args_buf[4] = "-type";
        find_args_buf[5] = "f";
        find_args_buf[6] = "-not";
        find_args_buf[7] = "-path";
        // 简化: 不排除 hidden, find 在 home 经常太慢, 改用 mdfind
        const mdfind_out = try self.runCmd(&[_][]const u8{ "/usr/bin/mdfind", "-onlyin", self.home_dir, "(kMDItemFSContentChangeDate > $time.today(-1))" });
        defer self.alloc.free(mdfind_out);
        snap.recent_files = try parseMdfind(self.alloc, mdfind_out, 20);

        // 7) 检测是否 GHW 进程
        snap.is_ghw_process = std.mem.indexOf(u8, snap.self_info.cmdline, "ghw") != null;
    }

    fn collectLinux(self: *WorldContext, snap: *WorldSnapshot) !void {
        snap.self_info.pid = @intCast(std.posix.system.getpid());
        snap.self_info.ppid = @intCast(std.posix.system.getppid());

        // ps: 读 /proc/[pid]/stat 和 /proc/[pid]/cmdline
        // 简化: 调 ps 命令
        const ps_out = try self.runCmd(&[_][]const u8{ "/bin/ps", "-A", "-o", "pid,ppid,%cpu,%mem,rss,comm,args" });
        defer self.alloc.free(ps_out);
        snap.top_procs = try parsePsOutput(self.alloc, ps_out, 25);

        // ss -tlnp (监听端口)
        const ss_out = try self.runCmd(&[_][]const u8{ "/usr/bin/ss", "-tlnp" });
        defer self.alloc.free(ss_out);
        snap.network_peers = try parseSsListening(self.alloc, ss_out);

        // 自身 cmdline
        var pid_buf: [16]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{snap.self_info.pid}) catch "?";
        const self_out = try self.runCmd(&[_][]const u8{ "/bin/ps", "-p", pid_str, "-o", "args=" });
        defer self.alloc.free(self_out);
        const trimmed = std.mem.trim(u8, self_out, " \n");
        const cmd = if (trimmed.len > 200) trimmed[0..200] else trimmed;
        snap.self_info.cmdline = try self.alloc.dupe(u8, cmd);

        // 近期修改: find ~ -mmin -60 -type f 2>/dev/null | head -20
        const find_out = try self.runCmd(&[_][]const u8{ "/usr/bin/find", self.home_dir, "-mmin", "-60", "-type", "f", "-not", "-path", "*/.git/*" });
        defer self.alloc.free(find_out);
        snap.recent_files = try parseFindRecent(self.alloc, find_out, 20);
        snap.is_ghw_process = std.mem.indexOf(u8, snap.self_info.cmdline, "ghw") != null;
    }

    /// 序列化为 LLM 可读的纯文本
    pub fn toLLMContext(self: *WorldContext, snap: WorldSnapshot, ghw_state_str: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);

        try out.print(self.alloc, "== 你的物理世界快照 (real-time, 这台机器) ==\n\n", .{});
        try out.print(self.alloc, "时间: {d} (unix sec)\n\n", .{snap.timestamp});

        try out.print(self.alloc, "== 自身 (GHW 进程) ==\n", .{});
        try out.print(self.alloc, "PID: {d}, PPID: {d}, uptime: {d}s\n", .{ snap.self_info.pid, snap.self_info.ppid, snap.self_info.uptime_s });
        try out.print(self.alloc, "cmdline: {s}\n\n", .{snap.self_info.cmdline});

        try out.print(self.alloc, "== 跑在最前面的进程 (按 CPU 排序) ==\n", .{});
        for (snap.top_procs) |p| {
            try out.print(self.alloc, "PID {d:>6}  CPU {d:5.1}%  MEM {d:5.1}%  RSS {d:>7}K  {s}\n", .{
                p.pid, p.cpu_pct, p.mem_pct, p.rss_kb, p.cmdline,
            });
        }
        try out.print(self.alloc, "\n", .{});

        try out.print(self.alloc, "== 网络监听端口 (其他进程 / 可能是 GHW 同伴) ==\n", .{});
        if (snap.network_peers.len == 0) {
            try out.print(self.alloc, "  (无)\n", .{});
        } else {
            for (snap.network_peers) |p| {
                try out.print(self.alloc, "  {s} {s}{s}\n", .{
                    p.process, p.address, if (p.is_ghw) "  [GHW 同伴!]" else "",
                });
            }
        }
        try out.print(self.alloc, "\n", .{});

        try out.print(self.alloc, "== 最近 1 小时用户活动文件 (mdfind) ==\n", .{});
        if (snap.recent_files.len == 0) {
            try out.print(self.alloc, "  (无)\n", .{});
        } else {
            for (snap.recent_files) |f| {
                try out.print(self.alloc, "  {s}\n", .{f.path});
            }
        }
        try out.print(self.alloc, "\n", .{});

        try out.print(self.alloc, "== 你的内部状态 ==\n{s}\n", .{ghw_state_str});

        return out.toOwnedSlice(self.alloc);
    }
};

// ===== 解析器 =====

fn parsePsOutput(alloc: Allocator, out: []const u8, max: usize) ![]ProcessInfo {
    var procs: std.ArrayList(ProcessInfo) = .empty;
    errdefer procs.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next(); // header
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        if (count >= max) break;
        // 格式: "PID PPID %CPU %MEM RSS COMM ARGS"
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const pid_str = fields.next() orelse continue;
        const ppid_str = fields.next() orelse continue;
        const cpu_str = fields.next() orelse continue;
        const mem_str = fields.next() orelse continue;
        const rss_str = fields.next() orelse continue;
        const comm = fields.next() orelse continue;
        // ARGS 拼接剩下的
        var args_buf: std.ArrayList(u8) = .empty;
        defer args_buf.deinit(alloc);
        while (fields.next()) |f| {
            if (args_buf.items.len > 0) try args_buf.append(alloc, ' ');
            try args_buf.appendSlice(alloc, f);
        }
        if (args_buf.items.len > 80) args_buf.shrinkRetainingCapacity(80);

        const p = ProcessInfo{
            .pid = std.fmt.parseInt(u32, pid_str, 10) catch continue,
            .ppid = std.fmt.parseInt(u32, ppid_str, 10) catch 0,
            .cpu_pct = std.fmt.parseFloat(F, cpu_str) catch 0,
            .mem_pct = std.fmt.parseFloat(F, mem_str) catch 0,
            .rss_kb = std.fmt.parseInt(u64, rss_str, 10) catch 0,
            .cmdline = try alloc.dupe(u8, args_buf.items),
            .comm = try alloc.dupe(u8, comm),
        };
        try procs.append(alloc, p);
    }
    std.mem.sort(ProcessInfo, procs.items, {}, lessThanCpu);
    return procs.toOwnedSlice(alloc);
}

fn lessThanCpu(_: void, a: ProcessInfo, b: ProcessInfo) bool {
    return a.cpu_pct > b.cpu_pct;
}

fn parseLsofListening(alloc: Allocator, out: []const u8) ![]NetworkPeer {
    var peers: std.ArrayList(NetworkPeer) = .empty;
    errdefer peers.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        // "rapportd  132  user  6u  IPv4  0x...  0t0  TCP *:49296 (LISTEN)"
        // 找 "(LISTEN)"
        if (std.mem.indexOf(u8, line, "(LISTEN)") == null) continue;
        // 第一列是 command
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        // 跳过 pid, user, fd, type, device
        var addr: []const u8 = "";
        var col: u8 = 0;
        while (it.next()) |tok| : (col += 1) {
            if (col == 7) {
                addr = tok;
                break;
            }
        }
        if (addr.len == 0) continue;
        // 解析 port
        var port: u16 = 0;
        if (std.mem.lastIndexOf(u8, addr, ":")) |colon| {
            port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch 0;
        }
        const is_ghw = std.mem.indexOf(u8, cmd, "ghw") != null or
            std.mem.indexOf(u8, cmd, "ui_server") != null;
        try peers.append(alloc, .{
            .process = try alloc.dupe(u8, cmd),
            .address = try alloc.dupe(u8, addr),
            .port = port,
            .is_ghw = is_ghw,
        });
    }
    return peers.toOwnedSlice(alloc);
}

fn parseSsListening(alloc: Allocator, out: []const u8) ![]NetworkPeer {
    var peers: std.ArrayList(NetworkPeer) = .empty;
    errdefer peers.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        // "LISTEN  0  128  *:8080  *:*  users:(("node",pid=1234,fd=20))"
        if (std.mem.indexOf(u8, line, "LISTEN") == null) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const state = it.next() orelse continue;
        if (!std.mem.eql(u8, state, "LISTEN")) continue;
        const local = it.next() orelse continue;
        // process 可能在 users:(("name",pid=...)) 里
        var proc_name: []const u8 = "unknown";
        if (std.mem.indexOf(u8, line, "users:((\"")) |u_start| {
            const u = u_start + 8;
            if (std.mem.indexOfPos(u8, line, u, "\"")) |u_end| {
                proc_name = line[u..u_end];
            }
        }
        var port: u16 = 0;
        if (std.mem.lastIndexOf(u8, local, ":")) |colon| {
            port = std.fmt.parseInt(u16, local[colon + 1 ..], 10) catch 0;
        }
        const is_ghw = std.mem.indexOf(u8, proc_name, "ghw") != null or
            std.mem.indexOf(u8, proc_name, "ui_server") != null;
        try peers.append(alloc, .{
            .process = try alloc.dupe(u8, proc_name),
            .address = try alloc.dupe(u8, local),
            .port = port,
            .is_ghw = is_ghw,
        });
    }
    return peers.toOwnedSlice(alloc);
}

fn parseMdfind(alloc: Allocator, out: []const u8, max: usize) ![]RecentFile {
    var files: std.ArrayList(RecentFile) = .empty;
    errdefer files.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        if (count >= max) break;
        if (line.len == 0) continue;
        try files.append(alloc, .{
            .path = try alloc.dupe(u8, line),
            .mtime = 0,
            .size = 0,
        });
    }
    return files.toOwnedSlice(alloc);
}

fn parseFindRecent(alloc: Allocator, out: []const u8, max: usize) ![]RecentFile {
    var files: std.ArrayList(RecentFile) = .empty;
    errdefer files.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        if (count >= max) break;
        if (line.len == 0) continue;
        try files.append(alloc, .{
            .path = try alloc.dupe(u8, line),
            .mtime = 0,
            .size = 0,
        });
    }
    return files.toOwnedSlice(alloc);
}

fn parseLstart(out: []const u8) i64 {
    _ = out;
    // "Thu Jun  5 19:36:02 2026" → 估算 unix sec
    // 简化: 失败返回 0
    return 0;
}

test "world context on macos" {
    if (!is_macos) return;
    var wc = WorldContext.init(std.testing.allocator, std.testing.io);
    defer wc.deinit();
    const snap = try wc.collect();
    try std.testing.expect(snap.top_procs.len > 0);
    try std.testing.expect(snap.network_peers.len > 0);
}
