//! TaskQueue: 任务队列 + 优先级
//!
//! 数字生命"接活"的数据结构:
//!   - 人类投递任务 (title / description / required_dimension / deadline)
//!   - 数字生命取任务 (按 priority 排序)
//!   - 完成任务 → 记录 result + 等待 human feedback
//!
//! 任务维度对齐 GHW 三源合恰: material / representation / nature

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;

pub const Task = struct {
    id: u64,
    /// 任务标题
    title: []const u8,
    /// 任务描述 (自然语言, 可给 LLM 看)
    description: []const u8,
    /// 优先级: 1 (低) - 10 (高)
    priority: u8 = 5,
    /// 投递者 (人类 id)
    from_human: []const u8,
    /// 任务需要的维度 (对齐 GHW 三源)
    required_dimension: Dimension = .all,
    /// 期望的 ΔE (投递者的预期, 实际可能不同)
    expected_delta_e: F = 0.05,
    /// 给数字生命多少 cycle
    cycles_allocated: u32 = 4,
    /// 创建时间
    created_at: u64 = 0,
    /// 状态
    status: Status = .pending,
    /// 结果 (completed/failed 时填)
    result: ?TaskResult = null,
    /// 人类反馈 (signal 模块填)
    feedback: ?HumanFeedbackRef = null,
    allocator: Allocator,

    pub const Dimension = enum { material, representation, nature, all };
    pub const Status = enum { pending, in_progress, completed, failed, abandoned };

    pub const TaskResult = struct {
        output: []u8, // 任务输出 (代码/文本/...)
        actual_delta_e: F,
        cycles_used: u32,
        completed_at: u64,
    };

    /// 人类反馈 (不带 from_human, 跟 task 关联时补)
    pub const HumanFeedbackRef = struct {
        score: i8,
        comment: []const u8,
        timestamp: u64,
        delta_e: F,
    };

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.title);
        self.allocator.free(self.description);
        self.allocator.free(self.from_human);
        if (self.result) |r| {
            self.allocator.free(r.output);
        }
        if (self.feedback) |f| {
            self.allocator.free(f.comment);
        }
    }
};

/// 优先级队列: pending 任务按 priority 排序
pub const TaskQueue = struct {
    allocator: Allocator,
    tasks: std.ArrayList(*Task) = .empty,
    next_id: u64 = 1,
    /// pending 计数 (O(1) 查询)
    pending_count: u32 = 0,
    /// completed 计数
    completed_count: u32 = 0,
    /// failed 计数
    failed_count: u32 = 0,

    pub fn init(allocator: Allocator) TaskQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TaskQueue) void {
        for (self.tasks.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.tasks.deinit(self.allocator);
    }

    /// 投递一个新任务 (从人类), 返回 task id
    pub fn submit(
        self: *TaskQueue,
        title: []const u8,
        description: []const u8,
        from_human: []const u8,
        priority: u8,
        required_dimension: Task.Dimension,
        cycles_allocated: u32,
    ) !u64 {
        const t = try self.allocator.create(Task);
        errdefer self.allocator.destroy(t);
        t.* = .{
            .id = self.next_id,
            .title = try self.allocator.dupe(u8, title),
            .description = try self.allocator.dupe(u8, description),
            .from_human = try self.allocator.dupe(u8, from_human),
            .priority = priority,
            .required_dimension = required_dimension,
            .cycles_allocated = cycles_allocated,
            .expected_delta_e = 0.05,
            .created_at = 0, // 调用方填
            .status = .pending,
            .allocator = self.allocator,
        };
        self.next_id += 1;
        try self.tasks.append(self.allocator, t);
        self.pending_count += 1;
        return t.id;
    }

    /// 取下一个 pending 任务 (按 priority 降序, 同 priority 按 id 升序)
    /// 取出后 status 变 in_progress
    pub fn dequeue(self: *TaskQueue) ?*Task {
        var best_idx: ?usize = null;
        var best_priority: i8 = -1;
        for (self.tasks.items, 0..) |t, i| {
            if (t.status != .pending) continue;
            const p: i8 = @intCast(t.priority);
            if (p > best_priority) {
                best_priority = p;
                best_idx = i;
            }
        }
        if (best_idx) |i| {
            const t = self.tasks.items[i];
            t.status = .in_progress;
            self.pending_count -= 1;
            return t;
        }
        return null;
    }

    /// 标记任务完成
    pub fn complete(
        self: *TaskQueue,
        task_id: u64,
        output: []const u8,
        actual_delta_e: F,
        cycles_used: u32,
    ) !void {
        const t = self.find(task_id) orelse return;
        // 释放旧 output
        if (t.result) |r| {
            self.allocator.free(r.output);
        }
        t.result = .{
            .output = try self.allocator.dupe(u8, output),
            .actual_delta_e = actual_delta_e,
            .cycles_used = cycles_used,
            .completed_at = 0,
        };
        t.status = .completed;
        self.completed_count += 1;
    }

    /// 标记任务失败
    pub fn fail(self: *TaskQueue, task_id: u64) void {
        if (self.find(task_id)) |t| {
            if (t.status == .completed) self.completed_count -= 1; // 撤回之前的完成计数
            t.status = .failed;
            self.failed_count += 1;
        }
    }

    /// 附加人类反馈
    pub fn attachFeedback(
        self: *TaskQueue,
        task_id: u64,
        score: i8,
        comment: []const u8,
        timestamp: u64,
        delta_e: F,
    ) !void {
        const t = self.find(task_id) orelse return;
        // 释放旧 comment
        if (t.feedback) |old| {
            self.allocator.free(old.comment);
        }
        t.feedback = .{
            .score = score,
            .comment = try self.allocator.dupe(u8, comment),
            .timestamp = timestamp,
            .delta_e = delta_e,
        };
    }

    /// 找任务 by id
    pub fn find(self: *TaskQueue, task_id: u64) ?*Task {
        for (self.tasks.items) |t| {
            if (t.id == task_id) return t;
        }
        return null;
    }

    /// 统计: 跨所有任务的人类反馈总 ΔE
    pub fn totalHumanDeltaE(self: *TaskQueue) F {
        var sum: F = 0;
        for (self.tasks.items) |t| {
            if (t.feedback) |f| sum += f.delta_e;
        }
        return sum;
    }

    /// 统计: 实际完成任务的累计 ΔE (从 Task.result.actual_delta_e)
    pub fn totalActualDeltaE(self: *const TaskQueue) F {
        var sum: F = 0;
        for (self.tasks.items) |t| {
            if (t.result) |r| sum += r.actual_delta_e;
        }
        return sum;
    }
};

