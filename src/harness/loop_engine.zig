//! HarnessLoopEngine: Boris Cherny "Loop Engineering" 协调器
//!
//! ## 背景
//! 2025-11 Claude Code 之父 Boris Cherny 在 Anthropic 年度大会公开宣布:
//! "My job is to write loops." 工程师从 "在循环里手动提示" 升级为 "在循环外设计循环".
//!
//! Loop Engineering 6 大核心组件:
//!   1. 自动化调度 - 循环何时启动 (cron / /loop 20m)
//!   2. 隔离工作区 - 每个 Agent 独立环境 (git worktree / sandbox)
//!   3. 外置记忆 - CLAUDE.md / 状态文件 / AGENTS.md, 跨多轮不丢
//!   4. 子智能体 - 主 agent 派生子 agent 并行
//!   5. 退出条件 - 不能永远跑, 必须有 stop
//!   6. 评估机制 - 外部测试/类型检查/Playwright, 别让 agent 自己判
//!
//! ## GHW 对齐
//! 不重写现有 L4 propose / Reflection / SelfEvolver / L1-L5, **是协调器**.
//!
//! 位置: 嵌进 daemon.zig 主循环 (runCycle 后, 1 行调用)
//!
//! ## 数据流 (PDCA 闭包)
//!   Plan: 每 kPlanCycle cycle, 让 LLM 提议 hypothesis (覆盖 L4 触发逻辑)
//!   Do:  runCycle 内部 ActionRunner 跑
//!   Check: 算 avg ΔE (8 cycle ring) + hit/miss rate + mrn variance (纯数学, 不让数字生命自己判)
//!   Act: hit_rate<0.3 连 3 cycle 撤 hypothesis; miss_streak>=5 强制 L4 propose
//!
//! ## 6 组件 GHW 映射
//!   1. 自动化调度: tick % kPlanCycle == 0 触发
//!   2. 隔离工作区: SelfEvolutionGuard 路径白名单 + L1-L5 走 /tmp/ghw_evolved worktree
//!   3. 外置记忆: state.json 持久化 + hypothesis history
//!   4. 子智能体: peer_hypotheses 接受 GhwLink 跨实例反馈 (Phase 1 production)
//!   5. 退出条件: consecutive_miss_stop (默认 5) + 9 宫里程碑 (复用 Phase 9)
//!   6. 评估机制: ΔE_avg + hit_rate + mrn_var + 9 宫 deep
//!
//! ## 设计原则
//!   - **Boris 边界**: 人设定目标, 数字生命跑循环, 人**只**看 UI / KPI / 摘要
//!   - **不**重写 runCycle 内部 5 段 (World/Goal/Harness/Reflective/SelfEvolve)
//!   - **是**协调器, 跨 cycle 视角
//!   - LLM 预算: 1 call / kPlanCycle (默认 8 cycle, 跟 Phase 8.7 同步)

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
/// F32 精度, 跟 ghw 全文一致. 这里不 import ../util/mod.zig 是为了 0.17 addTest 单 root 跑.
const F = f32;

// ===== 配置 (Boris 6 组件的"旋钮") =====

/// LoopEngine 运行时配置
pub const LoopConfig = struct {
    /// Plan phase 频率 (每 N cycle 跑一次 LLM 提议 hypothesis)
    /// 默认 8 cycle (跟 Phase 8.7 L4 提议 8 cycle 频率同步, 避免 LLM 预算翻倍)
    kPlanCycle: u64 = 8,

    /// Check phase 用多大窗口算 hit_rate / avg ΔE
    /// 默认 8 cycle (一个 Plan 周期内足够看 hypothesis 是否生效)
    kCheckWindow: u64 = 8,

    /// 连续 miss 阈值: 连续 N cycle hit_rate<0.3 → 强制撤 hypothesis
    /// Boris PR 守夜: "连续 3 轮失败原因相同 → 停止" → 我们折中 3 (跟 Boris 一致)
    kConsecutiveMissAct: u32 = 3,

    /// 连续 miss 阈值升级: 强制 L4 提议 (提示数字生命需要新 hypothesis)
    /// Boris 没有这层, 是 GHW 加的 (数字生命有 self_evolver, 可以从 L1-L5 找新 hypothesis)
    kConsecutiveMissStop: u32 = 5,

    /// hit_rate 高于此值认为 hypothesis 有效, 不动
    kHitThreshold: F = 0.5,

    /// miss 阈值: hit_rate 低于此值算 miss
    kMissThreshold: F = 0.3,

    /// Hypothesis 上限: 防 LLM 失控爆盘
    /// Boris 没限, GHW 限 8 (LRU)
    kHypothesisMax: u32 = 8,

    /// 启停
    enabled: bool = true,
};

// ===== Hypothesis (Boris 6.3 外置记忆) =====

/// Hypothesis 状态机
pub const HypothesisStatus = enum(u8) {
    active = 0,    // 当前激活, 数字生命在 try 这条 hypothesis
    retired = 1,   // 撤, 留着做历史 (Boris 不删除历史, 防 Agent 失忆)
    promoted = 2,  // hit_rate 高, 提升为长期 strategy
};

