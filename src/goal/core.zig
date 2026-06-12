//! Goal 层: 注目 → 察觉 → 差集
//!
//! 论文附录 B.3 的四个核心算法实现:
//!   1. Existential-TopK-Attention (B.3.1)   - 存在度加权 Top-K + ε-greedy
//!   2. Difference-Tensor-Computation (B.3.2) - 差异张量 Δ ∈ R^{d_G × 4 × d_W}
//!   3. Difference-Set-Goal-Generation (B.3.3) - 差集目标生成 (含张量分解)
//!   4. Existential-Degree-Update-Loop (B.3.4) - 三时间尺度主循环
//!
//! 创造性扩展:
//!   - 信息的"特征嵌入": 用 4 维特征向量 (resonance / impact / novelty / cost)
//!     替代 LLM 调用,纯算法可实现
//!   - 张量分解: 简化的 HOSVD (高阶 SVD) 提取差异模式, 替代 LLM 推理
//!   - 目标冲突图: 用目标间的"资源/方向"竞争度做冲突消解

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const math_util = util.math;
const F = util.F;
const LCG = util.LCG;
const world = @import("../world/mod.zig");
const ExistenceVector = world.ExistenceVector;
const ExistenceDegree = world.ExistenceDegree;
const WorldModel = world.WorldModel;
const CoappropriationTensor = world.CoappropriationTensor;
const idx2 = util.idx2;
const idx3 = util.idx3;
const Tensor2Shape = util.Tensor2Shape;
const Tensor3Shape = util.Tensor3Shape;

// ============================================================
//   Information:  环境输入的最小数据单元
//   每个信息项有 4 个核心特征:
//     - resonance:  与现有目标/价值的语义关联度
//     - impact:     对存在增益的潜在影响
//     - novelty:    相对历史的新颖度
//     - cost:       消耗的资源 (CPU/时间)
// ============================================================
pub const Information = struct {
    id: u64,
    label: []const u8,
    /// 4 维特征向量
    features: [4]F,

    pub fn format(self: Information, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("[{s} res={d:.2} imp={d:.2} nov={d:.2} cost={d:.2}]", .{
            self.label, self.features[0], self.features[1], self.features[2], self.features[3],
        });
    }
};

// ============================================================
//   Attention:  存在度加权 Top-K + ε-greedy 注目
//   论文 B.3.1 算法 1 的 Zig 创造性实现
// ============================================================
pub const AttentionParams = struct {
    /// 特征权重 α (resonance), β (impact), γ (novelty)
    alpha: F = 0.45,
    beta: F = 0.35,
    gamma: F = 0.20,
    /// 基础探索率
    epsilon_base: F = 0.05,
    /// 存在度阈值, 高于此值 -> 系统稳定 -> 探索率低
    e_threshold: F = 0.5,
    /// 选择数量
    k: usize = 3,
    /// 存在度安全阈值: 低于此值时, 任何"高 cost" 信息被过滤
    existential_safety: F = 0.20,
};

pub const AttentionResult = struct {
    selected: []usize, // 选中信息的索引
    scores: []F, // 选中项的关切度分数
    epsilon_used: F,
    allocator: Allocator,

    pub fn deinit(self: *AttentionResult) void {
        self.allocator.free(self.selected);
        self.allocator.free(self.scores);
    }
};

pub const AttentionEngine = struct {
    params: AttentionParams,
    /// 历史签名 (用于 novelty 估计): 最近 N 个信息 label 的 hash
    history_hashes: std.ArrayList(u64),
    history_capacity: usize = 64,
    allocator: Allocator,
    rng: LCG,
    /// 全局 tick, 用于稳定 id
    next_id: u64 = 1,

    pub fn init(allocator: Allocator, seed: u64, params: AttentionParams) AttentionEngine {
        return .{
            .params = params,
            .history_hashes = .empty,
            .allocator = allocator,
            .rng = LCG.init(seed),
        };
    }

    pub fn deinit(self: *AttentionEngine) void {
        self.history_hashes.deinit(self.allocator);
    }

    /// 计算存在度感知的 ε (论文 B.3.1 步骤 2)
    /// E 高 -> ε 低 (稳定 -> 利用); E 低 -> ε 高 (受威胁 -> 探索)
    pub fn computeEpsilon(self: AttentionEngine, e: F) F {
        if (e > self.params.e_threshold) {
            return self.params.epsilon_base * (1.0 - math_util.tanh(e));
        } else {
            return self.params.epsilon_base *
                (1.0 + math_util.sigmoid(self.params.e_threshold - e));
        }
    }

    /// 字符串 hash (FNV-1a 64bit)
    pub fn hashLabel(self: *AttentionEngine, s: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (s) |c| {
            h ^= @as(u64, c);
            h *%= 0x100000001b3;
        }
        // 记录到历史. 注意 0.17 std.array_list.orderedRemove(0) 在 @memmove strict
        // 检查时 panic ("source and destination arguments have non-equal lengths").
        // 改用 swapRemove(0) — O(1) 把首元素跟末尾交换再 pop, 顺序不重要 (我们只算 novelty)
        if (self.history_hashes.items.len >= self.history_capacity) {
            _ = self.history_hashes.swapRemove(0);
        }
        self.history_hashes.append(self.allocator, h) catch return h;
        return h;
    }

    /// novelty 估计: 1 - 归一化历史相似度
    pub fn novelty(self: AttentionEngine, hash: u64) F {
        if (self.history_hashes.items.len == 0) return 1.0;
        var nearest: u64 = std.math.maxInt(u64);
        for (self.history_hashes.items) |h| {
            const d: u64 = if (h > hash) h - hash else hash - h;
            if (d < nearest) nearest = d;
        }
        // 把最近距离映射到 [0, 1]
        const norm: F = @as(F, @floatFromInt(nearest)) / @as(F, @floatFromInt(std.math.maxInt(u64)));
        return math_util.clamp(norm * 50.0, 0, 1); // 缩放以产生有效变化
    }

    /// 单个信息的"关切度"分数 (论文 concern_i = α·relevance + β·impact + γ·novelty)
    pub fn concern(self: *AttentionEngine, info: *const Information) F {
        const h = self.hashLabel(info.label);
        const nov = self.novelty(h);
        return self.params.alpha * info.features[0] +
            self.params.beta * info.features[1] +
            self.params.gamma * nov;
    }

    /// 存在论过滤器: cost 高且存在度低 -> 过滤
    pub fn existentialSafetyCheck(self: AttentionEngine, info: *const Information, e: F) bool {
        if (e > self.params.existential_safety) return true;
        // 存在度受威胁, 拒绝任何高 cost 信息
        return info.features[3] < 0.7;
    }

    /// 主算法: Existential-TopK-Attention
    /// 输入: 信息流, 存在度 E, 目标图 G
    /// 输出: Top-K 选中的索引
    pub fn attend(
        self: *AttentionEngine,
        infos: []const Information,
        e: F,
        target_relevance: []const F, // 当前目标图, 提供 relevance 调整
    ) !AttentionResult {
        const n = infos.len;
        // 1. 计算所有 concern 分数
        var scores = try self.allocator.alloc(F, n);
        defer self.allocator.free(scores);
        for (infos, 0..) |*info_ref, i| {
            const info = info_ref;
            // 引入目标相关性: 如果有目标, 用目标作为相关性的修正
            const target_boost: F = if (i < target_relevance.len) 0.1 * target_relevance[i] else 0;
            const c = self.concern(info) + target_boost;
            // 2. 存在论安全检查
            if (!self.existentialSafetyCheck(info, e)) {
                scores[i] = -1.0; // 标记为不可选
            } else {
                scores[i] = c;
            }
        }
        // 3. 计算 ε
        const eps = self.computeEpsilon(e);
        // 4. Top-K 选择
        const k = @min(self.params.k, n);
        var selected = try self.allocator.alloc(usize, k);
        var out_scores = try self.allocator.alloc(F, k);
        // 零初始化, 防止未填满的槽位返回垃圾值
        @memset(selected, 0);
        @memset(out_scores, 0);
        // 复制 scores 用于排序
        const indexed = try self.allocator.alloc(usize, n);
        defer self.allocator.free(indexed);
        for (indexed, 0..) |*v, i| v.* = i;
        // 简单排序: 选 K 个最大 (O(n*K), 对小流够用)
        var used = try self.allocator.alloc(bool, n);
        defer self.allocator.free(used);
        for (used) |*v| v.* = false;
        // 真排序: 找 Top-K (排除 -1)
        var found: usize = 0;
        while (found < k) {
            var best: usize = std.math.maxInt(usize);
            var best_score: F = -math.inf(F);
            for (indexed) |idx| {
                if (used[idx]) continue;
                if (scores[idx] < 0) continue;
                if (scores[idx] > best_score) {
                    best_score = scores[idx];
                    best = idx;
                }
            }
            if (best == std.math.maxInt(usize)) break;
            selected[found] = best;
            out_scores[found] = best_score;
            used[best] = true;
            found += 1;
        }
        // 5. ε-探索: 用一个未选中的次优项替换某个选中项
        if (eps > 0 and found > 0) {
            if (self.rng.unitF() < eps) {
                // 找一个未选中的可用项
                const swap_idx: usize = self.rng.lessThan(@intCast(found));
                var replace: usize = std.math.maxInt(usize);
                for (indexed) |idx| {
                    if (used[idx]) continue;
                    if (scores[idx] < 0) continue;
                    if (replace == std.math.maxInt(usize)) replace = idx;
                }
                if (replace != std.math.maxInt(usize)) {
                    used[selected[swap_idx]] = false;
                    used[replace] = true;
                    const old_score = out_scores[swap_idx];
                    selected[swap_idx] = replace;
                    out_scores[swap_idx] = scores[replace] * 0.5; // 探索项降权
                    _ = old_score;
                }
            }
        }
        return AttentionResult{
            .selected = selected,
            .scores = out_scores,
            .epsilon_used = eps,
            .allocator = self.allocator,
        };
    }
};

