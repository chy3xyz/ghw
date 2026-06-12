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
        try self.feedbacks.append(self.allocator, fb);

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
