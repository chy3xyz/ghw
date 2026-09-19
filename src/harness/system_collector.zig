//! SystemCollector: 真生产级 — 同步采样本机系统信号
//!
//! 数据源 (macOS / Linux 都支持, 自动检测):
//!   - CPU 使用率:    top -l 1 / /proc/stat
//!   - 内存压力:      vm_stat / /proc/meminfo
//!   - 磁盘使用:      df -h /
//!   - 负载均值:      sysctl vm.loadavg / /proc/loadavg
//!   - 网络流量:      netstat -ib 差分 / /proc/net/dev 差分
//!   - 进程数:        ps -A 数行数
//!   - 时间上下文:    hour + day-of-week → 三角函数编码
//!   - 用户事件:      外部 push (chat / 命令)
//!
//! 输出: 5-10 个 Information, 每个 4 维 [0,1] 特征, 真实反映机器状态
//!
//! 设计: 每次 collect() 之间保持 delta 状态 (上次采样), 这样网络/磁盘 I/O 才有变化
//!
//! 跟 WorldCollector (用 autocli 拉 web) 是平行关系, 都接到 GHWAgent.runCycle

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Information = @import("../goal/core.zig").Information;
const LCG = @import("../util/math.zig").LCG;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

pub const SystemSnapshot = struct {
    cpu_user_pct: F, // user CPU %
    cpu_sys_pct: F, // sys CPU %
    cpu_idle_pct: F, // idle CPU %
    mem_used_gb: F, // used memory in GB
    mem_total_gb: F, // total memory in GB
    mem_pct: F, // memory used %
    disk_used_pct: F, // disk used % (root partition)
    load_1m: F, // 1-minute load average
    proc_count: u32, // total process count
    /// 逻辑核数 (危机判定按每核负载归一; 0/未采集按 1)
    n_cpus: u32 = 0,
    /// 网络 in MB/s (rate, 从 prev 算的 delta)
    net_in_mbps: F,
    /// 网络 out MB/s (rate)
    net_out_mbps: F,
    /// 磁盘读 MB/s
    disk_read_mbps: F,
    /// 磁盘写 MB/s
    disk_write_mbps: F,
    hour: u8, // 0-23
    weekday: u8, // 0-6 (Mon-Sun)
    timestamp: i64, // unix seconds
};

/// 内部用的累计字节, 跟 snapshot 平行存
const CumulativeState = struct {
    net_in_bytes: u64,
    net_out_bytes: u64,
    disk_read_sectors: u64,
    disk_write_sectors: u64,
    timestamp: i64,
};

