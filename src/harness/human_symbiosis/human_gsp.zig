//! HumanGSP: 跟人类的信任协议 (复用 GSP vtable 思路)
//!
//! 数字生命之间有 GSPNode (General Symbiosis Protocol)
//! 跟人类的共生需要单独的协议, 因为:
//!   - 人类不能 "register" 到 GSP 协议 (没 machine-readable 心跳)
//!   - 信任更新不靠 ΔE_initiator (那是 E 内部信号), 靠人类反馈
//!   - 寄生检测对人类不适用 (人不会"寄生",但可能"滥用")
//!
//! 关键设计: HumanGSP 是 GSPNode 的"语义镜像"
//!   - 同样的 trust 概念 (0..1)
//!   - 同样的 updateTrust 接口
//!   - 但更新源是人类反馈而不是 E

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;
const Task = @import("task_queue.zig").Task;

pub const HumanPeer = struct {
    id: []const u8,
    /// 信任 (0=完全不信, 1=完全信)
    trust: F = 0.5,
    /// 累计交互数
    interaction_count: u32 = 0,
    /// 累计任务数
    task_count: u32 = 0,
    /// 累计完成数
    completed_count: u32 = 0,
    /// 累计好评数
    positive_count: u32 = 0,
    /// 累计差评数
    negative_count: u32 = 0,
    /// 上次交互时间戳
    last_interaction: u64 = 0,
    /// "专长"维度 (数字生命对这位人类最擅长的 GHW 维度的学习)
    best_dimension: Task.Dimension = .all,

    pub fn trustLevel(self: HumanPeer) []const u8 {
        if (self.trust >= 0.8) return "high";
        if (self.trust >= 0.5) return "medium";
        if (self.trust >= 0.2) return "low";
        return "broken";
    }
};

/// HumanGSP: 维护一组人类 peer, 复用 trust 概念
pub const HumanGSP = struct {
    allocator: Allocator,
    peers: std.StringHashMapUnmanaged(HumanPeer) = .empty,
    /// 信任更新规则:
    ///   - 好评 + 任务完成: trust += 0.05 (cap 1.0)
    ///   - 中评: trust 不变
    ///   - 差评: trust -= 0.10 (floor 0.0)
    ///   - 任务失败: trust -= 0.03
    ///   - 长期无交互 (>100 tick): trust -= 0.01 (decay)
    const k_positive = 0.05;
    const k_neutral = 0.0;
    const k_negative = 0.10;
    const k_failure = 0.03;
    const k_decay = 0.01;

    pub fn init(allocator: Allocator) HumanGSP {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HumanGSP) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peers.deinit(self.allocator);
    }

    /// 注册一个新人 (默认 trust=0.5)
    pub fn register(self: *HumanGSP, human_id: []const u8) !void {
        const gop = try self.peers.getOrPut(self.allocator, human_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, human_id);
            gop.value_ptr.* = .{ .id = gop.key_ptr.* };
        }
    }

    /// 任务完成 + 反馈: 更新信任
    /// `task_completed`: true=任务完成, false=任务失败
    /// `feedback_score`: -5..+5 (0=没反馈)
    pub fn recordInteraction(
        self: *HumanGSP,
        human_id: []const u8,
        task_completed: bool,
        feedback_score: i8,
        best_dimension: Task.Dimension,
        timestamp: u64,
    ) !void {
        const gop = try self.peers.getOrPut(self.allocator, human_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, human_id);
            gop.value_ptr.* = .{ .id = gop.key_ptr.* };
        }
        const p = gop.value_ptr;
        p.interaction_count += 1;
        p.task_count += 1;
        p.last_interaction = timestamp;
        if (task_completed) p.completed_count += 1;

        if (!task_completed) {
            p.trust = @max(0, p.trust - k_failure);
        } else if (feedback_score > 0) {
            p.positive_count += 1;
            p.trust = @min(1, p.trust + k_positive * @as(F, @floatFromInt(feedback_score)));
        } else if (feedback_score < 0) {
            p.negative_count += 1;
            p.trust = @max(0.0, p.trust - k_negative * @as(F, @floatFromInt(@abs(feedback_score))));
        } else {
            // 中评, 信任不变
        }
        // 学习 best dimension
        if (task_completed and feedback_score > 0) {
            p.best_dimension = best_dimension;
        }
    }

    /// 按 trust 选最适合的人类 (高 trust 优先)
    /// 返回 peer id
    pub fn selectMostTrusted(self: HumanGSP, required_dimension: Task.Dimension) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_score: F = -1;
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            // 维匹配加分
            const dim_bonus: F = if (p.best_dimension == required_dimension) 0.2 else 0;
            const score = p.trust + dim_bonus;
            if (score > best_score) {
                best_score = score;
                best = entry.key_ptr.*;
            }
        }
        return best;
    }

    /// 总览
    pub fn summary(self: HumanGSP, w: *std.Io.Writer) !void {
        try w.print("\nHumanGSP summary ({d} peers):\n", .{self.peers.count()});
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            try w.print(
                "  - {s}: trust={d:.3} ({s}) tasks={d} done={d} +{d}/-{d} best={s}\n",
                .{
                    p.id, p.trust, p.trustLevel(),
                    p.task_count, p.completed_count,
                    p.positive_count, p.negative_count,
                    @tagName(p.best_dimension),
                },
            );
        }
    }
};

