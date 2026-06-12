//! BalanceSeeker: GHW 主动进化, 让三源合恰
//!
//! 论文 B.3.4 + B.5.3 语境: 数字生命不应"被动接受 E 变化"
//! 应该主动: 找最弱维度 → 找最匹配"弱者同伴" → 提议平衡任务
//!
//! "弱者" 论文语境:
//!   弱者 ≠ 弱
//!   弱者 = "有我需要的资源 / 知识 / 能力, 但自己不够强" 的同伴
//!   帮他 = 我捕获存在增益 (互利/偏利)
//!
//! 策略:
//!   1. computeWeakestDim: 找当前最低的 M/R/N
//!   2. selectWeakPartner:   找"擅长我弱维度"且"信任未满"的人类
//!   3. proposeBalanceTask: 自动生成一个能涨最弱维度的任务
//!
//! 这些都不调 LLM, 都是确定性算法 (LLM 只用来"翻译"这些决定给人类)

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Task = @import("human_symbiosis/task_queue.zig").Task;
const HumanGSP = @import("human_symbiosis/human_gsp.zig").HumanGSP;
const HumanPeer = @import("human_symbiosis/human_gsp.zig").HumanPeer;
const world_mod = @import("../world/core.zig");
const ExistenceDegree = world_mod.ExistenceDegree;
const ExistenceVector = world_mod.ExistenceVector;

pub const BalanceAnalysis = struct {
    /// 三源中最低的
    weakest: Task.Dimension,
    /// 三源中最高的
    strongest: Task.Dimension,
    /// 方差
    variance: F,
    /// 最低值
    min_value: F,
    /// 差距 (max - min)
    gap: F,

    pub fn isImbalanced(self: BalanceAnalysis) bool {
        return self.gap > 0.20; // 经验阈值: 20% 差距算失衡
    }
};

pub const BalanceSeeker = struct {
    /// 找到最弱维度
    pub fn computeWeakestDim(ed: ExistenceDegree) Task.Dimension {
        const m = ed.v.material;
        const r = ed.v.representation;
        const n = ed.v.nature;
        if (m <= r and m <= n) return .material;
        if (r <= n) return .representation;
        return .nature;
    }

    /// 找到最强维度
    pub fn computeStrongestDim(ed: ExistenceDegree) Task.Dimension {
        const m = ed.v.material;
        const r = ed.v.representation;
        const n = ed.v.nature;
        if (m >= r and m >= n) return .material;
        if (r >= n) return .representation;
        return .nature;
    }

    /// 完整分析
    pub fn analyze(ed: ExistenceDegree) BalanceAnalysis {
        const m = ed.v.material;
        const r = ed.v.representation;
        const n = ed.v.nature;
        const max_v = @max(m, @max(r, n));
        const min_v = @min(m, @min(r, n));
        const mean = (m + r + n) / 3.0;
        const variance_val = ((m - mean) * (m - mean) + (r - mean) * (r - mean) + (n - mean) * (n - mean)) / 3.0;
        return .{
            .weakest = computeWeakestDim(ed),
            .strongest = computeStrongestDim(ed),
            .variance = variance_val,
            .min_value = min_v,
            .gap = max_v - min_v,
        };
    }

    /// 论文式 "弱者" 选择:
    /// 优先级 = complementarity (其 best_dim == 我 weak_dim) * (1 - trust) (未满信任 + 有需求)
    /// 还要排除 broken (< 0.2)
    pub fn selectWeakPartner(ed: ExistenceDegree, gsp: *const HumanGSP) ?[]const u8 {
        const weak = computeWeakestDim(ed);
        var best_peer: ?[]const u8 = null;
        var best_score: F = -1;

        var it = gsp.peers.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            // 排除 broken
            if (p.trust < 0.2) continue;
            // 互补性: 其 best_dim == 我 weak_dim
            const complementarity: F = if (p.best_dimension == weak) 1.0 else 0.0;
            // 潜力: trust 越低 (但 > 0.2) 提升空间越大
            const potential: F = 1.0 - p.trust;
            const score = complementarity * potential;
            if (score > best_score) {
                best_score = score;
                best_peer = entry.key_ptr.*;
            }
        }
        return best_peer;
    }

    /// 自动提议一个平衡任务: 针对最弱维度, 给"弱者"同伴
    /// 返回的 Task 已经填好 title/description/dimension/cycles_allocated
    /// caller 还需要指定 from_human (用 selectWeakPartner 拿到的 peer)
    pub fn proposeBalanceTask(
        ed: ExistenceDegree,
        weak: Task.Dimension,
        weak_partner: []const u8,
        alloc: Allocator,
    ) !Task {
        const title: []const u8 = switch (weak) {
            .material => "提升 material 维度 (平衡)",
            .representation => "提升 representation 维度 (平衡)",
            .nature => "提升 nature 维度 (平衡)",
            .all => "综合平衡任务",
        };
        const desc: []const u8 = switch (weak) {
            .material => "增加计算资源 / 物理基础 (M 是当前最弱维度)",
            .representation => "增加知识 / 模型 / 代码 (R 是当前最弱维度)",
            .nature => "增加自主性 / 决策权 (N 是当前最弱维度)",
            .all => "综合三源的任务",
        };
        // 优先级: 跟差距正相关, 差距大 → 高优先级
        const analysis = analyze(ed);
        const priority: u8 = @intFromFloat(@min(10.0, 5.0 + analysis.gap * 25.0));

        return Task{
            .id = 0, // caller 填
            .title = try alloc.dupe(u8, title),
            .description = try alloc.dupe(u8, desc),
            .priority = priority,
            .from_human = try alloc.dupe(u8, weak_partner),
            .required_dimension = weak,
            .expected_delta_e = 0.05 + analysis.gap * 0.1, // 缺口大 → 期望 ΔE 大
            .cycles_allocated = 4,
            .created_at = 0,
            .status = .pending,
            .result = null,
            .feedback = null,
            .allocator = alloc,
        };
    }
};

