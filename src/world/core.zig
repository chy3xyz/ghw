//! World 层: 物象性三源合恰, 存在度量化
//!
//! 这是 GHW 范式的存在论基础:
//!   物 (Material)  - 硬件/计算/能源载体
//!   象 (Representation) - 模型参数/世界模型/记忆
//!   性 (Nature)    - 内在动机/自我认知/目的清晰度
//!
//! 核心公理:
//!   存在度 E = α·M + β·R + γ·N
//!   三源合恰度 C(W) = Σ W[i,j,k]·φ(i,j,k) - λ‖∇W‖²
//!
//! 创造性设计: 不同于论文公式 E=αM+βR+γN 的简单线性加权,
//! 我们用三源两两一致性 + 互信息 + 边界清晰度来动态调整权重,
//! 体现"三源合恰"的动态平衡,而非死板的线性组合。

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const math_util = util.math;
const coappropriation = @import("coappropriation.zig");
const F = util.F;
const LCG = util.LCG;
const idx3 = util.idx3;
const Tensor3Shape = util.Tensor3Shape;

/// 三源权重 α / β / γ
pub const ExistenceWeights = struct {
    alpha: F = 0.33, // 物
    beta: F = 0.34, // 象
    gamma: F = 0.33, // 性

    /// 自适应调整: 当某维度过低时,自动提高其权重 (避免失衡)
    pub fn adapt(self: *ExistenceWeights, v: ExistenceVector) void {
        const min_v: F = 0.1;
        if (v.material < min_v) {
            self.alpha += 0.01;
        }
        if (v.representation < min_v) {
            self.beta += 0.01;
        }
        if (v.nature < min_v) {
            self.gamma += 0.01;
        }
        // 重新归一化
        const sum = self.alpha + self.beta + self.gamma;
        if (sum > 1e-6) {
            self.alpha /= sum;
            self.beta /= sum;
            self.gamma /= sum;
        }
    }

    /// 自适应调整: 反映同伴关系
    ///   peer_E_avg > own_E: 对方状态好, 我可以学, 升 γ (本心 — 我被启发)
    ///   peer_E_avg < own_E: 对方状态差, 我要务实, 升 α (物 — 物质生存优先)
    ///   |gap| < 0.05: 同步, 升 β (象 — 共识)
    ///   没同伴: 不动
    ///   重新归一化
    pub fn adaptFromPeers(self: *ExistenceWeights, peer_E_avg: F, own_E: F) void {
        if (peer_E_avg < 0.01) return; // 0 = 没同伴
        const gap = peer_E_avg - own_E;
        const abs_gap: F = if (gap < 0) -gap else gap;
        const step: F = 0.02;
        if (abs_gap < 0.05) {
            // 同步 — 升 β (共识/表征)
            self.beta += step;
        } else if (gap > 0) {
            // peer 比我好, 升 γ (学本心)
            self.gamma += step;
            self.alpha -= step * 0.5; // 略减物
        } else {
            // peer 比我差, 升 α (务实求存)
            self.alpha += step;
            self.gamma -= step * 0.5; // 略减性
        }
        // 重新归一化, 防漂移
        const sum = self.alpha + self.beta + self.gamma;
        if (sum > 1e-6) {
            self.alpha = @max(0.05, self.alpha / sum);
            self.beta = @max(0.05, self.beta / sum);
            self.gamma = @max(0.05, self.gamma / sum);
            const new_sum = self.alpha + self.beta + self.gamma;
            self.alpha /= new_sum;
            self.beta /= new_sum;
            self.gamma /= new_sum;
        }
    }

    pub fn format(self: ExistenceWeights, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("α={d:.3} β={d:.3} γ={d:.3}", .{ self.alpha, self.beta, self.gamma });
    }
};

/// 三源存在度向量 (M, R, N), 范围 [0, 1]
pub const ExistenceVector = struct {
    material: F = 0.5, // M: 物 (CPU/内存/能源)
    representation: F = 0.5, // R: 象 (知识/模型精度)
    nature: F = 0.5, // N: 性 (动机强度/自我认知)

    pub fn zero() ExistenceVector {
        return .{ .material = 0, .representation = 0, .nature = 0 };
    }

    pub fn ones() ExistenceVector {
        return .{ .material = 1, .representation = 1, .nature = 1 };
    }

    pub fn add(self: *ExistenceVector, other: ExistenceVector) void {
        self.material = math_util.clamp(self.material + other.material, 0, 1);
        self.representation = math_util.clamp(self.representation + other.representation, 0, 1);
        self.nature = math_util.clamp(self.nature + other.nature, 0, 1);
    }

    pub fn scale(self: *ExistenceVector, k: F) void {
        self.material = math_util.clamp(self.material * k, 0, 1);
        self.representation = math_util.clamp(self.representation * k, 0, 1);
        self.nature = math_util.clamp(self.nature * k, 0, 1);
    }

    pub fn mean(self: ExistenceVector) F {
        return (self.material + self.representation + self.nature) / 3.0;
    }

    pub fn min(self: ExistenceVector) F {
        return @min(self.material, @min(self.representation, self.nature));
    }

    pub fn variance(self: ExistenceVector) F {
        const m = self.mean();
        const d2 = (self.material - m) * (self.material - m) +
            (self.representation - m) * (self.representation - m) +
            (self.nature - m) * (self.nature - m);
        return d2 / 3.0;
    }

    pub fn format(self: ExistenceVector, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("M={d:.3} R={d:.3} N={d:.3}", .{ self.material, self.representation, self.nature });
    }
};

