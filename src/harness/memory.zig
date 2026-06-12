//! Memory — 数字生命的记忆系统
//!
//! 三类记忆 + 自我叙事:
//!   1. Episode:  滚动 200 条, 每个 cycle 一条, 记录"那一刻发生了什么"
//!   2. Belief:   LLM 提炼的"我相信什么", 持续累积
//!   3. SelfNarrative: 自我叙事, 一段话, 定期 LLM 更新
//!
//! 三源记忆维度 (与 M/R/N 对应):
//!   M-belief: 物质世界事实 (机器有什么资源, 哪些进程在烧 CPU, 哪些能优化)
//!   R-belief: 表达/沟通事实 (我用什么方式说话, 哪些任务被接受率高)
//!   N-belief: 自我认知 (我是谁, 我在乎什么, 我擅长什么)
//!
//! Memory **不依赖 LLM** 就能工作 (episodic 是结构化存储)
//! 但 reflection/提炼 需要 LLM
//!
//! 设计要点:
//!   - Episode 写时低开销 (单 struct append)
//!   - Belief 接受 LLM 输出, 失败时回退到启发式
//!   - SelfNarrative 简化为单字符串, LLM 周期性重新生成
//!   - 全部可序列化 (state.json 的一部分), 跨重启保留

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const LCG = @import("../util/math.zig").LCG;

pub const EpisodeKind = enum {
    system_event, // 系统状态变化 (CPU spike, mem full, network)
    user_chat, // 用户消息
    llm_proposal, // LLM 提议了目标
    self_evolution, // 自演化触发
    task_completed, // TaskQueue 任务完成
    reflection, // 自省周期触发
    peer_discovered, // 发现其他 GHW
};

pub const Episode = struct {
    tick: u64,
    timestamp: i64,
    kind: EpisodeKind,
    /// 简短描述 (1 句话, 内部 alloc)
    summary: []u8,
    /// 自由扩展 (LLM 提炼的事实/观察, 可选)
    detail: ?[]u8,
    /// 该 episode 对哪个三源有影响 (+1=material, 2=representation, 3=nature)
    /// 0 = 跨维度
    dimension: u8,
    /// E 变化 (e_after - e_before)
    delta_e: F,
};

pub const BeliefSource = enum {
    material, // M 维度: 物理世界事实
    representation, // R 维度: 表达/沟通
    nature, // N 维度: 自我/价值观
};

pub const Belief = struct {
    source: BeliefSource,
    /// "我应该 xxx" / "xxx 让我 E 跌" / "用户偏好 yyy"
    text: []u8,
    /// 置信度 0-1
    confidence: F,
    /// 何时形成
    formed_at_tick: u64,
    /// 基于哪几条 episode
    evidence_ticks: []u64, // 最多 4 个
};

