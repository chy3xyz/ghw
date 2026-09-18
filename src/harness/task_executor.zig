//! task_executor — 有界真执行 (P2)
//!
//! world_sensor / peer / 世界扫描任务不再只跑合成 Information：
//!   - diagnose_host: 用 SystemSnapshot 写诊断报告 + 压力特征进 runCycle
//!   - query_peer:    经 GHW Link 只读 query_state/beliefs/actions
//!   - scan_world:    只读进程景观摘要 (已采集的 WorldContext, 不新开无限 shell)
//!
//! 硬边界: 无任意 shell、无写盘、无杀进程。LLM 只提议任务; 执行器只做只读诊断,
//! ΔE 仍由数字生命 runCycle 决定。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Information = @import("../goal/mod.zig").Information;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const GhwLink = @import("ghw_link.zig").Link;
const action_runner = @import("../sandbox/action_runner.zig");

pub const Kind = enum {
    diagnose_host,
    query_peer,
    scan_world,
    human_handoff,
    synthetic,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .diagnose_host => "diagnose_host",
            .query_peer => "query_peer",
            .scan_world => "scan_world",
            .human_handoff => "human_handoff",
            .synthetic => "synthetic",
        };
    }
};

pub const PeerRef = struct {
    path: []const u8,
    peer_id: []const u8,
    health: []const u8 = "unknown",
};

pub const ProcBrief = struct {
    comm: []const u8,
    cpu_pct: F,
    mem_pct: F,
};

pub const Env = struct {
    snap: ?SystemSnapshot = null,
    top_procs: []const ProcBrief = &[_]ProcBrief{},
    link: ?*const GhwLink = null,
    peers: []const PeerRef = &[_]PeerRef{},
};

pub const Prep = struct {
    kind: Kind,
    /// 诊断/查询报告 (owned)
    report: []u8,
    /// 喂给 runCycle 的特征 (owned labels)
    infos: []Information,
    acted: bool,

    pub fn deinit(self: *Prep, alloc: Allocator) void {
        alloc.free(self.report);
        for (self.infos) |inf| alloc.free(inf.label);
        alloc.free(self.infos);
        self.* = undefined;
    }
};