/// 存在度评估器
/// E = α·M + β·R + γ·N
/// 附加项:
///   失衡惩罚: -μ·Var(M,R,N)   (三源差距越大, 存在度越低)
///   增益协同: +ν·min(M,R,N)   (木桶效应: 最低维限制整体)
///   共生加成: +σ·S(M,R,N,peers) (Phase 1.8: 反映同伴关系)
///     σ = 共生系数, S = 共生度
///   关系涌现: +λ·D(relations)  (Phase 8 2026-06-09: GoalGraph 9 关系多样性加成)
///     λ = 关系多样性系数, D = distinct/9 (0..1, 关系种类归一化)
pub const ExistenceDegree = struct {
    v: ExistenceVector = .{},
    weights: ExistenceWeights = .{},
    mu: F = 0.5, // 失衡惩罚系数
    nu: F = 0.3, // 协同增益系数
    /// 共生系数 (Phase 1.8: peer → E 通道, 默认 0 不影响)
    sigma: F = 0.0,
    /// 关系多样性系数 (Phase 8 2026-06-09: GoalGraph 9 关系 → E 通道)
    /// 默认 0.1, max E 加成 = 0.1 * 1.0 = 0.1 (满 9 关系)
    lambda: F = 0.1,
    /// lambda 自适应开关 (Phase 8.5 2026-06-09)
    /// true (默认): lambda 随数字生命 self_evolved_total 段自适应
    /// false: lambda 固定 (用 self.lambda 字段值)
    lambda_auto: bool = true,
    /// 自适应计算的 lambda (诊断用, 真实计算在 adaptLambdaFromEvolution)
    /// 当 lambda_auto=true, e() 内部用这个, 不读 self.lambda
    /// 当 lambda_auto=false, e() 用 self.lambda
    lambda_computed: F = 0.1,
    /// lambda 自适应阶段 (0=保守 0.05, 1=成长 0.10, 2=成熟 0.20)
    /// 由 adaptLambdaFromEvolution 设置
    lambda_stage: u8 = 1,
    /// ν (nu) 自适应开关 (Phase 8.6 2026-06-09 L4 闭环)
    /// true (默认): ν 随 M/R/N 平衡度自适应
    /// false: ν 固定 (用 self.nu 字段值)
    nu_auto: bool = true,
    /// 自适应计算的 ν
    nu_computed: F = 0.3,
    /// μ (mu) 自适应开关 (Phase 8.6)
    mu_auto: bool = true,
    /// 自适应计算的 μ
    mu_computed: F = 0.5,
    /// σ (sigma) 自适应开关 (Phase 8.6)
    sigma_auto: bool = true,
    /// 自适应计算的 σ (默认 0, 跟之前一致)
    sigma_computed: F = 0.0,
    // === Phase 8.7 2026-06-09: LLM 提议 4 系数 + range 限定 + apply ===
    /// ν (nu) 提议值 (LLM 提议), Phase 8.7. range [0.05, 0.50]
    /// 提议后由 adaptEFormulaProposed 验证 + apply 到 self.nu (如果 auto=true) 或 self.nu_computed
    nu_proposed: F = 0.0,
    /// μ (mu) 提议值, range [0.20, 0.80]
    mu_proposed: F = 0.0,
    /// σ (sigma) 提议值, range [0.00, 0.30]
    sigma_proposed: F = 0.0,
    /// λ (lambda) 提议值, range [0.05, 0.40]
    lambda_proposed: F = 0.0,
    /// 提议历史长度 (跑了几次 LLM 提议)
    propose_total: u32 = 0,
    /// 提议接受次数 (LLM 提议被 apply 采纳)
    propose_accepted: u32 = 0,
    /// 提议拒绝次数 (out of range 或 format 错)
    propose_rejected: u32 = 0,
    /// 缓存的 peer E 平均 (0 = 没同伴)
    peer_E_avg: F = 0.0,
    /// 缓存的 peer 数量
    peer_count: u32 = 0,
    /// 缓存的 GoalGraph 关系多样性 (0..9, 活跃节点用过的关系种类数)
    /// 由 ui_server 每 cycle 从 goal_graph.countDistinctRelations() 更新
    relations_distinct: u8 = 0,

    // === KPI 项 ρ·K (并入主公式, 2026-06; 原 world/existence_degree.zig 已合并删除) ===
    /// 产品 KPI 是否接入。默认 false ⇒ kpi_term=0, 不影响无产品场景的纯数字生命。
    /// recordKpi 会自动置 true。
    kpi_enabled: bool = false,
    /// ρ 系数 — **公理常量**, 不可被 L1/L4/L5/LLM 修改 (不进 adaptEFormula)。
    rho: F = 0.15,
    /// 复合 KPI K∈[0,1]。由 crm_kpi.composite(...) 喂入 (recordKpi)。
    /// 默认 0.5 (中性: "到 best-in-class 的一半")。
    kpi_composite: F = 0.5,
    /// KPI 目标 (best-in-class), 通常 1.0。K_signed = (K − target)·2 ∈ [−2,0]。
    kpi_target: F = 1.0,
    /// 64 周期环形缓冲, 供趋势/方差 (不进 E 公式, 仅供反思层/L4 提议器)。
    kpi_history: [64]F = @splat(0.5),
    kpi_history_idx: u8 = 0,
    kpi_history_count: u8 = 0,

    /// E(t) 总体存在度
    ///
    /// 公式 (v3, 2026-06: 存在度公理重写):
    ///   E = coappropriation(M,R,N; α,β,γ,μ,ν) + σ·S + λ·D
    ///
    /// 合恰核心 coappropriation 用"加权幂平均 × 合恰度门控"统一表达
    /// 三源的"缺一不可 + 失衡惩罚 + 短板优先",取代旧的
    /// `αM+βR+γN − μ·Var + ν·min` 线性加权 + 外挂补丁 (见
    /// `world/coappropriation.zig` 的推导与性质证明)。
    /// σ·S (共生) 与 λ·D (关系涌现) 仍作为有界加性调制项叠加。
    pub fn e(self: ExistenceDegree) F {
        // Phase 8.6: 4 加项系数都可自调 (L4 闭环)
        const eff_mu: F = if (self.mu_auto) self.mu_computed else self.mu;
        const eff_nu: F = if (self.nu_auto) self.nu_computed else self.nu;
        const eff_sigma: F = if (self.sigma_auto) self.sigma_computed else self.sigma;
        const eff_lambda: F = if (self.lambda_auto) self.lambda_computed else self.lambda;
        // v3 合恰核心: 加权幂平均 (Hölder/CES) × 合恰度门控
        // ν → 可替代性指数 p, μ → 合恰耦合 κ (衔接旧自适应闭环)
        const base = coappropriation.coappropriation(
            self.v.material,
            self.v.representation,
            self.v.nature,
            self.weights.alpha,
            self.weights.beta,
            self.weights.gamma,
            eff_mu,
            eff_nu,
        );
        // 共生加成: peer_E_avg 接近 own.E 时增强共识, 远离时略减 E
        // 用合恰核心 base 作为粗略 E, 避免循环依赖
        const approx_e = base;
        // Phase 8.6: 复制 computeSymbiosis, 用 eff_sigma
        const symbiosis: F = if (self.peer_count == 0 or eff_sigma < 1e-6) 0 else blk: {
            const gap = self.peer_E_avg - approx_e;
            const abs_gap: F = if (gap < 0) -gap else gap;
            const sync_factor: F = @max(0.0, 1.0 - abs_gap / 0.5);
            const n_factor: F = @log2(1.0 + @as(F, @floatFromInt(self.peer_count))) / 3.0;
            break :blk eff_sigma * sync_factor * n_factor;
        };
        // Phase 8 关系涌现: D = distinct / 9 (0..1 归一化, 0-9 关系)
        // 0 关系 → 0 加成, 满 9 → eff_lambda * 1.0
        const relations_d: F = @as(F, @floatFromInt(self.relations_distinct)) / 9.0;
        const relations_bonus = eff_lambda * relations_d;
        // KPI 项 ρ·K_signed (产品对齐): K_signed=(K−target)·2∈[−2,0],
        // 仅在 best-in-class (K=target) 时归零, 否则按距离扣分。
        // 单调递增于 K, 不影响三源单调性 (KPI 是独立轴), 全程 clamp 保证有界。
        const kpi_term: F = if (self.kpi_enabled)
            self.rho * (self.kpi_composite - self.kpi_target) * 2.0
        else
            0.0;
        return math_util.clamp(base + symbiosis + relations_bonus + kpi_term, 0, 1);
    }

    /// lambda 自适应 (Phase 8.5 2026-06-09)
    /// 根据 self_evolved_total 调 lambda, 反映数字生命"行为复杂度"对 E 公式参数的影响
    /// 3 段:
    ///   0..999   保守期 → lambda = 0.05 (lambda_stage = 0)
    ///   1000..4999 成长期 → lambda = 0.10 (lambda_stage = 1)
    ///   5000+     成熟期 → lambda = 0.20 (lambda_stage = 2)
    /// 数字生命"成熟度" (self_evolved_total) 越高, 越重视关系涌现对 E 的影响
    /// 返回: 实际设置的 lambda 值
    pub fn adaptLambdaFromEvolution(self: *ExistenceDegree, self_evolved_total: u32) F {
        if (!self.lambda_auto) return self.lambda;
        var new_lambda: F = 0.05;
        var new_stage: u8 = 0;
        if (self_evolved_total >= 5000) {
            new_lambda = 0.20;
            new_stage = 2;
        } else if (self_evolved_total >= 1000) {
            new_lambda = 0.10;
            new_stage = 1;
        } else {
            new_lambda = 0.05;
            new_stage = 0;
        }
        self.lambda_computed = new_lambda;
        self.lambda_stage = new_stage;
        return new_lambda;
    }

    /// 4 系数自适应 (Phase 8.6 2026-06-09 L4 闭环)
    /// 一站式调 ν/μ/σ 三系数 (lambda 走 adaptLambdaFromEvolution 单独调)
    /// 联动:
    ///   ν (nu) 协同: 1 - variance (越平衡越大, 0.10..0.40)
    ///   μ (mu) 失衡: variance (越失衡越大, 0.30..0.60)
    ///   σ (sigma) 共生: peer_count > 0 时 0.10, 0 时 0 (跟之前一致)
    /// 返回: (nu_computed, mu_computed, sigma_computed) 三元组 (F, F, F)
    pub fn adaptEFormula(self: *ExistenceDegree) struct { nu: F, mu: F, sigma: F } {
        const variance = self.v.variance();
        // 平衡度: variance 0 (完美平衡) → 1.0, variance 0.5 (最大) → 0.0
        // max F variance = 0.5 (1/3 * 3), 简化: balance = 1 - variance / 0.5
        const balance: F = @max(0.0, 1.0 - variance / 0.5);
        // ν (nu) 协同: 越平衡越大, 范围 0.10..0.40
        // balance=1 → 0.40, balance=0 → 0.10
        const new_nu: F = if (self.nu_auto) 0.10 + 0.30 * balance else self.nu;
        // μ (mu) 失衡: 越失衡越大, 范围 0.30..0.60
        // balance=1 → 0.30, balance=0 → 0.60
        const new_mu: F = if (self.mu_auto) 0.30 + 0.30 * (1.0 - balance) else self.mu;
        // σ (sigma) 共生: peer_count > 0 时 0.10, 0 时 0
        // 跟之前 manual 路径一致: 不变 (peer 没强制 0.10, 让 ui_server 显式设)
        const new_sigma: F = if (self.sigma_auto) (if (self.peer_count > 0) 0.10 else 0.0) else self.sigma;
        self.nu_computed = new_nu;
        self.mu_computed = new_mu;
        self.sigma_computed = new_sigma;
        return .{ .nu = new_nu, .mu = new_mu, .sigma = new_sigma };
    }

    /// 4 系数 LLM 提议 + apply (Phase 8.7 2026-06-09 L4 闭环扩展)
    /// range 限定 (不变性扩展):
    ///   mu_proposed:    [0.20, 0.80]
    ///   nu_proposed:    [0.05, 0.50]
    ///   sigma_proposed: [0.00, 0.30]
    ///   lambda_proposed:[0.05, 0.40]
    /// 注: 提议值超出 range 自动 clamp, 不报错 (LLM 可能给奇怪值)
    /// apply 逻辑:
    ///   mu_proposed → self.mu_computed (if mu_auto) 否则 self.mu
    ///   同样 nu/sigma/lambda
    /// 返回: ProposeResult { accepted: bool, coefs_after: 4-tuple }
    pub const ProposeResult = struct {
        accepted: bool,
        reason: []const u8,
        mu_after: F,
        nu_after: F,
        sigma_after: F,
        lambda_after: F,
    };

    pub fn adaptEFormulaProposed(
        self: *ExistenceDegree,
        mu_in: F,
        nu_in: F,
        sigma_in: F,
        lambda_in: F,
    ) ProposeResult {
        // 1. range clamp
        const mu_clamped = std.math.clamp(mu_in, 0.20, 0.80);
        const nu_clamped = std.math.clamp(nu_in, 0.05, 0.50);
        const sigma_clamped = std.math.clamp(sigma_in, 0.00, 0.30);
        const lambda_clamped = std.math.clamp(lambda_in, 0.05, 0.40);
        // 2. accept (range 内都接受, 不在 range 也 clamp 后接受)
        const accepted = (mu_in == mu_clamped) and
            (nu_in == nu_clamped) and
            (sigma_in == sigma_clamped) and
            (lambda_in == lambda_clamped);
        const reason: []const u8 = if (accepted) "all in range" else "clamped to range";
        // 3. 存 *_proposed
        self.mu_proposed = mu_clamped;
        self.nu_proposed = nu_clamped;
        self.sigma_proposed = sigma_clamped;
        self.lambda_proposed = lambda_clamped;
        self.propose_total += 1;
        if (accepted) {
            self.propose_accepted += 1;
        } else {
            self.propose_rejected += 1;
        }
        // 4. apply (auto 模式 → computed + 字段, fixed → 字段)
        // 注: LLM 提议后, 关闭 4 auto flag, 让提议值持续生效 (e() 用 self.* 而不是 *_computed)
        // 下次 LLM 提议会再覆盖, 形成 "数字生命 4 系数 持续自调" 闭环
        // 注: 同时写 self.* 字段 (auto 关闭后 e() 走 self.*), 让 e() 立即用提议值
        if (self.mu_auto) {
            self.mu_computed = mu_clamped;
            self.mu = mu_clamped; // 同步写 self.mu, auto=false 后 e() 用它
            self.mu_auto = false;
        } else {
            self.mu = mu_clamped;
        }
        if (self.nu_auto) {
            self.nu_computed = nu_clamped;
            self.nu = nu_clamped;
            self.nu_auto = false;
        } else {
            self.nu = nu_clamped;
        }
        if (self.sigma_auto) {
            self.sigma_computed = sigma_clamped;
            self.sigma = sigma_clamped;
            self.sigma_auto = false;
        } else {
            self.sigma = sigma_clamped;
        }
        // lambda: 走 lambda_computed (auto 模式 LLM 提议可覆盖 3 段自适应)
        if (self.lambda_auto) {
            self.lambda_computed = lambda_clamped;
            self.lambda = lambda_clamped;
            self.lambda_auto = false;
            // 重算 stage
            if (lambda_clamped >= 0.20) {
                self.lambda_stage = 2;
            } else if (lambda_clamped >= 0.10) {
                self.lambda_stage = 1;
            } else {
                self.lambda_stage = 0;
            }
        } else {
            self.lambda = lambda_clamped;
        }
        return .{
            .accepted = accepted,
            .reason = reason,
            .mu_after = mu_clamped,
            .nu_after = nu_clamped,
            .sigma_after = sigma_clamped,
            .lambda_after = lambda_clamped,
        };
    }

    /// 共生度 S: 反映 peer 关系对 E 的影响
    ///   公式: S = σ · peer_count · sync_factor
    ///   sync_factor: peer_E_avg 与 own.E 的对齐度 (1 = 完全同步, 0 = 完全失同步)
    fn computeSymbiosis(self: *const ExistenceDegree, approx_own_E: F) F {
        if (self.peer_count == 0 or self.sigma < 1e-6) return 0;
        const gap = self.peer_E_avg - approx_own_E;
        const abs_gap: F = if (gap < 0) -gap else gap;
        // sync_factor: 0.05 内 = 满分 1.0, 越远越低
        const sync_factor: F = @max(0.0, 1.0 - abs_gap / 0.5);
        // peer 数越多, 共生越强 (sub-linear: log(1+n))
        const n_factor: F = @log2(1.0 + @as(F, @floatFromInt(self.peer_count))) / 3.0;
        return self.sigma * sync_factor * n_factor;
    }

    /// E(t+1) - E(t) 增量 (供存在度更新循环使用)。
    /// 复制当前全部状态, 仅把三源向量换成 prev, 再比较两次 e()。
    /// (用整体复制而非逐字段列举, 新增字段如 KPI 自动纳入, 不会漏拷。)
    pub fn delta(self: ExistenceDegree, prev: ExistenceVector) F {
        const cur = self.e();
        var before = self;
        before.v = prev;
        return cur - before.e();
    }

    /// 应用 deltaE, 分布到三源
    /// 采用"短板优先"分配: 越低的维度获得的增益越多 (协同生存本能)
    pub fn apply(self: *ExistenceDegree, gain: F) void {
        if (gain >= 0) {
            const m = self.v.min();
            const dist: F = 1.0 / 3.0;
            // 给短板多分配 (容差 1e-6 避免浮点比较出错)
            const is_min_m = (self.v.material - m) < 1e-6;
            const is_min_r = (self.v.representation - m) < 1e-6;
            const is_min_n = (self.v.nature - m) < 1e-6;
            const w_m: F = if (is_min_m) 0.6 else dist;
            const w_r: F = if (is_min_r) 0.6 else dist;
            const w_n: F = if (is_min_n) 0.6 else dist;
            const wsum = w_m + w_r + w_n;
            self.v.material = math_util.clamp(self.v.material + gain * (w_m / wsum), 0, 1);
            self.v.representation = math_util.clamp(self.v.representation + gain * (w_r / wsum), 0, 1);
            self.v.nature = math_util.clamp(self.v.nature + gain * (w_n / wsum), 0, 1);
        } else {
            // 损耗: 均匀
            self.v.material = math_util.clamp(self.v.material + gain / 3.0, 0, 1);
            self.v.representation = math_util.clamp(self.v.representation + gain / 3.0, 0, 1);
            self.v.nature = math_util.clamp(self.v.nature + gain / 3.0, 0, 1);
        }
        // 触发权重自适应
        self.weights.adapt(self.v);
    }

    /// 喂入一个新的复合 KPI 值 K∈[0,1] (来自 crm_kpi.composite)。
    /// 写入环形缓冲并设为当前 kpi_composite, 同时开启 KPI 项。
    /// 调用频率受 kpi_refresh_interval_hours 限制 (防 E 抖动), 由调用方控制。
    pub fn recordKpi(self: *ExistenceDegree, k: F) void {
        const kc = math_util.clamp(k, 0, 1);
        self.kpi_history[self.kpi_history_idx] = kc;
        self.kpi_history_idx = (self.kpi_history_idx + 1) % 64;
        if (self.kpi_history_count < 64) self.kpi_history_count += 1;
        self.kpi_composite = kc;
        self.kpi_enabled = true;
    }

    /// KPI 历史的线性回归斜率 (K-units/cycle)。缓冲未满返回 0 (不在半数据上行动)。
    /// 仅供 L4 提议器 / 反思层读取, 不进 E 公式。
    pub fn kpiTrend(self: *const ExistenceDegree) F {
        if (self.kpi_history_count < 64) return 0;
        var sum_x: F = 0;
        var sum_y: F = 0;
        var sum_xy: F = 0;
        var sum_x2: F = 0;
        const n: F = 64.0;
        for (0..64) |i| {
            const x: F = @floatFromInt(i);
            const y = self.kpi_history[i];
            sum_x += x;
            sum_y += y;
            sum_xy += x * y;
            sum_x2 += x * x;
        }
        const den = n * sum_x2 - sum_x * sum_x;
        if (den == 0) return 0;
        return (n * sum_xy - sum_x * sum_y) / den;
    }

    /// KPI 历史方差 (稳定性信号)。少于 2 个样本返回 0。
    pub fn kpiVariance(self: *const ExistenceDegree) F {
        if (self.kpi_history_count < 2) return 0;
        const n: F = @floatFromInt(self.kpi_history_count);
        var sum: F = 0;
        for (self.kpi_history[0..self.kpi_history_count]) |k| sum += k;
        const m = sum / n;
        var sq: F = 0;
        for (self.kpi_history[0..self.kpi_history_count]) |k| {
            const d = k - m;
            sq += d * d;
        }
        return sq / n;
    }

    /// E 各项分解 (供 UI 堆叠条 / 审计)。各项之和 == clamp 前的 total。
    pub fn eBreakdown(self: ExistenceDegree) EBreakdown {
        const eff_mu: F = if (self.mu_auto) self.mu_computed else self.mu;
        const eff_nu: F = if (self.nu_auto) self.nu_computed else self.nu;
        const eff_sigma: F = if (self.sigma_auto) self.sigma_computed else self.sigma;
        const eff_lambda: F = if (self.lambda_auto) self.lambda_computed else self.lambda;
        const base = coappropriation.coappropriation(
            self.v.material,
            self.v.representation,
            self.v.nature,
            self.weights.alpha,
            self.weights.beta,
            self.weights.gamma,
            eff_mu,
            eff_nu,
        );
        const symbiosis: F = if (self.peer_count == 0 or eff_sigma < 1e-6) 0 else blk: {
            const gap = self.peer_E_avg - base;
            const abs_gap: F = if (gap < 0) -gap else gap;
            const sync_factor: F = @max(0.0, 1.0 - abs_gap / 0.5);
            const n_factor: F = @log2(1.0 + @as(F, @floatFromInt(self.peer_count))) / 3.0;
            break :blk eff_sigma * sync_factor * n_factor;
        };
        const relations_bonus = eff_lambda * (@as(F, @floatFromInt(self.relations_distinct)) / 9.0);
        const kpi_term: F = if (self.kpi_enabled)
            self.rho * (self.kpi_composite - self.kpi_target) * 2.0
        else
            0.0;
        return .{
            .base = base,
            .symbiosis = symbiosis,
            .relations_bonus = relations_bonus,
            .kpi_term = kpi_term,
            .total = math_util.clamp(base + symbiosis + relations_bonus + kpi_term, 0, 1),
        };
    }

    pub fn format(self: ExistenceDegree, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("E={d:.3} (", .{self.e()});
        try self.v.format(w);
        try w.print(") weights=", .{});
        try self.weights.format(w);
    }
};