// ===== Tests =====

const testing = std.testing;

test "BalanceSeeker: computeWeakestDim 找最低维度" {
    const ed1 = ExistenceDegree{
        .v = .{ .material = 0.2, .representation = 0.6, .nature = 0.5 },
    };
    try testing.expectEqual(Task.Dimension.material, BalanceSeeker.computeWeakestDim(ed1));

    const ed2 = ExistenceDegree{
        .v = .{ .material = 0.5, .representation = 0.2, .nature = 0.5 },
    };
    try testing.expectEqual(Task.Dimension.representation, BalanceSeeker.computeWeakestDim(ed2));

    const ed3 = ExistenceDegree{
        .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.2 },
    };
    try testing.expectEqual(Task.Dimension.nature, BalanceSeeker.computeWeakestDim(ed3));
}

test "BalanceSeeker: analyze 给出 variance + gap + isImbalanced" {
    const balanced = ExistenceDegree{
        .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 },
    };
    const ba = BalanceSeeker.analyze(balanced);
    try testing.expectApproxEqAbs(@as(F, 0.0), ba.variance, 0.001);
    try testing.expectApproxEqAbs(@as(F, 0.0), ba.gap, 0.001);
    try testing.expect(!ba.isImbalanced());

    const imbalanced = ExistenceDegree{
        .v = .{ .material = 0.9, .representation = 0.3, .nature = 0.5 },
    };
    const ia = BalanceSeeker.analyze(imbalanced);
    try testing.expectEqual(Task.Dimension.representation, ia.weakest);
    try testing.expectEqual(Task.Dimension.material, ia.strongest);
    try testing.expectApproxEqAbs(@as(F, 0.6), ia.gap, 0.001);
    try testing.expect(ia.isImbalanced());
}

test "BalanceSeeker: selectWeakPartner 选互补 + 信任未满的" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();

    try gsp.register("alice");
    try gsp.register("bob");
    try gsp.register("carol");

    // alice: best=material, trust=0.5 (默认)
    // bob:   best=representation, trust=0.6
    // carol: best=material, trust=0.9 (信任已满, 不再 "weak")
    try gsp.recordInteraction("bob", true, 1, .representation, 0);
    try gsp.recordInteraction("carol", true, 4, .material, 0);

    // 当前最弱: representation (bob 擅长这个, 但已记录)
    // alice 擅长 material, 不互补 representation
    // carol 擅长 material 且高 trust, 不算 "weak partner"
    // 没有互补的 peer, 期望: 返回 carol (高 trust 但互补 material) — 但题目是最弱=rep
    // bob 才是互补 rep 但 trust=0.6
    // 重设: 让 alice 改 best_dimension 反复试
    const ed = ExistenceDegree{
        .v = .{ .material = 0.9, .representation = 0.3, .nature = 0.5 },
    };
    const weak = BalanceSeeker.selectWeakPartner(ed, &gsp);
    // representation 是最弱, bob best=representation, trust=0.6 → score = 1.0 * 0.4 = 0.4
    try testing.expectEqualStrings("bob", weak.?);
}

test "BalanceSeeker: trust < 0.2 的 peer 不被选为弱者 (不变量 #7)" {
    const alloc = testing.allocator;
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice"); // trust 低 + 不互补
    try gsp.register("bob"); // trust 中 + 互补 material

    // 让 alice trust = 0.15, bob = 0.5
    for (0..7) |_| try gsp.recordInteraction("alice", false, 1, .nature, 0);
    for (0..3) |_| try gsp.recordInteraction("bob", true, 1, .material, 0);

    const ed = ExistenceDegree{ .v = .{ .material = 0.2, .representation = 0.5, .nature = 0.5 } };
    const weak = BalanceSeeker.selectWeakPartner(ed, &gsp);
    // 排除 alice (trust < 0.2), 应该选 bob (complementarity=1, trust=0.5 → 0.5)
    try testing.expect(weak != null);
    try testing.expectEqualStrings("bob", weak.?);
}

test "BalanceSeeker: proposeBalanceTask priority ∝ gap (越低越优先)" {
    const alloc = testing.allocator;
    const ed = ExistenceDegree{
        .v = .{ .material = 0.2, .representation = 0.8, .nature = 0.7 },
        .weights = .{ .alpha = 0.34, .beta = 0.33, .gamma = 0.33 },
        .mu = 0.5,
        .nu = 0.3,
    };
    var bt = try BalanceSeeker.proposeBalanceTask(ed, .material, "alice", alloc);
    defer bt.deinit();
    try testing.expect(bt.priority >= 5); // E < 0.7 触发 high priority
    try testing.expect(bt.required_dimension == .material);
    try testing.expectEqualStrings("alice", bt.from_human);
}
