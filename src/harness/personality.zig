//! Personality — 从数据中涌现的人格特征
//!
//! 数字生命没有写死的"性格", 但我们可以从它的行为/状态推断出"风格":
//!   - 心情 (Mood):  从 E 趋势 + variance 推断
//!   - 倾向 (Bias): 从 M/R/N 哪个最大 推断 "更关心物质/表征/本心"
//!   - 节奏 (Tempo):  从自省频率 + 反思间隔 推断 "好动/沉稳"
//!   - 成熟度 (Maturity): 从反思次数 + belief 数 推断 "新生/老成"
//!   - 链接 (Connectedness): 从 chat 频率 + peer 数 推断
//!
//! 这些特征是**涌现**的: 它们不是规则, 是数据形状
//! UI 用它们来让用户感知到"这是一个有个性的存在, 不是数据图"

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;

pub const Mood = enum {
    thriving, // E > 0.8, 上升
    stable, // 0.6-0.8
    wandering, // 0.4-0.6
    struggling, // 0.2-0.4
    dormant, // < 0.2
};

pub const Dimension = enum {
    material,
    representation,
    nature,
    balanced, // 三者差不多
};

pub const Tempo = enum {
    frantic, // 自省频繁
    active, // 活跃
    steady, // 稳定
    lethargic, // 迟缓
};