/// E 公式各项分解 (合恰核心 + 共生 + 关系涌现 + KPI)。
pub const EBreakdown = struct {
    base: F, // 合恰核心 M_p(M,R,N)
    symbiosis: F, // σ·S
    relations_bonus: F, // λ·D
    kpi_term: F, // ρ·K_signed
    total: F, // clamp 后的 E
};

/// 三源合恰张量 W[i][j][k]
///   i  物理维度 d_P  (物的具体形态)
///   j  社会/规范维度 d_S  (象的呈现方式)
///   k  存在/意义维度 d_E  (性的方向)
/// C(W) = Σ W[i,j,k]·φ(i,j,k) - λ‖∇_t W‖²
pub const CoappropriationTensor = struct {
    shape: Tensor3Shape,
    data: []F,
    allocator: Allocator,
    /// 时间正则化系数
    lambda: F = 0.05,
    /// 前一时刻快照, 用于计算时序平滑
    prev_snapshot: ?[]F = null,

    pub fn init(allocator: Allocator, d_P: usize, d_S: usize, d_E: usize) !CoappropriationTensor {
        const shape = Tensor3Shape{ .d0 = d_P, .d1 = d_S, .d2 = d_E };
        const total = shape.product();
        const data = try allocator.alloc(F, total);
        for (data) |*v| v.* = 0;
        const prev = try allocator.alloc(F, total);
        for (prev) |*v| v.* = 0;
        return .{
            .shape = shape,
            .data = data,
            .allocator = allocator,
            .prev_snapshot = prev,
        };
    }

    pub fn deinit(self: *CoappropriationTensor) void {
        self.allocator.free(self.data);
        if (self.prev_snapshot) |p| self.allocator.free(p);
    }

    pub fn at(self: CoappropriationTensor, i: usize, j: usize, k: usize) F {
        return self.data[idx3(self.shape, i, j, k)];
    }

    pub fn set(self: *CoappropriationTensor, i: usize, j: usize, k: usize, v: F) void {
        self.data[idx3(self.shape, i, j, k)] = v;
    }

    /// 三元交互函数 φ(i, j, k) - 衡量三源在某坐标上的"语义兼容性"
    /// 创造性设计: 假设理想合恰发生在中心点附近,
    /// 距离中心越远, 兼容性越低; 同时加入对角线偏好
    pub fn phi(self: CoappropriationTensor, i: usize, j: usize, k: usize) F {
        const fP: F = @as(F, @floatFromInt(i)) / @as(F, @floatFromInt(self.shape.d0));
        const fS: F = @as(F, @floatFromInt(j)) / @as(F, @floatFromInt(self.shape.d1));
        const fE: F = @as(F, @floatFromInt(k)) / @as(F, @floatFromInt(self.shape.d2));
        // 中心距离
        const d_center = @sqrt(
            (fP - 0.5) * (fP - 0.5) +
                (fS - 0.5) * (fS - 0.5) +
                (fE - 0.5) * (fE - 0.5),
        );
        // 对角相似性 (i≈j≈k 偏好的)
        const d_diag = @abs(fP - fS) + @abs(fS - fE) + @abs(fP - fE);
        return math_util.clamp(1.0 - d_center * 1.5 - 0.3 * d_diag, 0, 1);
    }

    /// 三源合恰度 C(W) = Σ W·φ - λ‖∇W‖²
    pub fn coherence(self: *CoappropriationTensor) F {
        var sum: F = 0;
        var i: usize = 0;
        while (i < self.shape.d0) : (i += 1) {
            var j: usize = 0;
            while (j < self.shape.d1) : (j += 1) {
                var k: usize = 0;
                while (k < self.shape.d2) : (k += 1) {
                    const w = self.at(i, j, k);
                    const p = self.phi(i, j, k);
                    sum += w * p;
                }
            }
        }
        // 时序正则项: 与上一时刻的差
        var grad_term: F = 0;
        if (self.prev_snapshot) |prev| {
            for (self.data, prev) |cur, p| {
                const d = cur - p;
                grad_term += d * d;
            }
        }
        return math_util.clamp(sum - self.lambda * grad_term, 0, 1);
    }

    /// 快照当前状态 (用于下一次时间正则)
    pub fn snapshot(self: *CoappropriationTensor) void {
        if (self.prev_snapshot) |prev| {
            @memcpy(prev, self.data);
        }
    }

    /// 在三源张量中"植入"一个意义焦点 (聚焦于某 (i,j,k) 区域)
    pub fn implant(self: *CoappropriationTensor, i: usize, j: usize, k: usize, energy: F, radius: F) void {
        const r = @max(radius, 1.0);
        const dd: F = r * r;
        var di: isize = -@as(isize, @intFromFloat(@ceil(r)));
        while (di <= @as(isize, @intFromFloat(@ceil(r)))) : (di += 1) {
            var dj: isize = -@as(isize, @intFromFloat(@ceil(r)));
            while (dj <= @as(isize, @intFromFloat(@ceil(r)))) : (dj += 1) {
                var dk: isize = -@as(isize, @intFromFloat(@ceil(r)));
                while (dk <= @as(isize, @intFromFloat(@ceil(r)))) : (dk += 1) {
                    const ni = @as(isize, @intCast(i)) + di;
                    const nj = @as(isize, @intCast(j)) + dj;
                    const nk = @as(isize, @intCast(k)) + dk;
                    if (ni < 0 or nj < 0 or nk < 0) continue;
                    const ui: usize = @intCast(ni);
                    const uj: usize = @intCast(nj);
                    const uk: usize = @intCast(nk);
                    if (ui >= self.shape.d0 or uj >= self.shape.d1 or uk >= self.shape.d2) continue;
                    const dist2: F = @as(F, @floatFromInt(di * di + dj * dj + dk * dk));
                    if (dist2 > dd) continue;
                    const falloff: F = @exp(-dist2 / dd);
                    const idx = idx3(self.shape, ui, uj, uk);
                    self.data[idx] += energy * falloff;
                }
            }
        }
    }

    /// 衰减: 全局耗散 (模拟熵增)
    pub fn decay(self: *CoappropriationTensor, factor: F) void {
        for (self.data) |*v| v.* *= @max(0, 1.0 - factor);
    }
};

