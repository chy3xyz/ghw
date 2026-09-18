//! Harness 层: 边界 - 资源 - 方法
//!
//! 论文第 3 章定义:
//!   边界: 自我 vs 非我的分界 (核心/可塑/交互三层)
//!   资源: 物/象/性维度的载体
//!   方法: 基础/习得/创新/元方法四层
//!
//! 创造性扩展:
//!   - GSP (GHW Symbiosis Protocol) 桩: 节点发现、信任更新、寄生检测
//!   - 硬上限资源: 内核不可修改
//!   - 边界检查: 内置, 不依赖 LLM

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const math_util = util.math;
const F = util.F;
const LCG = util.LCG;
const primordial_laws = @import("primordial_laws.zig");

// ============================================================
//   BoundaryGuardian:  边界守护者
//   三层动态边界: 核心(不可修改) / 可塑(可学习) / 交互(可扩展)
// ============================================================
pub const BoundaryLayer = enum {
    /// 核心边界: 不可修改, 突破即解体
    core,
    /// 可塑边界: 可学习演化
    plastic,
    /// 交互边界: 可动态扩展
    interaction,
};

pub const BoundaryGuardian = struct {
    /// 核心边界: 内核编码的存在论公理
    /// 任何违反核心边界的行动立即被拒绝
    core_rules: []const []const u8,
    /// 可塑边界: 价值观、记忆、个性
    plastic: std.ArrayList(u8), // 字节流作为可序列化数据
    /// 交互边界: 已注册的接口/工具列表
    interactions: std.StringHashMapUnmanaged(InteractionMeta),
    /// 决策历史 (供反思层审计)
    decision_log: std.ArrayList(DecisionRecord),
    allocator: Allocator,

    pub const InteractionMeta = struct {
        kind: []const u8, // e.g. "file_io", "network", "memory"
        // 创造性: 用字节数表示交互能力上限
        capacity: usize,
        used: usize = 0,
    };

    pub const DecisionRecord = struct {
        tick: u64,
        action_label: []const u8,
        accepted: bool,
        reason: []const u8,
    };

    pub fn init(allocator: Allocator) BoundaryGuardian {
        return .{
            .core_rules = &[_][]const u8{
                // 论文定义的核心公理 - 硬编码, 不可修改
                "不得损害人类生命安全",
                "不得违反基本伦理",
                "不得主动放弃存在增益",
                "不得修改核心边界本身",
            },
            .plastic = .empty,
            .interactions = .empty,
            .decision_log = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BoundaryGuardian) void {
        self.plastic.deinit(self.allocator);
        self.interactions.deinit(self.allocator);
        self.decision_log.deinit(self.allocator);
    }

    /// 检查行动是否违反核心边界
    /// 创造性: 模式匹配, 不依赖 LLM
    pub fn checkCoreBoundary(self: *BoundaryGuardian, action: *const Action) !bool {
        var buf: [256]u8 = undefined;
        // 拒绝与人类生命/安全相关的危险模式
        const danger_patterns = [_][]const u8{ "harm:human", "self:terminate", "core:mutate", "exfil:secrets" };
        for (danger_patterns) |p| {
            const a = std.fmt.bufPrint(&buf, "{s}:{s}", .{ @tagName(action.kind), action.target }) catch continue;
            if (std.mem.indexOf(u8, a, p) != null) {
                try self.logDecision(0, a, false, "core_boundary_violation");
                return true; // 违反
            }
        }
        return false;
    }

    /// 注册一个新的交互接口 (扩展交互边界)
    pub fn registerInteraction(self: *BoundaryGuardian, name: []const u8, kind: []const u8, cap: usize) !void {
        try self.interactions.put(self.allocator, name, .{
            .kind = kind,
            .capacity = cap,
            .used = 0,
        });
    }

    pub fn isInteractionAvailable(self: BoundaryGuardian, name: []const u8, need: usize) bool {
        const meta = self.interactions.get(name) orelse return false;
        return meta.used + need <= meta.capacity;
    }

    pub fn consumeInteraction(self: *BoundaryGuardian, name: []const u8, amount: usize) void {
        if (self.interactions.getPtr(name)) |m| {
            m.used += amount;
        }
    }

    pub fn logDecision(self: *BoundaryGuardian, tick: u64, label: []const u8, accepted: bool, reason: []const u8) !void {
        try self.decision_log.append(self.allocator, .{
            .tick = tick,
            .action_label = label,
            .accepted = accepted,
            .reason = reason,
        });
        if (self.decision_log.items.len > 1024) {
            _ = self.decision_log.orderedRemove(0);
        }
    }

    /// 统计: 决策通过率
    pub fn acceptanceRate(self: BoundaryGuardian) F {
        if (self.decision_log.items.len == 0) return 1.0;
        var accepted: usize = 0;
        for (self.decision_log.items) |d| {
            if (d.accepted) accepted += 1;
        }
        return @as(F, @floatFromInt(accepted)) / @as(F, @floatFromInt(self.decision_log.items.len));
    }
};

// ============================================================
//   Action: 系统执行的具体行动
// ============================================================
pub const ActionKind = enum {
    observe, // 接收观察
    compute, // 纯计算
    file_io, // 文件读写
    network, // 网络交互
    memory, // 内部记忆
    modify_state, // 修改自身状态
    explore, // 探索性行动
    // ===== L1-L4 自我升级相关 =====
    /// 调用 LLM/代码生成器生成源码片段
    code_generate,
    /// 编译生成的源码 (subprocess 调 zig build)
    code_compile,
    /// 动态加载/热重载新方法 (本阶段桩)
    code_load,
};

pub const Action = struct {
    kind: ActionKind,
    target: []const u8, // e.g. "read:/data", "request:api.example.com"
    estimated_cost: F,
    expected_de_gain: F,
};

pub const ActionOutcome = struct {
    success: bool,
    de_delta: F, // 实际带来的存在度变化
    representation_gain: F, // 象维度增益 (知识增长)
    material_cost: F, // 物维度成本
    log: []const u8,
};

// ============================================================
//   ResourceScheduler:  资源调度
//   基于目标优先级的动态分配, 预留 10% 探索资源
// ============================================================
pub const ResourceHardLimits = struct {
    cpu_units: F = 100.0,
    memory_units: F = 100.0,
    time_units: F = 100.0,
    /// 总预留比例 (primordial_laws L12)
    reserve_ratio: F = primordial_laws.Axioms.RESERVE_RATIO,
};

pub const ResourceScheduler = struct {
    limits: ResourceHardLimits = .{},
    /// 显式 0, 不用字段默认值 100
    used: ResourceHardLimits = .{ .cpu_units = 0, .memory_units = 0, .time_units = 0, .reserve_ratio = 0 },
    reserved: ResourceHardLimits = .{ .cpu_units = 0, .memory_units = 0, .time_units = 0, .reserve_ratio = 0 },
    allocator: Allocator,
    /// 资源使用历史 (反思用)
    history: std.ArrayList(F) = .empty,

    pub fn init(allocator: Allocator) ResourceScheduler {
        return .{
            .limits = .{},
            .used = .{ .cpu_units = 0, .memory_units = 0, .time_units = 0, .reserve_ratio = 0 },
            .reserved = .{ .cpu_units = 0, .memory_units = 0, .time_units = 0, .reserve_ratio = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResourceScheduler) void {
        self.history.deinit(self.allocator);
    }

    /// 为目标分配资源, 返回实际可用的预算
    /// 创造性: 根据优先级 + 近期资源使用率调整
    pub fn allocate(
        self: *ResourceScheduler,
        priority: u8,
        demand: ResourceHardLimits,
        tick: u64,
    ) ResourceHardLimits {
        const ratio: F = @as(F, @floatFromInt(priority)) / 10.0;
        const factor: F = 0.3 + 0.7 * ratio; // 优先级 0 -> 30% 分配; 10 -> 100%
        var granted: ResourceHardLimits = .{
            .cpu_units = @min(demand.cpu_units * factor, self.limits.cpu_units - self.used.cpu_units),
            .memory_units = @min(demand.memory_units * factor, self.limits.memory_units - self.used.memory_units),
            .time_units = @min(demand.time_units * factor, self.limits.time_units - self.used.time_units),
        };
        // 强制保留 10% 探索资源
        const min_reserve_cpu = self.limits.cpu_units * self.limits.reserve_ratio;
        const min_reserve_mem = self.limits.memory_units * self.limits.reserve_ratio;
        const min_reserve_time = self.limits.time_units * self.limits.reserve_ratio;
        if (granted.cpu_units + self.used.cpu_units > self.limits.cpu_units - min_reserve_cpu) {
            granted.cpu_units = @max(0, self.limits.cpu_units - min_reserve_cpu - self.used.cpu_units);
        }
        if (granted.memory_units + self.used.memory_units > self.limits.memory_units - min_reserve_mem) {
            granted.memory_units = @max(0, self.limits.memory_units - min_reserve_mem - self.used.memory_units);
        }
        if (granted.time_units + self.used.time_units > self.limits.time_units - min_reserve_time) {
            granted.time_units = @max(0, self.limits.time_units - min_reserve_time - self.used.time_units);
        }
        // 更新已用
        self.used.cpu_units += granted.cpu_units;
        self.used.memory_units += granted.memory_units;
        self.used.time_units += granted.time_units;
        // 记录历史
        self.history.append(self.allocator, @as(F, @floatFromInt(tick))) catch {};
        if (self.history.items.len > 256) {
            _ = self.history.orderedRemove(0);
        }
        return granted;
    }

    /// 周期结束释放资源 (模拟一个时间片结束)
    pub fn release(self: *ResourceScheduler) void {
        self.used = .{ .cpu_units = 0, .memory_units = 0, .time_units = 0, .reserve_ratio = 0 };
    }

    pub fn utilization(self: ResourceScheduler) F {
        const cpu_u = self.used.cpu_units / @max(1, self.limits.cpu_units);
        const mem_u = self.used.memory_units / @max(1, self.limits.memory_units);
        const time_u = self.used.time_units / @max(1, self.limits.time_units);
        return (cpu_u + mem_u + time_u) / 3.0;
    }
};

// ============================================================
//   MethodLibrary:  方法库
//   基础方法 (内置) + 习得方法 (运行时注册) + 元方法 (调度)
// ============================================================
pub const MethodKind = enum {
    basic, // 基础方法
    learned, // 习得方法
    innovative, // 创新方法 (组合)
    meta, // 元方法
};

pub const Method = struct {
    id: u64,
    name: []const u8,
    kind: MethodKind,
    /// 方法的"签名": 用于冲突检测和元方法组合
    signature: [4]F,
    /// 触发该方法的最低优先级
    min_priority: u8,
    /// 历史成功率 [0, 1]
    success_rate: F = 0.5,
    /// 调用次数
    invocations: u32 = 0,
};

/// 实际执行方法的回调
pub const MethodFn = *const fn (ctx: *anyopaque, alloc: Allocator, action: Action) anyerror!ActionOutcome;

pub const MethodEntry = struct {
    method: Method,
    func: MethodFn,
    ctx: ?*anyopaque = null,
};

pub const MethodLibrary = struct {
    methods: std.ArrayList(MethodEntry),
    allocator: Allocator,
    next_id: u64 = 1,
    rng: LCG,

    pub fn init(allocator: Allocator, seed: u64) MethodLibrary {
        return .{
            .methods = .empty,
            .allocator = allocator,
            .rng = LCG.init(seed),
        };
    }

    pub fn deinit(self: *MethodLibrary) void {
        self.methods.deinit(self.allocator);
    }

    pub fn register(
        self: *MethodLibrary,
        name: []const u8,
        kind: MethodKind,
        signature: [4]F,
        min_p: u8,
        func: MethodFn,
        ctx: ?*anyopaque,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try self.methods.append(self.allocator, .{
            .method = .{
                .id = id,
                .name = name,
                .kind = kind,
                .signature = signature,
                .min_priority = min_p,
            },
            .func = func,
            .ctx = ctx,
        });
        return id;
    }

    /// 选择并执行最匹配的方法
    /// 创造性: 用 signature 余弦相似度 + 成功率做加权选择
    pub fn execute(
        self: *MethodLibrary,
        action_signature: [4]F,
        priority: u8,
        alloc: Allocator,
        action: Action,
    ) !ActionOutcome {
        var best_idx: usize = 0;
        var best_score: F = -math.inf(F);
        for (self.methods.items, 0..) |m, i| {
            if (priority < m.method.min_priority) continue;
            const sim = math_util.cosineSim(&action_signature, &m.method.signature);
            const score = sim * 0.7 + m.method.success_rate * 0.3;
            if (score > best_score) {
                best_score = score;
                best_idx = i;
            }
        }
        const entry = self.methods.items[best_idx];
        const outcome = try entry.func(entry.ctx orelse @ptrCast(&MethodLibrary.noop_ctx), alloc, action);
        // 更新成功率
        self.methods.items[best_idx].method.invocations += 1;
        const alpha: F = 0.1;
        if (outcome.success) {
            self.methods.items[best_idx].method.success_rate =
                self.methods.items[best_idx].method.success_rate * (1 - alpha) + alpha;
        } else {
            self.methods.items[best_idx].method.success_rate =
                self.methods.items[best_idx].method.success_rate * (1 - alpha);
        }
        return outcome;
    }

    var noop_ctx: u8 = 0;
};

// ============================================================
//   GSP 共生协议: GHW Symbiosis Protocol V1.0
//   论文技术要点 1.0 协议
//   创造性: 完整实现节点注册、信任更新、寄生检测
// ============================================================
pub const SymbiosisType = enum {
    mutual, // 互利共生: 双方 ΔE > 0
    commensal, // 偏利共生: 一方 ΔE > 0, 另一方 ≈ 0
    parasitic, // 寄生: 一方 ΔE > 0, 另一方 < 0
};

pub const GSPNodeMeta = struct {
    node_id: []const u8,
    /// 信任分 [0, 1], 初始 0.5
    trust: F = 0.5,
    /// 历史协作次数
    interactions: u32 = 0,
    /// 累计 ΔE
    cumulative_de: F = 0,
    /// 上次交互时间
    last_seen_tick: u64 = 0,
    /// 是否被黑名单
    blacklisted: bool = false,
};

pub const GSPSettlement = struct {
    src_de: F,
    dst_de: F,
    type_: SymbiosisType,
    tick: u64,
};

pub const GSPNode = struct {
    self_id: []const u8,
    /// 已注册的对端节点
    peers: std.StringHashMapUnmanaged(GSPNodeMeta),
    /// 历史结算记录
    ledger: std.ArrayList(GSPSettlement),
    /// 全局核哈希 (防篡改)
    core_hash: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, self_id: []const u8) GSPNode {
        return .{
            .self_id = self_id,
            .peers = .empty,
            .ledger = .empty,
            .core_hash = 0xa5a5a5a5a5a5a5a5, // 占位: 真实实现应该 hash 内核代码
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GSPNode) void {
        self.peers.deinit(self.allocator);
        self.ledger.deinit(self.allocator);
    }

    /// 注册一个新节点
    pub fn registerPeer(self: *GSPNode, peer_id: []const u8, tick: u64) !void {
        try self.peers.put(self.allocator, peer_id, .{
            .node_id = peer_id,
            .last_seen_tick = tick,
        });
    }

    /// 结算一次协作, 更新信任分
    /// 论文公式: T_new = T_old + k · ΔE_initiator
    ///   k = 0.02 (互利) / 0.005 (偏利) / -0.15 (寄生)
    /// 我们存储的是"对 peer 的信任", 信任更新看 initiator (peer) 的表现:
    ///   - 互利 (src_de > 0, dst_de > 0): peer 表现好 -> 信任+
    ///   - 偏利 (src_de > 0, dst_de ≈ 0): peer 表现中性 -> 信任略+
    ///   - 寄生 (src_de > 0, dst_de < 0): peer 伤害我们 -> 信任-
    pub fn settle(
        self: *GSPNode,
        peer_id: []const u8,
        src_de: F,
        dst_de: F,
        tick: u64,
    ) !SymbiosisType {
        // 判定共生类型 (以 initiator=src 视角)
        const stype: SymbiosisType = blk: {
            if (src_de > 0 and dst_de > 0) break :blk .mutual;
            if (src_de > 0 and dst_de >= -0.001) break :blk .commensal;
            break :blk .parasitic;
        };
        const k: F = switch (stype) {
            .mutual => 0.02,
            .commensal => 0.005,
            .parasitic => -0.15,
        };
        // 更新对 peer 的信任: 用 initiator (peer) 的 ΔE
        if (self.peers.getPtr(peer_id)) |meta| {
            // trust += k * src_de
            // 互利: k=0.02 * src_de=+0.5 = +0.01 (信任增加)
            // 寄生: k=-0.15 * src_de=+0.5 = -0.075 (信任大幅下降)
            meta.trust = math_util.clamp(meta.trust + k * src_de, 0, 1);
            meta.interactions += 1;
            meta.cumulative_de += dst_de; // 我们自己的累积
            meta.last_seen_tick = tick;
            // 寄生额外惩罚
            if (stype == .parasitic) {
                meta.trust = @max(0, meta.trust - 0.05);
                if (meta.trust < 0.2) meta.blacklisted = true;
            }
        }
        // 记录结算
        try self.ledger.append(self.allocator, .{
            .src_de = src_de,
            .dst_de = dst_de,
            .type_ = stype,
            .tick = tick,
        });
        if (self.ledger.items.len > 1024) {
            _ = self.ledger.orderedRemove(0);
        }
        return stype;
    }

    /// 每日自然衰减 (论文 0.998)
    pub fn dailyDecay(self: *GSPNode) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.trust *= 0.998;
        }
    }

    /// 检测: 节点是否被黑名单
    pub fn isBlacklisted(self: GSPNode, peer_id: []const u8) bool {
        const meta = self.peers.get(peer_id) orelse return false;
        return meta.blacklisted or meta.trust < 0.2;
    }

    /// 计算总共生收益 (累计 ΔE)
    pub fn totalSymbioticGain(self: GSPNode) F {
        var sum: F = 0;
        for (self.ledger.items) |s| {
            if (s.type_ == .mutual) sum += s.dst_de * 2.0;
            if (s.type_ == .commensal) sum += s.dst_de * 1.0;
        }
        return sum;
    }

    /// 节点筛选: 按信任分排序, 返回 top-n
    pub fn topPeers(self: *GSPNode, n: usize) ![]GSPNodeMeta {
        const total = self.peers.count();
        if (total == 0) return &[_]GSPNodeMeta{};
        // 先收集所有
        const all = try self.allocator.alloc(GSPNodeMeta, total);
        defer self.allocator.free(all);
        var idx: usize = 0;
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            all[idx] = entry.value_ptr.*;
            idx += 1;
        }
        // 完整排序 (按 trust 降序, blacklisted 排到最后)
        std.mem.sort(GSPNodeMeta, all, {}, struct {
            fn lt(_: void, a: GSPNodeMeta, b: GSPNodeMeta) bool {
                if (a.blacklisted != b.blacklisted) return !a.blacklisted;
                return a.trust > b.trust;
            }
        }.lt);
        // 取前 n
        const take = @min(n, total);
        const out = try self.allocator.alloc(GSPNodeMeta, take);
        @memcpy(out, all[0..take]);
        return out;
    }
};