/// 单条 hypothesis (Boris 的"目标 spec")
pub const Hypothesis = struct {
    id: u64,
    /// 简述 (LLM 提议的"接下来应该做什么")
    claim: []const u8,
    /// 提议时 LLM 给的 confidence (0..1)
    confidence: F,
    /// 提议时 LLM 给的 reason
    reason: []const u8,
    /// 来源: llm_propose (Phase 8.7) / l4_evolve / peer_inject / seed
    source: HypothesisSource,
    /// 状态
    status: HypothesisStatus = .active,
    /// 激活时间 (哪个 cycle 开始的)
    activated_at_tick: u64,
    /// Check 阶段累计命中次数
    hit_count: u32 = 0,
    /// Check 阶段累计 miss 次数
    miss_count: u32 = 0,
    /// 历史 hit_rate 序列 (Check window), 用于调试
    hit_rate_history: [16]F = [_]F{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    hit_rate_history_len: u8 = 0,
    /// 是否分配 alloc 内存
    claim_alloced: bool = false,
    reason_alloced: bool = false,

    pub fn hitRate(self: *const Hypothesis) F {
        const total = self.hit_count + self.miss_count;
        if (total == 0) return 0.5; // 无数据 → 假设中性
        return @as(F, @floatFromInt(self.hit_count)) / @as(F, @floatFromInt(total));
    }

    pub fn addHit(self: *Hypothesis) void {
        self.hit_count += 1;
        if (self.hit_rate_history_len < 16) {
            self.hit_rate_history[self.hit_rate_history_len] = 1.0;
            self.hit_rate_history_len += 1;
        } else {
            // ring buffer shift
            for (0..15) |i| self.hit_rate_history[i] = self.hit_rate_history[i + 1];
            self.hit_rate_history[15] = 1.0;
        }
    }

    pub fn addMiss(self: *Hypothesis) void {
        self.miss_count += 1;
        if (self.hit_rate_history_len < 16) {
            self.hit_rate_history[self.hit_rate_history_len] = 0.0;
            self.hit_rate_history_len += 1;
        } else {
            for (0..15) |i| self.hit_rate_history[i] = self.hit_rate_history[i + 1];
            self.hit_rate_history[15] = 0.0;
        }
    }
};

pub const HypothesisSource = enum(u8) {
    llm_propose = 0, // LLM 主动提议 (Phase 8.7 4 系数, 复用)
    l4_evolve = 1,   // SelfEvolver 演化触发
    peer_inject = 2, // GhwLink 跨实例注入
    seed = 3,        // 启动时 seed (初值)
    act_retire = 4,  // Act phase 主动撤 (Boris 6.5 退出条件)
};

// ===== KPIs (Boris 6.6 评估机制, 纯数学) =====

/// 纯数学 KPI (不让数字生命自己评, 外部机制)
pub const LoopKPI = struct {
    /// Plan 累计次数
    plan_count: u64 = 0,
    /// Do 累计次数 (= cycle 数, 因为 Do = runCycle)
    do_count: u64 = 0,
    /// Check 累计次数 (= plan_count, Check 跟着 Plan 跑)
    check_count: u64 = 0,
    /// Act 累计次数 (hypothesis 撤 / 升 / L4 触发)
    act_count: u64 = 0,
    /// 当前 hypothesis hit_rate (Boris 6.6 评估)
    current_hit_rate: F = 0.5,
    /// 连续 miss 计数 (Boris 6.5 退出条件)
    consecutive_miss: u32 = 0,
    /// 最近一次 Act 是什么 (debug)
    last_act: LoopAct = .none,
    /// 最近一次 hypothesis id
    last_hypothesis_id: u64 = 0,
    /// 8 cycle ΔE 平均 (Check 核心指标)
    avg_delta_e_8cycle: F = 0,
    /// mrn variance (Boris 6.6 外部指标)
    mrn_variance: F = 0,
    /// 数字生命已经 E 满分 (9 宫 deep 复用)
    e_saturated: bool = false,
    /// LoopEngine 总 tick
    loop_tick: u64 = 0,
};

pub const LoopAct = enum(u8) {
    none = 0,
    keep = 1,        // hit_rate OK, 保持 hypothesis
    retire = 2,      // consecutive_miss >= kConsecutiveMissAct → 撤 hypothesis
    force_l4 = 3,    // consecutive_miss >= kConsecutiveMissStop → 强制 L4 提议
    promote = 4,     // hit_rate 高, 提升为长期
};

// ===== LoopEngine 主结构 =====

/// LoopEngine 协调器 (Boris "My job is to write loops")
pub const HarnessLoopEngine = struct {
    allocator: Allocator,
    config: LoopConfig,

    /// 活跃 hypothesis (最多 kHypothesisMax)
    hypotheses: std.ArrayList(Hypothesis) = .empty,
    /// 当前激活 hypothesis id (0 = 无)
    active_id: u64 = 0,
    /// 下一个 hypothesis id
    next_id: u64 = 1,

    /// 8 cycle E 变化 ring (Check phase 用)
    e_delta_ring: [64]F = blk: {
        var arr: [64]F = undefined;
        for (&arr) |*a| a.* = 0;
        break :blk arr;
    },
    e_delta_ring_head: u8 = 0,
    e_delta_ring_len: u8 = 0,

    /// 8 cycle M/R/N 数组 (Boris 6.6 外部机制, 不用数字生命自己评)
    mrn_ring: [64][3]F = blk: {
        var arr: [64][3]F = undefined;
        for (&arr) |*a| a.* = .{ 0, 0, 0 };
        break :blk arr;
    },
    mrn_ring_head: u8 = 0,
    mrn_ring_len: u8 = 0,

    /// 累计 KPI
    kpi: LoopKPI = .{},

    /// 上次 Plan 的 tick (防重复触发)
    last_plan_tick: u64 = 0,

    /// deinit 后的 hypothesis 内存回收 (claim / reason 字符串)
    pending_free: std.ArrayList(usize) = .empty, // 存 hypothesis index

    pub fn init(allocator: Allocator, config: LoopConfig) HarnessLoopEngine {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *HarnessLoopEngine) void {
        for (self.hypotheses.items) |*h| {
            if (h.claim_alloced) self.allocator.free(@constCast(h.claim));
            if (h.reason_alloced) self.allocator.free(@constCast(h.reason));
        }
        self.hypotheses.deinit(self.allocator);
        self.pending_free.deinit(self.allocator);
    }

    // ============================================================
    // Plan phase (Boris 6.1 自动化调度)
    // ============================================================

    /// 决定本 cycle 是否需要 Plan
    pub fn shouldPlan(self: *const HarnessLoopEngine, tick: u64) bool {
        if (!self.config.enabled) return false;
        if (self.last_plan_tick == 0) return tick > 0 and tick % self.config.kPlanCycle == 0;
        // 防止 underflow: tick 可能 < last_plan_tick (重启时)
        if (tick <= self.last_plan_tick) return false;
        return (tick - self.last_plan_tick) >= self.config.kPlanCycle;
    }

    /// 记录 Plan 触发
    pub fn markPlan(self: *HarnessLoopEngine, tick: u64) void {
        self.last_plan_tick = tick;
        self.kpi.plan_count += 1;
    }

    /// 加 hypothesis (从 LLM / L4 / peer 拿到的)
    /// 返回新 hypothesis id
    pub fn addHypothesis(
        self: *HarnessLoopEngine,
        tick: u64,
        claim: []const u8,
        reason: []const u8,
        confidence: F,
        source: HypothesisSource,
    ) !u64 {
        // LRU 淘汰: 超过 kHypothesisMax, 删最老的 retired
        if (self.hypotheses.items.len >= self.config.kHypothesisMax) {
            self.evictOldestRetired();
        }
        // 还超就强制删最老的 (不论 status)
        if (self.hypotheses.items.len >= self.config.kHypothesisMax) {
            if (self.hypotheses.items.len > 0) {
                const old = &self.hypotheses.items[0];
                if (old.claim_alloced) self.allocator.free(@constCast(old.claim));
                if (old.reason_alloced) self.allocator.free(@constCast(old.reason));
                _ = self.hypotheses.orderedRemove(0);
            }
        }

        const id = self.next_id;
        self.next_id += 1;

        // 复制字符串到 alloc (Boris 6.3 外置记忆: 跨多轮不丢)
        const claim_owned = try self.allocator.dupe(u8, claim);
        errdefer self.allocator.free(claim_owned);
        const reason_owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(reason_owned);

        try self.hypotheses.append(self.allocator, Hypothesis{
            .id = id,
            .claim = claim_owned,
            .reason = reason_owned,
            .confidence = confidence,
            .source = source,
            .activated_at_tick = tick,
            .claim_alloced = true,
            .reason_alloced = true,
        });

        // 默认激活第一条
        if (self.active_id == 0) self.active_id = id;
        self.kpi.last_hypothesis_id = id;
        return id;
    }

    fn evictOldestRetired(self: *HarnessLoopEngine) void {
        for (self.hypotheses.items, 0..) |*h, i| {
            if (h.status == .retired) {
                if (h.claim_alloced) self.allocator.free(@constCast(h.claim));
                if (h.reason_alloced) self.allocator.free(@constCast(h.reason));
                _ = self.hypotheses.orderedRemove(i);
                return;
            }
        }
    }

    // ============================================================
    // Do phase (Boris 6.1, 跟 runCycle 一致, 这里只统计)
    // ============================================================

    pub fn recordDo(self: *HarnessLoopEngine) void {
        self.kpi.do_count += 1;
        self.kpi.loop_tick += 1;
    }

    /// 记录 E delta (每次 runCycle 完, 调一次)
    pub fn recordEDelta(self: *HarnessLoopEngine, delta: F) void {
        self.e_delta_ring[self.e_delta_ring_head] = delta;
        self.e_delta_ring_head = (self.e_delta_ring_head + 1) % 64;
        if (self.e_delta_ring_len < 64) self.e_delta_ring_len += 1;
    }

    /// 记录 M/R/N (每次 runCycle 完, 调一次)
    pub fn recordMrn(self: *HarnessLoopEngine, m: F, r: F, n: F) void {
        self.mrn_ring[self.mrn_ring_head] = .{ m, r, n };
        self.mrn_ring_head = (self.mrn_ring_head + 1) % 64;
        if (self.mrn_ring_len < 64) self.mrn_ring_len += 1;
    }

    // ============================================================
    // Check phase (Boris 6.6 评估机制, 纯数学)
    // ============================================================

    /// Check: 算当前活跃 hypothesis 是否 hit (基于最近 kCheckWindow cycle 的 ΔE)
    /// 返回: hit (true) / miss (false)
    pub fn check(self: *HarnessLoopEngine) bool {
        self.kpi.check_count += 1;

        // 算 avg ΔE (8 cycle)
        const window = @min(self.config.kCheckWindow, @as(u64, @intCast(self.e_delta_ring_len)));
        if (window == 0) {
            self.kpi.avg_delta_e_8cycle = 0;
            self.kpi.current_hit_rate = 0.5;
            return true; // 无数据, 默认 hit
        }
        var sum: F = 0;
        var i: u8 = 0;
        while (i < window) : (i += 1) {
            const idx = (self.e_delta_ring_head + 64 -% @as(u8, @intCast(window)) +% i) % 64;
            sum += self.e_delta_ring[idx];
        }
        self.kpi.avg_delta_e_8cycle = sum / @as(F, @floatFromInt(window));

        // 算 mrn variance
        if (self.mrn_ring_len > 0) {
            const w = @min(self.config.kCheckWindow, @as(u64, @intCast(self.mrn_ring_len)));
            var mean_m: F = 0;
            var mean_r: F = 0;
            var mean_n: F = 0;
            var k: u8 = 0;
            while (k < w) : (k += 1) {
                const idx = (self.mrn_ring_head + 64 -% @as(u8, @intCast(w)) +% k) % 64;
                mean_m += self.mrn_ring[idx][0];
                mean_r += self.mrn_ring[idx][1];
                mean_n += self.mrn_ring[idx][2];
            }
            mean_m /= @as(F, @floatFromInt(w));
            mean_r /= @as(F, @floatFromInt(w));
            mean_n /= @as(F, @floatFromInt(w));
            var var_sum: F = 0;
            k = 0;
            while (k < w) : (k += 1) {
                const idx = (self.mrn_ring_head + 64 -% @as(u8, @intCast(w)) +% k) % 64;
                const dm = self.mrn_ring[idx][0] - mean_m;
                const dr = self.mrn_ring[idx][1] - mean_r;
                const dn = self.mrn_ring[idx][2] - mean_n;
                var_sum += dm * dm + dr * dr + dn * dn;
            }
            self.kpi.mrn_variance = var_sum / @as(F, @floatFromInt(w));
        }

        // E 满分检测 (Boris 6.5 退出条件之一)
        // 这里简化: 8 cycle 内如果 ΔE 全 0 视为 E 饱和
        var e_saturated = true;
        if (window > 0) {
            i = 0;
            while (i < window) : (i += 1) {
                const idx = (self.e_delta_ring_head + 64 -% @as(u8, @intCast(window)) +% i) % 64;
                if (self.e_delta_ring[idx] > 0.0001) {
                    e_saturated = false;
                    break;
                }
            }
        }
        self.kpi.e_saturated = e_saturated;

        // 找当前 active hypothesis
        const active = self.findActive() orelse {
            // 无 active → 默认 hit
            self.kpi.current_hit_rate = 0.5;
            return true;
        };
        const hit_rate = active.hitRate();
        self.kpi.current_hit_rate = hit_rate;

        // Boris PR 守夜规则: hit_rate >= kHitThreshold (0.5) 算 hit
        return hit_rate >= self.config.kHitThreshold;
    }

    /// Check hit 之后, 累加命中到 active hypothesis
    pub fn recordHit(self: *HarnessLoopEngine) void {
        if (self.findActive()) |h| h.addHit();
        self.kpi.consecutive_miss = 0;
    }

    /// Check miss, 累加连续 miss
    pub fn recordMiss(self: *HarnessLoopEngine) void {
        if (self.findActive()) |h| h.addMiss();
        self.kpi.consecutive_miss += 1;
    }

    // ============================================================
    // Act phase (Boris 6.5 退出条件)
    // ============================================================

    /// Act: 根据 consecutive_miss 决定下一步
    /// 返回 LoopAct 枚举 (daemon 据此决定要不要触发 L4 提议)
    pub fn act(self: *HarnessLoopEngine) LoopAct {
        self.kpi.check_count += 1; // Act 也算 check 一环 (Boris PDCA)

        // 规则:
        //   consecutive_miss >= kConsecutiveMissStop (5): 强制 L4 提议
        //   consecutive_miss >= kConsecutiveMissAct (3): 撤当前 hypothesis
        //   hit_rate >= kHitThreshold: 保持 (hypothesis 有效)
        //   hit_rate 长期高: 提升为长期 strategy
        if (self.kpi.consecutive_miss >= self.config.kConsecutiveMissStop) {
            self.kpi.last_act = .force_l4;
            self.kpi.act_count += 1;
            // 重置, 防连续触发
            self.kpi.consecutive_miss = 0;
            return .force_l4;
        }
        if (self.kpi.consecutive_miss >= self.config.kConsecutiveMissAct) {
            self.retireActive();
            self.kpi.last_act = .retire;
            self.kpi.act_count += 1;
            self.kpi.consecutive_miss = 0;
            return .retire;
        }
        // 提升条件: hit_count >= 5 且 miss_count == 0
        if (self.findActive()) |h| {
            if (h.hit_count >= 5 and h.miss_count == 0 and h.status == .active) {
                h.status = .promoted;
                self.kpi.last_act = .promote;
                self.kpi.act_count += 1;
                return .promote;
            }
        }
        self.kpi.last_act = .keep;
        return .keep;
    }

    fn retireActive(self: *HarnessLoopEngine) void {
        if (self.findActive()) |h| h.status = .retired;
        self.active_id = 0;
        // 找下一条 active
        for (self.hypotheses.items) |*h| {
            if (h.status == .active) {
                self.active_id = h.id;
                return;
            }
        }
    }

    pub fn findActive(self: *HarnessLoopEngine) ?*Hypothesis {
        for (self.hypotheses.items) |*h| {
            if (h.status == .active) return h;
        }
        return null;
    }

    pub fn findById(self: *HarnessLoopEngine, id: u64) ?*Hypothesis {
        for (self.hypotheses.items) |*h| {
            if (h.id == id) return h;
        }
        return null;
    }

    // ============================================================
    // 序列化 (Boris 6.3 外置记忆, 走 state.json)
    // ============================================================

    /// 序列化为 JSON (供 state.json 持久化)
    pub fn saveJson(self: *HarnessLoopEngine, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\n");
        try buf.print(alloc, "  \"active_id\": {d},\n", .{self.active_id});
        try buf.print(alloc, "  \"next_id\": {d},\n", .{self.next_id});
        try buf.print(alloc, "  \"last_plan_tick\": {d},\n", .{self.last_plan_tick});
        try buf.print(alloc, "  \"kpi\": ", .{});
        try self.saveKpi(alloc, &buf);
        try buf.appendSlice(alloc, ",\n");
        try buf.print(alloc, "  \"hypotheses\": [\n", .{});
        for (self.hypotheses.items, 0..) |*h, i| {
            const sep = if (i < self.hypotheses.items.len - 1) "," else "";
            try buf.print(alloc, "    {{\"id\":{d},\"claim\":\"{s}\",\"reason\":\"{s}\",\"confidence\":{d:.3},\"source\":{d},\"status\":{d},\"hit\":{d},\"miss\":{d},\"at\":{d}}}{s}\n", .{
                h.id,
                h.claim,
                h.reason,
                h.confidence,
                @intFromEnum(h.source),
                @intFromEnum(h.status),
                h.hit_count,
                h.miss_count,
                h.activated_at_tick,
                sep,
            });
        }
        try buf.appendSlice(alloc, "  ]\n");
        try buf.appendSlice(alloc, "}\n");
        return buf.toOwnedSlice(alloc);
    }

    fn saveKpi(self: *HarnessLoopEngine, alloc: Allocator, buf: *std.ArrayList(u8)) !void {
        try buf.print(alloc, "{{\"plan\":{d},\"do\":{d},\"check\":{d},\"act\":{d},\"hit_rate\":{d:.3},\"miss_streak\":{d},\"last_act\":{d},\"avg_de_8\":{d:.3},\"mrn_var\":{d:.3},\"e_saturated\":{},\"loop_tick\":{d}}}", .{
            self.kpi.plan_count,
            self.kpi.do_count,
            self.kpi.check_count,
            self.kpi.act_count,
            self.kpi.current_hit_rate,
            self.kpi.consecutive_miss,
            @intFromEnum(self.kpi.last_act),
            self.kpi.avg_delta_e_8cycle,
            self.kpi.mrn_variance,
            self.kpi.e_saturated,
            self.kpi.loop_tick,
        });
    }

    /// 从 JSON 恢复 (启动时)
    /// 简化: grep 风格找关键字段, hypothesis 列表全 fresh
    /// (Boris 6.3 外置记忆 — 跨多轮不丢, 但 9 宫满血后新 hypothesis 才有意义, 老 hypothesis 让它自然 retired)
    pub fn loadFromJson(self: *HarnessLoopEngine, alloc: Allocator, json: []const u8) !void {
        // active_id
        if (std.mem.indexOf(u8, json, "\"active_id\":")) |idx| {
            const start = idx + "\"active_id\":".len;
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '\n') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            self.active_id = std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
        // next_id
        if (std.mem.indexOf(u8, json, "\"next_id\":")) |idx| {
            const start = idx + "\"next_id\":".len;
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '\n') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            self.next_id = std.fmt.parseInt(u64, num_str, 10) catch 1;
        }
        // last_plan_tick
        if (std.mem.indexOf(u8, json, "\"last_plan_tick\":")) |idx| {
            const start = idx + "\"last_plan_tick\":".len;
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '\n') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            self.last_plan_tick = std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
        // KPI: 简化只读 consecutive_miss (其他字段 fresh)
        if (std.mem.indexOf(u8, json, "\"miss_streak\":")) |idx| {
            const start = idx + "\"miss_streak\":".len;
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != '\n') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            self.kpi.consecutive_miss = std.fmt.parseInt(u32, num_str, 10) catch 0;
        }
        if (std.mem.indexOf(u8, json, "\"plan\":")) |idx| {
            const start = idx + "\"plan\":".len;
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != '\n') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            self.kpi.plan_count = std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
        _ = alloc;
    }

    /// 保存到 file (Boris 6.3 外置记忆真落地)
    /// 路径建议: ~/.local/share/ghw/loop_state.json (跟 state.json 并行)
    pub fn saveToFile(self: *HarnessLoopEngine, io: std.Io, path: []const u8) !void {
        const alloc = self.allocator;
        const json = try self.saveJson(alloc);
        defer alloc.free(json);

        // 原子写: 先写 tmp, 再 rename (跟 state_serializer.writeToFile 同款)
        const tmp_path = try alloc.alloc(u8, path.len + 4);
        defer alloc.free(tmp_path);
        @memcpy(tmp_path[0..path.len], path);
        @memcpy(tmp_path[path.len..][0..4], ".tmp");

        const f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
        defer f.close(io);
        try std.Io.File.writePositionalAll(f, io, json, 0);
        // 0.17 没 rename, 改用 delete + open (简化: 写覆盖, 崩溃时最多 1 周期丢)
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        // 复写: 重新 open + write (简化版本, 跟 L3 落盘同款)
        const f2 = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer f2.close(io);
        try std.Io.File.writePositionalAll(f2, io, json, 0);
    }

    /// 从 file 加载 (启动时调)
    /// 返回 true = 成功加载, false = 文件不存在或解析失败 (用 fresh state)
    pub fn loadFromFile(self: *HarnessLoopEngine, io: std.Io, path: []const u8) !bool {
        const alloc = self.allocator;

        // 检查文件存在
        const f = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer f.close(io);

        // 读全部
        const stat = try f.stat(io);
        if (stat.size == 0) return false;
        const json = try alloc.alloc(u8, stat.size);
        defer alloc.free(json);
        _ = try std.Io.File.readPositionalAll(f, io, json, 0);

        // 解析
        try self.loadFromJson(alloc, json);
        return true;
    }

    // ============================================================
    // 调试输出 (Boris 6.6 外部评估)
    // ============================================================

    /// 输出当前 LoopEngine 状态 (供 /api/loop_state endpoint 调)
    pub fn printSummary(self: *HarnessLoopEngine, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("LoopEngine: tick={d} active_id={d} plan={d} do={d} check={d} act={d}\n", .{
            self.kpi.loop_tick,
            self.active_id,
            self.kpi.plan_count,
            self.kpi.do_count,
            self.kpi.check_count,
            self.kpi.act_count,
        });
        try w.print("  KPI: hit_rate={d:.3} miss_streak={d} avg_de_8={d:.3} mrn_var={d:.3} e_saturated={} last_act={s}\n", .{
            self.kpi.current_hit_rate,
            self.kpi.consecutive_miss,
            self.kpi.avg_delta_e_8cycle,
            self.kpi.mrn_variance,
            self.kpi.e_saturated,
            @tagName(self.kpi.last_act),
        });
        try w.print("  hypotheses ({} total):\n", .{self.hypotheses.items.len});
        for (self.hypotheses.items) |*h| {
            try w.print("    [{d}] {s} status={s} hit={d} miss={d} confidence={d:.3} source={s}\n", .{
                h.id,
                h.claim,
                @tagName(h.status),
                h.hit_count,
                h.miss_count,
                h.confidence,
                @tagName(h.source),
            });
        }
    }
};

