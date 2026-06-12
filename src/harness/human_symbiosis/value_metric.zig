//! ValueMetric: 量化数字生命给人类交付的价值
//!
//! 数字生命挣 E 是内部信号
//! 数字生命给人类挣...什么? 需要一个独立的 metric
//!
//! ValueMetric = 综合:
//!   - 完成的任务数
//!   - 人类平均评分
//!   - 给人类挣的 ΔE (人类反馈聚合)
//!   - 信任增长
//!   - 触及的独立人类数
//!
//! 单一 "value_score" 指标: 0..1
//!   value = w_task*完成率 + w_human*avg_score + w_trust*avg_trust + w_reach*reach_norm

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;
const Task = @import("task_queue.zig").Task;
const HumanSignal = @import("human_signal.zig").HumanSignal;
const HumanFeedback = @import("human_signal.zig").HumanFeedback;
const HumanGSP = @import("human_gsp.zig").HumanGSP;
const TaskQueue = @import("task_queue.zig").TaskQueue;

pub const ValueMetric = struct {
    /// 任务完成数
    tasks_completed: u32 = 0,
    /// 任务失败数
    tasks_failed: u32 = 0,
    /// 收到的反馈数
    feedback_count: u32 = 0,
    /// 反馈总分
    feedback_total_score: i64 = 0,
    /// 人类反馈带来的累计 ΔE
    human_e_uplift: F = 0,
    /// 任务实际挣的累计 ΔE (内部)
    actual_e_uplift: F = 0,
    /// 触及的独立人类数
    unique_humans: u32 = 0,
    /// 起始时平均 trust
    initial_trust_sum: F = 0,
    /// 当前 trust sum
    current_trust_sum: F = 0,
    /// 权重 (config)
    w_completion: F = 0.30,
    w_satisfaction: F = 0.30,
    w_trust: F = 0.20,
    w_reach: F = 0.20,

    /// 从 HumanSignal 拉取数据
    pub fn pullFromSignal(self: *ValueMetric, signal: *const HumanSignal) void {
        self.human_e_uplift = signal.total_e_uplift;
        self.feedback_count = signal.total_count;
        // 总分
        var sum: i64 = 0;
        for (signal.feedbacks.items) |fb| sum += fb.score;
        self.feedback_total_score = sum;
        // 触及的人类数
        self.unique_humans = @intCast(signal.by_human.count());
    }

    /// 从 TaskQueue 拉取任务完成数据
    pub fn pullFromQueue(self: *ValueMetric, queue: *const TaskQueue) void {
        self.tasks_completed = queue.completed_count;
        self.tasks_failed = queue.failed_count;
        self.actual_e_uplift = queue.totalActualDeltaE();
    }

    /// 从 HumanGSP 拉取信任数据
    pub fn pullFromGSP(self: *ValueMetric, gsp: *const HumanGSP) void {
        var sum: F = 0;
        var count: u32 = 0;
        var it = gsp.peers.iterator();
        while (it.next()) |entry| {
            sum += entry.value_ptr.trust;
            count += 1;
        }
        self.current_trust_sum = sum;
        self.unique_humans = count;
    }

    /// 综合 value_score: 0..1
    /// 完成率 = completed / (completed + failed) (避免除 0)
    /// satisfaction = avg_score / 5 (归一化)
    /// trust = avg_trust (0..1)
    /// reach_norm = min(unique / 10, 1) (假设 10 触及是 100%)
    pub fn valueScore(self: ValueMetric) F {
        const total = self.tasks_completed + self.tasks_failed;
        const completion: F = if (total == 0) 0 else
            @as(F, @floatFromInt(self.tasks_completed)) / @as(F, @floatFromInt(total));
        const satisfaction: F = if (self.feedback_count == 0) 0 else
            (@as(F, @floatFromInt(self.feedback_total_score)) / @as(F, @floatFromInt(self.feedback_count))) / 5.0;
        const trust: F = if (self.unique_humans == 0) 0 else
            self.current_trust_sum / @as(F, @floatFromInt(self.unique_humans));
        const reach: F = @min(@as(F, @floatFromInt(self.unique_humans)) / 10.0, 1.0);

        return self.w_completion * completion +
            self.w_satisfaction * satisfaction +
            self.w_trust * trust +
            self.w_reach * reach;
    }

    /// 输出报表
    pub fn report(self: ValueMetric, w: *std.Io.Writer) !void {
        try w.print("\n=== ValueMetric Report ===\n", .{});
        try w.print("  Tasks:        completed={d} failed={d} (success_rate=", .{
            self.tasks_completed, self.tasks_failed,
        });
        const total = self.tasks_completed + self.tasks_failed;
        if (total > 0) {
            try w.print("{d:.1}%)\n", .{@as(F, @floatFromInt(self.tasks_completed)) * 100 / @as(F, @floatFromInt(total))});
        } else {
            try w.print("n/a)\n", .{});
        }
        try w.print("  Feedback:     count={d} avg_score={d:.2}\n", .{
            self.feedback_count,
            if (self.feedback_count == 0) @as(F, 0) else
                @as(F, @floatFromInt(self.feedback_total_score)) / @as(F, @floatFromInt(self.feedback_count)),
        });
        try w.print("  Human E:      total_uplift={d:.3} (from feedback)\n", .{self.human_e_uplift});
        try w.print("  Internal E:   total_uplift={d:.3} (from tasks)\n", .{self.actual_e_uplift});
        try w.print("  Reach:        unique_humans={d}\n", .{self.unique_humans});
        try w.print("  Trust:        avg={d:.3} (sum={d:.3})\n", .{
            if (self.unique_humans == 0) @as(F, 0)
            else self.current_trust_sum / @as(F, @floatFromInt(self.unique_humans)),
            self.current_trust_sum,
        });
        try w.print("  ───────────────────────────\n", .{});
        try w.print("  VALUE SCORE:  {d:.3} / 1.0\n", .{self.valueScore()});
        try w.print("========================\n", .{});
    }
};

