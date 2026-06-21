//! HumanSignal: 人类反馈 → ΔE 转换
//!
//! 数字生命跟人共生,必须能"听懂"人的反馈
//! 反馈形式:
//!   - 点赞/差评 (score: -5..+5)
//!   - 文字评论 (comment, 可选)
//!   - 隐式: 任务完成时间、是否复用

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;

pub const HumanFeedback = struct {
    /// 谁给的反馈 (人类 id, 例如 "alice" / "feishu-bot")
    from_human: []const u8,
    /// 对哪个任务 (task id)
    task_id: u64,
    /// 评分: -5 (很糟) 到 +5 (超棒)
    score: i8,
    /// 文字评论 (可选)
    comment: []const u8 = "",
    /// 时间戳
    timestamp: u64 = 0,

    /// 把 score 转为 ΔE
    /// 非对称: 负分比正分重 (人对差评更敏感)
    ///   score=+5 → +0.30 E
    ///   score=+1 → +0.06 E
    ///   score= 0 →  0.00 E
    ///   score=-1 → -0.10 E
    ///   score=-5 → -0.50 E
    pub fn toDeltaE(self: HumanFeedback) F {
        if (self.score >= 0) {
            return @as(F, @floatFromInt(self.score)) * 0.06;
        } else {
            return @as(F, @floatFromInt(self.score)) * 0.10;
        }
    }
};

/// HumanSignal 聚合器: 收所有 feedback,提供累加 ΔE
pub const HumanSignal = struct {
    allocator: Allocator,
    feedbacks: std.ArrayList(HumanFeedback) = .empty,
    /// 累计 E 变化 (从所有 feedback 加总)
    total_e_uplift: F = 0,
    /// 反馈总数
    total_count: u32 = 0,
    /// 按 human 聚合
    by_human: std.StringHashMapUnmanaged(HumanAggregate) = .empty,

    pub const HumanAggregate = struct {
        feedback_count: u32 = 0,
        total_score: i32 = 0,
        total_e_uplift: F = 0,
        avg_score: F = 0,

        pub fn record(self: *HumanAggregate, fb: HumanFeedback) void {
            self.feedback_count += 1;
            self.total_score += fb.score;
            self.total_e_uplift += fb.toDeltaE();
            if (self.feedback_count > 0) {
                self.avg_score = @as(F, @floatFromInt(self.total_score)) /
                    @as(F, @floatFromInt(self.feedback_count));
            }
        }
    };

    pub fn init(allocator: Allocator) HumanSignal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HumanSignal) void {
        for (self.feedbacks.items) |fb| {
            self.allocator.free(fb.comment);
        }
        self.feedbacks.deinit(self.allocator);
        var it = self.by_human.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.by_human.deinit(self.allocator);
    }

    /// 接收一条反馈, 累加到聚合
    pub fn receive(self: *HumanSignal, fb: HumanFeedback) !void {
        const de = fb.toDeltaE();
        self.total_e_uplift += de;
        self.total_count += 1;
        const comment_owned = try self.allocator.dupe(u8, fb.comment);
        errdefer self.allocator.free(comment_owned);
        const stored = HumanFeedback{
            .from_human = fb.from_human,
            .task_id = fb.task_id,
            .score = fb.score,
            .comment = comment_owned,
            .timestamp = fb.timestamp,
        };
        try self.feedbacks.append(self.allocator, stored);

        // 按 human 聚合
        const gop = try self.by_human.getOrPut(self.allocator, fb.from_human);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, fb.from_human);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.record(fb);
    }

    /// 平均评分 (跨所有 human)
    pub fn avgScore(self: HumanSignal) F {
        if (self.feedbacks.items.len == 0) return 0;
        var sum: i64 = 0;
        for (self.feedbacks.items) |fb| sum += fb.score;
        return @as(F, @floatFromInt(sum)) /
            @as(F, @floatFromInt(self.feedbacks.items.len));
    }

    /// 序列化为 JSON (P10: 反馈历史跨重启保留)
    pub fn toJson(self: *const HumanSignal, alloc: Allocator) ![]u8 {
        const sj = @import("state_json.zig");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.print(alloc, "{{\"total_e_uplift\":{d:.6},\"total_count\":{d},\"feedbacks\":[", .{
            self.total_e_uplift, self.total_count,
        });
        for (self.feedbacks.items, 0..) |fb, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.print(alloc, "{{\"from_human\":\"", .{});
            try sj.writeJsonString(alloc, &buf, fb.from_human);
            try buf.print(alloc, "\",\"task_id\":{d},\"score\":{d},\"comment\":\"", .{ fb.task_id, fb.score });
            try sj.writeJsonString(alloc, &buf, fb.comment);
            try buf.print(alloc, "\",\"timestamp\":{d}}}", .{fb.timestamp});
        }
        try buf.appendSlice(alloc, "]}");
        return buf.toOwnedSlice(alloc);
    }

    /// 从 state.json 的 human_signal 块恢复; 无字段时返回 false
    pub fn loadFromJson(self: *HumanSignal, json: []const u8) !bool {
        const sj = @import("state_json.zig");
        const obj = sj.extractObjectBlock(json, "human_signal") orelse return false;
        self.clearAll();
        if (std.mem.indexOf(u8, obj, "\"feedbacks\"")) |fb_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, fb_pos, "[") orelse return true;
            const arr_end = sj.findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = sj.findMatchingBrace(arr, os) orelse break;
                try loadOneFeedback(self, arr[os .. oe + 1]);
                i = oe + 1;
            }
        }
        return true;
    }

    fn clearAll(self: *HumanSignal) void {
        for (self.feedbacks.items) |fb| {
            self.allocator.free(fb.comment);
        }
        self.feedbacks.clearRetainingCapacity();
        self.total_e_uplift = 0;
        self.total_count = 0;
        var it = self.by_human.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.by_human.clearRetainingCapacity();
    }

    fn loadOneFeedback(self: *HumanSignal, one: []const u8) !void {
        const sj = @import("state_json.zig");
        const from_human = sj.extractJsonString(self.allocator, one, "from_human") orelse return;
        errdefer self.allocator.free(from_human);
        const comment_owned = sj.extractJsonString(self.allocator, one, "comment") orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(comment_owned);
        const gop = try self.by_human.getOrPut(self.allocator, from_human);
        if (!gop.found_existing) {
            gop.key_ptr.* = from_human;
            gop.value_ptr.* = .{};
        } else {
            self.allocator.free(from_human);
        }
        const fb = HumanFeedback{
            .from_human = gop.key_ptr.*,
            .task_id = std.fmt.parseInt(u64, sj.extractJsonNumber(one, "task_id") orelse "0", 10) catch 0,
            .score = @intCast(std.fmt.parseInt(i16, sj.extractJsonNumber(one, "score") orelse "0", 10) catch 0),
            .comment = comment_owned,
            .timestamp = std.fmt.parseInt(u64, sj.extractJsonNumber(one, "timestamp") orelse "0", 10) catch 0,
        };
        const de = fb.toDeltaE();
        self.total_e_uplift += de;
        self.total_count += 1;
        try self.feedbacks.append(self.allocator, fb);
        gop.value_ptr.record(fb);
    }
};