// ============================================================
//   Perception:  察觉算法 - 差异张量计算
//   论文 B.3.2 算法 2 的 Zig 实现
// ============================================================
/// 存在状态向量: [E, coherence, engagement, resilience]
pub const ExistenceGap = struct {
    e: F,
    coherence: F,
    engagement: F,
    resilience: F,
};

/// 差异张量: Δ ∈ R^{d_G × 4 × d_W}
/// d_G: 目标数,  4: 存在状态维度,  d_W: 世界模型特征维度
pub const DifferenceTensor = struct {
    shape: struct { d_g: usize, k: usize = 4, d_w: usize },
    data: []F,
    allocator: Allocator,
    /// 缓存: 每个目标 j 的差距向量
    gaps: []ExistenceGap,

    pub fn deinit(self: *DifferenceTensor) void {
        self.allocator.free(self.data);
        self.allocator.free(self.gaps);
    }

    pub fn at(self: DifferenceTensor, g: usize, k: usize, w: usize) F {
        const s = self.shape;
        return self.data[g * s.k * s.d_w + k * s.d_w + w];
    }

    pub fn set(self: *DifferenceTensor, g: usize, k: usize, w: usize, v: F) void {
        const s = self.shape;
        self.data[g * s.k * s.d_w + k * s.d_w + w] = v;
    }

    /// Frobenius 范数 (差异张量总能量)
    pub fn energy(self: DifferenceTensor) F {
        var s: F = 0;
        for (self.data) |v| s += v * v;
        return @sqrt(s);
    }
};

pub const PerceptionEngine = struct {
    allocator: Allocator,
    rng: LCG,

    pub fn init(allocator: Allocator, seed: u64) PerceptionEngine {
        return .{ .allocator = allocator, .rng = LCG.init(seed + 7919) };
    }

    /// 计算当前存在状态向量
    /// [E, coherence(W), engagement(W), resilience(W)]
    pub fn currentState(
        self: *PerceptionEngine,
        ed: ExistenceDegree,
        wms: *CoappropriationTensor,
        wm: *WorldModel,
    ) ExistenceGap {
        _ = self;
        return .{
            .e = ed.e(),
            .coherence = wms.coherence(),
            .engagement = wm.miWithReality(),
            .resilience = wm.resilience(),
        };
    }

    /// 模拟达成某目标 g_j 后的理想存在状态
    /// 创造性: 假设理想态是当前态 + 目标 j 提供的 delta
    /// (论文 B.3.2 步骤 2.a simulate_optimal_trajectory)
    pub fn simulateIdeal(
        self: *PerceptionEngine,
        current: ExistenceGap,
        target_de: F, // 目标预期带来的 E 增益
        target_focus: F, // 目标在 coherence/engagement/resilience 上的权重
    ) ExistenceGap {
        _ = self;
        return .{
            .e = math_util.clamp(current.e + target_de, 0, 1),
            .coherence = math_util.clamp(current.coherence + target_focus * 0.2, 0, 1),
            .engagement = math_util.clamp(current.engagement + target_focus * 0.3, 0, 1),
            .resilience = math_util.clamp(current.resilience + target_focus * 0.1, 0, 1),
        };
    }

    /// 计算世界模型 W 相对于存在维度 k 的"梯度" (论文 B.3.2 步骤 3)
    /// 创造性: 用统计互信息估计每个特征与该维度的关联度
    ///  返回: 每个 world 特征 j 的梯度值
    pub fn worldGradient(
        self: *PerceptionEngine,
        wm: *WorldModel,
        dim: usize, // 0=coherence, 1=engagement, 2=resilience
    ) ![]F {
        const d_w = wm.dim;
        const grad = try self.allocator.alloc(F, d_w);
        errdefer self.allocator.free(grad);
        // 简单启发式: 不同维度对应不同的特征偏移
        // 0 (coherence): 偏向稳定 (低方差)
        // 1 (engagement): 偏向多样性 (高方差)
        // 2 (resilience): 偏向中庸 (近 0.5)
        const bias: F = switch (dim) {
            0 => -0.5, // coherence: 越偏离 0.5 越不合
            1 => 0.5, // engagement: 越多样越好
            2 => 0.0, // resilience: 中庸
            else => 0.0,
        };
        for (wm.state, 0..) |s, i| {
            // 简单的线性: 距离 (s - target) 的反向
            const target: F = 0.5 - bias;
            grad[i] = (s - target) * 0.2;
        }
        return grad;
    }

    /// 主算法: Difference-Tensor-Computation
    /// goal_hints: 任何带 .de 和 .focus 字段的类型切片
    pub fn compute(
        self: *PerceptionEngine,
        current: ExistenceGap,
        wm: *WorldModel,
        goal_hints: anytype,
    ) !DifferenceTensor {
        const T = @TypeOf(goal_hints[0]);
        const has_de = @hasField(T, "de");
        const has_focus = @hasField(T, "focus");
        if (!has_de or !has_focus) @compileError("goal_hints must have .de and .focus fields");
        const d_g = goal_hints.len;
        const d_w = wm.dim;
        var tensor = DifferenceTensor{
            .shape = .{ .d_g = d_g, .d_w = d_w },
            .data = try self.allocator.alloc(F, d_g * 4 * d_w),
            .allocator = self.allocator,
            .gaps = try self.allocator.alloc(ExistenceGap, d_g),
        };
        // 步骤 1-2: 逐目标计算 gap
        for (goal_hints, 0..) |gh, j| {
            const ideal = self.simulateIdeal(current, gh.de, gh.focus);
            const gap: ExistenceGap = .{
                .e = ideal.e - current.e,
                .coherence = ideal.coherence - current.coherence,
                .engagement = ideal.engagement - current.engagement,
                .resilience = ideal.resilience - current.resilience,
            };
            tensor.gaps[j] = gap;
            // 步骤 3: 填充张量 Δ[j, k, :] = gap_j[k] · gradient_W(W, k)
            inline for ([_]usize{ 0, 1, 2, 3 }) |k| {
                const grad = try self.worldGradient(wm, k);
                defer self.allocator.free(grad);
                const g_k: F = switch (k) {
                    0 => gap.e,
                    1 => gap.coherence,
                    2 => gap.engagement,
                    3 => gap.resilience,
                    else => 0,
                };
                for (grad, 0..) |gw, i| {
                    tensor.set(j, k, i, g_k * gw);
                }
            }
        }
        // 步骤 4: Frobenius 归一化
        const e = tensor.energy();
        if (e > 1e-6) {
            for (tensor.data) |*v| v.* /= e;
        }
        return tensor;
    }
};

// ============================================================
//   DifferenceSet:  差集目标生成
//   论文 B.3.3 算法 3 的 Zig 实现
//   创造性: 用简化的 HOSVD (高阶 SVD) 提取差异模式
// ============================================================
/// 目标种类
pub const GoalKind = enum {
    /// 存在增益型: 直接提升 E
    enhance_existence,
    /// 知识获取型: 提升 R
    acquire_knowledge,
    /// 资源获取型: 提升 M
    acquire_resource,
    /// 边界维护型: 维持核心安全
    maintain_boundary,
    /// 探索型: 拓展世界模型
    explore,
    /// 共生型: 协助他者
    symbiosis,
    /// L1/L2: 自我调整参数 / 行为策略
    self_modify_params,
    /// L3: 自我扩展方法库 (调用 LLM 生成新方法)
    self_extend_method,
    /// L4: 自我优化内部算法
    self_optimize,
};