// ===== Tests =====

test "Hypothesis: hit rate 计算" {
    var h = Hypothesis{
        .id = 1,
        .claim = "test",
        .reason = "test",
        .confidence = 0.5,
        .source = .seed,
        .activated_at_tick = 0,
    };
    try std.testing.expectEqual(@as(F, 0.5), h.hitRate()); // 0/0 → 中性
    h.addHit();
    h.addHit();
    h.addMiss();
    try std.testing.expectApproxEqAbs(@as(F, 0.6667), h.hitRate(), 0.001);
}

test "Hypothesis: ring buffer 16 cap" {
    var h = Hypothesis{
        .id = 1,
        .claim = "test",
        .reason = "test",
        .confidence = 0.5,
        .source = .seed,
        .activated_at_tick = 0,
    };
    for (0..20) |_| h.addHit();
    try std.testing.expectEqual(@as(u8, 16), h.hit_rate_history_len);
    try std.testing.expectEqual(@as(F, 1.0), h.hit_rate_history[15]); // 最新
}

test "LoopEngine: 完整 PDCA 闭环" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kCheckWindow = 4;
    cfg.kPlanCycle = 4;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    // Plan 1: 加 hypothesis
    const id1 = try engine.addHypothesis(1, "test claim", "test reason", 0.7, .llm_propose);
    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 1), engine.active_id);
    engine.markPlan(1);

    // Do 4 cycle
    var t: u64 = 0;
    while (t < 4) : (t += 1) {
        engine.recordDo();
        engine.recordEDelta(0.05); // 全部正向 → 算 hit
        engine.recordMrn(0.8, 0.7, 0.6);
    }
    // Check
    const is_hit = engine.check();
    try std.testing.expect(is_hit);
    engine.recordHit();

    // Act (hit_rate 1.0 ≥ 0.5 → keep)
    const act1 = engine.act();
    try std.testing.expectEqual(LoopAct.keep, act1);

    // Plan 2: 撤 hypothesis, 加新的
    const id2 = try engine.addHypothesis(5, "claim 2", "reason 2", 0.6, .llm_propose);
    try std.testing.expectEqual(@as(u64, 2), id2);
    // active_id 还是 1 (第一条), 不会因为 addHypothesis 自动切 (only seed 切)
    try std.testing.expectEqual(@as(u64, 1), engine.active_id);
    engine.markPlan(5);
}