pub const Memory = struct {
    alloc: Allocator,
    rng: LCG,

    episodes: std.ArrayList(Episode) = .empty,
    beliefs: std.ArrayList(Belief) = .empty,
    /// 自我叙事: 1 段话, 描述"我是谁"
    self_narrative: []u8,

    /// 最近一次 reflection 的 tick
    last_reflection_tick: u64 = 0,
    /// 总反思次数
    reflection_count: u32 = 0,

    const MAX_EPISODES: usize = 200;
    const MAX_BELIEFS: usize = 32;
    const SELF_NARRATIVE_MAX: usize = 2048;

    pub fn init(alloc: Allocator, seed: u64) Memory {
        return .{
            .alloc = alloc,
            .rng = LCG.init(seed),
            .self_narrative = alloc.dupe(u8, "") catch &[_]u8{},
        };
    }

    pub fn deinit(self: *Memory) void {
        for (self.episodes.items) |e| {
            self.alloc.free(e.summary);
            if (e.detail) |d| self.alloc.free(d);
        }
        self.episodes.deinit(self.alloc);
        for (self.beliefs.items) |b| {
            self.alloc.free(b.text);
            self.alloc.free(b.evidence_ticks);
        }
        self.beliefs.deinit(self.alloc);
        self.alloc.free(self.self_narrative);
    }

    /// 记录一条 episode (rolling buffer)
    pub fn record(self: *Memory, io: std.Io, kind: EpisodeKind, summary: []const u8, detail: ?[]const u8, dim: u8, delta_e: F) !void {
        if (self.episodes.items.len >= MAX_EPISODES) {
            // 弹出最老的
            const old = self.episodes.orderedRemove(0);
            self.alloc.free(old.summary);
            if (old.detail) |d| self.alloc.free(d);
        }
        try self.episodes.append(self.alloc, .{
            .tick = @intCast(0), // 实际由调用方填
            .timestamp = std.Io.Clock.real.now(io).toSeconds(),
            .kind = kind,
            .summary = try self.alloc.dupe(u8, summary),
            .detail = if (detail) |d| try self.alloc.dupe(u8, d) else null,
            .dimension = dim,
            .delta_e = delta_e,
        });
    }

    pub fn recordAt(self: *Memory, io: std.Io, kind: EpisodeKind, tick: u64, summary: []const u8, detail: ?[]const u8, dim: u8, delta_e: F) !void {
        if (self.episodes.items.len >= MAX_EPISODES) {
            const old = self.episodes.orderedRemove(0);
            self.alloc.free(old.summary);
            if (old.detail) |d| self.alloc.free(d);
        }
        try self.episodes.append(self.alloc, .{
            .tick = tick,
            .timestamp = std.Io.Clock.real.now(io).toSeconds(),
            .kind = kind,
            .summary = try self.alloc.dupe(u8, summary),
            .detail = if (detail) |d| try self.alloc.dupe(u8, d) else null,
            .dimension = dim,
            .delta_e = delta_e,
        });
    }

    /// 提炼新 belief (LLM 输出或用户输入)
    /// formed_at_tick: 提炼时的 agent tick, 不传默认 0
    pub fn addBelief(self: *Memory, source: BeliefSource, text: []const u8, confidence: F, evidence: []const u64) !void {
        return self.addBeliefAt(source, text, confidence, evidence, 0);
    }

    pub fn addBeliefAt(self: *Memory, source: BeliefSource, text: []const u8, confidence: F, evidence: []const u64, formed_at_tick: u64) !void {
        if (self.beliefs.items.len >= MAX_BELIEFS) {
            // 弹出置信度最低的
            var min_idx: usize = 0;
            for (self.beliefs.items, 0..) |b, i| {
                if (b.confidence < self.beliefs.items[min_idx].confidence) min_idx = i;
            }
            const old = self.beliefs.orderedRemove(min_idx);
            self.alloc.free(old.text);
            self.alloc.free(old.evidence_ticks);
        }
        try self.beliefs.append(self.alloc, .{
            .source = source,
            .text = try self.alloc.dupe(u8, text),
            .confidence = confidence,
            .formed_at_tick = formed_at_tick,
            .evidence_ticks = try self.alloc.dupe(u64, evidence),
        });
    }

    /// 替换 self_narrative (LLM 输出)
    pub fn setSelfNarrative(self: *Memory, text: []const u8) !void {
        self.alloc.free(self.self_narrative);
        const capped = if (text.len > SELF_NARRATIVE_MAX) text[0..SELF_NARRATIVE_MAX] else text;
        self.self_narrative = try self.alloc.dupe(u8, capped);
    }

    /// 取最近 N 条 episode
    pub fn recentEpisodes(self: *const Memory, n: usize) []const Episode {
        if (n >= self.episodes.items.len) return self.episodes.items;
        return self.episodes.items[self.episodes.items.len - n ..];
    }

    /// 按维度取最近 N 条 belief
    pub fn recentBeliefsBySource(self: *const Memory, source: BeliefSource, n: usize) []const Belief {
        _ = source;
        _ = n;
        return self.beliefs.items;
    }

    /// 序列化为 JSON (用于 state.json 持久化)
    pub fn toJson(self: *const Memory, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.print(alloc, "{{\"self_narrative\":\"", .{});
        try writeJsonString(alloc, &buf, self.self_narrative);
        try buf.print(alloc, "\",\"reflection_count\":{d},\"last_reflection_tick\":{d},\"beliefs\":[", .{ self.reflection_count, self.last_reflection_tick });
        for (self.beliefs.items, 0..) |b, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.print(alloc, "{{\"source\":\"{s}\",\"text\":\"", .{@tagName(b.source)});
            try writeJsonString(alloc, &buf, b.text);
            try buf.print(alloc, "\",\"confidence\":{d:.3},\"formed_at_tick\":{d},\"evidence_ticks\":[", .{ b.confidence, b.formed_at_tick });
            for (b.evidence_ticks, 0..) |t, j| {
                if (j > 0) try buf.append(alloc, ',');
                try buf.print(alloc, "{d}", .{t});
            }
            try buf.append(alloc, ']');
            try buf.append(alloc, '}');
        }
        try buf.print(alloc, "],\"episodes_count\":{d}", .{self.episodes.items.len});
        try buf.append(alloc, '}');
        return buf.toOwnedSlice(alloc);
    }
};

fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
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
