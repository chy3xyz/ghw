//! 存在度公理 v3 — 三源合恰的有理论根基的聚合器
//!
//! ## 为什么要重写 E 的核心
//!
//! 旧实现把"三源合恰"落成了:
//!   E = α·M + β·R + γ·N − μ·Var(M,R,N) + ν·min(M,R,N) + ...
//! 即"线性加权 + 方差惩罚补丁 + 短板加成补丁"。问题在于:
//!   1. 线性加权意味着三源**完全可替代** (M 高可无限补偿 N=0),
//!      与"物象性缺一不可"的存在论直接矛盾。
//!   2. μ·Var / ν·min 是事后**外挂的修正项**,系数靠手调,
//!      没有统一数学骨架,无法证明任何整体性质。
//!
//! ## v3 的骨架:加权幂平均 (Hölder / CES / Atkinson 等价分配)
//!
//! 核心聚合用**加权幂平均**(经济学 CES 生产函数、福利经济学的
//! "等价均分收入 (equally-distributed-equivalent)"、数学 Hölder
//! 均值,本质同一族):
//!
//!   M_p(x; w) = ( Σ w_i · x_i^p )^(1/p)      (p ≠ 0)
//!   M_0(x; w) = Π x_i^{w_i}                   (p → 0, 加权几何平均)
//!
//! 单一参数 p∈(0,1] 连续刻画三源"可替代性 / 互补性":
//!   p = 1   → 算术平均   (完全可替代, 退化回旧线性加权)
//!   p → 0   → 几何平均   (Cobb-Douglas, 任一源=0 ⇒ E=0, 缺一不可)
//!   p < 1   → 严格凹      (失衡被自动惩罚, 短板梯度更大 ⇒ 短板优先)
//!
//! 旧公式里要 μ·Var + ν·min 两个外挂项才能勉强表达的
//! "失衡惩罚 + 短板优先",在 v3 里全是幂平均**凹性的数学推论**:
//!   失衡损失 = AM(算术平均) − M_p ≥ 0,  当且仅当三源相等时取 0。
//! 这个 AM − M_p 就是"三源合恰度"的量化:三源越撕裂,损失越大。
//!
//! ## 关键不变性:自由处置 (free disposal / 单调性)
//!
//! 幂平均对每个分量单调不减 ⇒ "任一源增加, E 绝不下降"。
//! 这是存在度作为生存驱动量必须满足的公理 (拿到更多资源不该
//! 反而降低存在度)。旧的"乘性合恰门控"会破坏这条 (堆高最强源
//! 拉大方差反而扣分),故 v3 不用乘性门控,改由凹性内生地奖励均衡。
//!
//! ## 与旧系数的衔接 (不破坏 L1/L4 自适应闭环)
//!
//! 旧的 ν (协同) 和 μ (失衡) 仍有意义,从"加性系数"变为"曲率参数":
//!   p = 1 − 1.5·ν − ζ·(μ − 0.5)
//!   ν ↑ ⇒ p ↓ (更互补);  μ ↑ ⇒ p ↓ (更厌恶失衡)。
//! adaptEFormula / adaptEFormulaProposed 的自适应逻辑全部保留,
//! 只是它们调的 μ/ν 现在改变的是幂平均曲率而非加性补丁。
//!
//! ## 可证明的性质 (见本文件 test 块)
//!   A. 有界:  x_i∈[0,1] ⇒ E_core∈[0,1]
//!   B. 幂等:  x_i 全相等 = c ⇒ E_core = c
//!   C. 单调:  任一 x_i ↑ ⇒ E_core 不降 (自由处置)
//!   D. 凹性:  p<1 ⇒ E_core ≤ 算术平均 (失衡惩罚, 合恰损失 ≥ 0)
//!   E. 夹挤:  min ≤ E_core ≤ max
//!   F. 互补:  p→0 且某源=0 ⇒ E_core=0 (缺一不可)
//!   G. 对称:  等权下置换 x_i 不改变 E_core
//!   H. 曲率:  ν↑ 或 μ↑ ⇒ 失衡态 E_core 下降 (系数衔接)

