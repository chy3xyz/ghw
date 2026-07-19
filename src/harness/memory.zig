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
    world_fetch, // AutoCLI 外网拉取 (Wiki/HN/ArXiv/RSS)
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

    /// M/R/N 最低维度 (1/2/3), 供各 LLM 通道统一用作记忆检索 query_dim。
    pub fn weakestDim(m: F, r: F, n: F) u8 {
        if (m <= r and m <= n) return 1;
        if (r <= m and r <= n) return 2;
        return 3;
    }

    /// 按维度取置信度最高的 top-n belief (caller 只读 slice, 指向内部存储)。
    pub fn recentBeliefsBySource(self: *const Memory, source: BeliefSource, n: usize) []const Belief {
        if (n == 0 or self.beliefs.items.len == 0) return &[_]Belief{};
        var picked: [MAX_BELIEFS]Belief = undefined;
        var count: usize = 0;
        for (self.beliefs.items) |b| {
            if (b.source != source) continue;
            picked[count] = b;
            count += 1;
            if (count >= n) break;
        }
        // 按置信度降序 (简单选择排序, n≤32)
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var best = i;
            var j = i + 1;
            while (j < count) : (j += 1) {
                if (picked[j].confidence > picked[best].confidence) best = j;
            }
            if (best != i) {
                const tmp = picked[i];
                picked[i] = picked[best];
                picked[best] = tmp;
            }
        }
        return picked[0..count];
    }

    /// 相关情节检索 (P1 连续记忆的核心): 按
    ///   (维度匹配 + ΔE 显著性 + 关键词重叠 + 新近度)
    /// 给每条 episode 打分, 返回 top-k 的**索引** (降序; caller owns)。
    /// query_dim: 1=material 2=representation 3=nature, 0=不限维度。
    /// query_text: 当下关注点 (如 top_goal + last_action), 用于关键词重叠。
    /// 这让数字生命"从自己的一生里"找出与当下最相关的往事, 而非只看最近 N 条。
    pub fn relevantEpisodes(
        self: *const Memory,
        alloc: Allocator,
        query_dim: u8,
        query_text: []const u8,
        k: usize,
    ) ![]usize {
        const n = self.episodes.items.len;
        if (n == 0 or k == 0) return alloc.alloc(usize, 0);
        var scored = try alloc.alloc(Scored, n);
        defer alloc.free(scored);
        for (self.episodes.items, 0..) |ep, i| {
            const recency: F = @as(F, @floatFromInt(i + 1)) / @as(F, @floatFromInt(n)); // 越新越高
            scored[i] = .{ .idx = i, .score = episodeScore(ep, query_dim, query_text, recency) };
        }
        std.sort.pdq(Scored, scored, {}, scoredGreater);
        const take = @min(k, n);
        const out = try alloc.alloc(usize, take);
        for (0..take) |i| out[i] = scored[i].idx;
        return out;
    }

    /// 取置信度最高的 k 条 belief 索引 (降序; caller owns)。
    fn topBeliefsByConfidence(self: *const Memory, alloc: Allocator, k: usize) ![]usize {
        const n = self.beliefs.items.len;
        const idx = try alloc.alloc(usize, n);
        for (0..n) |i| idx[i] = i;
        std.sort.pdq(usize, idx, self.beliefs.items, beliefConfGreater);
        const take = @min(k, n);
        if (take < n) {
            const out = try alloc.alloc(usize, take);
            @memcpy(out, idx[0..take]);
            alloc.free(idx);
            return out;
        }
        return idx;
    }

    /// 构造"自传体记忆"上下文块 —— 注入到任何驱动决策的 LLM prompt。
    /// 让数字生命每次"开口"都带着: 我是谁 (self_narrative) + 我相信什么 (top beliefs)
    /// + 与当下最相关的往事 (relevant episodes + 它们的 ΔE 结果)。
    /// 这是"同一个生命跨时间连续"的关键: 不再每次失忆重启。caller owns 返回串。
    pub fn buildContext(
        self: *const Memory,
        alloc: Allocator,
        query_dim: u8,
        query_text: []const u8,
        k_episodes: usize,
        k_beliefs: usize,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        try buf.appendSlice(alloc, "=== 我的记忆 (autobiographical context) ===\n");
        if (self.self_narrative.len > 0) {
            try buf.print(alloc, "我是谁: {s}\n", .{self.self_narrative});
        } else {
            try buf.appendSlice(alloc, "我是谁: (自我叙事尚未形成)\n");
        }

        if (self.beliefs.items.len > 0 and k_beliefs > 0) {
            const bidx = try self.topBeliefsByConfidence(alloc, k_beliefs);
            defer alloc.free(bidx);
            try buf.appendSlice(alloc, "我相信:\n");
            for (bidx) |i| {
                const b = self.beliefs.items[i];
                try buf.print(alloc, "- [{s} 置信{d:.2}] {s}\n", .{ @tagName(b.source), b.confidence, b.text });
            }
        }

        if (self.episodes.items.len > 0 and k_episodes > 0) {
            const eidx = try self.relevantEpisodes(alloc, query_dim, query_text, k_episodes);
            defer alloc.free(eidx);
            try buf.appendSlice(alloc, "相关往事 (与当下最相关):\n");
            for (eidx) |i| {
                const e = self.episodes.items[i];
                try buf.print(alloc, "- tick{d} [{s}] ΔE={d:.3} | {s}\n", .{
                    e.tick, @tagName(e.kind), e.delta_e, e.summary,
                });
            }
        }
        return buf.toOwnedSlice(alloc);
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
        try buf.print(alloc, "],\"episodes\":[", .{});
        for (self.episodes.items, 0..) |e, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.print(alloc, "{{\"tick\":{d},\"timestamp\":{d},\"kind\":\"{s}\",\"summary\":\"", .{
                e.tick, e.timestamp, @tagName(e.kind),
            });
            try writeJsonString(alloc, &buf, e.summary);
            try buf.appendSlice(alloc, "\",\"detail\":");
            if (e.detail) |d| {
                try buf.append(alloc, '"');
                try writeJsonString(alloc, &buf, d);
                try buf.append(alloc, '"');
            } else {
                try buf.appendSlice(alloc, "null");
            }
            try buf.print(alloc, ",\"dimension\":{d},\"delta_e\":{d:.6}}}", .{ e.dimension, e.delta_e });
        }
        try buf.append(alloc, ']');
        try buf.append(alloc, '}');
        return buf.toOwnedSlice(alloc);
    }

    /// 从 state.json 的 memory 块恢复 (P4 跨重启连续记忆)。
    /// 支持完整块 (beliefs + episodes) 与旧版仅 self_narrative/reflection_count。
    /// 返回 true 表示找到并解析了 memory 字段。
    pub fn loadFromJson(self: *Memory, io: std.Io, json: []const u8) !bool {
        const mem_pos = std.mem.indexOf(u8, json, "\"memory\":") orelse return false;
        const obj_start = std.mem.indexOfPos(u8, json, mem_pos, "{") orelse return false;
        const obj_end = findMatchingBrace(json, obj_start) orelse return false;
        const obj = json[obj_start .. obj_end + 1];

        self.clearAutobiographical();

        if (extractJsonString(self.alloc, obj, "self_narrative")) |sn| {
            defer self.alloc.free(sn);
            try self.setSelfNarrative(sn);
        }
        if (extractJsonNumber(obj, "reflection_count")) |n| {
            self.reflection_count = @intCast(std.fmt.parseInt(u32, n, 10) catch 0);
        }
        if (extractJsonNumber(obj, "last_reflection_tick")) |n| {
            self.last_reflection_tick = std.fmt.parseInt(u64, n, 10) catch 0;
        }

        if (std.mem.indexOf(u8, obj, "\"beliefs\"")) |beliefs_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, beliefs_pos, "[") orelse return true;
            const arr_end = findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = findMatchingBrace(arr, os) orelse break;
                const one = arr[os .. oe + 1];
                const src_str = extractJsonString(self.alloc, one, "source") orelse {
                    i = oe + 1;
                    continue;
                };
                defer self.alloc.free(src_str);
                const src: BeliefSource = parseBeliefSource(src_str);
                const text = extractJsonString(self.alloc, one, "text") orelse {
                    i = oe + 1;
                    continue;
                };
                defer self.alloc.free(text);
                const conf_str = extractJsonNumber(one, "confidence") orelse "0.5";
                const conf = std.fmt.parseFloat(F, conf_str) catch 0.5;
                const tick_str = extractJsonNumber(one, "formed_at_tick") orelse "0";
                const formed = std.fmt.parseInt(u64, tick_str, 10) catch 0;
                const evidence = try self.alloc.dupe(u64, &[_]u64{formed});
                errdefer self.alloc.free(evidence);
                try self.addBeliefAt(src, text, conf, evidence, formed);
                self.alloc.free(evidence);
                i = oe + 1;
            }
        }

        if (std.mem.indexOf(u8, obj, "\"episodes\"")) |ep_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, ep_pos, "[") orelse return true;
            const arr_end = findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = findMatchingBrace(arr, os) orelse break;
                const one = arr[os .. oe + 1];
                const tick_str = extractJsonNumber(one, "tick") orelse "0";
                const ep_tick = std.fmt.parseInt(u64, tick_str, 10) catch 0;
                const kind_str = extractJsonString(self.alloc, one, "kind") orelse {
                    i = oe + 1;
                    continue;
                };
                defer self.alloc.free(kind_str);
                const summary = extractJsonString(self.alloc, one, "summary") orelse {
                    i = oe + 1;
                    continue;
                };
                defer self.alloc.free(summary);
                const detail = extractJsonString(self.alloc, one, "detail");
                const dim_str = extractJsonNumber(one, "dimension") orelse "0";
                const dim: u8 = @intCast(std.fmt.parseInt(u16, dim_str, 10) catch 0);
                const de_str = extractJsonNumber(one, "delta_e") orelse "0";
                const delta_e = std.fmt.parseFloat(F, de_str) catch 0;
                const kind = parseEpisodeKind(kind_str);
                try self.recordAt(io, kind, ep_tick, summary, detail, dim, delta_e);
                if (detail) |d| self.alloc.free(d);
                i = oe + 1;
            }
        }
        return true;
    }

    fn clearAutobiographical(self: *Memory) void {
        for (self.episodes.items) |e| {
            self.alloc.free(e.summary);
            if (e.detail) |d| self.alloc.free(d);
        }
        self.episodes.clearRetainingCapacity();
        for (self.beliefs.items) |b| {
            self.alloc.free(b.text);
            self.alloc.free(b.evidence_ticks);
        }
        self.beliefs.clearRetainingCapacity();
    }
};

