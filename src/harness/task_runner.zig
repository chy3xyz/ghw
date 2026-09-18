//! task_runner — TaskQueue 与 GHWAgent.runTask 的薄封装 (P6)
//!
//! dequeue → (P2 task_executor 有界动作) → runTaskPrepared → complete / fail
//! → (P3 survival_remedy 诊断后补救入队)
//! → (P4 survival_learn 信念写回)

const std = @import("std");
const Allocator = std.mem.Allocator;
const GHWAgent = @import("../agent/core.zig").GHWAgent;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const task_executor = @import("task_executor.zig");
const survival_remedy = @import("survival_remedy.zig");
const survival_learn = @import("survival_learn.zig");
const survival_act = @import("survival_act.zig");
const peer_symbiosis = @import("peer_symbiosis.zig");

pub const RunResult = struct {
    task_id: u64,
    title: []const u8,
    actual_delta_e: f32,
    cycles_used: u32,
    action_kind: []const u8 = "synthetic",
    acted: bool = false,
    remedy_submitted: u32 = 0,
    beliefs_added: u32 = 0,
    host_crisis: bool = false,
    act_human_tasks: u32 = 0,
    /// null = unchanged; Some(0) = clear; Some(N) = set override seconds
    throttle_autocli_s: ?u64 = null,
    peer_e_seen: f32 = 0,
    peer_followups: u32 = 0,
};

/// 取最高优先级 pending 任务并执行。返回 null 表示队列空或 dequeue 失败。
/// env=null → 纯合成路径 (旧行为, 单测兼容)。
pub fn runNextPending(agent: *GHWAgent, queue: *TaskQueue, alloc: Allocator) !?RunResult {
    return runNextPendingWithEnv(agent, queue, alloc, null);
}

pub fn runNextPendingWithEnv(
    agent: *GHWAgent,
    queue: *TaskQueue,
    alloc: Allocator,
    env: ?task_executor.Env,
) !?RunResult {
    const t = queue.dequeue() orelse return null;

    var prep: ?task_executor.Prep = null;
    defer if (prep) |*p| p.deinit(alloc);

    if (env) |e| {
        prep = task_executor.prepare(alloc, t, e) catch null;
    }

    const result = blk: {
        if (prep) |*p| {
            if (p.infos.len > 0 or p.report.len > 0) {
                break :blk agent.runTaskPrepared(t, if (p.infos.len > 0) p.infos else null, p.report);
            }
        }
        break :blk agent.runTask(t);
    } catch {
        queue.fail(t.id);
        return null;
    };
    defer alloc.free(result.output);
    try queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);

    const kind_label: []const u8 = if (prep) |p| p.kind.label() else "synthetic";
    const acted = if (prep) |p| p.acted else false;

    // P3: 诊断落地后提议有界补救 (只入队, 不直接改 E)
    var remedy_submitted: u32 = 0;
    if (prep) |p| {
        if (p.kind == .diagnose_host and p.acted and p.report.len > 0) {
            const has_peers = if (env) |e| blk: {
                for (e.peers) |peer| {
                    if (std.mem.eql(u8, peer.health, "self")) continue;
                    if (std.mem.eql(u8, peer.health, "unreachable")) continue;
                    if (peer.path.len > 0) break :blk true;
                }
                break :blk false;
            } else false;
            const fu = survival_remedy.maybeFollowUpFromReport(queue, p.report, has_peers, alloc) catch null;
            if (fu) |r| remedy_submitted = r.submitted;
        }
    }

    // P4: 诊断/补救报告 → 求存信念
    var beliefs_added: u32 = 0;
    var host_crisis: bool = false;
    if (prep) |p| {
        if (p.acted and p.report.len > 0) {
            if (agent.memory) |mem| {
                const learned = survival_learn.learnFromReport(
                    mem,
                    agent.memory_io,
                    agent.tick,
                    p.report,
                    result.actual_delta_e,
                ) catch null;
                if (learned) |lr| {
                    beliefs_added = lr.beliefs_added;
                    host_crisis = lr.crisis;
                }
            } else {
                host_crisis = survival_learn.isCrisisReport(p.report);
            }
        }
    }
    if (env) |e| {
        if (e.snap) |snap| {
            if (survival_learn.isCrisisSnap(snap)) host_crisis = true;
        }
    }

    // P5a: 有界补救 — 节流 AutoCLI + 人类介入清单
    var act_human_tasks: u32 = 0;
    var throttle_autocli_s: ?u64 = null;
    if (prep) |p| {
        if (p.kind == .diagnose_host and p.acted and p.report.len > 0) {
            const ar = survival_act.applyFromReport(
                queue,
                agent.memory,
                agent.memory_io,
                agent.tick,
                p.report,
                1,
            ) catch null;
            if (ar) |a| {
                act_human_tasks = a.human_tasks;
                throttle_autocli_s = a.throttle_autocli_s;
            }
        }
    }

    // P7: query_peer 结果 → 信念 + peer_E + follow-up
    var peer_e_seen: f32 = 0;
    var peer_followups: u32 = 0;
    if (prep) |p| {
        if (p.kind == .query_peer and p.acted and p.report.len > 0) {
            const pin = peer_symbiosis.learnFromReport(
                agent.memory,
                agent.memory_io,
                agent.tick,
                p.report,
                agent.ed.e(),
                queue,
            ) catch null;
            if (pin) |ins| {
                peer_e_seen = ins.peer_e;
                peer_followups = ins.followups;
                beliefs_added += ins.beliefs_added;
            }
        }
    }

    return .{
        .task_id = t.id,
        .title = t.title,
        .actual_delta_e = result.actual_delta_e,
        .cycles_used = result.cycles_used,
        .action_kind = kind_label,
        .acted = acted,
        .remedy_submitted = remedy_submitted,
        .beliefs_added = beliefs_added,
        .host_crisis = host_crisis,
        .act_human_tasks = act_human_tasks,
        .throttle_autocli_s = throttle_autocli_s,
        .peer_e_seen = peer_e_seen,
        .peer_followups = peer_followups,
    };
}