pub const SystemCollector = struct {
    alloc: Allocator,
    io: std.Io,
    rng: LCG,
    last: ?SystemSnapshot, // 上次完整 snapshot (rate 算完的)
    last_cumulative: ?CumulativeState, // 上次累计字节, 用于本次算 rate
    user_event: ?[]const u8, // 待注入的用户事件
    io_history: ?[]u8,
    /// 上次 collect 的 wall clock (纳秒), collectCached 用 TTL 守门
    /// 没设默认 0 = 永远 cache miss, 等价无 cache
    last_collect_ns: i128 = 0,

    pub fn init(alloc: Allocator, io: std.Io, seed: u64) SystemCollector {
        return .{
            .alloc = alloc,
            .io = io,
            .rng = LCG.init(seed),
            .last = null,
            .last_cumulative = null,
            .user_event = null,
            .io_history = null,
            .last_collect_ns = 0,
        };
    }

    pub fn deinit(self: *SystemCollector) void {
        if (self.io_history) |h| self.alloc.free(h);
        if (self.user_event) |e| self.alloc.free(e);
    }

    /// 注入用户事件 (chat 消息 / 系统命令), 下一轮 collect 会包含
    pub fn pushUserEvent(self: *SystemCollector, text: []const u8) !void {
        if (self.user_event) |old| self.alloc.free(old);
        self.user_event = try self.alloc.dupe(u8, text);
    }

    /// 核心: 同步采样系统状态
    pub fn collect(self: *SystemCollector) !SystemSnapshot {
        var cum: CumulativeState = .{
            .net_in_bytes = 0,
            .net_out_bytes = 0,
            .disk_read_sectors = 0,
            .disk_write_sectors = 0,
            .timestamp = std.Io.Clock.real.now(self.io).toSeconds(),
        };
        var snap: SystemSnapshot = .{
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
            .timestamp = cum.timestamp,
        };

        // 时间
        const days_since_epoch: u32 = @intCast(@divTrunc(cum.timestamp, 86400));
        const secs_today: u32 = @intCast(@mod(cum.timestamp, 86400));
        snap.hour = @intCast(@divTrunc(secs_today, 3600));
        snap.weekday = @intCast(@mod(days_since_epoch + 3, 7));

        if (comptime is_macos) {
            self.collectMacos(&snap, &cum) catch {};
        } else if (comptime is_linux) {
            self.collectLinux(&snap, &cum) catch {};
        }

        // 算 rate (MB/s) — 用上次的累计和这次的累计
        if (self.last_cumulative) |prev| {
            const dt: F = @as(F, @floatFromInt(cum.timestamp - prev.timestamp));
            if (dt > 0) {
                // 1 byte → 1/(1024*1024) MB, /dt = MB/s
                snap.net_in_mbps = @max(0, @as(F, @floatFromInt(cum.net_in_bytes -% prev.net_in_bytes)) / (1024.0 * 1024.0) / dt);
                snap.net_out_mbps = @max(0, @as(F, @floatFromInt(cum.net_out_bytes -% prev.net_out_bytes)) / (1024.0 * 1024.0) / dt);
                // 1 sector = 512 bytes
                snap.disk_read_mbps = @max(0, @as(F, @floatFromInt(cum.disk_read_sectors -% prev.disk_read_sectors)) * 512.0 / (1024.0 * 1024.0) / dt);
                snap.disk_write_mbps = @max(0, @as(F, @floatFromInt(cum.disk_write_sectors -% prev.disk_write_sectors)) * 512.0 / (1024.0 * 1024.0) / dt);
            }
        }

        self.last_cumulative = cum;
        self.last = snap;
        return snap;
    }

    /// 缓存 collect: ttl_ns 内复用上次 snapshot, 避免每个 cycle 都 fork 7 个子进程
    /// (top / sysctl / vm_stat / df / ps / netstat). SystemSnapshot 是 by-value (没 alloc),
    /// 复用安全. rate 字段保留上次值, 因为 last_cumulative 没更新.
    /// ttl_ns=0 行为等同 collect() (无缓存).
    pub fn collectCached(self: *SystemCollector, ttl_ns: i128) !SystemSnapshot {
        const now = std.Io.Clock.real.now(self.io).toNanoseconds();
        if (ttl_ns > 0) {
            if (self.last) |snap| {
                if (now - self.last_collect_ns < ttl_ns) {
                    return snap;
                }
            }
        }
        self.last_collect_ns = now;
        return self.collect();
    }

    /// macOS: 调 top / vm_stat / df / sysctl / netstat
    fn collectMacos(self: *SystemCollector, snap: *SystemSnapshot, cum: *CumulativeState) !void {
        // 1) top -l 1 -n 0: 拿 CPU 用量
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/bin/top", "-l", "1", "-n", "0" })) |out| {
            defer self.alloc.free(out);
            // "CPU usage: 23.71% user, 30.35% sys, 45.93% idle"
            if (std.mem.indexOf(u8, out, "CPU usage:")) |idx| {
                var parts = std.mem.splitScalar(u8, out[idx..], ',');
                while (parts.next()) |p| {
                    const t = std.mem.trim(u8, p, " \n");
                    if (std.mem.endsWith(u8, t, "% user")) {
                        snap.cpu_user_pct = std.fmt.parseFloat(F, t[0 .. t.len - "% user".len]) catch 0;
                    } else if (std.mem.endsWith(u8, t, "% sys")) {
                        snap.cpu_sys_pct = std.fmt.parseFloat(F, t[0 .. t.len - "% sys".len]) catch 0;
                    } else if (std.mem.endsWith(u8, t, "% idle")) {
                        snap.cpu_idle_pct = std.fmt.parseFloat(F, t[0 .. t.len - "% idle".len]) catch 0;
                    }
                }
            }
        }

        // 2) sysctl hw.memsize: 拿总内存 (bytes)
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/sbin/sysctl", "-n", "hw.memsize" })) |out| {
            defer self.alloc.free(out);
            const trimmed = std.mem.trim(u8, out, " \n");
            const total = std.fmt.parseInt(u64, trimmed, 10) catch 0;
            snap.mem_total_gb = @as(F, @floatFromInt(total)) / 1024.0 / 1024.0 / 1024.0;
        }

        // 2b) sysctl hw.ncpu: 逻辑核数 (load 危机按每核归一)
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/sbin/sysctl", "-n", "hw.ncpu" })) |out| {
            defer self.alloc.free(out);
            if (std.fmt.parseInt(u32, std.mem.trim(u8, out, " \n"), 10)) |n| {
                if (n > 0) snap.n_cpus = n;
            } else |_| {}
        }
        // 3) vm_stat: 拿 pages (页大小从输出头解析 — Intel Mac 是 4096, 硬编码会 4x 高估)
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/bin/vm_stat" })) |out| {
            defer self.alloc.free(out);
            const pages = parseVmStat(out);
            const used_bytes = pages.usedBytes();
            snap.mem_used_gb = @as(F, @floatFromInt(used_bytes)) / 1024.0 / 1024.0 / 1024.0;
            if (snap.mem_total_gb > 0) snap.mem_pct = snap.mem_used_gb / snap.mem_total_gb * 100.0;
        }

        // 4) df -h /: 拿磁盘 %
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/bin/df", "-h", "/" })) |out| {
            defer self.alloc.free(out);
            var it = std.mem.splitScalar(u8, out, '\n');
            _ = it.next(); // skip header
            if (it.next()) |line| {
                if (std.mem.indexOf(u8, line, "%")) |pct_end| {
                    var start: usize = pct_end;
                    while (start > 0) : (start -= 1) {
                        const c = line[start - 1];
                        if (c != ' ' and !std.ascii.isDigit(c)) break;
                    }
                    const pct_str = std.mem.trim(u8, line[start..pct_end], " ");
                    snap.disk_used_pct = std.fmt.parseFloat(F, pct_str) catch 0;
                }
            }
        }

        // 5) sysctl vm.loadavg: "{ 27.62 29.85 29.81 }"
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/sbin/sysctl", "-n", "vm.loadavg" })) |out| {
            defer self.alloc.free(out);
            const cleaned = std.mem.trim(u8, out, " \n\t{}");
            var it = std.mem.splitScalar(u8, cleaned, ' ');
            if (it.next()) |s| snap.load_1m = std.fmt.parseFloat(F, s) catch 0;
        }

        // 6) ps -A: 数行 = 进程数 (限 256KB, 800+ 进程)
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/bin/ps", "-A" })) |out| {
            defer self.alloc.free(out);
            var count: u32 = 0;
            for (out) |c| if (c == '\n') {
                count += 1;
            };
            snap.proc_count = if (count > 0) count - 1 else 0;
        }

        // 7) netstat -ib: 拿累计 bytes
        if (try runCmd(self.alloc, self.io, &[_][]const u8{ "/usr/sbin/netstat", "-ib" })) |out| {
            defer self.alloc.free(out);
            var total_in: u64 = 0;
            var total_out: u64 = 0;
            var it = std.mem.splitScalar(u8, out, '\n');
            _ = it.next();
            while (it.next()) |line| {
                if (std.mem.indexOf(u8, line, "lo0") != null) continue;
                if (std.mem.indexOf(u8, line, "gif") != null) continue;
                if (std.mem.indexOf(u8, line, "stf") != null) continue;
                if (std.mem.indexOf(u8, line, "anpi") != null) continue;
                if (std.mem.indexOf(u8, line, "lo") != null) continue;
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                var idx: u8 = 0;
                var in_bytes: u64 = 0;
                var out_bytes: u64 = 0;
                while (fields.next()) |f| : (idx += 1) {
                    if (idx == 6) in_bytes = std.fmt.parseInt(u64, f, 10) catch 0;
                    if (idx == 9) out_bytes = std.fmt.parseInt(u64, f, 10) catch 0;
                }
                total_in += in_bytes;
                total_out += out_bytes;
            }
            cum.net_in_bytes = total_in;
            cum.net_out_bytes = total_out;
        }
    }

    /// Linux: 读 /proc 文件
    fn collectLinux(self: *SystemCollector, snap: *SystemSnapshot, cum: *CumulativeState) !void {
        // 逻辑核数 (load 危机按每核归一)
        if (std.Thread.getCpuCount()) |n| {
            if (n > 0) snap.n_cpus = @intCast(@min(n, std.math.maxInt(u32)));
        } else |_| {}
        // /proc/stat: cpu line "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
        if (try readFile(self.alloc, self.io, "/proc/stat")) |content| {
            defer self.alloc.free(content);
            if (std.mem.indexOf(u8, content, "cpu ")) |cpu_start| {
                var it = std.mem.tokenizeScalar(u8, content[cpu_start..], ' ');
                var idx: u8 = 0;
                var user: u64 = 0;
                var sys: u64 = 0;
                var idle: u64 = 0;
                var total: u64 = 0;
                while (it.next()) |f| {
                    if (idx == 0) {
                        idx += 1;
                        continue; // skip "cpu"
                    }
                    const n = std.fmt.parseInt(u64, f, 10) catch 0;
                    total += n;
                    if (idx == 1) user = n;
                    if (idx == 3) sys = n;
                    if (idx == 4) idle = n;
                    idx += 1;
                }
                if (total > 0) {
                    snap.cpu_user_pct = @as(F, @floatFromInt(user)) * 100.0 / @as(F, @floatFromInt(total));
                    snap.cpu_sys_pct = @as(F, @floatFromInt(sys)) * 100.0 / @as(F, @floatFromInt(total));
                    snap.cpu_idle_pct = @as(F, @floatFromInt(idle)) * 100.0 / @as(F, @floatFromInt(total));
                }
            }
        }
        // /proc/meminfo
        if (try readFile(self.alloc, self.io, "/proc/meminfo")) |content| {
            defer self.alloc.free(content);
            var mem_total_kb: u64 = 0;
            var mem_avail_kb: u64 = 0;
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                if (std.mem.indexOf(u8, line, "MemTotal")) |_| {
                    if (extractLeadingNumber(line)) |n| mem_total_kb = n;
                } else if (std.mem.indexOf(u8, line, "MemAvailable")) |_| {
                    if (extractLeadingNumber(line)) |n| mem_avail_kb = n;
                }
            }
            snap.mem_total_gb = @as(F, @floatFromInt(mem_total_kb)) / 1024.0 / 1024.0;
            const used_kb = if (mem_total_kb > mem_avail_kb) mem_total_kb - mem_avail_kb else 0;
            snap.mem_used_gb = @as(F, @floatFromInt(used_kb)) / 1024.0 / 1024.0;
            if (mem_total_kb > 0) snap.mem_pct = @as(F, @floatFromInt(used_kb)) * 100.0 / @as(F, @floatFromInt(mem_total_kb));
        }
        // /proc/loadavg
        if (try readFile(self.alloc, self.io, "/proc/loadavg")) |content| {
            defer self.alloc.free(content);
            var it = std.mem.tokenizeScalar(u8, content, ' ');
            if (it.next()) |s| snap.load_1m = std.fmt.parseFloat(F, s) catch 0;
        }
        // /proc/net/dev
        if (try readFile(self.alloc, self.io, "/proc/net/dev")) |content| {
            defer self.alloc.free(content);
            var total_in: u64 = 0;
            var total_out: u64 = 0;
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                if (std.mem.indexOf(u8, line, ":")) |colon| {
                    if (std.mem.indexOf(u8, line, "lo:") == null) {
                        var fields = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
                        var idx: u8 = 0;
                        while (fields.next()) |f| : (idx += 1) {
                            if (idx == 0) total_in += std.fmt.parseInt(u64, f, 10) catch 0;
                            if (idx == 8) total_out += std.fmt.parseInt(u64, f, 10) catch 0;
                        }
                    }
                }
            }
            cum.net_in_bytes = total_in;
            cum.net_out_bytes = total_out;
        }
        // /proc/diskstats
        if (try readFile(self.alloc, self.io, "/proc/diskstats")) |content| {
            defer self.alloc.free(content);
            var total_read: u64 = 0;
            var total_write: u64 = 0;
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                // major minor name reads_completed reads_merged sectors_read time_reading writes_completed ...
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                var idx: u8 = 0;
                while (fields.next()) |f| : (idx += 1) {
                    if (idx == 2) {
                        // skip non-physical (e.g. "loop", "ram")
                        if (std.mem.eql(u8, f, "loop") or std.mem.eql(u8, f, "ram") or std.mem.eql(u8, f, "dm-")) break;
                    }
                    if (idx == 5) total_read += std.fmt.parseInt(u64, f, 10) catch 0; // sectors read
                    if (idx == 9) total_write += std.fmt.parseInt(u64, f, 10) catch 0; // sectors written
                }
            }
            cum.disk_read_sectors = total_read;
            cum.disk_write_sectors = total_write;
        }
    }

    /// 把 snapshot 编码成 Information[] (5-7 个)
    pub fn toInformation(self: *SystemCollector, snap: SystemSnapshot) ![]Information {
        const allocs = self.alloc;
        var items: std.ArrayList(Information) = .empty;
        errdefer items.deinit(allocs);

        // 1) 系统资源压力 (CPU + mem + load 归一)
        const resource_pressure: F = blk: {
            const cpu_avg = (snap.cpu_user_pct + snap.cpu_sys_pct) / 2.0;
            const load_norm = @min(1.0, snap.load_1m / @as(F, @floatFromInt(@max(snap.n_cpus, 1)))) * 100.0; // 全核饱和算满
            break :blk @min(1.0, (cpu_avg + snap.mem_pct + load_norm) / 300.0);
        };
        try items.append(allocs, .{
            .id = @intCast(snap.timestamp),
            .label = try std.fmt.allocPrint(allocs, "system_pressure cpu={d:.0}% mem={d:.0}% load={d:.1}", .{
                snap.cpu_user_pct + snap.cpu_sys_pct, snap.mem_pct, snap.load_1m,
            }),
            .features = .{
                resource_pressure, // 0: resource pressure
                @min(1.0, snap.disk_used_pct / 100.0), // 1: disk saturation
                snap.cpu_user_pct / 100.0, // 2: cpu user share
                snap.cpu_idle_pct / 100.0, // 3: cpu idle
            },
        });

        // 2) 网络流量 (rate 已算好在 snap.net_in_mbps)
        const net_total = snap.net_in_mbps + snap.net_out_mbps;
        try items.append(allocs, .{
            .id = @intCast(snap.timestamp + 1),
            .label = try std.fmt.allocPrint(allocs, "network in={d:.3}MB/s out={d:.3}MB/s", .{
                snap.net_in_mbps, snap.net_out_mbps,
            }),
            .features = .{
                @min(1.0, net_total * 10.0), // 0: net activity
                snap.net_in_mbps, // 1: in direction
                snap.net_out_mbps, // 2: out direction
                @min(1.0, @as(F, @floatFromInt(snap.proc_count)) / 1000.0), // 3: proc density
            },
        });

        // 3) 磁盘 I/O
        const io_total = snap.disk_read_mbps + snap.disk_write_mbps;
        try items.append(allocs, .{
            .id = @intCast(snap.timestamp + 2),
            .label = try std.fmt.allocPrint(allocs, "disk r={d:.3}MB/s w={d:.3}MB/s used={d:.0}%", .{
                snap.disk_read_mbps, snap.disk_write_mbps, snap.disk_used_pct,
            }),
            .features = .{
                @min(1.0, io_total * 10.0), // 0: io activity
                snap.disk_read_mbps, // 1: read direction
                snap.disk_write_mbps, // 2: write direction
                snap.disk_used_pct / 100.0, // 3: disk used %
            },
        });

        // 4) 时间上下文 (三角函数编码, 24h 周期 + 7d 周期)
        const h: F = @as(F, @floatFromInt(snap.hour));
        const d: F = @as(F, @floatFromInt(snap.weekday));
        const hour_phase = @cos(h / 24.0 * 2.0 * std.math.pi);
        const day_phase = @sin(d / 7.0 * 2.0 * std.math.pi);
        try items.append(allocs, .{
            .id = @intCast(snap.timestamp + 3),
            .label = try std.fmt.allocPrint(allocs, "time {d:0>2}:00 weekday={d}", .{ snap.hour, snap.weekday }),
            .features = .{
                (hour_phase + 1.0) / 2.0, // 0: hour sin → [0,1]
                (day_phase + 1.0) / 2.0, // 1: day sin → [0,1]
                @as(F, @floatFromInt(snap.hour)) / 24.0, // 2: hour progress
                @as(F, @floatFromInt(snap.weekday)) / 7.0, // 3: week progress
            },
        });

        // 5) 进程负载
        try items.append(allocs, .{
            .id = @intCast(snap.timestamp + 4),
            .label = try std.fmt.allocPrint(allocs, "procs={d} load_1m={d:.2}", .{ @as(F, @floatFromInt(snap.proc_count)), snap.load_1m }),
            .features = .{
                @min(1.0, @as(F, @floatFromInt(snap.proc_count)) / 1000.0),
                @min(1.0, snap.load_1m / 8.0),
                @min(1.0, snap.load_1m / 16.0),
                @min(1.0, snap.load_1m / 32.0),
            },
        });

        // 6) 用户事件 (如果有)
        if (self.user_event) |evt| {
            // 简单的 hash 把事件文本转 4 维特征
            var f0: F = 0;
            var f1: F = 0;
            var f2: F = 0;
            var f3: F = 0;
            for (evt, 0..) |c, i| {
                const x: F = @as(F, @floatFromInt(c)) / 255.0;
                const bucket: u2 = @intCast(i % 4);
                switch (bucket) {
                    0 => f0 += x,
                    1 => f1 += x,
                    2 => f2 += x,
                    3 => f3 += x,
                }
            }
            const norm = @max(1.0, @as(F, @floatFromInt(evt.len)));
            // 0.17 std.fmt.allocPrint 在 writer.grow 时 segfault — 用 bufPrint 固定 buffer
            // 预留 512 字节 (user_event 正常 < 200 字符)
            var label_buf: [512]u8 = undefined;
            const label_str = std.fmt.bufPrint(&label_buf, "user_event {s}", .{evt}) catch
                std.fmt.bufPrint(&label_buf, "user_event_long", .{}) catch "user_event";
            try items.append(allocs, .{
                .id = @intCast(snap.timestamp + 5),
                .label = try allocs.dupe(u8, label_str),
                .features = .{ f0 / norm, f1 / norm, f2 / norm, f3 / norm },
            });
            // 消费掉
            self.alloc.free(evt);
            self.user_event = null;
        }

        return items.toOwnedSlice(allocs);
    }

    /// 释放 Information[] 内存 (每个 label 都是 dupe 出来的)
    pub fn freeInformation(self: *SystemCollector, items: []Information) void {
        for (items) |i| self.alloc.free(i.label);
        self.alloc.free(items);
    }
};