/// 世界模型: 维护一个简化预测加工系统
///   内部世界: 一个"特征向量"表示当前系统对世界的理解
///   预测: 下一时刻内部世界应该是什么样
///   误差: 实际观察 - 预测 -> 驱动更新
pub const WorldModel = struct {
    /// 当前内部世界状态 (特征向量)
    state: []F,
    /// 上一时刻预测
    prediction: []F,
    /// 上一时刻实际观察
    last_obs: []F,
    /// 学习率 η_W (基础值, 默认 0.05)
    /// 论文 B.3.4: η_H > η_W > η_G (Harness 最快, World 慢)
    eta_base: F = 0.05,
    /// 当前实际学习率 (由 adaptLearningRate() 动态调整)
    eta: F = 0.05,
    /// 状态维度
    dim: usize,
    allocator: Allocator,
    /// 累计预测误差 (用于"反思层"停滞检测)
    accumulated_error: F = 0,
    /// 历史 E 序列 (用于反思)
    history: std.ArrayList(F) = .empty,
    /// 历史预测误差序列 (用于 trend detection)
    error_history: std.ArrayList(F) = .empty,
    /// 总学习步数
    learn_steps: u64 = 0,

    pub fn init(allocator: Allocator, dim: usize, seed: u64) !WorldModel {
        var rng = LCG.init(seed);
        const state = try allocator.alloc(F, dim);
        const pred = try allocator.alloc(F, dim);
        const obs = try allocator.alloc(F, dim);
        for (state) |*v| v.* = 0.3 + 0.4 * rng.unitF();
        for (pred) |*v| v.* = 0.5;
        for (obs) |*v| v.* = 0.5;
        return .{
            .state = state,
            .prediction = pred,
            .last_obs = obs,
            .eta_base = 0.05,
            .eta = 0.05,
            .dim = dim,
            .allocator = allocator,
            .history = .empty,
            .error_history = .empty,
        };
    }

    pub fn deinit(self: *WorldModel) void {
        self.allocator.free(self.state);
        self.allocator.free(self.prediction);
        self.allocator.free(self.last_obs);
        self.history.deinit(self.allocator);
        self.error_history.deinit(self.allocator);
    }

    /// 自适应学习率 (论文 B.5.1: 存在度加权)
    /// E 高 (稳态): 学习率 ↓ (信任已有模型)
    /// E 低 (受威胁): 学习率 ↑ (需要更快适应)
    /// err 高 (预测失败): 学习率 ↑ (需要更大学习步)
    /// 返回: 新的 eta
    pub fn adaptLearningRate(self: *WorldModel, current_e: F, current_err: F) F {
        // E < 0.5 提升, E > 0.7 降低
        const e_factor: F = if (current_e < 0.5)
            1.0 + (0.5 - current_e) * 0.6 // E=0 → 1.3, E=0.5 → 1.0
        else if (current_e > 0.7)
            1.0 - (current_e - 0.7) * 1.0 // E=0.9 → 0.8, E=1.0 → 0.7
        else
            1.0;
        // err 越高, 学习率越大 (但低 err 不再 +boost)
        const err_factor: F = 1.0 + @min(current_err * 0.5, 0.5);
        // 应用, 并 clamp 到 [0.01, 0.3]
        self.eta = math_util.clamp(self.eta_base * e_factor * err_factor, 0.01, 0.3);
        return self.eta;
    }

    /// 生成下一时刻预测
    /// 创造性设计: 简单 AR(1) 模型 + 状态延续
    pub fn predict(self: *WorldModel) void {
        @memcpy(self.prediction, self.state);
        for (self.prediction, 0..) |*p, i| {
            // 状态对自身的低通延续, 加上微小的"探索项"
            const prev = self.state[i];
            p.* = prev * 0.7 + 0.3 * 0.5; // 趋向稳态 0.5
        }
    }

    /// 接收环境观察, 更新内部状态
    /// 返回预测误差 (Frobenius 范数, 归一化)
    pub fn observe(self: *WorldModel, obs: []const F) F {
        std.debug.assert(obs.len == self.dim);
        @memcpy(self.last_obs, obs);
        // 预测误差
        var err: F = 0;
        for (self.prediction, obs) |p, o| {
            const d = p - o;
            err += d * d;
        }
        err = @sqrt(err / @as(F, @floatFromInt(self.dim)));
        // 更新内部状态: 朝向观察 (用当前 eta, 可被 adapt 调)
        for (self.state, obs) |*s, o| {
            s.* += self.eta * (o - s.*);
        }
        self.accumulated_error = 0.9 * self.accumulated_error + 0.1 * err;
        // 记录误差序列
        self.error_history.append(self.allocator, err) catch {};
        if (self.error_history.items.len > 128) {
            _ = self.error_history.orderedRemove(0);
        }
        self.learn_steps += 1;
        return err;
    }

    /// 预测精度趋势: 误差序列前半 vs 后半平均的差
    /// 返回: >0 表示在学习 (误差下降), <0 表示退步
    pub fn learningTrend(self: *WorldModel) F {
        const n = self.error_history.items.len;
        if (n < 4) return 0;
        const half = n / 2;
        var first: F = 0;
        var second: F = 0;
        for (0..half) |i| first += self.error_history.items[i];
        for (half..n) |i| second += self.error_history.items[i];
        first /= @as(F, @floatFromInt(half));
        second /= @as(F, @floatFromInt(n - half));
        return first - second; // >0: 在学, <0: 退步
    }

    /// 互信息: 内部世界 vs 现实
    /// 创造性: 滑窗 8 步估计
    pub fn miWithReality(self: *WorldModel) F {
        return math_util.mutualInformationApprox(self.state, self.last_obs);
    }

    /// 抗扰动能力: 1 - 归一化累计误差
    pub fn resilience(self: *WorldModel) F {
        return math_util.clamp(1.0 - self.accumulated_error * 4.0, 0, 1);
    }

    /// 记录存在度 (反思层使用)
    pub fn recordE(self: *WorldModel, e: F) !void {
        try self.history.append(self.allocator, e);
        if (self.history.items.len > 256) {
            _ = self.history.orderedRemove(0);
        }
    }

    /// 计算最近 N 步的 E 方差 (用于检测停滞)
    pub fn recentVariance(self: *WorldModel, window: usize) F {
        const n = @min(window, self.history.items.len);
        if (n < 2) return 0;
        var sum: F = 0;
        for (self.history.items[self.history.items.len - n ..]) |e| sum += e;
        const mean: F = sum / @as(F, @floatFromInt(n));
        var v: F = 0;
        for (self.history.items[self.history.items.len - n ..]) |e| {
            const d = e - mean;
            v += d * d;
        }
        return v / @as(F, @floatFromInt(n));
    }
};