/// 按 source + 标题启发式分类 (无 LLM)
pub fn classify(task: *const Task) Kind {
    if (task.source == .world_sensor) return .diagnose_host;
    // P6: 外网信号任务 (须在通用 [world] 前缀之前)
    if (task.source == .world_fetch or
        std.mem.startsWith(u8, task.title, "[world] security") or
        std.mem.startsWith(u8, task.title, "[world] incident") or
        std.mem.startsWith(u8, task.title, "[world] agent") or
        std.mem.startsWith(u8, task.title, "[world] systems"))
    {
        return .scan_world;
    }
    if (std.mem.startsWith(u8, task.title, "[world]")) return .diagnose_host;
    // P5: 人类介入清单 — 数字生命「动作」= 升级给人类 (不执行破坏)
    if (task.source == .survival_act or std.mem.startsWith(u8, task.title, "[act]")) return .human_handoff;
    // P7: 同伴共生任务 → 再 query
    if (task.source == .peer_symbiosis or std.mem.startsWith(u8, task.title, "[peer]")) return .query_peer;
    // P5b / P3: 代谢与补救
    if (task.source == .metabolism or std.mem.startsWith(u8, task.title, "[meta]")) {
        if (containsAny(task.title, &[_][]const u8{ "peer", "同伴", "共生" })) return .query_peer;
        if (containsAny(task.title, &[_][]const u8{ "scan", "world", "novelty" })) return .scan_world;
        return .synthetic;
    }
    if (task.source == .survival_remedy or std.mem.startsWith(u8, task.title, "[remedy]")) {
        if (containsAny(task.title, &[_][]const u8{ "peer", "同伴", "共生" })) return .query_peer;
        return .scan_world;
    }
    if (action_runner.isPeerGoal(task.title) or action_runner.isPeerGoal(task.description)) return .query_peer;
    if (containsAny(task.title, &[_][]const u8{ "磁盘", "disk", "内存", "memory", "负载", "load", "压力" }) or
        containsAny(task.description, &[_][]const u8{ "disk", "memory", "load", "磁盘", "内存" }))
    {
        return .diagnose_host;
    }
    if (task.source == .llm_proposer and
        containsAny(task.title, &[_][]const u8{ "进程", "process", "扫描", "scan", "世界", "world", "主机" }))
    {
        return .scan_world;
    }
    return .synthetic;
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

/// 执行有界动作, 产出报告 + Information。synthetic 时 report 为空、acted=false。
pub fn prepare(alloc: Allocator, task: *const Task, env: Env) !Prep {
    const kind = classify(task);
    return switch (kind) {
        .diagnose_host => try prepareDiagnose(alloc, task, env),
        .query_peer => try preparePeerQuery(alloc, task, env),
        .scan_world => try prepareWorldScan(alloc, task, env),
        .human_handoff => try prepareHumanHandoff(alloc, task),
        .synthetic => .{
            .kind = .synthetic,
            .report = try alloc.dupe(u8, ""),
            .infos = try alloc.alloc(Information, 0),
            .acted = false,
        },
    };
}

fn prepareHumanHandoff(alloc: Allocator, task: *const Task) !Prep {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.print(alloc, "[human_handoff] escalated: {s}\n", .{task.title});
    try buf.print(alloc, "checklist:\n{s}\n", .{task.description});
    try buf.appendSlice(alloc, "action: waited for human (no shell/kill). GHW acted by escalating.\n");
    const report = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(report);

    var infos = try alloc.alloc(Information, 1);
    errdefer {
        for (infos) |inf| alloc.free(inf.label);
        alloc.free(infos);
    }
    infos[0] = .{
        .id = task.id * 1000 + 17,
        .label = try std.fmt.allocPrint(alloc, "handoff:{s}", .{truncate(task.title, 40)}),
        .features = .{ 0.40, 0.55, 0.70, 0.20 },
    };
    return .{
        .kind = .human_handoff,
        .report = report,
        .infos = infos,
        .acted = true,
    };
}

fn prepareDiagnose(alloc: Allocator, task: *const Task, env: Env) !Prep {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.print(alloc, "[diagnose_host] task=\"{s}\"\n", .{task.title});
    if (env.snap) |snap| {
        try buf.print(alloc,
            \\host: cpu={d:.0}% mem={d:.1}/{d:.1}GB ({d:.0}%) disk={d:.0}% load={d:.2} procs={d}
            \\net_in={d:.3}MB/s net_out={d:.3}MB/s disk_r={d:.3}MB/s disk_w={d:.3}MB/s
            \\
        , .{
            snap.cpu_user_pct + snap.cpu_sys_pct,
            snap.mem_used_gb,
            snap.mem_total_gb,
            snap.mem_pct,
            snap.disk_used_pct,
            snap.load_1m,
            snap.proc_count,
            snap.net_in_mbps,
            snap.net_out_mbps,
            snap.disk_read_mbps,
            snap.disk_write_mbps,
        });
        if (snap.disk_used_pct >= 90.0) {
            try buf.appendSlice(alloc, "finding: disk near full — free caches / large logs before material E collapses.\n");
        }
        if (snap.mem_pct >= 92.0) {
            try buf.appendSlice(alloc, "finding: memory pressure — identify heavy procs; avoid new allocations.\n");
        }
        if (snap.load_1m >= 8.0) {
            try buf.appendSlice(alloc, "finding: load spike — isolate runaway CPU before nature/material starve.\n");
        }
    } else {
        try buf.appendSlice(alloc, "host: snapshot unavailable; falling back to title heuristics.\n");
    }

    if (env.top_procs.len > 0) {
        try buf.appendSlice(alloc, "top_procs:\n");
        const n = @min(env.top_procs.len, 5);
        for (env.top_procs[0..n]) |p| {
            try buf.print(alloc, "  - {s} cpu={d:.1}% mem={d:.1}%\n", .{ p.comm, p.cpu_pct, p.mem_pct });
        }
    }

    const report = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(report);

    var infos = try alloc.alloc(Information, 1);
    errdefer {
        for (infos) |inf| alloc.free(inf.label);
        alloc.free(infos);
    }
    const features = pressureFeatures(env.snap);
    const label = try std.fmt.allocPrint(alloc, "diagnose:{s}", .{truncate(task.title, 48)});
    infos[0] = .{
        .id = task.id * 1000 + 7,
        .label = label,
        .features = features,
    };

    return .{
        .kind = .diagnose_host,
        .report = report,
        .infos = infos,
        .acted = true,
    };
}

fn pressureFeatures(snap: ?SystemSnapshot) [4]F {
    if (snap) |s| {
        const cpu = @min(1.0, (s.cpu_user_pct + s.cpu_sys_pct) / 100.0);
        const mem = @min(1.0, s.mem_pct / 100.0);
        const disk = @min(1.0, s.disk_used_pct / 100.0);
        const load = @min(1.0, s.load_1m / 8.0);
        return .{ @max(cpu, load), disk, mem, 1.0 - @min(cpu, 0.95) };
    }
    return .{ 0.75, 0.70, 0.40, 0.30 };
}

fn preparePeerQuery(alloc: Allocator, task: *const Task, env: Env) !Prep {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.print(alloc, "[query_peer] task=\"{s}\"\n", .{task.title});

    const link = env.link orelse {
        try buf.appendSlice(alloc, "skipped: GHW Link not bound.\n");
        const report = try buf.toOwnedSlice(alloc);
        return syntheticPrep(alloc, .query_peer, report, false);
    };
    const peer = pickLivePeer(env.peers) orelse {
        try buf.appendSlice(alloc, "skipped: no live peer (exclude self/unreachable).\n");
        const report = try buf.toOwnedSlice(alloc);
        return syntheticPrep(alloc, .query_peer, report, false);
    };

    const method: []const u8 = if (std.mem.indexOf(u8, task.title, "信念") != null)
        "query_beliefs"
    else if (std.mem.indexOf(u8, task.title, "行动") != null or std.mem.indexOf(u8, task.title, "动作") != null)
        "query_actions"
    else
        "query_state";

    try buf.print(alloc, "peer={s} method={s}\n", .{ peer.peer_id, method });
    const resp = link.query(peer.path, method, "{}") catch |err| {
        try buf.print(alloc, "query failed: {t}\n", .{err});
        const report = try buf.toOwnedSlice(alloc);
        return syntheticPrep(alloc, .query_peer, report, false);
    };
    defer alloc.free(resp);

    const clipped = truncate(resp, 1500);
    try buf.print(alloc, "response: {s}\n", .{clipped});

    const report = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(report);

    var infos = try alloc.alloc(Information, 1);
    errdefer {
        for (infos) |inf| alloc.free(inf.label);
        alloc.free(infos);
    }
    infos[0] = .{
        .id = task.id * 1000 + 11,
        .label = try std.fmt.allocPrint(alloc, "peer:{s}:{s}", .{ peer.peer_id, method }),
        .features = .{ 0.55, 0.35, 0.80, 0.25 },
    };

    return .{
        .kind = .query_peer,
        .report = report,
        .infos = infos,
        .acted = true,
    };
}

fn prepareWorldScan(alloc: Allocator, task: *const Task, env: Env) !Prep {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.print(alloc, "[scan_world] task=\"{s}\"\n", .{task.title});

    if (env.snap) |snap| {
        try buf.print(alloc, "host load={d:.2} mem={d:.0}% procs={d}\n", .{ snap.load_1m, snap.mem_pct, snap.proc_count });
    }
    if (env.top_procs.len == 0) {
        try buf.appendSlice(alloc, "landscape: unavailable (WorldContext not collected).\n");
        const report = try buf.toOwnedSlice(alloc);
        return syntheticPrep(alloc, .scan_world, report, false);
    }

    try buf.appendSlice(alloc, "top_procs (read-only):\n");
    const n = @min(env.top_procs.len, 8);
    for (env.top_procs[0..n]) |p| {
        try buf.print(alloc, "  - {s} cpu={d:.1}% mem={d:.1}%\n", .{ p.comm, p.cpu_pct, p.mem_pct });
    }

    const report = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(report);

    var infos = try alloc.alloc(Information, 1);
    errdefer {
        for (infos) |inf| alloc.free(inf.label);
        alloc.free(infos);
    }
    infos[0] = .{
        .id = task.id * 1000 + 13,
        .label = try alloc.dupe(u8, "scan_world:top_procs"),
        .features = .{ 0.50, 0.45, 0.70, 0.35 },
    };

    return .{
        .kind = .scan_world,
        .report = report,
        .infos = infos,
        .acted = true,
    };
}

fn syntheticPrep(alloc: Allocator, kind: Kind, report: []u8, acted: bool) !Prep {
    return .{
        .kind = kind,
        .report = report,
        .infos = try alloc.alloc(Information, 0),
        .acted = acted,
    };
}

fn pickLivePeer(peers: []const PeerRef) ?PeerRef {
    for (peers) |p| {
        if (std.mem.eql(u8, p.health, "self")) continue;
        if (std.mem.eql(u8, p.health, "unreachable")) continue;
        if (p.path.len == 0) continue;
        return p;
    }
    return null;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

const testing = std.testing;

fn testTask(alloc: Allocator, title: []const u8, desc: []const u8, source: Task.Source) !Task {
    return .{
        .id = 1,
        .title = try alloc.dupe(u8, title),
        .description = try alloc.dupe(u8, desc),
        .from_human = try alloc.dupe(u8, "world_sensor"),
        .priority = 9,
        .required_dimension = .material,
        .cycles_allocated = 2,
        .source = source,
        .allocator = alloc,
    };
}

test "task_executor: classify world_sensor → diagnose_host" {
    const alloc = testing.allocator;
    var t = try testTask(alloc, "[world] disk pressure 95%", "disk full", .world_sensor);
    defer t.deinit();
    try testing.expectEqual(Kind.diagnose_host, classify(&t));
}

test "task_executor: classify peer title → query_peer" {
    const alloc = testing.allocator;
    var t = try testTask(alloc, "连接同伴查询状态", "peer", .llm_proposer);
    defer t.deinit();
    try testing.expectEqual(Kind.query_peer, classify(&t));
}

test "task_executor: prepare diagnose uses snapshot features" {
    const alloc = testing.allocator;
    var t = try testTask(alloc, "[world] memory pressure 93%", "mem high", .world_sensor);
    defer t.deinit();
    const snap = SystemSnapshot{
        .cpu_user_pct = 20,
        .cpu_sys_pct = 10,
        .cpu_idle_pct = 70,
        .mem_used_gb = 14,
        .mem_total_gb = 16,
        .mem_pct = 93,
        .disk_used_pct = 40,
        .load_1m = 2.0,
        .proc_count = 300,
        .net_in_mbps = 0.1,
        .net_out_mbps = 0.1,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
    var prep = try prepare(alloc, &t, .{ .snap = snap });
    defer prep.deinit(alloc);
    try testing.expectEqual(Kind.diagnose_host, prep.kind);
    try testing.expect(prep.acted);
    try testing.expect(prep.infos.len == 1);
    try testing.expect(std.mem.indexOf(u8, prep.report, "mem=") != null);
    try testing.expect(prep.infos[0].features[2] >= 0.9);
}