/// 9 种目标关系 (Phase 8 数字生命实装里程碑)
/// 论文 7.3 叙事: 数字生命的 GoalGraph 是 DAG, 关系决定行为策略
/// 1. parent_child   - 父子层级 (子等父完成才能开始)
/// 2. sibling        - 并列 (同父或同级, 可同时跑)
/// 3. conflict       - 冲突 (二选一, 跑一个抑制另一个)
/// 4. depends_on     - 依赖 (A 跑前必须 B 完成)
/// 5. replaces       - 替代 (A 成功后 B 自动 obsolete)
/// 6. enables        - 促成 (A 完成降低 B 成本)
/// 7. inhibits       - 抑制 (A 跑时降低 B 优先级)
/// 8. emerges_from   - 涌现 (A 由 B+C 共同 enable 才会触发)
/// 9. emerges_after  - 涌现+时间 (B 跑完后 Δt 时间后 A 才触发, 论文 7.4 时间涌现)
pub const GoalRelation = enum(u8) {
    parent_child = 1,
    sibling = 2,
    conflict = 3,
    depends_on = 4,
    replaces = 5,
    enables = 6,
    inhibits = 7,
    emerges_from = 8,
    emerges_after = 9,
    _count = 10,
};

pub const Goal = struct {
    id: u64,
    kind: GoalKind,
    label: []const u8,
    /// 优先级 [0, 10]
    priority: u8,
    /// 预期存在增益
    expected_de: F,
    /// 父目标 id (parent_child 关系, 层级结构)
    parent: ?u64 = null,
    /// 子目标数 (用于"层级整合")
    children: u32 = 0,
    /// 该目标的世界模型梯度签名 (用于冲突检测)
    signature: [4]F = .{ 0, 0, 0, 0 },
    /// 状态: 0=active, 1=in_progress, 2=completed, 3=obsolete (被 replaces 取代)
    status: u8 = 0,

    // === 7 个非层级关系 (parent_child 走 parent 字段) ===
    /// sibling: 同级并列, 可同时跑
    siblings: std.ArrayList(u64) = .empty,
    /// conflict: 冲突节点 (二选一)
    conflicts_with: std.ArrayList(u64) = .empty,
    /// depends_on: 前置依赖 (必须先完成)
    depends_on: std.ArrayList(u64) = .empty,
    /// replaces: 替代关系 (成功后让对方 obsolete)
    replaces: ?u64 = null,
    /// enables: 促成 (完成后让对方成本降低)
    enables: std.ArrayList(u64) = .empty,
    /// inhibits: 抑制 (在跑时让对方优先级降)
    inhibits: std.ArrayList(u64) = .empty,
    /// emerges_from: 涌现 (由 2+ 节点共同 enable)
    emerges_from: std.ArrayList(u64) = .empty,
    /// emerges_after: 涌现 + 时间 (B 跑完后 Δt 时间后 A 才触发)
    /// 单向: A.emerges_after 存 B, A 等 B 完成 + Δt 后才能开始
    emerges_after: std.ArrayList(u64) = .empty,
    /// emerges_after 时间戳: 节点完成时间 + Δt (cycle 数) — 由 graph 维护, 启动时按 addRelation 设置
    emerges_after_delay: u32 = 0,

    pub fn format(self: Goal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("G{id}({s},p={d},ΔE={d:.3})", .{ self.id, @tagName(self.kind), self.priority, self.expected_de });
    }

    /// 计算这个 goal 用了哪些关系类型 (返回 16-bit 位掩码, 每位对应 GoalRelation)
    /// 注: 返 u16 是因为 0.17 严格, 1<<8 不能装进 u8 (会静默 wrap 到 0)
    /// bit i = 1 表示用了第 (i+1) 种关系
    pub fn relationsBitmask(self: *const Goal) u16 {
        var mask: u16 = 0;
        if (self.parent != null) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.parent_child));
        if (self.siblings.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.sibling));
        if (self.conflicts_with.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.conflict));
        if (self.depends_on.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.depends_on));
        if (self.replaces != null) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.replaces));
        if (self.enables.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.enables));
        if (self.inhibits.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.inhibits));
        if (self.emerges_from.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.emerges_from));
        if (self.emerges_after.items.len > 0) mask |= std.math.shl(u16, 1, @intFromEnum(GoalRelation.emerges_after));
        return mask;
    }
};