// ===== Tests =====

const testing = std.testing;
const HumanSignalMod = @import("human_signal.zig");
const HumanGSPMod = @import("human_gsp.zig");
const TaskQueueMod = @import("task_queue.zig");

test "ValueMetric: pulls data from Signal + Queue + GSP" {
    const alloc = testing.allocator;

    var sig = HumanSignalMod.HumanSignal.init(alloc);
    defer sig.deinit();
    try sig.receive(.{ .from_human = "alice", .task_id = 1, .score = 3 });
    try sig.receive(.{ .from_human = "bob", .task_id = 1, .score = -1 });

    var q = TaskQueueMod.TaskQueue.init(alloc);
    defer q.deinit();
    _ = try q.submit("t1", "d", "alice", 5, .all, 4);
    _ = try q.submit("t2", "d", "bob", 5, .all, 4);
    try q.complete(1, "out1", 0.05, 4);
    try q.complete(2, "out2", 0.10, 4);
    q.fail(2);

    var gsp = HumanGSPMod.HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");
    try gsp.register("bob");
    try gsp.recordInteraction("alice", true, 3, .material, 0);
    try gsp.recordInteraction("bob", true, -1, .representation, 0);

    var vm = ValueMetric{};
    vm.pullFromSignal(&sig);
    vm.pullFromQueue(&q);
    vm.pullFromGSP(&gsp);

    try testing.expectEqual(@as(u32, 2), vm.feedback_count);
    try testing.expectEqual(@as(u32, 2), vm.unique_humans);
    try testing.expectEqual(@as(u32, 1), vm.tasks_completed);
    try testing.expectEqual(@as(u32, 1), vm.tasks_failed);
    try testing.expectApproxEqAbs(@as(F, 0.15), vm.actual_e_uplift, 0.001);

    // value_score: weighted sum
    // completion: 1/2 = 0.5
    // satisfaction: (3 + -1)/2 / 5 = 0.2
    // trust: alice(0.65) + bob(0.40) / 2 = 0.525
    // reach: 2/10 = 0.2
    // score = 0.3*0.5 + 0.3*0.2 + 0.2*0.525 + 0.2*0.2 = 0.15 + 0.06 + 0.105 + 0.04 = 0.355
    try testing.expectApproxEqAbs(@as(F, 0.355), vm.valueScore(), 0.01);
}

test "ValueMetric: 空状态 value_score = 0" {
    const vm = ValueMetric{};
    try testing.expectEqual(@as(F, 0.0), vm.valueScore());
}

test "ValueMetric: 4 个权重归一化和 = 1.0 (D4 不变量)" {
    // 直接测试 valueScore 的 4 项权重
    // 完美状态: C=10, F=0, 全部人类给 +5, 信任都 1.0, 10 人 (reach=1.0)
    const alloc = testing.allocator;
    var sig = HumanSignal.init(alloc);
    defer sig.deinit();
    for (0..10) |i| {
        const fb = HumanFeedback{ .from_human = "h", .task_id = i, .score = 5 };
        try sig.receive(fb);
    }
    var vm = ValueMetric{};
    vm.pullFromSignal(&sig);
    vm.tasks_completed = 10;
    vm.tasks_failed = 0;
    vm.current_trust_sum = 10.0; // 10 人 × 1.0
    vm.unique_humans = 10;
    const score = vm.valueScore();
    // 完美状态下 valueScore ≈ 1.0
    try testing.expectApproxEqAbs(@as(F, 1.0), score, 0.05);
}