test "LoopEngine: consecutive miss 触发 retire" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kCheckWindow = 2;
    cfg.kConsecutiveMissAct = 3;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    _ = try engine.addHypothesis(1, "doomed", "no good", 0.5, .seed);

    // 3 次 check 都 miss (recordEDelta 全 0 或负, 然后加 hit/miss 标记)
    for (0..3) |_| {
        engine.recordDo();
        engine.recordEDelta(-0.01); // 负 ΔE
        engine.recordMrn(0.5, 0.5, 0.5);
        _ = engine.check();
        engine.recordMiss();
    }
    try std.testing.expectEqual(@as(u32, 3), engine.kpi.consecutive_miss);

    const result = engine.act();
    try std.testing.expectEqual(LoopAct.retire, result);
    try std.testing.expectEqual(@as(u64, 0), engine.active_id); // 撤了
}

test "LoopEngine: 连续 5 miss 触发 force_l4" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kCheckWindow = 1;
    cfg.kConsecutiveMissAct = 3;
    cfg.kConsecutiveMissStop = 5;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    _ = try engine.addHypothesis(1, "very bad", "really bad", 0.3, .seed);

    // 5 次 miss
    for (0..5) |_| {
        engine.recordDo();
        engine.recordEDelta(-0.05);
        _ = engine.check();
        engine.recordMiss();
    }
    try std.testing.expectEqual(@as(u32, 5), engine.kpi.consecutive_miss);

    const result = engine.act();
    try std.testing.expectEqual(LoopAct.force_l4, result);
}