const std = @import("std");
const F = @import("../util/mod.zig").F;

/// 低于此阈值的 p 退化为加权几何平均,避免 x^p (p→0) 的 1/p 指数放大数值误差
pub const GEOMETRIC_THRESHOLD: F = 0.05;

/// μ 对曲率的额外影响强度 (μ 偏离 0.5 每单位对 p 的拉动)
const MU_CURVATURE: F = 0.5;

/// 由协同系数 ν 与失衡系数 μ 推出幂平均的可替代性指数 p∈(0,1]。
///   p = 1 − 1.5·ν − MU_CURVATURE·(μ − 0.5)
/// ν∈[0.05,0.50], μ∈[0.20,0.80] (adaptEFormula 取值域) ⇒ p∈(0,1)。
/// p 恒 < 1 ⇒ 聚合恒严格凹 ⇒ 失衡恒被惩罚;p 恒 > 0 ⇒ 单调可计算。
pub fn substitutionExponent(mu: F, nu: F) F {
    const clamped_nu = std.math.clamp(nu, 0.0, 0.6);
    const clamped_mu = std.math.clamp(mu, 0.0, 1.0);
    const p = 1.0 - 1.5 * clamped_nu - MU_CURVATURE * (clamped_mu - 0.5);
    return std.math.clamp(p, GEOMETRIC_THRESHOLD, 1.0);
}

/// 三源合恰度 H∈[0,1] = 1 − 三源张力(max−min)。诊断量:三源越接近 H 越高。
/// (注:H 仅用于可视化 / 审计,不参与 E 计算,以保证单调性。)
pub fn harmony(m: F, r: F, n: F) F {
    const hi = @max(m, @max(r, n));
    const lo = @min(m, @min(r, n));
    return std.math.clamp(1.0 - (hi - lo), 0.0, 1.0);
}

/// 加权幂平均 M_p(x; w)。要求 x_i ≥ 0;权重自动归一化。
/// p < GEOMETRIC_THRESHOLD 时退化为加权几何平均(任一源为 0 ⇒ 返回 0)。
pub fn weightedPowerMean(vals: [3]F, weights: [3]F, p: F) F {
    // 防御:权重归一化,负值截零
    var w = [3]F{ @max(weights[0], 0), @max(weights[1], 0), @max(weights[2], 0) };
    const wsum = w[0] + w[1] + w[2];
    if (wsum < 1e-9) {
        w = .{ 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0 };
    } else {
        w[0] /= wsum;
        w[1] /= wsum;
        w[2] /= wsum;
    }

    const x = [3]F{
        std.math.clamp(vals[0], 0, 1),
        std.math.clamp(vals[1], 0, 1),
        std.math.clamp(vals[2], 0, 1),
    };

    // p → 0:加权几何平均 Π x_i^{w_i} = exp(Σ w_i ln x_i)
    if (p < GEOMETRIC_THRESHOLD) {
        var ln_sum: F = 0;
        for (x, w) |xi, wi| {
            if (wi <= 0) continue;
            if (xi <= 0) return 0; // 缺一不可:任一源为 0 ⇒ 整体为 0
            ln_sum += wi * @log(xi);
        }
        return std.math.clamp(@exp(ln_sum), 0, 1);
    }

    // 一般情形:( Σ w_i x_i^p )^(1/p)
    var acc: F = 0;
    for (x, w) |xi, wi| {
        acc += wi * std.math.pow(F, xi, p);
    }
    return std.math.clamp(std.math.pow(F, acc, 1.0 / p), 0, 1);
}

/// 三源合恰核心 E_core(不含 σ 共生 / λ 关系 / ρ KPI 等加性调制项)。
///   E_core = M_p(M,R,N; α,β,γ),  p 由 μ、ν 决定。
/// "失衡惩罚 + 短板优先 + 缺一不可"均为幂平均凹性的内生推论。
pub fn coappropriation(m: F, r: F, n: F, alpha: F, beta: F, gamma: F, mu: F, nu: F) F {
    const p = substitutionExponent(mu, nu);
    return weightedPowerMean(.{ m, r, n }, .{ alpha, beta, gamma }, p);
}