// ===== helpers =====

fn runCmd(alloc: Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(256 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch |err| {
        std.debug.print("[SC DEBUG] runCmd failed: {t} argv={s}\n", .{ err, argv[0] });
        return null;
    };
    defer alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else blk: {
            alloc.free(result.stdout);
            break :blk null;
        },
        else => blk: {
            alloc.free(result.stdout);
            break :blk null;
        },
    };
}

fn readFile(alloc: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0) return null;
    const buf = alloc.alloc(u8, stat.size) catch return null;
    const n = std.Io.File.readStreaming(file, io, &.{buf}) catch {
        alloc.free(buf);
        return null;
    };
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    return buf[0..n];
}

fn extractLeadingNumber(line: []const u8) ?u64 {
    // "MemTotal:        16384000 kB" → 16384000
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // skip name
    if (it.next()) |s| return std.fmt.parseInt(u64, s, 10) catch null;
    return null;
}

/// macOS vm_stat 页类快照 (纯数据, 可测)
const VmStatPages = struct {
    page_size: u64 = 16384,
    active: u64 = 0,
    inactive: u64 = 0,
    wired: u64 = 0,
    compressor: u64 = 0, // "Pages occupied by compressor"

    /// 已用 = wired + active + compressor。语义对齐 Linux 的
    /// MemTotal − MemAvailable: inactive/speculative 是**可回收储备**
    /// (文件缓存 + 待驱逐页), 不计危机水位 —— 计入则 macOS 正常运行
    /// 常年 ~95% 假危机 (2026-09 实测: 旧公式 95.3% vs 承诺内存 79.1%,
    /// 同时 memory_pressure 报 free 47%)。
    pub fn usedBytes(p: VmStatPages) u64 {
        return (p.wired + p.active + p.compressor) * p.page_size;
    }
};