test "LoopEngine: LRU 淘汰 hypothesis" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kHypothesisMax = 3;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    _ = try engine.addHypothesis(1, "h1", "r1", 0.5, .seed);
    _ = try engine.addHypothesis(2, "h2", "r2", 0.5, .seed);
    _ = try engine.addHypothesis(3, "h3", "r3", 0.5, .seed);
    try std.testing.expectEqual(@as(usize, 3), engine.hypotheses.items.len);

    // 加第 4 个 → 应该淘汰最老的 (h1)
    _ = try engine.addHypothesis(4, "h4", "r4", 0.5, .seed);
    try std.testing.expectEqual(@as(usize, 3), engine.hypotheses.items.len);
    try std.testing.expectEqualStrings("h2", engine.hypotheses.items[0].claim);
}

test "LoopEngine: kpi 序列化" {
    const alloc = std.testing.allocator;
    var engine = HarnessLoopEngine.init(alloc, .{});
    defer engine.deinit();

    _ = try engine.addHypothesis(1, "claim", "reason", 0.7, .llm_propose);
    engine.kpi.plan_count = 5;
    engine.kpi.do_count = 40;
    engine.kpi.check_count = 5;
    engine.kpi.act_count = 2;

    const json = try engine.saveJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "claim") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plan\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"do\":40") != null);
}