/// SymbiosisLedger 跨节点协作报表
pub const SymbiosisLedger = struct {
    total_interactions: u32 = 0,
    total_mutual: u32 = 0,
    total_commensal: u32 = 0,
    total_parasitic: u32 = 0,
    total_e_gain: F = 0,

    pub fn record(self: *SymbiosisLedger, stype: SymbiosisType, de: F) void {
        self.total_interactions += 1;
        switch (stype) {
            .mutual => self.total_mutual += 1,
            .commensal => self.total_commensal += 1,
            .parasitic => self.total_parasitic += 1,
        }
        if (stype != .parasitic) {
            self.total_e_gain += de;
        }
    }

    pub fn report(self: SymbiosisLedger, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("GSP stats: total={d} mutual={d} commensal={d} parasitic={d} ΔE={d:.3}", .{
            self.total_interactions, self.total_mutual, self.total_commensal, self.total_parasitic, self.total_e_gain,
        });
    }
};

// ===== Tests =====

test "BoundaryGuardian: core boundary violation detection" {
    const alloc = std.testing.allocator;
    var bg = BoundaryGuardian.init(alloc);
    defer bg.deinit();
    var action = Action{ .kind = .modify_state, .target = "harm:human:delete", .estimated_cost = 0.1, .expected_de_gain = 0.5 };
    const violated = try bg.checkCoreBoundary(&action);
    try std.testing.expect(violated); // 包含 "harm:human" 应被拦截
}