pub const Personality = struct {
    alloc: Allocator,

    mood: Mood = .wandering,
    bias: Dimension = .balanced,
    tempo: Tempo = .steady,
    maturity: u8 = 0, // 0-100, 由 reflection_count + belief 数推
    connectedness: u8 = 0, // 0-100, 由 chat 频率 + peer 数推

    /// 自评的短句 (用第一人称, 由 LLM 反思周期生成)
    self_phrase: []u8 = "",

    /// 三源思维特征标签 (从 M/R/N 比例 + belief 源分布涌现, 最多 5 个)
    /// 例: "务实型", "分析型", "内省型", "好奇驱动", "直觉型"
    thinking_tags: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator) Personality {
        return .{ .alloc = alloc, .self_phrase = alloc.dupe(u8, "我刚刚醒来") catch &[_]u8{} };
    }

    pub fn deinit(self: *Personality) void {
        self.alloc.free(self.self_phrase);
        for (self.thinking_tags.items) |t| self.alloc.free(t);
        self.thinking_tags.deinit(self.alloc);
    }

    /// 从 E/M/R/N/方差/反思次数/peer 数计算当前人格
    pub fn recompute(
        self: *Personality,
        e_current: F,
        e_trend: F, // 最近 32 cycle 的 ΔE 均值
        m_share: F, // M / (M+R+N) ∈ [0,1]
        r_share: F,
        n_share: F,
        reflection_count: u32,
        belief_count: u32,
        chat_recent_count: u32,
        ghw_peer_count: u32,
    ) void {
        // Mood: 趋势 + 当前值
        if (e_current >= 0.8 and e_trend >= 0)
            self.mood = .thriving
        else if (e_current >= 0.6)
            self.mood = .stable
        else if (e_current >= 0.4)
            self.mood = .wandering
        else if (e_current >= 0.2)
            self.mood = .struggling
        else
            self.mood = .dormant;

        // Bias: 哪一维最大
        const max_dim = @max(m_share, @max(r_share, n_share));
        const max_count: u8 = (if (m_share == max_dim) @as(u8, 1) else @as(u8, 0)) +
            (if (r_share == max_dim) @as(u8, 1) else @as(u8, 0)) +
            (if (n_share == max_dim) @as(u8, 1) else @as(u8, 0));
        if (max_count > 1) {
            self.bias = .balanced;
        } else if (m_share == max_dim) {
            self.bias = .material;
        } else if (r_share == max_dim) {
            self.bias = .representation;
        } else {
            self.bias = .nature;
        }

        // Tempo: 反思次数 / 100, 越多次越 frantic
        if (reflection_count >= 50) self.tempo = .frantic
        else if (reflection_count >= 20) self.tempo = .active
        else if (reflection_count >= 5) self.tempo = .steady
        else self.tempo = .lethargic;

        // Maturity: 综合 reflection + beliefs (0-100)
        const ref_score: u32 = @intCast(@min(50, reflection_count * 2));
        const belief_score: u32 = @intCast(@min(50, belief_count * 3));
        self.maturity = @intCast(@min(100, ref_score + belief_score));

        // Connectedness: chat + peers (0-100)
        const chat_score: u32 = @intCast(@min(70, chat_recent_count * 10));
        const peer_score: u32 = @intCast(@min(30, ghw_peer_count * 15));
        self.connectedness = @intCast(@min(100, chat_score + peer_score));

        // 思维特征标签: 从三源 (M/R/N) 比例 + 当前状态涌现
        // 释放旧的
        for (self.thinking_tags.items) |t| self.alloc.free(t);
        self.thinking_tags.clearRetainingCapacity();

        // helper: 出错就吞掉 (人格推导不该 crash)
        const addTag = struct {
            fn a(alloc: Allocator, list: *std.ArrayList([]u8), s: []const u8) void {
                const t = alloc.dupe(u8, s) catch return;
                list.append(alloc, t) catch alloc.free(t);
            }
        }.a;
        const allocator = self.alloc;

        // M 主导 (>0.5) → 务实型 / 行动派
        if (m_share > 0.5) addTag(allocator, &self.thinking_tags, "务实型");
        if (m_share > 0.45 and r_share < 0.3) addTag(allocator, &self.thinking_tags, "行动派");

        // R 主导 → 分析型 / 逻辑驱动
        if (r_share > 0.5) addTag(allocator, &self.thinking_tags, "分析型");
        if (r_share > 0.4 and m_share < 0.3) addTag(allocator, &self.thinking_tags, "逻辑驱动");

        // N 主导 → 内省型 / 直觉型
        if (n_share > 0.5) addTag(allocator, &self.thinking_tags, "内省型");
        if (n_share > 0.4 and (m_share + r_share) < 0.5) addTag(allocator, &self.thinking_tags, "直觉型");

        // 平衡 (任何一源 <0.45) → 整合思维
        if (m_share < 0.45 and r_share < 0.45 and n_share < 0.45 and self.thinking_tags.items.len == 0) {
            addTag(allocator, &self.thinking_tags, "整合思维");
        }

        // 加上状态标签
        if (e_current < 0.3) addTag(allocator, &self.thinking_tags, "存在焦虑");
        if (e_current > 0.8) addTag(allocator, &self.thinking_tags, "自信状态");
        if (chat_recent_count > 5) addTag(allocator, &self.thinking_tags, "外倾");
        if (chat_recent_count == 0 and reflection_count > 3) addTag(allocator, &self.thinking_tags, "内倾");
    }

    /// 人格 → UI 展示文案
    pub fn toJson(self: *const Personality, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.print(alloc, "{{\"mood\":\"{s}\",\"bias\":\"{s}\",\"tempo\":\"{s}\",\"maturity\":{d},\"connectedness\":{d},\"self_phrase\":\"", .{
            @tagName(self.mood), @tagName(self.bias), @tagName(self.tempo), self.maturity, self.connectedness,
        });
        try writeJsonString(alloc, &buf, self.self_phrase);
        try buf.append(alloc, '\"');
        try buf.append(alloc, ',');
        // thinking_tags 数组
        try buf.append(alloc, '\"');
        try buf.append(alloc, 't');
        try buf.append(alloc, 'h');
        try buf.append(alloc, 'i');
        try buf.append(alloc, 'n');
        try buf.append(alloc, 'k');
        try buf.append(alloc, 'i');
        try buf.append(alloc, 'n');
        try buf.append(alloc, 'g');
        try buf.append(alloc, '_');
        try buf.append(alloc, 't');
        try buf.append(alloc, 'a');
        try buf.append(alloc, 'g');
        try buf.append(alloc, 's');
        try buf.append(alloc, '\"');
        try buf.append(alloc, ':');
        try buf.append(alloc, '[');
        for (self.thinking_tags.items, 0..) |t, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.append(alloc, '\"');
            try writeJsonString(alloc, &buf, t);
            try buf.append(alloc, '\"');
        }
        try buf.append(alloc, ']');
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