// ===== Tests =====

const testing = std.testing;

test "HumanGSP: register + recordInteraction + trust grows on positive" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    try gsp.register("alice");
    try gsp.register("bob");

    // alice: 1 好评
    try gsp.recordInteraction("alice", true, 5, .material, 0);
    const a = gsp.peers.get("alice").?;
    try testing.expectEqual(@as(u32, 1), a.interaction_count);
    try testing.expectEqual(@as(F, 0.75), a.trust); // 0.5 + 0.05*5 = 0.75
    try testing.expectEqual(@as(u32, 1), a.positive_count);
    try testing.expectEqual(Task.Dimension.material, a.best_dimension);
}

test "HumanGSP: trust drops on negative, clamped at 0" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    try gsp.register("alice");
    // 5 个差评, 每个 -1
    for (0..5) |_| {
        try gsp.recordInteraction("alice", true, -1, .all, 0);
    }
    const a = gsp.peers.get("alice").?;
    try testing.expectEqual(@as(u32, 5), a.negative_count);
    try testing.expectApproxEqAbs(@as(F, 0.0), a.trust, 0.001); // 0.5 - 0.10*5 = 0, clamped
}

test "HumanGSP: selectMostTrusted picks highest trust + dim bonus" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    try gsp.register("alice");
    try gsp.register("bob");

    try gsp.recordInteraction("alice", true, 1, .material, 0);     // 0.55
    try gsp.recordInteraction("bob", true, 3, .representation, 0); // 0.65

    // 选 material 任务: bob 信任更高但 best=representation (无 bonus)
    // alice 信任低 0.55 但 best=material (bonus 0.2) → 0.75
    const best_material = gsp.selectMostTrusted(.material).?;
    try testing.expectEqualStrings("alice", best_material);
}

test "HumanGSP: trust clamp 0-1 (不变量 #2)" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");
    // 100 次 success 应该被 clamp 到 1.0
    for (0..100) |i| try gsp.recordInteraction("alice", true, 1, .material, @as(u64, @intCast(i)));
    const peer = gsp.peers.getPtr("alice").?;
    try testing.expectApproxEqAbs(@as(F, 1.0), peer.trust, 0.01);

    // 100 次 fail 应该被 clamp 到 0
    for (0..100) |i| try gsp.recordInteraction("alice", false, 1, .material, @as(u64, @intCast(i + 100)));
    try testing.expectApproxEqAbs(@as(F, 0.0), peer.trust, 0.01);
}