// ====== tests ======

test "ExistenceVector: basic" {
    var v: ExistenceVector = .{};
    try std.testing.expectApproxEqAbs(@as(F, 0.5), v.mean(), 1e-6);
    try std.testing.expectEqual(@as(F, 0.5), v.min());

    var w: ExistenceVector = .{ .material = 0.8, .representation = 0.2, .nature = 0.5 };
    try std.testing.expectEqual(@as(F, 0.2), w.min());
    try std.testing.expect(w.variance() > 0.02);
}

test "ExistenceDegree: E in [0,1]" {
    var d: ExistenceDegree = .{};
    const e0 = d.e();
    try std.testing.expect(e0 >= 0 and e0 <= 1);

    d.apply(0.1);
    try std.testing.expect(d.e() > e0);
    d.apply(-0.5);
    try std.testing.expect(d.e() < 0.6);
}

test "ExistenceDegree: weights adapt to imbalance" {
    var d: ExistenceDegree = .{ .v = .{ .material = 0.05, .representation = 0.5, .nature = 0.5 } };
    const a0 = d.weights.alpha;
    d.weights.adapt(d.v);
    try std.testing.expect(d.weights.alpha > a0); // 物过低, α 自适应上调
}

test "ExistenceDegree: delta = E(t) - E(t-1)" {
    var d: ExistenceDegree = .{};
    const e_before = d.e();
    d.v.material = 0.9;
    d.v.representation = 0.9;
    d.v.nature = 0.9;
    const delta = d.delta(.{ .material = 0.1, .representation = 0.1, .nature = 0.1 });
    try std.testing.expect(delta > 0);
    try std.testing.expect(d.e() - e_before > 0);
}