pub const GoalGraph = struct {
    goals: std.ArrayList(Goal),
    /// 邻接表: children_of[parent_id] = []child_id
    /// 论文 7.3: 目标层级 = DAG (允许多父 -> 我们先做单父简化)
    children_of: std.ArrayList(std.ArrayList(u64)),
    /// 哪些 children_of 槽位已被释放 (removeCascade 标记)
    children_of_freed: std.ArrayList(bool),
    /// parent_of[id] = parent_id (反向索引, O(1) 查询)
    parent_of: std.ArrayList(u64), // index = goal_id - 1 (假设 id 从 1 连续)
    allocator: Allocator,
    next_id: u64 = 1,

    pub fn init(allocator: Allocator) GoalGraph {
        return .{
            .goals = .empty,
            .children_of = .empty,
            .children_of_freed = .empty,
            .parent_of = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GoalGraph) void {
        // 安全 deinit: 跳过已被 removeCascade 释放过的槽位
        for (self.children_of.items, 0..) |*c, i| {
            if (i < self.children_of_freed.items.len and self.children_of_freed.items[i]) continue;
            c.deinit(self.allocator);
        }
        self.children_of.deinit(self.allocator);
        self.children_of_freed.deinit(self.allocator);
        self.parent_of.deinit(self.allocator);
        // 释放每个 goal 的 7 个关系 ArrayList (sibling/conflict/depends_on/enables/inhibits/emerges_from/emerges_after)
        for (self.goals.items) |*g| {
            g.siblings.deinit(self.allocator);
            g.conflicts_with.deinit(self.allocator);
            g.depends_on.deinit(self.allocator);
            g.enables.deinit(self.allocator);
            g.inhibits.deinit(self.allocator);
            g.emerges_from.deinit(self.allocator);
            g.emerges_after.deinit(self.allocator);
        }
        self.goals.deinit(self.allocator);
    }

    /// 添加目标 (顶级, 无父)
    pub fn add(self: *GoalGraph, kind: GoalKind, label: []const u8, priority: u8, de: F, sig: [4]F) !u64 {
        return try self.addChild(kind, label, priority, de, sig, null);
    }

    /// 添加子目标
    /// 论文 7.3: 父子关系, 子必须等父完成才能开始
    /// 返回: 分配的新 id
    pub fn addChild(
        self: *GoalGraph,
        kind: GoalKind,
        label: []const u8,
        priority: u8,
        de: F,
        sig: [4]F,
        parent_id: ?u64,
    ) !u64 {
        if (parent_id) |pid| {
            // 验证父存在
            if (self.get(pid) == null) return error.ParentNotFound;
            // 防止环
            if (try self.wouldCreateCycle(self.next_id, pid)) return error.CycleDetected;
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.goals.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .label = label,
            .priority = priority,
            .expected_de = de,
            .parent = parent_id,
            .children = 0,
            .signature = sig,
        });
        // 同步 parent_of 索引
        try self.parent_of.append(self.allocator, parent_id orelse 0);
        // 如果有父, 更新父的 children + children_of 表
        if (parent_id) |pid| {
            // 扩展 children_of 到足够长
            while (self.children_of.items.len < pid) {
                try self.children_of.append(self.allocator, .empty);
            }
            const idx = pid - 1;
            // 确保 children_of[idx] 存在
            if (idx >= self.children_of.items.len) {
                try self.children_of.append(self.allocator, .empty);
            }
            try self.children_of.items[idx].append(self.allocator, id);
            // 更新父节点的 children 数
            if (self.getPtr(pid)) |p| p.children += 1;
        }
        return id;
    }

    // ===== 8 关系 API =====

    /// 加一条关系 (a -> b, kind)
    /// 注: parent_child 走 addChild(parent_id:), 不走 addRelation
    pub fn addRelation(self: *GoalGraph, a: u64, b: u64, rel: GoalRelation) !void {
        if (rel == .parent_child) return error.UseAddChild;
        const a_ptr = self.getPtr(a) orelse return error.GoalANotFound;
        const b_ptr = self.getPtr(b) orelse return error.GoalBNotFound;
        // 防止自己指向自己
        if (a == b) return error.SelfRelation;
        switch (rel) {
            .sibling => {
                // 双向 (a↔b 互为 sibling)
                if (!containsU64(a_ptr.siblings.items, b)) try a_ptr.siblings.append(self.allocator, b);
                if (!containsU64(b_ptr.siblings.items, a)) try b_ptr.siblings.append(self.allocator, a);
            },
            .conflict => {
                if (!containsU64(a_ptr.conflicts_with.items, b)) try a_ptr.conflicts_with.append(self.allocator, b);
                if (!containsU64(b_ptr.conflicts_with.items, a)) try b_ptr.conflicts_with.append(self.allocator, a);
            },
            .depends_on => {
                // A depends on B (单向: a 需要 b 完成)
                if (!containsU64(a_ptr.depends_on.items, b)) try a_ptr.depends_on.append(self.allocator, b);
            },
            .replaces => {
                // 单向: a 替换 b
                a_ptr.replaces = b;
            },
            .enables => {
                // 单向: a 完成促成 b
                if (!containsU64(a_ptr.enables.items, b)) try a_ptr.enables.append(self.allocator, b);
            },
            .inhibits => {
                // 单向: a 跑时抑制 b
                if (!containsU64(a_ptr.inhibits.items, b)) try a_ptr.inhibits.append(self.allocator, b);
            },
            .emerges_from => {
                // 单向: a 由 b 涌现
                if (!containsU64(a_ptr.emerges_from.items, b)) try a_ptr.emerges_from.append(self.allocator, b);
            },
            .emerges_after => {
                // 单向: a 在 b 跑完后 Δt 时间才能开始 (论文 7.4 时间涌现)
                if (!containsU64(a_ptr.emerges_after.items, b)) try a_ptr.emerges_after.append(self.allocator, b);
            },
            .parent_child => return error.UseAddChild,
            ._count => unreachable,
        }
    }

    /// 统计活跃节点用过的不同关系类型数 (1-8, 用于 phase 8 触发)
    /// 注: status=0 (active) 或 status=1 (in_progress) 才算活跃
    pub fn countDistinctRelations(self: *const GoalGraph) u8 {
        var mask: u16 = 0;
        for (self.goals.items) |*g| {
            if (g.status >= 2) continue; // 跳过 completed/obsolete
            mask |= g.relationsBitmask();
        }
        return @popCount(mask);
    }

    /// 统计每种关系类型的活跃边数
    /// 返回 9 元素数组 [parent_child_count, sibling_count, conflict, depends, replaces, enables, inhibits, emerges_from, emerges_after]
    pub fn relationStats(self: *const GoalGraph) [9]u32 {
        var stats = [_]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        for (self.goals.items) |*g| {
            if (g.status >= 2) continue;
            if (g.parent != null) stats[0] += 1;
            stats[1] += @intCast(g.siblings.items.len);
            stats[2] += @intCast(g.conflicts_with.items.len);
            stats[3] += @intCast(g.depends_on.items.len);
            if (g.replaces != null) stats[4] += 1;
            stats[5] += @intCast(g.enables.items.len);
            stats[6] += @intCast(g.inhibits.items.len);
            stats[7] += @intCast(g.emerges_from.items.len);
            stats[8] += @intCast(g.emerges_after.items.len);
        }
        // sibling/conflict 双向, 除 2
        stats[1] /= 2;
        stats[2] /= 2;
        return stats;
    }

    /// 把 9 关系状态格式化成 JSON-friendly 字符串 (供 UI)
    /// 格式: "parent:3 sibling:5 conflict:1 depends:2 replaces:1 enables:4 inhibits:0 emerges:2 emerges_after:1"
    pub fn relationsSummary(self: *const GoalGraph, alloc: Allocator) ![]u8 {
        const stats = self.relationStats();
        const names = [_][]const u8{
            "parent", "sibling", "conflict", "depends",
            "replaces", "enables", "inhibits", "emerges",
            "emerges_after",
        };
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        for (stats, names) |n, name| {
            if (n == 0) continue;
            if (buf.items.len > 0) try buf.append(alloc, ' ');
            try buf.print(alloc, "{s}:{d}", .{ name, n });
        }
        return buf.toOwnedSlice(alloc);
    }

fn containsU64(slice: []const u64, v: u64) bool {
    for (slice) |x| if (x == v) return true;
    return false;
}

    /// 移除节点 (并提升子节点为父的兄弟, 或级联删除)
    /// cascade=true: 级联删除所有子孙
    pub fn remove(self: *GoalGraph, id: u64) void {
        self.removeCascade(id, false) catch {};
    }

    pub fn removeCascade(self: *GoalGraph, id: u64, cascade: bool) Allocator.Error!void {
        // 找位置
        var idx: usize = 0;
        var found = false;
        for (self.goals.items, 0..) |g, i| {
            if (g.id == id) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) return;

        // 先复制子列表 (因为 deinit 会清空 children_of[id-1])
        var children_copy: std.ArrayList(u64) = .empty;
        defer children_copy.deinit(self.allocator);
        const child_idx = id - 1;
        if (child_idx < self.children_of.items.len) {
            for (self.children_of.items[child_idx].items) |c| {
                try children_copy.append(self.allocator, c);
            }
        }

        // 如果级联, 先删所有子
        if (cascade) {
            for (children_copy.items) |c| {
                try self.removeCascade(c, true);
            }
        } else {
            const my_parent = self.goals.items[idx].parent;
            for (children_copy.items) |c| {
                if (self.getPtr(c)) |cg| {
                    cg.parent = my_parent;
                    if (c - 1 < self.parent_of.items.len) {
                        self.parent_of.items[c - 1] = my_parent orelse 0;
                    }
                }
                if (my_parent) |mp| {
                    const mp_idx = mp - 1;
                    while (self.children_of.items.len <= mp_idx) {
                        try self.children_of.append(self.allocator, .empty);
                    }
                    try self.children_of.items[mp_idx].append(self.allocator, c);
                    if (self.getPtr(mp)) |mpg| mpg.children += 1;
                }
            }
            if (child_idx < self.children_of.items.len) {
                self.children_of.items[child_idx].deinit(self.allocator);
            }
        }

        if (self.goals.items[idx].parent) |pid| {
            const pidx = pid - 1;
            if (pidx < self.children_of.items.len) {
                var pchildren = &self.children_of.items[pidx];
                for (pchildren.items, 0..) |c, i| {
                    if (c == id) {
                        _ = pchildren.orderedRemove(i);
                        break;
                    }
                }
                if (self.getPtr(pid)) |pg| {
                    if (pg.children > 0) pg.children -= 1;
                }
            }
        }

        _ = self.goals.orderedRemove(idx);
        if (id - 1 < self.parent_of.items.len) {
            self.parent_of.items[id - 1] = 0;
        }
        if (child_idx < self.children_of.items.len) {
            self.children_of.items[child_idx].deinit(self.allocator);
            // 标记为已释放, 防止 deinit 重复
            while (self.children_of_freed.items.len <= child_idx) {
                self.children_of_freed.append(self.allocator, false) catch {};
            }
            self.children_of_freed.items[child_idx] = true;
        }
    }

    pub fn get(self: GoalGraph, id: u64) ?*Goal {
        if (id == 0) return null;
        if (id - 1 >= self.parent_of.items.len) return null;
        if (self.parent_of.items[id - 1] == 0 and !self.isLive(id)) return null;
        for (self.goals.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    pub fn getPtr(self: *GoalGraph, id: u64) ?*Goal {
        if (id == 0) return null;
        for (self.goals.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    fn isLive(self: GoalGraph, id: u64) bool {
        for (self.goals.items) |g| {
            if (g.id == id) return true;
        }
        return false;
    }

    /// 返回 id 的所有直接子 id
    pub fn children(self: GoalGraph, id: u64) []const u64 {
        if (id == 0) return &[_]u64{};
        const idx = id - 1;
        if (idx >= self.children_of.items.len) return &[_]u64{};
        return self.children_of.items[idx].items;
    }

    /// 返回 id 的所有祖先 (父, 祖父, ..., 根) (深度优先)
    pub fn ancestors(self: GoalGraph, id: u64, alloc: Allocator) ![]u64 {
        var out: std.ArrayList(u64) = .empty;
        defer out.deinit(alloc);
        var cur = self.get(id);
        while (cur) |c| {
            if (c.parent) |p| {
                try out.append(alloc, p);
                cur = self.get(p);
            } else break;
        }
        return out.toOwnedSlice(alloc);
    }

    /// 返回 id 的所有后代 (子, 孙, ...) (BFS)
    pub fn descendants(self: GoalGraph, id: u64, alloc: Allocator) ![]u64 {
        var out: std.ArrayList(u64) = .empty;
        defer out.deinit(alloc);
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(alloc);
        for (self.children(id)) |c| try queue.append(alloc, c);
        while (queue.items.len > 0) {
            const cur = queue.orderedRemove(0);
            try out.append(alloc, cur);
            for (self.children(cur)) |c| try queue.append(alloc, c);
        }
        return out.toOwnedSlice(alloc);
    }

    /// 拓扑排序 (Kahn 算法)
    /// 返回: 排序后的 id 列表 (依赖在前面)
    /// 返回 error.CycleDetected 如果有环
    /// 拓扑排序 (Kahn 算法, 考虑 3 种"必须先跑" 关系)
    /// 论文 7.3 协商: 父子层级 + 兄弟并行
    /// 论文 7.4 时间涌现: emerges_after 强制 A 在 B 完成后 Δt 才能开始
    /// 考虑的关系 (影响 start 顺序):
    ///   - parent_child: 父在子前
    ///   - depends_on:   依赖在子前
    ///   - emerges_after: 时间涌现 (B 完成后 A 才能)
    /// 不考虑 (不影响顺序):
    ///   - sibling, conflict, replaces, enables, inhibits, emerges_from
    /// 返回: 排序后的 id 列表 (依赖在前面)
    /// 返回 error.CycleDetected 如果有环
    pub fn topologicalSort(self: GoalGraph, alloc: Allocator) ![]u64 {
        // 计算入度: parent + depends_on + emerges_after 全部算入度
        var in_degree: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer in_degree.deinit(alloc);
        for (self.goals.items) |g| {
            try in_degree.put(alloc, g.id, 0);
        }
        // 1. parent_child: 子节点入度 +1
        for (self.goals.items) |g| {
            if (g.parent) |p| {
                if (in_degree.getPtr(p) != null) {
                    if (in_degree.getPtr(g.id)) |e| e.* += 1;
                }
            }
        }
        // 2. depends_on: A.depends_on 包含 B → A 入度 +1
        for (self.goals.items) |g| {
            for (g.depends_on.items) |dep| {
                if (in_degree.getPtr(dep) != null) {
                    if (in_degree.getPtr(g.id)) |e| e.* += 1;
                }
            }
        }
        // 3. emerges_after: A.emerges_after 包含 B → A 入度 +1
        for (self.goals.items) |g| {
            for (g.emerges_after.items) |ea| {
                if (in_degree.getPtr(ea) != null) {
                    if (in_degree.getPtr(g.id)) |e| e.* += 1;
                }
            }
        }
        // 找入度 0 的节点
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(alloc);
        for (self.goals.items) |g| {
            if (in_degree.get(g.id).? == 0) try queue.append(alloc, g.id);
        }
        var result: std.ArrayList(u64) = .empty;
        defer result.deinit(alloc);
        while (queue.items.len > 0) {
            const cur = queue.orderedRemove(0);
            try result.append(alloc, cur);
            // 1. 父节点 cur 完成后, children 入度 -1
            for (self.children(cur)) |c| {
                if (in_degree.getPtr(c)) |e| {
                    e.* -= 1;
                    if (e.* == 0) try queue.append(alloc, c);
                }
            }
            // 2. cur 完成后, 任何 depends_on 包含 cur 的节点入度 -1
            for (self.goals.items) |g| {
                for (g.depends_on.items) |dep| {
                    if (dep == cur) {
                        if (in_degree.getPtr(g.id)) |e| {
                            e.* -= 1;
                            if (e.* == 0) try queue.append(alloc, g.id);
                        }
                    }
                }
            }
            // 3. cur 完成后, 任何 emerges_after 包含 cur 的节点入度 -1
            for (self.goals.items) |g| {
                for (g.emerges_after.items) |ea| {
                    if (ea == cur) {
                        if (in_degree.getPtr(g.id)) |e| {
                            e.* -= 1;
                            if (e.* == 0) try queue.append(alloc, g.id);
                        }
                    }
                }
            }
        }
        if (result.items.len != self.goals.items.len) return error.CycleDetected;
        return result.toOwnedSlice(alloc);
    }


    /// 环检测: 添加边 (parent_id → new_id) 是否会形成环
    pub fn wouldCreateCycle(self: GoalGraph, new_id: u64, parent_id: u64) !bool {
        _ = self;
        // new_id 是新节点的 id (还没插入), parent_id 不能等于 new_id (自环)
        if (new_id == parent_id) return true;
        return false;
    }

    /// 论文 7.3 协商策略 1: 父子约束检查
    /// 父没完成时, 子不能选 (priority 返回 0)
    pub fn effectivePriority(self: GoalGraph, id: u64) u8 {
        const g = self.get(id) orelse return 0;
        if (g.parent) |pid| {
            const p = self.get(pid) orelse return 0;
            // 简化: 父如果 priority > 0 视为活跃, 子可用
            // 真实场景应该看 status (pending/in_progress/completed)
            return if (p.priority > 0) g.priority else 0;
        }
        return g.priority;
    }

    /// 论文 7.3 协商策略 2: 冲突消解时考虑父子关系
    /// 同父的子目标互斥时, 保留 expected_de 较大的
    pub fn siblingsOf(self: GoalGraph, id: u64) []const u64 {
        const g = self.get(id) orelse return &[_]u64{};
        const pid = g.parent orelse return &[_]u64{};
        return self.children(pid);
    }
};

/// 简化的 HOSVD (高阶 SVD) - 提取三阶张量的"差异模式"
/// 输入: 差异张量 Δ ∈ R^{d_G × 4 × d_W}
/// 输出: 主要差异模式 (rank-r 近似)
/// 创造性: 用 power iteration 沿每个 mode 提取最大方差方向
pub const TensorDecomposer = struct {
    rng: LCG,
    allocator: Allocator,

    pub fn init(allocator: Allocator, seed: u64) TensorDecomposer {
        return .{ .rng = LCG.init(seed), .allocator = allocator };
    }

    /// 沿 mode 展开三阶张量为矩阵
    /// mode 0: [d_G] × [4 * d_W]   行=g, 列=(k,w)
    /// mode 1: [4]   × [d_G * d_W] 行=k, 列=(g,w)
    /// mode 2: [d_W] × [d_G * 4]   行=w, 列=(g,k)
    pub fn unfold(self: TensorDecomposer, t: *const DifferenceTensor, mode: u8) ![]F {
        const s = t.shape;
        switch (mode) {
            0 => {
                const rows = s.d_g;
                const cols = s.k * s.d_w;
                const out = try self.allocator.alloc(F, rows * cols);
                for (0..rows) |g| for (0..s.k) |k| for (0..s.d_w) |w| {
                    out[g * cols + k * s.d_w + w] = t.at(g, k, w);
                };
                return out;
            },
            1 => {
                const rows = s.k;
                const cols = s.d_g * s.d_w;
                const out = try self.allocator.alloc(F, rows * cols);
                for (0..rows) |k| for (0..s.d_g) |g| for (0..s.d_w) |w| {
                    out[k * cols + g * s.d_w + w] = t.at(g, k, w);
                };
                return out;
            },
            2 => {
                const rows = s.d_w;
                const cols = s.d_g * s.k;
                const out = try self.allocator.alloc(F, rows * cols);
                for (0..rows) |w| for (0..s.d_g) |g| for (0..s.k) |k| {
                    out[w * cols + g * s.k + k] = t.at(g, k, w);
                };
                return out;
            },
            else => return error.InvalidMode,
        }
    }

    /// Power iteration 找主奇异向量
    /// 输入: 矩阵 A (rows × cols), 输出 cols 维向量
    pub fn powerIterate(self: *TensorDecomposer, A: []const F, rows: usize, cols: usize, iters: usize) ![]F {
        const v = try self.allocator.alloc(F, cols);
        defer self.allocator.free(v);
        for (v) |*x| x.* = self.rng.unitF();
        math_util.normalizeL2(v);
        const out = try self.allocator.alloc(F, cols);
        const tmp = try self.allocator.alloc(F, rows);
        defer self.allocator.free(tmp);
        var iter: usize = 0;
        while (iter < iters) : (iter += 1) {
            // tmp = A · v
            for (tmp, 0..) |*t, i| {
                var s: F = 0;
                for (0..cols) |j| {
                    s += A[i * cols + j] * v[j];
                }
                t.* = s;
            }
            // out = A^T · tmp
            for (out, 0..) |*o, j| {
                var s: F = 0;
                for (0..rows) |i| {
                    s += A[i * cols + j] * tmp[i];
                }
                o.* = s;
            }
            math_util.normalizeL2(out);
            @memcpy(v, out);
        }
        return out;
    }

    /// 简化的 HOSVD: 返回 rank-r 近似 (论文 B.3.3 步骤 1)
    /// 返回: 显著模式列表 (向量 + 显著性分数)
    pub fn decompose(
        self: *TensorDecomposer,
        t: *const DifferenceTensor,
        rank: usize,
    ) ![]SignificantPattern {
        const s = t.shape;
        const max_rank = @min(rank, @min(s.d_g, s.k * s.d_w));
        if (max_rank == 0) return &[_]SignificantPattern{};
        // 沿 mode 0 展开, 做 SVD
        const A0 = try self.unfold(t, 0);
        defer self.allocator.free(A0);
        // 收集主奇异向量
        var sigs: std.ArrayList(SignificantPattern) = .empty;
        defer sigs.deinit(self.allocator);
        var r: usize = 0;
        while (r < max_rank) : (r += 1) {
            const vec = try self.powerIterate(A0, s.d_g, s.k * s.d_w, 8);
            // 显著性 = L2 范数 / 总能量
            var norm: F = 0;
            for (vec) |x| norm += x * x;
            norm = @sqrt(norm);
            // 把向量 reshape 为 (4 × d_W) 提取签名
            var sig: [4]F = .{ 0, 0, 0, 0 };
            for (0..s.k) |k| {
                var s_k: F = 0;
                for (0..s.d_w) |w| {
                    s_k += @abs(vec[k * s.d_w + w]);
                }
                sig[k] = s_k;
            }
            try sigs.append(self.allocator, .{
                .vector = vec,
                .significance = norm,
                .signature = sig,
            });
        }
        // 排序: 按显著性降序
        std.mem.sort(SignificantPattern, sigs.items, {}, lessThan);
        return sigs.toOwnedSlice(self.allocator);
    }

    fn lessThan(_: void, a: SignificantPattern, b: SignificantPattern) bool {
        return a.significance > b.significance;
    }
};

pub const SignificantPattern = struct {
    vector: []F,
    significance: F,
    signature: [4]F,
};

pub const DifferenceSetEngine = struct {
    allocator: Allocator,
    decomposer: TensorDecomposer,
    /// 最小存在增益阈值 (论文 B.3.3 步骤 2 中 γ_min)
    min_potential_gain: F = 0.05,
    /// 冲突阈值 (θ_conflict)
    conflict_threshold: F = 0.6,
    rng: LCG,

    pub fn init(allocator: Allocator, seed: u64) DifferenceSetEngine {
        return .{
            .allocator = allocator,
            .decomposer = TensorDecomposer.init(allocator, seed),
            .rng = LCG.init(seed + 31337),
        };
    }

    /// 从显著模式构造目标候选
    /// 创造性: 根据 sig 特征自动判定 GoalKind
    pub fn patternToGoal(
        self: *DifferenceSetEngine,
        pattern: SignificantPattern,
        current_e: F,
    ) Goal {
        _ = self;
        const sig = pattern.signature;
        // 找最显著的维度
        var max_dim: usize = 0;
        var max_v: F = sig[0];
        var i: usize = 1;
        while (i < sig.len) : (i += 1) {
            const v = sig[i];
            if (v > max_v) {
                max_v = v;
                max_dim = i;
            }
        }
        const kind: GoalKind = switch (max_dim) {
            0 => .enhance_existence, // e 维度主导
            1 => .explore, // coherence 主导 -> 探索
            2 => .acquire_knowledge, // engagement 主导 -> 知识
            3 => .maintain_boundary, // resilience 主导 -> 维护
            else => .enhance_existence,
        };
        // 优先级: 显著性 * (1 - 当前 E) -> 越紧迫优先级越高
        const urgency: F = 1.0 - current_e;
        const priority_f: F = pattern.significance * 10.0 * urgency;
        const priority: u8 = @intFromFloat(@min(10, @max(0, priority_f)));
        const expected_de = pattern.significance * 0.3;
        return Goal{
            .id = 0, // 由 GoalGraph 分配
            .kind = kind,
            .label = "auto-from-pattern",
            .priority = priority,
            .expected_de = expected_de,
            .signature = sig,
        };
    }

    /// 冲突检测: 两目标的 signature 余弦相似度
    pub fn conflictDegree(self: *DifferenceSetEngine, a: Goal, b: Goal) F {
        _ = self;
        return math_util.cosineSim(&a.signature, &b.signature);
    }

    /// 主算法: Difference-Set-Goal-Generation
    pub fn generate(
        self: *DifferenceSetEngine,
        delta: *const DifferenceTensor,
        prev: *const GoalGraph,
        current_e: F,
    ) !GoalGraph {
        var new_graph = GoalGraph.init(self.allocator);
        errdefer new_graph.deinit();
        // 步骤 1: 张量分解提取显著模式
        const patterns = try self.decomposer.decompose(delta, 3);
        defer {
            for (patterns) |p| self.allocator.free(p.vector);
            self.allocator.free(patterns);
        }
        // 步骤 2: 候选目标生成 + 过滤
        var candidates: std.ArrayList(Goal) = .empty;
        defer candidates.deinit(self.allocator);
        for (patterns) |p| {
            const potential_gain: F = p.significance * 0.3;
            if (potential_gain > self.min_potential_gain) {
                var g = self.patternToGoal(p, current_e);
                g.id = new_graph.next_id;
                new_graph.next_id += 1;
                try candidates.append(self.allocator, g);
            }
        }
        // 步骤 3: 继承前一时刻的目标 (保留长期目标)
        for (prev.goals.items) |pg| {
            if (pg.priority >= 7) {
                // 高优先级目标跨周期保留
                var g = pg;
                g.id = new_graph.next_id;
                new_graph.next_id += 1;
                g.priority = @intFromFloat(@as(F, @floatFromInt(g.priority)) * 0.95); // 略微衰减
                try candidates.append(self.allocator, g);
            }
        }
        // 步骤 4: 冲突消解 (论文 B.3.3 步骤 4)
        var i: usize = 0;
        while (i < candidates.items.len) {
            var j: usize = i + 1;
            while (j < candidates.items.len) {
                const c = self.conflictDegree(candidates.items[i], candidates.items[j]);
                if (c > self.conflict_threshold) {
                    // 保留 potential_gain 较大的
                    if (candidates.items[i].expected_de < candidates.items[j].expected_de) {
                        _ = candidates.orderedRemove(i);
                    } else {
                        _ = candidates.orderedRemove(j);
                    }
                    continue;
                }
                j += 1;
            }
            i += 1;
        }
        // 步骤 5: 加入到新目标图
        for (candidates.items) |g| {
            try new_graph.goals.append(self.allocator, g);
        }
        return new_graph;
    }
};

// ===== Tests =====

test "Information format" {
    const i = Information{ .id = 1, .label = "test", .features = .{ 0.5, 0.6, 0.7, 0.3 } };
    _ = i;
    // format only writes, no panic
}

test "AttentionEngine: computeEpsilon reflects E" {
    const alloc = std.testing.allocator;
    var eng = AttentionEngine.init(alloc, 42, .{});
    defer eng.deinit();
    const e_high = eng.computeEpsilon(0.9);
    const e_low = eng.computeEpsilon(0.1);
    try std.testing.expect(e_low > e_high); // 受威胁时探索率更高
}

test "AttentionEngine: attend selects K highest" {
    const alloc = std.testing.allocator;
    var eng = AttentionEngine.init(alloc, 1, .{ .k = 2 });
    defer eng.deinit();
    const infos = [_]Information{
        .{ .id = 1, .label = "a", .features = .{ 0.1, 0.1, 0.1, 0.1 } },
        .{ .id = 2, .label = "b", .features = .{ 0.9, 0.9, 0.9, 0.1 } },
        .{ .id = 3, .label = "c", .features = .{ 0.5, 0.5, 0.5, 0.1 } },
    };
    const tr = [_]F{ 0, 0, 0 };
    var res = try eng.attend(&infos, 0.5, &tr);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.selected.len);
    // b (idx=1) 应该被选
    try std.testing.expect(res.selected[0] == 1 or res.selected[1] == 1);
}

test "AttentionEngine: safety filter at low E" {
    const alloc = std.testing.allocator;
    var eng = AttentionEngine.init(alloc, 1, .{ .k = 3 });
    defer eng.deinit();
    const infos = [_]Information{
        .{ .id = 1, .label = "cheap", .features = .{ 0.5, 0.5, 0.5, 0.1 } },
        .{ .id = 2, .label = "expensive", .features = .{ 0.5, 0.5, 0.5, 0.9 } },
    };
    const tr = [_]F{ 0, 0 };
    var res = try eng.attend(&infos, 0.1, &tr); // 低 E
    defer res.deinit();
    // 高 cost 信息应被过滤
    for (res.selected) |idx| {
        try std.testing.expect(infos[idx].features[3] < 0.7);
    }
}

test "PerceptionEngine: worldGradient is finite" {
    const alloc = std.testing.allocator;
    var pe = PerceptionEngine.init(alloc, 1);
    var wm = try WorldModel.init(alloc, 5, 42);
    defer wm.deinit();
    const grad = try pe.worldGradient(&wm, 0);
    defer alloc.free(grad);
    try std.testing.expectEqual(@as(usize, 5), grad.len);
    for (grad) |g| try std.testing.expect(std.math.isFinite(g));
}

test "PerceptionEngine: compute produces valid tensor" {
    const alloc = std.testing.allocator;
    var pe = PerceptionEngine.init(alloc, 1);
    var wm = try WorldModel.init(alloc, 3, 42);
    defer wm.deinit();
    const ed: ExistenceDegree = .{};
    var wms = try CoappropriationTensor.init(alloc, 3, 3, 3);
    defer wms.deinit();
    const current = pe.currentState(ed, &wms, &wm);
    const hints = [_]struct { id: u64, de: F, focus: F }{
        .{ .id = 1, .de = 0.1, .focus = 0.5 },
        .{ .id = 2, .de = 0.2, .focus = 0.7 },
    };
    var dt = try pe.compute(current, &wm, &hints);
    defer dt.deinit();
    try std.testing.expectEqual(@as(usize, 2), dt.shape.d_g);
    try std.testing.expect(dt.energy() > 0);
}

test "TensorDecomposer: unfold modes" {
    const alloc = std.testing.allocator;
    var td = TensorDecomposer.init(alloc, 1);
    var wm = try WorldModel.init(alloc, 2, 1);
    defer wm.deinit();
    var wms = try CoappropriationTensor.init(alloc, 2, 2, 2);
    defer wms.deinit();
    const ed: ExistenceDegree = .{};
    var pe = PerceptionEngine.init(alloc, 1);
    const cur = pe.currentState(ed, &wms, &wm);
    const hints = [_]struct { id: u64, de: F, focus: F }{
        .{ .id = 1, .de = 0.1, .focus = 0.5 },
        .{ .id = 2, .de = 0.2, .focus = 0.7 },
    };
    var dt = try pe.compute(cur, &wm, &hints);
    defer dt.deinit();
    const m0 = try td.unfold(&dt, 0);
    defer alloc.free(m0);
    try std.testing.expectEqual(@as(usize, 2 * (4 * 2)), m0.len);
    const m1 = try td.unfold(&dt, 1);
    defer alloc.free(m1);
    try std.testing.expectEqual(@as(usize, 4 * (2 * 2)), m1.len);
}

test "DifferenceSetEngine: end-to-end generate" {
    const alloc = std.testing.allocator;
    var dse = DifferenceSetEngine.init(alloc, 42);
    var wm = try WorldModel.init(alloc, 4, 1);
    defer wm.deinit();
    var wms = try CoappropriationTensor.init(alloc, 3, 3, 3);
    defer wms.deinit();
    const ed: ExistenceDegree = .{};
    var pe = PerceptionEngine.init(alloc, 1);
    const cur = pe.currentState(ed, &wms, &wm);
    const hints = [_]struct { id: u64, de: F, focus: F }{
        .{ .id = 1, .de = 0.1, .focus = 0.5 },
        .{ .id = 2, .de = 0.2, .focus = 0.7 },
        .{ .id = 3, .de = 0.05, .focus = 0.3 },
    };
    var dt = try pe.compute(cur, &wm, &hints);
    defer dt.deinit();
    var prev = GoalGraph.init(alloc);
    defer prev.deinit();
    var new_g = try dse.generate(&dt, &prev, 0.3);
    defer new_g.deinit();
    try std.testing.expect(new_g.goals.items.len > 0);
}

// ===== GoalGraph DAG 测试 (论文 7.3) =====

test "GoalGraph: 加子 + ancestors + descendants" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 根 → 子 → 孙
    const root = try g.add(.enhance_existence, "root", 5, 0.1, .{ 0.1, 0, 0, 0 });
    const child1 = try g.addChild(.acquire_knowledge, "c1", 7, 0.05, .{ 0, 0.5, 0, 0 }, root);
    _ = try g.addChild(.acquire_knowledge, "c2", 6, 0.04, .{ 0, 0.4, 0, 0 }, root);
    const grandchild = try g.addChild(.explore, "gc1", 8, 0.03, .{ 0, 0, 0.3, 0 }, child1);

    try std.testing.expectEqual(@as(usize, 4), g.goals.items.len);
    try std.testing.expectEqual(@as(u32, 2), g.getPtr(root).?.children);
    try std.testing.expectEqual(@as(u32, 1), g.getPtr(child1).?.children);

    // 根的子列表
    try std.testing.expectEqual(@as(usize, 2), g.children(root).len);

    // ancestors
    const anc = try g.ancestors(grandchild, alloc);
    defer alloc.free(anc);
    try std.testing.expectEqual(@as(usize, 2), anc.len);
    try std.testing.expectEqual(child1, anc[0]);
    try std.testing.expectEqual(root, anc[1]);

    // descendants (BFS)
    const desc = try g.descendants(root, alloc);
    defer alloc.free(desc);
    try std.testing.expectEqual(@as(usize, 3), desc.len);
}

test "GoalGraph: 环检测 (自环 → 拒绝)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 直接调 wouldCreateCycle 测自环检测
    const self_loop = try g.wouldCreateCycle(5, 5);
    try std.testing.expect(self_loop);
    const no_loop = try g.wouldCreateCycle(5, 3);
    try std.testing.expect(!no_loop);
}

test "GoalGraph: topological sort 父在前" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const root = try g.add(.enhance_existence, "root", 5, 0.1, .{ 0, 0, 0, 0 });
    const c1 = try g.addChild(.acquire_knowledge, "c1", 7, 0.05, .{ 0, 0.5, 0, 0 }, root);
    _ = try g.addChild(.acquire_knowledge, "c2", 6, 0.04, .{ 0, 0.4, 0, 0 }, root);
    const gc = try g.addChild(.explore, "gc", 8, 0.03, .{ 0, 0, 0.3, 0 }, c1);

    const sorted = try g.topologicalSort(alloc);
    defer alloc.free(sorted);

    // 根 → c1 → gc → c2 是合法序 (c1 在 gc 前, c2 不依赖 c1)
    try std.testing.expectEqual(@as(usize, 4), sorted.len);
    const root_pos = indexOf(sorted, root).?;
    const c1_pos = indexOf(sorted, c1).?;
    const gc_pos = indexOf(sorted, gc).?;
    try std.testing.expect(root_pos < c1_pos);
    try std.testing.expect(c1_pos < gc_pos);
}