/// 检索打分用的 (索引, 分数) 对
const Scored = struct { idx: usize, score: F };

fn scoredGreater(_: void, a: Scored, b: Scored) bool {
    return a.score > b.score;
}

fn beliefConfGreater(items: []const Belief, a: usize, b: usize) bool {
    return items[a].confidence > items[b].confidence;
}

/// 单条 episode 的相关性分数 (P2: token Jaccard 取代纯子串匹配, 仍零依赖)。
fn episodeScore(ep: Episode, query_dim: u8, query_text: []const u8, recency: F) F {
    var s: F = recency * 0.5; // 新近度: 最多 +0.5
    if (query_dim != 0 and ep.dimension == query_dim) s += 2.0; // 维度命中
    s += @min(@abs(ep.delta_e) * 4.0, 2.0); // ΔE 显著性 (大起大落更"难忘"), 封顶 2.0
    // P2: token-set Jaccard (比单关键词子串更稳, 无需 embedding)
    s += tokenJaccard(query_text, ep.summary) * 3.0;
    if (ep.detail) |d| s += tokenJaccard(query_text, d) * 1.5;
    // P3: char trigram Jaccard (零依赖, 替代 embedding 的轻量语义层)
    s += charTrigramJaccard(query_text, ep.summary) * 2.0;
    if (ep.detail) |d| s += charTrigramJaccard(query_text, d) * 1.0;
    return s;
}