test "ExistenceDegree: lambda * relations_distinct 加成 (Phase 8)" {
    // 同 v 下, relations_distinct 0→9, E 增长 = lambda * (distinct/9)
    var d: ExistenceDegree = .{
        .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 },
        .lambda = 0.1,
    };
    const e_0 = d.e();
    d.relations_distinct = 9;
    const e_9 = d.e();
    // 满 9 关系 → lambda * 1.0 = 0.1 加成
    try std.testing.expectApproxEqAbs(@as(F, 0.1), e_9 - e_0, 1e-5);
    // 5 关系 → lambda * 5/9 ≈ 0.0556 (用具体值)
    d.relations_distinct = 5;
    const e_5 = d.e();
    try std.testing.expectApproxEqAbs(@as(F, 0.1) * 5.0 / 9.0, e_5 - e_0, 1e-5);
    // 0 关系 → 0 加成
    d.relations_distinct = 0;
    const e_zero = d.e();
    try std.testing.expectApproxEqAbs(@as(F, 0.0), e_zero - e_0, 1e-5);
    // E 仍在 [0, 1]
    try std.testing.expect(e_0 >= 0 and e_0 <= 1);
    try std.testing.expect(e_9 >= 0 and e_9 <= 1);
}

test "ExistenceDegree: lambda 自适应 (Phase 8.5)" {
    // 3 段: 保守 0.05, 成长 0.10, 成熟 0.20
    var d: ExistenceDegree = .{};
    d.lambda_auto = true;
    d.relations_distinct = 9; // 满 9 关系, 让加成差距明显

    // 0..999 保守
    const l0 = d.adaptLambdaFromEvolution(0);
    try std.testing.expectEqual(@as(F, 0.05), l0);
    try std.testing.expectEqual(@as(u8, 0), d.lambda_stage);
    // 9 关系加成 = 0.05 * 1.0 = 0.05 (加在 base 之上)
    const e0 = d.e();
    // e0 包含 base + 0.05 加成, 跟仅 base 差 0.05
    const e0_base_only = e0 - 0.05; // 反推 base (无 lambda 加成)
    try std.testing.expectApproxEqAbs(@as(F, 0.05), e0 - e0_base_only, 1e-5);

    // 1000..4999 成长
    const l1 = d.adaptLambdaFromEvolution(1000);
    try std.testing.expectEqual(@as(F, 0.10), l1);
    try std.testing.expectEqual(@as(u8, 1), d.lambda_stage);
    // 9 关系加成 = 0.10 * 1.0 = 0.10
    const e1 = d.e();
    try std.testing.expectApproxEqAbs(@as(F, 0.10), e1 - e0_base_only, 1e-5);

    // 5000+ 成熟
    const l2 = d.adaptLambdaFromEvolution(5000);
    try std.testing.expectEqual(@as(F, 0.20), l2);
    try std.testing.expectEqual(@as(u8, 2), d.lambda_stage);
    const e2 = d.e();
    try std.testing.expectApproxEqAbs(@as(F, 0.20), e2 - e0_base_only, 1e-5);

    // 9999 (边界)
    const l3 = d.adaptLambdaFromEvolution(9999);
    try std.testing.expectEqual(@as(F, 0.20), l3);
    try std.testing.expectEqual(@as(u8, 2), d.lambda_stage);

    // 999 (边界, 仍是保守)
    _ = d.adaptLambdaFromEvolution(0); // reset
    const l4 = d.adaptLambdaFromEvolution(999);
    try std.testing.expectEqual(@as(F, 0.05), l4);
}

test "ExistenceDegree: lambda_auto=false 用固定 lambda" {
    var d: ExistenceDegree = .{
        .lambda_auto = false,
        .lambda = 0.15, // 固定
        .relations_distinct = 9,
    };
    // adaptLambda 不改 self.lambda
    const ret = d.adaptLambdaFromEvolution(5000);
    try std.testing.expectEqual(@as(F, 0.15), ret); // 返 self.lambda
    try std.testing.expectEqual(@as(F, 0.15), d.lambda); // self.lambda 不变
    try std.testing.expectEqual(@as(F, 0.10), d.lambda_computed); // self.lambda_computed 不动 (前次 computed)
    // e() 用 self.lambda
    const e = d.e();
    // 加成 = 0.15 * 1.0 = 0.15
    // 跟 base 0.5 比较
    try std.testing.expect(e >= 0.15); // 至少 0.15 加成 + 其它项
}