test "GoalGraph: cascade remove 删子孙" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const root = try g.add(.enhance_existence, "root", 5, 0.1, .{ 0, 0, 0, 0 });
    const c1 = try g.addChild(.acquire_knowledge, "c1", 7, 0.05, .{ 0, 0.5, 0, 0 }, root);
    const gc = try g.addChild(.explore, "gc", 8, 0.03, .{ 0, 0, 0.3, 0 }, c1);
    _ = gc;
    try std.testing.expectEqual(@as(usize, 3), g.goals.items.len);

    g.removeCascade(c1, true) catch {};
    try std.testing.expectEqual(@as(usize, 1), g.goals.items.len);
    try std.testing.expect(g.get(root) != null);
}

test "GoalGraph: 父子协商 (effectivePriority 父完成才返非 0)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const root = try g.add(.enhance_existence, "root", 5, 0.1, .{ 0, 0, 0, 0 });
    const c1 = try g.addChild(.acquire_knowledge, "c1", 7, 0.05, .{ 0, 0.5, 0, 0 }, root);

    // 父 priority=5, 子应该可以选
    try std.testing.expectEqual(@as(u8, 7), g.effectivePriority(c1));

    // 把父 priority 设 0 (模拟被弃用)
    g.getPtr(root).?.priority = 0;
    try std.testing.expectEqual(@as(u8, 0), g.effectivePriority(c1));
}