/// 解析 vm_stat 输出 (含 "page size of N bytes" 头)
fn parseVmStat(out: []const u8) VmStatPages {
    var p: VmStatPages = .{};
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "page size of")) |_| {
            if (extractTrailingNumberBefore(line, " bytes")) |n| p.page_size = n;
            continue;
        }
        const n = extractTrailingNumber(line) orelse continue;
        if (std.mem.indexOf(u8, line, "Pages active") != null) {
            p.active = n;
        } else if (std.mem.indexOf(u8, line, "Pages inactive") != null) {
            p.inactive = n;
        } else if (std.mem.indexOf(u8, line, "Pages wired down") != null) {
            p.wired = n;
        } else if (std.mem.indexOf(u8, line, "Pages occupied by compressor") != null) {
            p.compressor = n;
        }
    }
    return p;
}

fn extractTrailingNumberBefore(line: []const u8, suffix: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, line, suffix) orelse return null;
    var end = idx;
    while (end > 0 and line[end - 1] >= '0' and line[end - 1] <= '9') : (end -= 1) {}
    if (end == idx) return null;
    // 跳过分隔逗号
    var start = end;
    while (start > 0 and (line[start - 1] == ',' or (line[start - 1] >= '0' and line[start - 1] <= '9'))) : (start -= 1) {}
    const digits = line[start..idx];
    var clean_buf: [32]u8 = undefined;
    var w: usize = 0;
    for (digits) |c| {
        if (c >= '0' and c <= '9' and w < clean_buf.len) {
            clean_buf[w] = c;
            w += 1;
        }
    }
    if (w == 0) return null;
    return std.fmt.parseInt(u64, clean_buf[0..w], 10) catch null;
}