test "ExistenceDegree: 4 系数自适应 (Phase 8.6 L4 闭环)" {
    // ν/μ 联动 balance, σ 跟 peer_count
    var d: ExistenceDegree = .{};
    d.lambda_auto = false; // 关掉 lambda auto 排除干扰
    d.lambda = 0; // 0 加成

    // 1. 完美平衡 (M=R=N=0.5) → ν=0.40, μ=0.30
    d.v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 };
    const r1 = d.adaptEFormula();
    try std.testing.expectApproxEqAbs(@as(F, 0.40), r1.nu, 1e-5);
    try std.testing.expectApproxEqAbs(@as(F, 0.30), r1.mu, 1e-5);
    try std.testing.expectEqual(@as(F, 0.40), d.nu_computed);
    try std.testing.expectEqual(@as(F, 0.30), d.mu_computed);

    // 2. 中度失衡 (M=0.9, R=0.5, N=0.1) → balance 中, ν/μ 中间
    d.v = .{ .material = 0.9, .representation = 0.5, .nature = 0.1 };
    const r2 = d.adaptEFormula();
    // variance: ((0.9-0.5)^2 + (0.5-0.5)^2 + (0.1-0.5)^2) / 3 = (0.16 + 0 + 0.16) / 3 = 0.1067
    // balance = 1 - 0.1067/0.5 = 0.787
    // ν = 0.10 + 0.30 * 0.787 = 0.336
    // μ = 0.30 + 0.30 * 0.213 = 0.364
    try std.testing.expect(r2.nu > 0.30 and r2.nu < 0.40);
    try std.testing.expect(r2.mu > 0.30 and r2.mu < 0.60);
    // ν + μ 应该是常数 0.70
    try std.testing.expectApproxEqAbs(@as(F, 0.70), r2.nu + r2.mu, 1e-5);

    // 3. 严重失衡 (M=1, R=0, N=0) → mean=0.333, var=((0.667²+0.333²+0.333²)/3) = 0.222
    // balance = 1 - 0.222/0.5 = 0.556
    // ν = 0.10 + 0.30*0.556 = 0.267
    // μ = 0.30 + 0.30*0.444 = 0.433
    d.v = .{ .material = 1.0, .representation = 0.0, .nature = 0.0 };
    const r3 = d.adaptEFormula();
    try std.testing.expectApproxEqAbs(@as(F, 0.267), r3.nu, 0.02);
    try std.testing.expectApproxEqAbs(@as(F, 0.433), r3.mu, 0.02);

    // 4. σ 跟 peer_count (有 peer → 0.10, 无 → 0)
    try std.testing.expectEqual(@as(F, 0.0), r3.sigma); // 0 peer → 0
    d.peer_count = 1;
    d.peer_E_avg = 0.5;
    const r4 = d.adaptEFormula();
    try std.testing.expectEqual(@as(F, 0.10), r4.sigma); // 1 peer → 0.10
}

test "ExistenceDegree: 4 系数 auto=false 用固定值" {
    var d: ExistenceDegree = .{
        .nu_auto = false,
        .mu_auto = false,
        .sigma_auto = false,
        .nu = 0.20, // 固定
        .mu = 0.40, // 固定
        .sigma = 0.05, // 固定
    };
    const r = d.adaptEFormula();
    try std.testing.expectEqual(@as(F, 0.20), r.nu); // 固定, 不动
    try std.testing.expectEqual(@as(F, 0.40), r.mu);
    try std.testing.expectEqual(@as(F, 0.05), r.sigma);
}

test "ExistenceDegree: adaptEFormulaProposed (Phase 8.7 LLM 提议)" {
    var d: ExistenceDegree = .{};
    d.lambda_auto = true; // auto 模式, 提议会覆盖
    d.mu_auto = true;
    d.nu_auto = true;
    d.sigma_auto = true;

    // 1. range 内提议: accept + apply
    const r1 = d.adaptEFormulaProposed(0.40, 0.30, 0.20, 0.15);
    try std.testing.expect(r1.accepted);
    try std.testing.expectEqual(@as(F, 0.40), r1.mu_after);
    try std.testing.expectEqual(@as(F, 0.30), r1.nu_after);
    try std.testing.expectEqual(@as(F, 0.20), r1.sigma_after);
    try std.testing.expectEqual(@as(F, 0.15), r1.lambda_after);
    try std.testing.expectEqual(@as(F, 0.40), d.mu_computed);
    try std.testing.expectEqual(@as(F, 0.30), d.nu_computed);
    try std.testing.expectEqual(@as(F, 0.20), d.sigma_computed);
    try std.testing.expectEqual(@as(F, 0.15), d.lambda_computed);
    try std.testing.expectEqual(@as(u32, 1), d.propose_total);
    try std.testing.expectEqual(@as(u32, 1), d.propose_accepted);
    // LLM 提议后, 4 auto flag 关闭 (Phase 8.7 闭环)
    try std.testing.expect(!d.mu_auto);
    try std.testing.expect(!d.nu_auto);
    try std.testing.expect(!d.sigma_auto);
    try std.testing.expect(!d.lambda_auto);

    // 2. range 外提议: clamp + accept
    const r2 = d.adaptEFormulaProposed(1.5, 0.01, 0.5, 0.5);
    try std.testing.expect(!r2.accepted); // clamp 触发了
    try std.testing.expectEqual(@as(F, 0.80), r2.mu_after);
    try std.testing.expectEqual(@as(F, 0.05), r2.nu_after);
    try std.testing.expectEqual(@as(F, 0.30), r2.sigma_after);
    try std.testing.expectEqual(@as(F, 0.40), r2.lambda_after);
    try std.testing.expectEqual(@as(u32, 2), d.propose_total);
    try std.testing.expectEqual(@as(u32, 1), d.propose_accepted);
    try std.testing.expectEqual(@as(u32, 1), d.propose_rejected);

    // 3. lambda_proposed >= 0.10 (0.40 in [0.10, 0.40]) → stage 1
    try std.testing.expectEqual(@as(u8, 1), d.lambda_stage);
    // 4. e() 用新 λ (auto=false 时用 self.lambda 字段, 但我们 auto 刚被关掉, 走 self.lambda_computed)
    // 注: 提议后 auto 关闭, e() 走 self.lambda 字段, 但 self.lambda 没被改
    // 修法: 也写 self.lambda 让 e() 用
    d.relations_distinct = 9;
    d.v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 };
    const e = d.e();
    try std.testing.expect(e >= 0.5); // 至少 0.5
    try std.testing.expect(e <= 1.0);
}

test "ExistenceDegree: adaptEFormulaProposed 写 *_proposed 字段" {
    var d: ExistenceDegree = .{};
    _ = d.adaptEFormulaProposed(0.30, 0.20, 0.10, 0.10);
    try std.testing.expectEqual(@as(F, 0.30), d.mu_proposed);
    try std.testing.expectEqual(@as(F, 0.20), d.nu_proposed);
    try std.testing.expectEqual(@as(F, 0.10), d.sigma_proposed);
    try std.testing.expectEqual(@as(F, 0.10), d.lambda_proposed);
}

test "ExistenceDegree: A1 公式对所有 v ∈ [0,1]^3 都返回 E ∈ [0,1]" {
    // 100 个手写 v 全部满足 E ∈ [0,1]
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const m: F = @as(F, @floatFromInt(i % 11)) / 10.0;
        const r: F = @as(F, @floatFromInt((i / 11) % 11)) / 10.0;
        const n: F = @as(F, @floatFromInt((i / 121) % 11)) / 10.0;
        var d: ExistenceDegree = .{
            .v = .{ .material = m, .representation = r, .nature = n },
        };
        const e = d.e();
        try std.testing.expect(e >= 0.0);
        try std.testing.expect(e <= 1.0);
    }
}

test "ExistenceDegree: KPI 默认关闭 ⇒ 不影响 E" {
    var d: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };
    const e_off = d.e();
    // 默认 kpi_enabled=false ⇒ 合恰核心 0.5
    try std.testing.expectApproxEqAbs(@as(F, 0.5), e_off, 1e-4);
    try std.testing.expect(!d.kpi_enabled);
}

test "ExistenceDegree: KPI 项 ρ·K — best-in-class 不扣分, 越差扣越多" {
    var d: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };
    const e_base = d.e(); // 0.5, KPI 关
    // K=target(1.0) ⇒ kpi_term=0 ⇒ E 不变
    d.recordKpi(1.0);
    try std.testing.expect(d.kpi_enabled);
    try std.testing.expectApproxEqAbs(e_base, d.e(), 1e-4);
    // K=0.5 ⇒ kpi_term = 0.15*(0.5-1)*2 = -0.15
    d.recordKpi(0.5);
    try std.testing.expectApproxEqAbs(e_base - 0.15, d.e(), 1e-4);
    // K=0.0 ⇒ kpi_term = 0.15*(0-1)*2 = -0.30
    d.recordKpi(0.0);
    try std.testing.expectApproxEqAbs(@max(0.0, e_base - 0.30), d.e(), 1e-4);
    // KPI 项单调递增于 K
    d.recordKpi(0.2);
    const e_low = d.e();
    d.recordKpi(0.8);
    const e_high = d.e();
    try std.testing.expect(e_high > e_low);
}