/// 失衡损失 = 算术平均 − 幂平均 ≥ 0,量化"三源不合恰"的存在度代价。
/// 三源完全相等时为 0,越撕裂越大。供审计 / 反思层使用。
pub fn imbalanceLoss(m: F, r: F, n: F, alpha: F, beta: F, gamma: F, mu: F, nu: F) F {
    const am = alpha * m + beta * r + gamma * n;
    const pm = coappropriation(m, r, n, alpha, beta, gamma, mu, nu);
    return @max(0.0, am - pm);
}

// ============================ 性质测试 ============================

const testing = std.testing;
fn eq(a: F, b: F, tol: F) !void {
    try testing.expectApproxEqAbs(a, b, tol);
}
fn arithMean(m: F, r: F, n: F, a: F, b: F, g: F) F {
    return a * m + b * r + g * n;
}

test "性质B 幂等: 三源相等 ⇒ E_core = 该值" {
    const vals = [_]F{ 0.0, 0.1, 0.3, 0.5, 0.7, 1.0 };
    for (vals) |c| {
        const e = coappropriation(c, c, c, 0.33, 0.34, 0.33, 0.5, 0.3);
        try eq(c, e, 1e-4);
    }
}

test "性质A 有界 + 性质E 夹挤: min ≤ M_p ≤ max ⊆ [0,1]" {
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const m: F = @as(F, @floatFromInt(i % 10)) / 9.0;
        const r: F = @as(F, @floatFromInt((i / 10) % 10)) / 9.0;
        const n: F = @as(F, @floatFromInt((i / 100) % 10)) / 9.0;
        const pm = coappropriation(m, r, n, 0.33, 0.34, 0.33, 0.5, 0.3);
        const lo = @min(m, @min(r, n));
        const hi = @max(m, @max(r, n));
        try testing.expect(pm >= lo - 1e-4);
        try testing.expect(pm <= hi + 1e-4);
        try testing.expect(pm >= 0.0 and pm <= 1.0);
    }
}

test "性质C 单调 (自由处置): 任一源上升 ⇒ E_core 不降" {
    // 遍历 11^3 网格, 对每个分量分别 +0.1 验证不降
    var ia: u32 = 0;
    while (ia < 11) : (ia += 1) {
        var ib: u32 = 0;
        while (ib < 11) : (ib += 1) {
            var ic: u32 = 0;
            while (ic < 10) : (ic += 1) {
                const a: F = @as(F, @floatFromInt(ia)) / 10.0;
                const b: F = @as(F, @floatFromInt(ib)) / 10.0;
                const c0: F = @as(F, @floatFromInt(ic)) / 10.0;
                const c1: F = @as(F, @floatFromInt(ic + 1)) / 10.0;
                const e0 = coappropriation(a, b, c0, 0.33, 0.34, 0.33, 0.5, 0.3);
                const e1 = coappropriation(a, b, c1, 0.33, 0.34, 0.33, 0.5, 0.3);
                try testing.expect(e1 >= e0 - 1e-5);
            }
        }
    }
}

test "性质D 凹性: p<1 时 E_core ≤ 算术平均 (失衡损失 ≥ 0)" {
    const cases = [_][3]F{
        .{ 0.9, 0.5, 0.1 }, .{ 1.0, 0.0, 0.5 },
        .{ 0.8, 0.2, 0.2 }, .{ 0.6, 0.4, 0.5 },
    };
    for (cases) |c| {
        const am = arithMean(c[0], c[1], c[2], 0.33, 0.34, 0.33);
        const e = coappropriation(c[0], c[1], c[2], 0.33, 0.34, 0.33, 0.5, 0.3);
        try testing.expect(e <= am + 1e-5);
        try testing.expect(imbalanceLoss(c[0], c[1], c[2], 0.33, 0.34, 0.33, 0.5, 0.3) >= -1e-6);
    }
    // 平衡态合恰损失为 0
    try eq(0.0, imbalanceLoss(0.5, 0.5, 0.5, 0.33, 0.34, 0.33, 0.5, 0.3), 1e-5);
}

