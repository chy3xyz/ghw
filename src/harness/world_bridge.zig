//! world_bridge — AutoCLI 外网 → 可行动任务 (P6)
//!
//! 历史缺口: world_fetch 进 Memory 后很少变成任务/规则采纳。
//! 本模块对拉取标题/摘要做启发式扫描, 命中则入队有界任务 (去重)。
//!
//! 决策权仍在数字生命: 只入队; 选跑靠 TaskBias + ΔE。
//! WorldCollector(旧 autocli ask 子进程) 与本通道并存 — 生产主路径是 AutoCLI+bridge。

const std = @import("std");
const Allocator = std.mem.Allocator;
const TaskQueue = @import("human_symbiosis/task_queue.zig").TaskQueue;
const Task = @import("human_symbiosis/task_queue.zig").Task;

pub const AdoptResult = struct {
    submitted: u32 = 0,
    skipped_dup: u32 = 0,
    skipped_noise: u32 = 0,
};

const Signal = struct {
    needles: []const []const u8,
    title_prefix: []const u8,
    dim: Task.Dimension,
    priority: u8,
    kind: enum { security, incident, agent, systems },
};

const SIGNALS = [_]Signal{
    .{
        .needles = &[_][]const u8{ "CVE", "vulnerability", "exploit", "zero-day", "0-day", "安全漏洞" },
        .title_prefix = "[world] security signal",
        .dim = .material,
        .priority = 8,
        .kind = .security,
    },
    .{
        .needles = &[_][]const u8{ "outage", "downtime", "incident", "故障", "中断", "breach" },
        .title_prefix = "[world] incident signal",
        .dim = .material,
        .priority = 7,
        .kind = .incident,
    },
    .{
        .needles = &[_][]const u8{ "AI agent", "LLM", "self-improv", "autonomous", "数字生命", "agentic" },
        .title_prefix = "[world] agent research",
        .dim = .nature,
        .priority = 5,
        .kind = .agent,
    },
    .{
        .needles = &[_][]const u8{ "Zig", "wasm", "WebAssembly", "systems programming" },
        .title_prefix = "[world] systems tech",
        .dim = .representation,
        .priority = 5,
        .kind = .systems,
    },
};

fn hasPendingTitlePrefix(queue: *const TaskQueue, prefix: []const u8) bool {
    for (queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        if (std.mem.startsWith(u8, t.title, prefix)) return true;
    }
    return false;
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

/// 单条 fetch → 最多 1 个任务 (按信号优先级)
pub fn maybeAdoptFromFetch(
    queue: *TaskQueue,
    title: []const u8,
    snippet: []const u8,
    alloc: Allocator,
) !AdoptResult {
    _ = alloc;
    var out: AdoptResult = .{};
    var hay_buf: [512]u8 = undefined;
    // 拼 title+snippet 到栈缓冲 (截断)
    var n: usize = 0;
    const tpart = clip(title, 200);
    @memcpy(hay_buf[0..tpart.len], tpart);
    n = tpart.len;
    if (n < hay_buf.len) {
        hay_buf[n] = ' ';
        n += 1;
    }
    const spart = clip(snippet, hay_buf.len - n);
    @memcpy(hay_buf[n .. n + spart.len], spart);
    n += spart.len;
    const hay = hay_buf[0..n];

    for (SIGNALS) |sig| {
        if (!containsAny(hay, sig.needles)) continue;
        if (hasPendingTitlePrefix(queue, sig.title_prefix)) {
            out.skipped_dup += 1;
            return out;
        }
        const summary = clip(title, 120);
        const desc = switch (sig.kind) {
            .security => try std.fmt.allocPrint(queue.allocator, "External security signal: {s}. Propose defensive/material rules; do not run untrusted code.", .{summary}),
            .incident => try std.fmt.allocPrint(queue.allocator, "External incident signal: {s}. Prefer resilience tasks and peer health checks.", .{summary}),
            .agent => try std.fmt.allocPrint(queue.allocator, "Agent/LLM research: {s}. Reflect into nature/representation goals (no GoalGraph injection).", .{summary}),
            .systems => try std.fmt.allocPrint(queue.allocator, "Systems/tech signal: {s}. May inform L2-L5 evolution proposals via Guard.", .{summary}),
        };
        defer queue.allocator.free(desc);
        const full_title = try std.fmt.allocPrint(queue.allocator, "{s}: {s}", .{ sig.title_prefix, clip(title, 60) });
        defer queue.allocator.free(full_title);
        _ = try queue.submitWithSource(full_title, desc, "world_bridge", sig.priority, sig.dim, 4, .world_fetch);
        out.submitted = 1;
        return out;
    }
    out.skipped_noise = 1;
    return out;
}

/// 批量: 每批最多 max_submit 条
pub fn maybeAdoptBatch(
    queue: *TaskQueue,
    titles: []const []const u8,
    snippets: []const []const u8,
    max_submit: u32,
    alloc: Allocator,
) !AdoptResult {
    var out: AdoptResult = .{};
    const n = @min(titles.len, snippets.len);
    var i: usize = 0;
    while (i < n and out.submitted < max_submit) : (i += 1) {
        const r = try maybeAdoptFromFetch(queue, titles[i], snippets[i], alloc);
        out.submitted += r.submitted;
        out.skipped_dup += r.skipped_dup;
        out.skipped_noise += r.skipped_noise;
    }
    return out;
}

/// 一行外网摘要给 RuleProposer (不拥有)
pub fn formatDigestLine(alloc: Allocator, title: []const u8, source_tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "[{s}] {s}", .{ source_tag, clip(title, 80) });
}

const testing = std.testing;

test "world_bridge: CVE title submits security task once" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r1 = try maybeAdoptFromFetch(&q, "Critical CVE-2026-1234 in OpenSSL", "exploit details", alloc);
    try testing.expectEqual(@as(u32, 1), r1.submitted);
    try testing.expectEqual(Task.Source.world_fetch, q.tasks.items[0].source);
    const r2 = try maybeAdoptFromFetch(&q, "Another CVE-2026-9999", "x", alloc);
    try testing.expectEqual(@as(u32, 0), r2.submitted);
    try testing.expectEqual(@as(u32, 1), r2.skipped_dup);
}

test "world_bridge: noise skipped" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const r = try maybeAdoptFromFetch(&q, "Cute cat photos", "fluff", alloc);
    try testing.expectEqual(@as(u32, 0), r.submitted);
    try testing.expectEqual(@as(u32, 1), r.skipped_noise);
}