const max_score_tokens = 32;
const max_trigrams = 48;

fn charTrigramJaccard(a: []const u8, b: []const u8) F {
    var ta: [max_trigrams][3]u8 = undefined;
    var tb: [max_trigrams][3]u8 = undefined;
    const na = collectTrigrams(a, &ta);
    const nb = collectTrigrams(b, &tb);
    if (na == 0 or nb == 0) return 0;
    var inter: usize = 0;
    for (0..na) |i| {
        for (0..nb) |j| {
            if (ta[i][0] == tb[j][0] and ta[i][1] == tb[j][1] and ta[i][2] == tb[j][2]) {
                inter += 1;
                break;
            }
        }
    }
    const union_size = na + nb - inter;
    if (union_size == 0) return 0;
    return @as(F, @floatFromInt(inter)) / @as(F, @floatFromInt(union_size));
}

fn collectTrigrams(text: []const u8, out: *[max_trigrams][3]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 < text.len and n < max_trigrams) : (i += 1) {
        if (!std.ascii.isAlphanumeric(text[i])) continue;
        if (!std.ascii.isAlphanumeric(text[i + 1])) continue;
        if (!std.ascii.isAlphanumeric(text[i + 2])) continue;
        out[n][0] = std.ascii.toLower(text[i]);
        out[n][1] = std.ascii.toLower(text[i + 1]);
        out[n][2] = std.ascii.toLower(text[i + 2]);
        n += 1;
    }
    return n;
}