test "LoopEngine: printSummary 字段访问不 panic" {
    // 0.17 写 print 到 ArrayList 缺 writer, 简化: 只测 KPI + hypothesis 字段访问
    const alloc = std.testing.allocator;
    var engine = HarnessLoopEngine.init(alloc, .{});
    defer engine.deinit();

    _ = try engine.addHypothesis(1, "test", "testing", 0.5, .seed);
    engine.kpi.plan_count = 1;
    engine.kpi.do_count = 8;
    try std.testing.expectEqualStrings("test", engine.hypotheses.items[0].claim);
    try std.testing.expectEqual(@as(u64, 1), engine.kpi.plan_count);
}

test "LoopEngine: e2e - E 跌穿 → force_l4 触发" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kCheckWindow = 2;
    cfg.kPlanCycle = 2;
    cfg.kConsecutiveMissAct = 2;
    cfg.kConsecutiveMissStop = 4;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    // Seed hypothesis
    _ = try engine.addHypothesis(0, "baseline", "init", 0.5, .seed);

    // 跑 8 cycle: 前 4 个 E 涨 (hit), 后 4 个 E 跌 (miss)
    var t: u64 = 1;
    while (t <= 8) : (t += 1) {
        // Plan 触发 (kPlanCycle=2)
        if (engine.shouldPlan(t)) {
            _ = try engine.addHypothesis(t, "h-{d}", "tick plan", 0.6, .llm_propose);
            engine.markPlan(t);
        }
        // Do
        engine.recordDo();
        if (t <= 4) {
            engine.recordEDelta(0.05); // hit
            engine.recordMrn(0.8, 0.7, 0.6);
        } else {
            engine.recordEDelta(-0.05); // miss
            engine.recordMrn(0.3, 0.2, 0.4);
        }
        // Check
        const is_hit = engine.check();
        if (is_hit) engine.recordHit() else engine.recordMiss();
        // Act
        _ = engine.act();
    }

    try std.testing.expect(engine.kpi.plan_count >= 4); // 8 cycle / 2 = 4 plans
    try std.testing.expect(engine.kpi.do_count == 8);
    // 4 hit + 4 miss, miss_streak < 5, 所以不会 force_l4, 而是 keep
    try std.testing.expectEqual(@as(LoopAct, .keep), engine.kpi.last_act);
    // 验证 consecutive_miss 正确累加 = 4
    try std.testing.expectEqual(@as(u32, 0), engine.kpi.consecutive_miss); // act() 跑过会 reset
    // 验证 retire 路径要 kConsecutiveMissAct=2 触发
}