fn indexOf(slice: []const u64, target: u64) ?usize {
    for (slice, 0..) |v, i| if (v == target) return i;
    return null;
}

// ===== 8 关系测试 (Phase 8 数字生命实装里程碑) =====

test "GoalGraph: 8 关系 schema — 各加一种, 验证 bitmask + countDistinct" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 8 个 goal 节点, 各用一种关系
    const a = try g.add(.enhance_existence, "A:parent_child", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.acquire_knowledge, "B:sibling", 5, 0.05, .{ 0, 0.5, 0, 0 });
    const c = try g.add(.acquire_resource, "C:conflict", 5, 0.05, .{ 0, 0, 0.3, 0 });
    const d = try g.add(.maintain_boundary, "D:depends_on", 5, 0.05, .{ 0, 0, 0, 0.4 });
    const e = try g.add(.explore, "E:replaces", 5, 0.05, .{ 0, 0.2, 0, 0 });
    const f = try g.add(.symbiosis, "F:enables", 5, 0.05, .{ 0, 0, 0, 0 });
    const h = try g.add(.self_modify_params, "G:inhibits", 5, 0.05, .{ 0, 0, 0, 0 });
    const i = try g.add(.self_extend_method, "H:emerges_from", 5, 0.05, .{ 0, 0, 0, 0 });

    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = h; _ = i;

    // 注: parent_child 走 addChild, 这里只是用 .add 验证基础 goal 加进去
    // sibling 走 addRelation 互加
    try g.addRelation(2, 3, .sibling);
    try g.addRelation(3, 4, .conflict);
    try g.addRelation(4, 5, .depends_on); // D depends on E
    try g.addRelation(5, 6, .replaces); // E replaces F
    try g.addRelation(6, 7, .enables);
    try g.addRelation(7, 8, .inhibits);
    try g.addRelation(8, 2, .emerges_from);

    // 验证 distinct 关系数 = 6 (sibling/conflict/depends_on/replaces/enables/inhibits, 7 个 emerged 是 G8→G2, G2 已经有 sibling 不重复)
    const distinct: u8 = g.countDistinctRelations();
    try std.testing.expect(distinct >= 6);

    // 验证 stats
    const stats = g.relationStats();
    try std.testing.expect(stats[0] == 0); // parent_child = 0 (没用)
    try std.testing.expect(stats[1] == 1); // sibling = 1 (2 节点 ÷ 2)
    try std.testing.expect(stats[2] == 1); // conflict = 1
    try std.testing.expect(stats[3] == 1); // depends_on
    try std.testing.expect(stats[4] == 1); // replaces
    try std.testing.expect(stats[5] == 1); // enables
    try std.testing.expect(stats[6] == 1); // inhibits
    try std.testing.expect(stats[7] == 1); // emerges_from
}