/// token-set Jaccard 相似度 ∈ [0,1]。ASCII 大小写不敏感, 忽略短词。
fn tokenJaccard(a: []const u8, b: []const u8) F {
    var ta: [max_score_tokens][]const u8 = undefined;
    var tb: [max_score_tokens][]const u8 = undefined;
    const na = collectTokens(a, &ta);
    const nb = collectTokens(b, &tb);
    if (na == 0 or nb == 0) return 0;
    var inter: usize = 0;
    for (0..na) |i| {
        for (0..nb) |j| {
            if (std.ascii.eqlIgnoreCase(ta[i], tb[j])) {
                inter += 1;
                break;
            }
        }
    }
    const union_size = na + nb - inter;
    if (union_size == 0) return 0;
    return @as(F, @floatFromInt(inter)) / @as(F, @floatFromInt(union_size));
}

fn collectTokens(text: []const u8, out: *[max_score_tokens][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r,.;:!?()[]{}\"'-/");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        if (n >= max_score_tokens) break;
        out[n] = tok;
        n += 1;
    }
    return n;
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        if (in_string) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 1;
                continue;
            }
            if (json[i] == '"') in_string = false;
            continue;
        }
        switch (json[i]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn findMatchingBracket(json: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        if (in_string) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 1;
                continue;
            }
            if (json[i] == '"') in_string = false;
            continue;
        }
        switch (json[i]) {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn extractJsonNumber(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    var ve = pos + quoted_key.len;
    while (ve < obj.len and (obj[ve] == ' ' or obj[ve] == '\t' or obj[ve] == '\n')) : (ve += 1) {}
    const start = ve;
    while (ve < obj.len and (std.ascii.isDigit(obj[ve]) or obj[ve] == '.' or obj[ve] == '-')) : (ve += 1) {}
    if (ve == start) return null;
    return obj[start..ve];
}

fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    var vs = pos + quoted_key.len;
    while (vs < obj.len and (obj[vs] == ' ' or obj[vs] == '\t' or obj[vs] == '\n')) : (vs += 1) {}
    if (vs >= obj.len or obj[vs] != '"') return null;
    const content_start = vs + 1;
    var ve: usize = content_start;
    while (ve < obj.len) : (ve += 1) {
        if (obj[ve] == '\\' and ve + 1 < obj.len) {
            ve += 1;
            if (obj[ve] == 'u' and ve + 4 < obj.len) ve += 4;
            continue;
        }
        if (obj[ve] == '"') break;
    }
    if (ve >= obj.len) return null;
    return alloc.dupe(u8, obj[content_start..ve]) catch null;
}

fn parseBeliefSource(s: []const u8) BeliefSource {
    if (std.mem.eql(u8, s, "material")) return .material;
    if (std.mem.eql(u8, s, "representation")) return .representation;
    if (std.mem.eql(u8, s, "nature")) return .nature;
    return .material;
}