fn extractTrailingNumber(line: []const u8) ?u64 {
    // "Pages free:                                3757." → 3757
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    var last: ?u64 = null;
    while (it.next()) |s| {
        const cleaned = std.mem.trimEnd(u8, s, ".");
        if (std.fmt.parseInt(u64, cleaned, 10)) |n| {
            last = n;
        } else |_| {}
    }
    return last;
}

test "macos system sample" {
    if (!is_macos) return;
    var sc = SystemCollector.init(std.testing.allocator, std.testing.io, 42);
    defer sc.deinit();
    const snap = try sc.collect();
    try std.testing.expect(snap.mem_total_gb > 0);
    try std.testing.expect(snap.proc_count > 0);
}

// ===== vm_stat 解析测试 =====

test "SystemCollector: parseVmStat — inactive 不计入已用 + 页大小解析" {
    const apple_silicon =
        \\Mach Virtual Memory Statistics: (page size of 16384 bytes)
        \\Pages free:                             7202.
        \\Pages active:                         171694.
        \\Pages inactive:                       168933.
        \\Pages speculative:                      1659.
        \\Pages wired down:                     242982.
        \\Pages occupied by compressor:          414803.
        \\"Pages compressed:                    3479181."
    ;
    const p = parseVmStat(apple_silicon);
    try std.testing.expectEqual(@as(u64, 16384), p.page_size);
    try std.testing.expectEqual(@as(u64, 171694), p.active);
    try std.testing.expectEqual(@as(u64, 168933), p.inactive);
    try std.testing.expectEqual(@as(u64, 242982), p.wired);
    try std.testing.expectEqual(@as(u64, 414803), p.compressor);
    // 已用 = wired+active+compressor (inactive 排除)
    const expect_used = (242982 + 171694 + 414803) * 16384;
    try std.testing.expectEqual(expect_used, p.usedBytes());
    // 旧公式 (含 inactive) 在本机样本上给出 95.3% 假危机水位; 新公式 79.1%
    const total = 1048576 * 16384;
    const old_pct = @as(f64, @floatFromInt((242982 + 171694 + 414803 + 168933) * 16384)) / @as(f64, @floatFromInt(total)) * 100;
    const new_pct = @as(f64, @floatFromInt(expect_used)) / @as(f64, @floatFromInt(total)) * 100;
    try std.testing.expect(old_pct > 94.0); // 旧公式确实假危机
    try std.testing.expect(new_pct < 80.0 and new_pct > 78.0); // 新公式低于 MEM_PCT_EPS=92
}

test "SystemCollector: parseVmStat — Intel 页大小 4096 不再 4x 高估" {
    const intel =
        \\Mach Virtual Memory Statistics: (page size of 4096 bytes)
        \\Pages free:                             10000.
        \\Pages active:                           500000.
        \\Pages inactive:                         400000.
        \\Pages wired down:                       300000.
        \\Pages occupied by compressor:            50000.
    ;
    const p = parseVmStat(intel);
    try std.testing.expectEqual(@as(u64, 4096), p.page_size);
    try std.testing.expectEqual((300000 + 500000 + 50000) * 4096, p.usedBytes());
}