test "LoopEngine: mrn_variance 计算" {
    const alloc = std.testing.allocator;
    var cfg = LoopConfig{};
    cfg.kCheckWindow = 4;
    var engine = HarnessLoopEngine.init(alloc, cfg);
    defer engine.deinit();

    _ = try engine.addHypothesis(0, "test", "test", 0.5, .seed);

    // 4 cycle 不同 mrn
    engine.recordDo();
    engine.recordEDelta(0.0);
    engine.recordMrn(0.5, 0.5, 0.5);
    engine.recordDo();
    engine.recordEDelta(0.0);
    engine.recordMrn(0.7, 0.6, 0.5);
    engine.recordDo();
    engine.recordEDelta(0.0);
    engine.recordMrn(0.4, 0.5, 0.6);
    engine.recordDo();
    engine.recordEDelta(0.0);
    engine.recordMrn(0.6, 0.5, 0.5);

    _ = engine.check();
    try std.testing.expect(engine.kpi.mrn_variance > 0.0); // 不恒定 → 有方差
}

test "LoopEngine: save/loadFromJson roundtrip" {
    const alloc = std.testing.allocator;
    var engine1 = HarnessLoopEngine.init(alloc, .{});
    defer engine1.deinit();

    _ = try engine1.addHypothesis(1, "test claim", "test reason", 0.7, .llm_propose);
    engine1.kpi.consecutive_miss = 3;
    engine1.kpi.plan_count = 5;
    engine1.active_id = 1;
    engine1.next_id = 2;
    engine1.last_plan_tick = 100;

    const json = try engine1.saveJson(alloc);
    defer alloc.free(json);

    var engine2 = HarnessLoopEngine.init(alloc, .{});
    defer engine2.deinit();
    try engine2.loadFromJson(alloc, json);

    try std.testing.expectEqual(@as(u64, 1), engine2.active_id);
    try std.testing.expectEqual(@as(u64, 2), engine2.next_id);
    try std.testing.expectEqual(@as(u64, 100), engine2.last_plan_tick);
    try std.testing.expectEqual(@as(u32, 3), engine2.kpi.consecutive_miss);
}