test "性质F 互补: 高互补 (低 p) 且某源=0 ⇒ E_core→0 (缺一不可)" {
    const e_geom = weightedPowerMean(.{ 0.9, 0.9, 0.0 }, .{ 0.33, 0.34, 0.33 }, 0.0);
    try eq(0.0, e_geom, 1e-6);
    // 高 ν + 高 μ ⇒ p 很小, 某源=0 ⇒ E_core 显著趋零
    const e = coappropriation(0.9, 0.9, 0.0, 0.33, 0.34, 0.33, 0.8, 0.5);
    try testing.expect(e < 0.25);
}

test "性质G 对称: 等权下置换三源不改变 E_core" {
    const a = coappropriation(0.2, 0.5, 0.9, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.5, 0.3);
    const b = coappropriation(0.9, 0.2, 0.5, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.5, 0.3);
    const c = coappropriation(0.5, 0.9, 0.2, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.5, 0.3);
    try eq(a, b, 1e-5);
    try eq(b, c, 1e-5);
}

test "极限: p=1 退化为算术平均 (μ=0, ν=0)" {
    const c = [3]F{ 0.9, 0.5, 0.1 };
    const p = substitutionExponent(0.0, 0.0);
    try eq(1.0, p, 1e-6);
    const pm = weightedPowerMean(c, .{ 0.33, 0.34, 0.33 }, 1.0);
    const am = arithMean(c[0], c[1], c[2], 0.33, 0.34, 0.33);
    try eq(am, pm, 1e-5);
}

test "极限: p→0 等价加权几何平均" {
    const c = [3]F{ 0.8, 0.5, 0.2 };
    const w = [3]F{ 0.33, 0.34, 0.33 };
    const pm = weightedPowerMean(c, w, 0.0);
    const geom = std.math.pow(F, c[0], w[0]) * std.math.pow(F, c[1], w[1]) * std.math.pow(F, c[2], w[2]);
    try eq(geom, pm, 1e-4);
}

test "性质H 曲率衔接: ν↑ 或 μ↑ ⇒ 失衡态 E_core 下降" {
    try testing.expect(substitutionExponent(0.5, 0.5) < substitutionExponent(0.5, 0.1)); // ν↑ ⇒ p↓
    try testing.expect(substitutionExponent(0.8, 0.3) < substitutionExponent(0.2, 0.3)); // μ↑ ⇒ p↓
    const lo_nu = coappropriation(0.9, 0.5, 0.1, 0.33, 0.34, 0.33, 0.5, 0.1);
    const hi_nu = coappropriation(0.9, 0.5, 0.1, 0.33, 0.34, 0.33, 0.5, 0.5);
    try testing.expect(hi_nu < lo_nu);
    const lo_mu = coappropriation(0.9, 0.5, 0.1, 0.33, 0.34, 0.33, 0.2, 0.3);
    const hi_mu = coappropriation(0.9, 0.5, 0.1, 0.33, 0.34, 0.33, 0.8, 0.3);
    try testing.expect(hi_mu < lo_mu);
}

test "默认系数 (μ=0.5,ν=0.3) ⇒ p=0.55, 平衡态 E_core=0.5" {
    try eq(0.55, substitutionExponent(0.5, 0.3), 1e-5);
    try eq(0.5, coappropriation(0.5, 0.5, 0.5, 0.33, 0.34, 0.33, 0.5, 0.3), 1e-4);
}

test "合恰度诊断: 平衡 H=1, 极端撕裂 H=0" {
    try eq(1.0, harmony(0.5, 0.5, 0.5), 1e-6);
    try eq(0.0, harmony(1.0, 0.0, 1.0), 1e-6);
    try eq(0.7, harmony(0.6, 0.3, 0.4), 1e-6);
}