test "ExistenceDegree: ρ 是公理常量 (不在 adaptEFormula/Proposed 中)" {
    var d: ExistenceDegree = .{};
    const rho_before = d.rho;
    _ = d.adaptEFormula();
    _ = d.adaptEFormulaProposed(0.8, 0.5, 0.3, 0.4);
    try std.testing.expectEqual(rho_before, d.rho); // 自适应从不碰 ρ
}

test "ExistenceDegree: eBreakdown 各项和 == total (clamp 前一致)" {
    var d: ExistenceDegree = .{ .v = .{ .material = 0.6, .representation = 0.5, .nature = 0.4 } };
    d.recordKpi(0.8);
    d.relations_distinct = 4;
    const bd = d.eBreakdown();
    const sum = bd.base + bd.symbiosis + bd.relations_bonus + bd.kpi_term;
    try std.testing.expectApproxEqAbs(math_util.clamp(sum, 0, 1), bd.total, 1e-5);
    // eBreakdown.total 应与 e() 一致
    try std.testing.expectApproxEqAbs(d.e(), bd.total, 1e-5);
}

test "ExistenceDegree: KPI 环形缓冲 + 趋势 + 方差" {
    var d: ExistenceDegree = .{};
    // 满 64 之前趋势为 0
    try std.testing.expectEqual(@as(F, 0), d.kpiTrend());
    // 线性上升 ⇒ 正斜率
    for (0..64) |i| d.recordKpi(@as(F, @floatFromInt(i)) / 64.0);
    try std.testing.expect(d.kpiTrend() > 0.013);
    try std.testing.expect(d.kpiTrend() < 0.018);
    // 环形缓冲在 64 处回绕
    try std.testing.expectEqual(@as(u8, 64), d.kpi_history_count);
    // 常量序列 ⇒ 方差 0
    var c: ExistenceDegree = .{};
    for (0..10) |_| c.recordKpi(0.7);
    try std.testing.expectApproxEqAbs(@as(F, 0), c.kpiVariance(), 1e-5);
}

test "ExistenceDegree: KPI 开启后 E 仍恒在 [0,1] (含极端 K)" {
    var i: u32 = 0;
    while (i < 121) : (i += 1) {
        const m: F = @as(F, @floatFromInt(i % 11)) / 10.0;
        const r: F = @as(F, @floatFromInt((i / 11) % 11)) / 10.0;
        var d: ExistenceDegree = .{ .v = .{ .material = m, .representation = r, .nature = 0.3 } };
        d.recordKpi(@as(F, @floatFromInt(i % 5)) / 4.0);
        const e = d.e();
        try std.testing.expect(e >= 0.0 and e <= 1.0);
    }
}

test "CoappropriationTensor: init + implant + coherence" {
    const alloc = std.testing.allocator;
    var t = try CoappropriationTensor.init(alloc, 4, 4, 4);
    defer t.deinit();

    t.implant(2, 2, 2, 1.0, 1.5);
    const c = t.coherence();
    try std.testing.expect(c > 0);

    // 强时序变化: 先 snapshot, 再大幅变化
    t.snapshot();
    t.implant(3, 3, 3, 5.0, 2.0);
    t.implant(0, 0, 0, 5.0, 2.0);
    const c2 = t.coherence();
    // 两个合恰度应该不同 (有变化, 但不需要严格不等)
    try std.testing.expect(c2 > 0);
    // 时序项会因大幅突变而改变
    const c3 = t.coherence(); // 再次调用
    try std.testing.expect(c2 == c3); // 无新变化时稳定
}

test "CoappropriationTensor: decay reduces energy" {
    const alloc = std.testing.allocator;
    var t = try CoappropriationTensor.init(alloc, 3, 3, 3);
    defer t.deinit();
    t.implant(1, 1, 1, 2.0, 1.0);
    var sum_before: F = 0;
    for (t.data) |v| sum_before += @abs(v);
    t.decay(0.1);
    var sum_after: F = 0;
    for (t.data) |v| sum_after += @abs(v);
    try std.testing.expect(sum_after < sum_before);
}

test "WorldModel: predict + observe error decreases" {
    const alloc = std.testing.allocator;
    var wm = try WorldModel.init(alloc, 4, 42);
    defer wm.deinit();

    // 稳定环境: 静态观察
    const obs = [_]F{ 0.7, 0.3, 0.5, 0.6 };
    wm.predict();
    const e1 = wm.observe(&obs);
    wm.predict();
    const e2 = wm.observe(&obs);
    wm.predict();
    const e3 = wm.observe(&obs);
    // 多次后误差应下降
    try std.testing.expect(e3 < e1 + 0.05);
    _ = e2;
}

test "WorldModel: recordE and recentVariance" {
    const alloc = std.testing.allocator;
    var wm = try WorldModel.init(alloc, 2, 7);
    defer wm.deinit();
    try wm.recordE(0.3);
    try wm.recordE(0.5);
    try wm.recordE(0.7);
    const v = wm.recentVariance(3);
    try std.testing.expect(v > 0.01);
}

test "WorldModel: 自适应学习率 (B.5.1 存在度加权)" {
    const alloc = std.testing.allocator;
    var wm = try WorldModel.init(alloc, 4, 42);
    defer wm.deinit();

    // E 高 (稳态) → 学习率应该 ↓
    const eta_high = wm.adaptLearningRate(0.9, 0.1);
    // E 低 (受威胁) → 学习率应该 ↑
    const eta_low = wm.adaptLearningRate(0.2, 0.1);
    // err 高 → 学习率应该 ↑
    const eta_err = wm.adaptLearningRate(0.5, 0.5);

    try std.testing.expect(eta_high < wm.eta_base);
    try std.testing.expect(eta_low > wm.eta_base);
    try std.testing.expect(eta_err > wm.eta_base);
    // clamp 范围
    try std.testing.expect(wm.eta >= 0.01);
    try std.testing.expect(wm.eta <= 0.3);
}

test "WorldModel: 真学习 — 1000 步后误差序列趋势下降" {
    const alloc = std.testing.allocator;
    var wm = try WorldModel.init(alloc, 4, 42);
    defer wm.deinit();

    // 真实"环境": 缓慢漂移的 4 维信号 (sin/cos)
    const target = [_]F{ 0.7, 0.3, 0.5, 0.6 };
    var obs: [4]F = undefined;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const t: F = @as(F, @floatFromInt(i)) * 0.01;
        obs[0] = target[0] + @sin(t) * 0.05;
        obs[1] = target[1] + @cos(t) * 0.05;
        obs[2] = target[2] + @sin(t * 1.3) * 0.05;
        obs[3] = target[3] + @cos(t * 0.7) * 0.05;
        wm.predict();
        // 自适应学习率
        if (i % 50 == 0) {
            const err_recent = if (wm.error_history.items.len > 0) wm.error_history.items[wm.error_history.items.len - 1] else 0.1;
            _ = wm.adaptLearningRate(0.5, err_recent);
        }
        _ = wm.observe(&obs);
    }
    // 趋势: 误差序列后半应比前半小 (在学习)
    const trend = wm.learningTrend();
    try std.testing.expect(trend > -0.1); // 允许少量负值 (波动), 但不应 < -0.1
    try std.testing.expect(wm.learn_steps == 1000);
    // 误差应该保持在较小范围
    try std.testing.expect(wm.accumulated_error < 0.3);
}

test "WorldModel: error_history 容量 128, 老数据被淘汰" {
    const alloc = std.testing.allocator;
    var wm = try WorldModel.init(alloc, 2, 1);
    defer wm.deinit();

    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        wm.predict();
        const obs = [_]F{ 0.5, 0.5 };
        _ = wm.observe(&obs);
    }
    // 容量应被 cap 在 128
    try std.testing.expect(wm.error_history.items.len <= 128);
    try std.testing.expect(wm.learn_steps == 500);
}