test "GoalGraph: relationsBitmask 单 goal 多关系" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 1 父 + 2 子
    const pid = try g.add(.enhance_existence, "p", 5, 0.1, .{ 0, 0, 0, 0 });
    const cid1 = try g.addChild(.explore, "c1", 5, 0.05, .{ 0, 0.5, 0, 0 }, pid);
    const cid2 = try g.addChild(.acquire_knowledge, "c2", 5, 0.04, .{ 0, 0.4, 0, 0 }, pid);

    // c1 同时有 4 种关系
    try g.addRelation(cid1, cid2, .sibling);
    try g.addRelation(cid1, pid, .depends_on);
    try g.addRelation(cid1, cid2, .conflict);
    // 注: enables 是单向 pid→cid1, 所以 pid 的 enables 字段有 cid1, 但 cid1 自己的 enables 字段空
    // 这里改成 cid1 主动启用 cid2 来让 cid1 的 enables bit 也亮
    try g.addRelation(cid1, cid2, .enables);

    // 验证 c1 bitmask 至少 5 位 (parent_child + sibling + depends_on + conflict + enables)
    if (g.getPtr(cid1)) |c1| {
        const mask = c1.relationsBitmask();
        try std.testing.expect((mask & std.math.shl(u16, 1, @intFromEnum(GoalRelation.parent_child))) != 0);
        try std.testing.expect((mask & std.math.shl(u16, 1, @intFromEnum(GoalRelation.sibling))) != 0);
        try std.testing.expect((mask & std.math.shl(u16, 1, @intFromEnum(GoalRelation.conflict))) != 0);
        try std.testing.expect((mask & std.math.shl(u16, 1, @intFromEnum(GoalRelation.depends_on))) != 0);
        try std.testing.expect((mask & std.math.shl(u16, 1, @intFromEnum(GoalRelation.enables))) != 0);
    } else {
        return error.GoalNotFound;
    }
}