test "task_runner: runNextPending 完成 pending 任务" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var agent = try GHWAgent.init(alloc, "tr-test", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    var mem = @import("memory.zig").Memory.init(alloc, 1);
    defer mem.deinit();
    agent.bindMemory(&mem, io);

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    _ = try queue.submit("do thing", "desc", "alice", 8, .nature, 2);

    const ran = try runNextPending(&agent, &queue, alloc);
    try std.testing.expect(ran != null);
    try std.testing.expectEqual(@as(u32, 1), queue.completed_count);
    try std.testing.expectEqual(@as(usize, 1), mem.episodes.items.len);
    try std.testing.expectEqual(@import("memory.zig").EpisodeKind.task_completed, mem.episodes.items[0].kind);
}

test "task_runner: world_sensor 走 diagnose_host" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var agent = try GHWAgent.init(alloc, "tr-ws", 4, .{ 3, 3, 3 }, 1);
    defer agent.deinit();
    var mem = @import("memory.zig").Memory.init(alloc, 1);
    defer mem.deinit();
    agent.bindMemory(&mem, io);

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    _ = try queue.submitWithSource(
        "[world] disk pressure 95%",
        "Root disk high",
        "world_sensor",
        9,
        .material,
        2,
        .world_sensor,
    );

    const snap = @import("system_collector.zig").SystemSnapshot{
        .cpu_user_pct = 10,
        .cpu_sys_pct = 5,
        .cpu_idle_pct = 85,
        .mem_used_gb = 8,
        .mem_total_gb = 16,
        .mem_pct = 50,
        .disk_used_pct = 95,
        .load_1m = 1.0,
        .proc_count = 200,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
    const ran = try runNextPendingWithEnv(&agent, &queue, alloc, .{ .snap = snap });
    try std.testing.expect(ran != null);
    try std.testing.expectEqualStrings("diagnose_host", ran.?.action_kind);
    try std.testing.expect(ran.?.acted);
    try std.testing.expect(ran.?.remedy_submitted >= 1);
    try std.testing.expect(queue.pending_count >= 1);
    try std.testing.expect(ran.?.beliefs_added >= 1);
    try std.testing.expect(ran.?.host_crisis);
    try std.testing.expect(ran.?.act_human_tasks >= 1);
    try std.testing.expect(ran.?.throttle_autocli_s != null);
    try std.testing.expect(ran.?.throttle_autocli_s.? >= 900);
    try std.testing.expect(mem.episodes.items.len >= 1);
    try std.testing.expect(mem.episodes.items[0].detail != null);
    // 求存信念已写入
    try std.testing.expect(mem.beliefs.items.len >= 1);
}