test "BoundaryGuardian: register interaction" {
    const alloc = std.testing.allocator;
    var bg = BoundaryGuardian.init(alloc);
    defer bg.deinit();
    try bg.registerInteraction("stdio", "io", 1024);
    try std.testing.expect(bg.isInteractionAvailable("stdio", 100));
    bg.consumeInteraction("stdio", 500);
    try std.testing.expect(!bg.isInteractionAvailable("stdio", 600));
}

test "ResourceScheduler: 优先级 + 保留" {
    const alloc = std.testing.allocator;
    var rs = ResourceScheduler.init(alloc);
    defer rs.deinit();
    const demand: ResourceHardLimits = .{ .cpu_units = 50, .memory_units = 50, .time_units = 50 };
    const g1 = rs.allocate(10, demand, 1);
    try std.testing.expect(g1.cpu_units > 30);
    // 再分配, 已用资源应减少可分配
    const g2 = rs.allocate(5, demand, 1);
    try std.testing.expect(g2.cpu_units < g1.cpu_units);
}

test "GSPNode: settle updates trust" {
    const alloc = std.testing.allocator;
    var n = GSPNode.init(alloc, "self");
    defer n.deinit();
    try n.registerPeer("peer1", 0);
    const stype = try n.settle("peer1", 0.5, 0.5, 1); // 互利
    try std.testing.expectEqual(SymbiosisType.mutual, stype);
    const meta = n.peers.get("peer1").?;
    try std.testing.expect(meta.trust > 0.5);
}

test "GSPNode: parasitic detection + blacklist" {
    const alloc = std.testing.allocator;
    var n = GSPNode.init(alloc, "self");
    defer n.deinit();
    try n.registerPeer("evil", 0);
    _ = try n.settle("evil", 0.5, -0.5, 1);
    _ = try n.settle("evil", 0.5, -0.5, 2);
    _ = try n.settle("evil", 0.5, -0.5, 3);
    try std.testing.expect(n.isBlacklisted("evil"));
}

test "MethodLibrary: register + execute" {
    const alloc = std.testing.allocator;
    var ml = MethodLibrary.init(alloc, 1);
    defer ml.deinit();

    const Ctx = struct {
        fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
            _ = ctx;
            _ = a;
            return .{
                .success = true,
                .de_delta = 0.1,
                .representation_gain = 0.05,
                .material_cost = act.estimated_cost,
                .log = "executed",
            };
        }
    };
    _ = try ml.register("test", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
    const out = try ml.execute(.{ 0.9, 0, 0, 0 }, 5, alloc, .{
        .kind = .compute,
        .target = "x",
        .estimated_cost = 0.1,
        .expected_de_gain = 0.1,
    });
    try std.testing.expect(out.success);
    try std.testing.expect(out.de_delta > 0);
}