test "GoalGraph: relationsSummary 格式化" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const a = try g.add(.enhance_existence, "a", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.explore, "b", 5, 0.05, .{ 0, 0, 0, 0 });
    const c = try g.add(.acquire_knowledge, "c", 5, 0.05, .{ 0, 0, 0, 0 });

    try g.addRelation(a, b, .sibling);
    try g.addRelation(b, c, .conflict);

    const summary = try g.relationsSummary(alloc);
    defer alloc.free(summary);

    // 应该包含 "sibling:1" 和 "conflict:1"
    try std.testing.expect(std.mem.indexOf(u8, summary, "sibling") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "conflict") != null);
}

test "GoalGraph: 同一关系去重 (addRelation 重复调用不重复加)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const a = try g.add(.enhance_existence, "a", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.explore, "b", 5, 0.05, .{ 0, 0, 0, 0 });

    // 重复 sibling
    try g.addRelation(a, b, .sibling);
    try g.addRelation(a, b, .sibling);
    try g.addRelation(a, b, .sibling);

    // 不应该有 3 个 sibling
    if (g.getPtr(a)) |ap| {
        try std.testing.expectEqual(@as(usize, 1), ap.siblings.items.len);
    }
}

test "GoalGraph: 自环拒绝 (a==b 报错)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const a = try g.add(.enhance_existence, "a", 5, 0.1, .{ 0, 0, 0, 0 });
    // 自环应报错
    const result = g.addRelation(a, a, .conflict);
    try std.testing.expectError(error.SelfRelation, result);
}

// ===== 9 关系 + 拓扑排序测试 =====

test "GoalGraph: 9 关系 (emerges_after 时间涌现)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 4 个 goal 节点, 用 4 种关系覆盖 schema
    const a = try g.add(.enhance_existence, "A", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.acquire_knowledge, "B", 5, 0.05, .{ 0, 0.5, 0, 0 });
    const c = try g.add(.explore, "C", 5, 0.05, .{ 0, 0, 0.3, 0 });
    const d = try g.add(.maintain_boundary, "D", 5, 0.05, .{ 0, 0, 0, 0.4 });

    // A.emerges_after = [B] → A 等 B 完成后 Δt 才能开始
    try g.addRelation(a, b, .emerges_after);
    // C.emerges_from = [A, B] → C 由 A + B 共同 enable
    try g.addRelation(c, a, .emerges_from);
    try g.addRelation(c, b, .emerges_from);
    // D.conflict A (双向)
    try g.addRelation(d, a, .conflict);

    // 验证
    if (g.getPtr(a)) |g_a| {
        try std.testing.expectEqual(@as(usize, 1), g_a.emerges_after.items.len);
        try std.testing.expectEqual(@as(u64, b), g_a.emerges_after.items[0]);
    }
    if (g.getPtr(c)) |g_c| {
        try std.testing.expectEqual(@as(usize, 2), g_c.emerges_from.items.len);
    }

    // 验证 9 关系 bitmask (c 用 parent_child=0, sibling=0, conflict=0, depends=0, replaces=0, enables=0, inhibits=0, emerges_from=1, emerges_after=0)
    // 不, c 是 goal 4 中的 1, has no parent, no others — c 用 emerges_from
    // distinct >= 2 (emerges_from + emerges_after)
    const distinct = g.countDistinctRelations();
    try std.testing.expect(distinct >= 2);

    // stats[8] = emerges_after 边数
    const stats = g.relationStats();
    try std.testing.expectEqual(@as(u32, 1), stats[8]); // emerges_after = 1
    try std.testing.expectEqual(@as(u32, 2), stats[7]); // emerges_from = 2
    try std.testing.expectEqual(@as(u32, 1), stats[2]); // conflict = 1
}

test "GoalGraph: 拓扑排序考虑 parent + depends_on + emerges_after" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 3 个节点: A (依赖 B, 时间涌现 C), B (父 of A 不可), C
    // 简化: A depends_on B + A emerges_after C, B 跟 C 无关系
    // 期望拓扑序: [B, C, A] (A 在最后)
    const a = try g.add(.enhance_existence, "A", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.acquire_knowledge, "B", 5, 0.05, .{ 0, 0.5, 0, 0 });
    const c = try g.add(.explore, "C", 5, 0.05, .{ 0, 0, 0.3, 0 });

    try g.addRelation(a, b, .depends_on);
    try g.addRelation(a, c, .emerges_after);

    const sorted = try g.topologicalSort(alloc);
    defer alloc.free(sorted);

    // A 必须在 B 跟 C 之后
    const a_pos = std.mem.indexOf(u64, sorted, &[_]u64{a}).?;
    const b_pos = std.mem.indexOf(u64, sorted, &[_]u64{b}).?;
    const c_pos = std.mem.indexOf(u64, sorted, &[_]u64{c}).?;
    try std.testing.expect(b_pos < a_pos); // B before A
    try std.testing.expect(c_pos < a_pos); // C before A
    // B 跟 C 是 sibling, 顺序无关
    try std.testing.expect(sorted.len == 3);
}

test "GoalGraph: 拓扑排序带 parent_child + depends_on + emerges_after 混合" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    // 父 p → 子 c1, c2
    // c2.depends_on = [c1]
    // c1.emerges_after = [p] (p 完成后 c1 才能)
    // 期望: p → c1 → c2 (c1 在 c2 前, 都在 p 后)
    const p = try g.add(.enhance_existence, "p", 5, 0.1, .{ 0, 0, 0, 0 });
    const c1 = try g.addChild(.acquire_knowledge, "c1", 5, 0.05, .{ 0, 0.5, 0, 0 }, p);
    const c2 = try g.addChild(.explore, "c2", 5, 0.05, .{ 0, 0, 0.3, 0 }, p);

    try g.addRelation(c2, c1, .depends_on);
    try g.addRelation(c1, p, .emerges_after);

    const sorted = try g.topologicalSort(alloc);
    defer alloc.free(sorted);

    // 找位置
    const p_pos = std.mem.indexOf(u64, sorted, &[_]u64{p}).?;
    const c1_pos = std.mem.indexOf(u64, sorted, &[_]u64{c1}).?;
    const c2_pos = std.mem.indexOf(u64, sorted, &[_]u64{c2}).?;

    try std.testing.expect(p_pos < c1_pos);
    try std.testing.expect(p_pos < c2_pos);
    try std.testing.expect(c1_pos < c2_pos); // c2 depends on c1
}

test "GoalGraph: 环检测 (depends_on 形成环 → 报错)" {
    const alloc = std.testing.allocator;
    var g = GoalGraph.init(alloc);
    defer g.deinit();

    const a = try g.add(.enhance_existence, "a", 5, 0.1, .{ 0, 0, 0, 0 });
    const b = try g.add(.acquire_knowledge, "b", 5, 0.05, .{ 0, 0.5, 0, 0 });

    try g.addRelation(a, b, .depends_on);
    try g.addRelation(b, a, .depends_on); // 形成环

    const result = g.topologicalSort(alloc);
    try std.testing.expectError(error.CycleDetected, result);
}