// ===== Tests =====

const testing = std.testing;

test "HumanSignal: toDeltaE 非对称映射" {
    const f_pos = HumanFeedback{ .from_human = "a", .task_id = 1, .score = 5 };
    const f_neg = HumanFeedback{ .from_human = "a", .task_id = 1, .score = -5 };
    const f_zero = HumanFeedback{ .from_human = "a", .task_id = 1, .score = 0 };
    try testing.expectApproxEqAbs(@as(F, 0.30), f_pos.toDeltaE(), 0.001);
    try testing.expectEqual(@as(F, 0.0), f_zero.toDeltaE());
    try testing.expectApproxEqAbs(@as(F, -0.50), f_neg.toDeltaE(), 0.001);
}

test "HumanSignal: receive + aggregate by_human" {
    const alloc = testing.allocator;
    var sig = HumanSignal.init(alloc);
    defer sig.deinit();

    try sig.receive(.{ .from_human = "alice", .task_id = 1, .score = 3 });
    try sig.receive(.{ .from_human = "alice", .task_id = 2, .score = -2 });
    try sig.receive(.{ .from_human = "bob", .task_id = 1, .score = 5 });

    try testing.expectEqual(@as(u32, 3), sig.total_count);
    try testing.expectApproxEqAbs(@as(F, 0.18 + 0.30 - 0.20), sig.total_e_uplift, 0.001);

    const alice = sig.by_human.get("alice").?;
    try testing.expectEqual(@as(u32, 2), alice.feedback_count);
    try testing.expectEqual(@as(i32, 1), alice.total_score);
    try testing.expectEqual(@as(u32, 2), sig.by_human.count());
}

test "HumanSignal: A3 非对称比 ≈ 1.67 (H4 假设)" {
    const alloc = testing.allocator;
    var sig = HumanSignal.init(alloc);
    defer sig.deinit();

    const pos = HumanFeedback{ .from_human = "a", .task_id = 1, .score = 5 };
    const neg = HumanFeedback{ .from_human = "b", .task_id = 2, .score = -5 };

    const pos_de = pos.toDeltaE();
    const neg_de = neg.toDeltaE();

    // |neg_de| / pos_de ≈ 0.50 / 0.30 = 1.667
    const ratio = @abs(neg_de) / pos_de;
    try testing.expectApproxEqAbs(@as(F, 1.667), ratio, 0.01);
}

test "HumanSignal: toJson/loadFromJson roundtrip" {
    const alloc = testing.allocator;
    var sig = HumanSignal.init(alloc);
    defer sig.deinit();
    try sig.receive(.{ .from_human = "alice", .task_id = 1, .score = 3, .comment = "ok", .timestamp = 50 });
    try sig.receive(.{ .from_human = "bob", .task_id = 2, .score = -1, .timestamp = 60 });

    const json = try sig.toJson(alloc);
    defer alloc.free(json);
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"human_signal\":{s}}}", .{json});
    defer alloc.free(wrapped);

    var sig2 = HumanSignal.init(alloc);
    defer sig2.deinit();
    try testing.expect(try sig2.loadFromJson(wrapped));
    try testing.expectEqual(@as(u32, 2), sig2.total_count);
    try testing.expectApproxEqAbs(sig.total_e_uplift, sig2.total_e_uplift, 0.001);
    try testing.expectEqual(@as(u32, 2), sig2.by_human.count());
    try testing.expect(sig2.by_human.get("alice") != null);
    try testing.expect(sig2.by_human.get("bob") != null);
}