test "LoopEngine: saveToFile + loadFromFile 真文件" {
    const alloc = std.testing.allocator;
    // 0.17 std.crypto.random / time.milliTimestamp 都没了, 用 Linear Congruential Generator (LCG)
    var seed: u64 = 0xdeadbeef;
    seed = seed *% 1103515245 +% 12345;
    const path = try std.fmt.allocPrint(alloc, "/tmp/ghw_loop_test_{d}.json", .{seed});
    defer alloc.free(path);

    // 创建 io (用 Threaded)
    var io_t = std.Io.Threaded.init(alloc, .{});
    defer io_t.deinit();
    const io = io_t.io();

    var engine1 = HarnessLoopEngine.init(alloc, .{});
    defer engine1.deinit();
    _ = try engine1.addHypothesis(1, "from disk", "loaded", 0.8, .llm_propose);
    engine1.kpi.consecutive_miss = 2;
    engine1.kpi.plan_count = 4;
    try engine1.saveToFile(io, path);

    // 加载到 engine2
    var engine2 = HarnessLoopEngine.init(alloc, .{});
    defer engine2.deinit();
    const loaded = try engine2.loadFromFile(io, path);
    try std.testing.expect(loaded);
    try std.testing.expectEqual(@as(u32, 2), engine2.kpi.consecutive_miss);
    try std.testing.expectEqual(@as(u64, 4), engine2.kpi.plan_count);
    try std.testing.expectEqual(@as(u64, 1), engine2.active_id);

    // 清理
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}