// ===== Tests =====

const testing = std.testing;

test "TaskQueue: submit + dequeue + complete + feedback" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    const id1 = try q.submit("t1", "desc1", "alice", 8, .material, 4);
    const id2 = try q.submit("t2", "desc2", "bob", 5, .representation, 2);
    try testing.expectEqual(@as(u32, 2), q.pending_count);

    // 高优先级先出
    const first = q.dequeue().?;
    try testing.expectEqual(id1, first.id);
    try testing.expectEqual(@as(u8, 8), first.priority);
    try testing.expectEqual(Task.Status.in_progress, first.status);
    try testing.expectEqual(@as(u32, 1), q.pending_count);

    // 完成
    try q.complete(id1, "output1", 0.05, 4);
    const t1 = q.find(id1).?;
    try testing.expectEqual(Task.Status.completed, t1.status);
    try testing.expectEqual(@as(u32, 1), q.completed_count);

    // 反馈
    try q.attachFeedback(id1, 4, "好活", 0, 0.24);
    const fb = t1.feedback.?;
    try testing.expectEqual(@as(i8, 4), fb.score);
    try testing.expectEqual(@as(F, 0.24), fb.delta_e);

    // 第二个还在
    const second = q.dequeue().?;
    try testing.expectEqual(id2, second.id);
    try testing.expectEqual(@as(F, 0.24), q.totalHumanDeltaE()); // 0.24 from t1's feedback
}

test "TaskQueue: priority order 严格降序" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    _ = try q.submit("low", "d", "a", 1, .all, 1);
    _ = try q.submit("high", "d", "a", 10, .all, 1);
    _ = try q.submit("mid", "d", "a", 5, .all, 1);

    const t1 = q.dequeue().?;
    try testing.expectEqualStrings("high", t1.title);
    const t2 = q.dequeue().?;
    try testing.expectEqualStrings("mid", t2.title);
    const t3 = q.dequeue().?;
    try testing.expectEqualStrings("low", t3.title);
}

test "TaskQueue: fail 后 completed_count 减 1" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    _ = try q.submit("t1", "d", "a", 5, .all, 1);
    const t = q.dequeue().?;
    try q.complete(t.id, "out", 0.1, 1);
    try testing.expectEqual(@as(u32, 1), q.completed_count);
    q.fail(t.id);
    try testing.expectEqual(@as(u32, 0), q.completed_count);
    try testing.expectEqual(@as(u32, 1), q.failed_count);
}