fn parseEpisodeKind(s: []const u8) EpisodeKind {
    inline for (std.enums.values(EpisodeKind)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .system_event;
}

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

// ===== Tests =====

test "Memory: relevantEpisodes 按维度+关键词+ΔE 检索" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.recordAt(io, .system_event, 1, "cpu spike on daemon", null, 1, -0.10);
    try mem.recordAt(io, .user_chat, 2, "user asked about files", null, 2, 0.05);
    try mem.recordAt(io, .reflection, 3, "explored novel states", null, 3, 0.20);

    // query: nature 维度 + "explore novel" ⇒ 第 3 条 (idx 2) 应排首
    const idx = try mem.relevantEpisodes(alloc, 3, "explore novel", 2);
    defer alloc.free(idx);
    try std.testing.expectEqual(@as(usize, 2), idx.len);
    try std.testing.expectEqual(@as(usize, 2), idx[0]);
}

test "Memory: token Jaccard 检索 — 语义相近词优于无关旧条" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    // 旧但语义相关
    try mem.recordAt(io, .system_event, 1, "cpu daemon optimization needed", null, 1, -0.05);
    // 新但语义无关
    try mem.recordAt(io, .user_chat, 99, "weather is sunny today", null, 2, 0.01);

    const idx = try mem.relevantEpisodes(alloc, 1, "optimize daemon cpu", 1);
    defer alloc.free(idx);
    try std.testing.expectEqual(@as(usize, 1), idx.len);
    try std.testing.expectEqual(@as(usize, 0), idx[0]); // tick1 语义相关, 胜过 tick99 新近
}

test "Memory: recentBeliefsBySource 按维度+置信度" {
    const alloc = std.testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.addBeliefAt(.nature, "low conf", 0.3, &[_]u64{1}, 1);
    try mem.addBeliefAt(.nature, "high conf", 0.9, &[_]u64{2}, 2);
    try mem.addBeliefAt(.material, "mat only", 0.8, &[_]u64{3}, 3);

    const nature = mem.recentBeliefsBySource(.nature, 2);
    try std.testing.expectEqual(@as(usize, 2), nature.len);
    try std.testing.expectEqualStrings("high conf", nature[0].text);
}

test "Memory: buildContext 含叙事+信念+相关往事" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("我是 GHW, 专注探索");
    try mem.addBeliefAt(.nature, "探索让我成长", 0.9, &[_]u64{3}, 3);
    try mem.addBeliefAt(.material, "低置信杂念", 0.2, &[_]u64{1}, 1);
    try mem.recordAt(io, .reflection, 3, "explored novel states", null, 3, 0.20);

    const ctx = try mem.buildContext(alloc, 3, "explore novel", 3, 1);
    defer alloc.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "我是 GHW, 专注探索") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "探索让我成长") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "explored novel states") != null);
    // k_beliefs=1 ⇒ 只保留最高置信, 低置信杂念被排除
    try std.testing.expect(std.mem.indexOf(u8, ctx, "低置信杂念") == null);
}

test "Memory: toJson/loadFromJson episodes+beliefs roundtrip" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("持久化测试");
    try mem.addBeliefAt(.nature, "重启后仍在", 0.85, &[_]u64{2}, 2);
    try mem.recordAt(io, .system_event, 5, "cycle five", null, 2, 0.03);

    const mem_json = try mem.toJson(alloc);
    defer alloc.free(mem_json);
    const json_wrap = try std.fmt.allocPrint(alloc, "{{\"agent_id\":\"t\",\"memory\":{s}}}", .{mem_json});
    defer alloc.free(json_wrap);

    var mem2 = Memory.init(alloc, 99);
    defer mem2.deinit();
    try std.testing.expect(try mem2.loadFromJson(io, json_wrap));
    try std.testing.expectEqualStrings("持久化测试", mem2.self_narrative);
    try std.testing.expectEqual(@as(usize, 1), mem2.beliefs.items.len);
    try std.testing.expectEqual(@as(usize, 1), mem2.episodes.items.len);
}
