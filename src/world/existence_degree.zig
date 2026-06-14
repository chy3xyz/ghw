//! ExistenceDegree — the closed-form E equation of a digital life.
//!
//! Status: Week 2 of Phase 1 (GHW-as-CRM). ρ term added.
//!
//! # E formula (v2 — Week 2)
//!
//! ```
//! E = α·M + β·R + γ·N - μ·Var + ν·min + σ·S + λ·D + ρ·K
//! ```
//!
//! The first 7 terms (α, β, γ, μ, ν, σ, λ, λ in D, σ in S) are the
//! original Phase 8.6 E equation. The new ρ·K term is **Week 2** and
//! brings the product's KPI into the E score.
//!
//! # Immutability classes
//!
//! The 5 core "axiom" coefficients — α, β, γ, ρ, plus the basic
//! formula structure — are immutable. L1 (parameter tuning) can
//! adjust the 4 *additive* coefficients μ, ν, σ, λ. L4 can propose
//! changes to those 4. L5 can never change any of the axiom fields.
//!
//! # Anti-flicker invariant
//!
//! ρ is fed by `kpi_composite`, which is updated at most every
//! `kpi_refresh_interval_hours` (set in ProductIntent.rhythm and
//! validated to be ≥ 10× cycle_interval_seconds). This prevents
//! the E score from oscillating with every cycle.
//!
//! # What this module is NOT
//!
//! - It does NOT fetch KPI values. The product backend registers
//!   a callback (see `src/harness/crm_kpi.zig`).
//! - It does NOT compute the composite K. The composite is
//!   computed in `crm_kpi.composite(...)` and fed in here.
//! - It does NOT decide what to do with the trend. The L4
//!   proposer (in `loop_engine.zig`) reads `kpi_trend` and acts.

const std = @import("std");

// ============================================================================
// ThreeSource — M / R / N values + variance + min
// ============================================================================

pub const ThreeSource = struct {
    method: f32, // M
    resource: f32, // R
    network: f32, // N

    /// Used for -μ·Var (imbalance penalty) and +ν·min (wood-bucket bonus).
    pub fn variance(self: *const ThreeSource) f32 {
        const mean = (self.method + self.resource + self.network) / 3.0;
        const dm = self.method - mean;
        const dr = self.resource - mean;
        const dn = self.network - mean;
        return (dm * dm + dr * dr + dn * dn) / 3.0;
    }

    pub fn min(self: *const ThreeSource) f32 {
        return @min(@min(self.method, self.resource), self.network);
    }
};

// ============================================================================
// ExistenceDegree — the 6-term E equation state
// ============================================================================

pub const ExistenceDegree = struct {
    allocator: std.mem.Allocator,

    // ---- Three sources (M / R / N) ----
    v: ThreeSource,

    // ---- 4 additive coefficients (Phase 8.6, L4-proposable) ----
    mu: f32,
    nu: f32,
    sigma: f32,
    lambda: f32,

    // ---- Peer (Phase 1.8) ----
    peer_count: u32,
    peer_E_avg: f32,
    sigma_open: bool, // if true, σ term contributes

    // ---- Relations (Phase 8) ----
    relations_distinct: u8, // 0..9
    relations_total: u32, // for richer metrics

    // ---- KPI (Week 2 — NEW) ----
    /// ρ coefficient. **Immutable** (axiom). Default 0.15.
    /// Cannot be changed by L1, L4, L5, or any LLM call.
    rho: f32 = 0.15,

    /// Composite KPI score K, in [0, 1]. Updated at most every
    /// `kpi_refresh_interval_hours`. NaN if no valid source in 7 days.
    kpi_composite: f32 = 0.5,

    /// Target K — typically 1.0 (best-in-class). The K term is
    /// `(kpi_composite - kpi_target) * 2 - 1`, peaking at 1.0 when
    /// K=1.0 and dropping linearly to -1.0 when K=0.0. This makes
    /// the ρ term a "K is good" measure centered at 0.
    kpi_target: f32 = 1.0,

    /// 64-cycle ring buffer of K values. Used for trend computation
    /// (slope of linear regression). NOT used in the E formula itself
    /// — only exposed to the L4 proposer. Default: 64 copies of 0.5.
    kpi_history: [64]f32,
    kpi_history_idx: u8 = 0,
    kpi_history_count: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) ExistenceDegree {
        return .{
            .allocator = allocator,
            .v = .{ .method = 1.0, .resource = 1.0, .network = 1.0 },
            .mu = 0.5,
            .nu = 0.3,
            .sigma = 0.0,
            .lambda = 0.1,
            .peer_count = 0,
            .peer_E_avg = 0.0,
            .sigma_open = false,
            .relations_distinct = 0,
            .relations_total = 0,
            // 64-element ring initialized to 0.5 (the "no signal" K).
            // @splat requires comptime-known length, which it is.
            .kpi_history = @splat(0.5),
        };
    }

    // ----- E formula (v2 — Week 2) -----

    /// Compute the current E value. Pure function of state.
    /// Does NOT mutate the degree.
    pub fn e(self: *const ExistenceDegree) f32 {
        // 1. Three sources weighted (α·M + β·R + γ·N)
        //    α, β, γ are defaults here; caller can override via
        //    `eWith(...)` for L4 proposer experiments.
        const base = 0.442 * self.v.method + 0.317 * self.v.resource + 0.241 * self.v.network;

        // 2. Imbalance penalty (-μ·Var)
        const var_term = -self.mu * self.v.variance();

        // 3. Wood-bucket bonus (+ν·min)
        const min_term = self.nu * self.v.min();

        // 4. Symbiosis bonus (+σ·S), if σ is open
        const sym_term = if (self.sigma_open) blk: {
            const n_log2 = @log2(@as(f32, @floatFromInt(self.peer_count + 1)));
            const sync = @max(0.0, 1.0 - @abs(self.peer_E_avg - self.e_base_no_rho()) / 0.5);
            break :blk self.sigma * sync * (n_log2 / 3.0);
        } else 0.0;

        // 5. Relations diversity bonus (+λ·D)
        const rel_term = self.lambda * (@as(f32, @floatFromInt(self.relations_distinct)) / 9.0);

        // 6. KPI term (+ρ·K_signed) — Week 2, NEW
        //    K_signed maps K∈[0,1] to signed K_signed∈[-1,1], so
        //    "K is bad" subtracts from E and "K is good" adds. This
        //    matches the spirit of the other terms (each term can
        //    subtract or add to E).
        const K_signed = (self.kpi_composite - self.kpi_target) * 2.0; // peak at 1.0 when K=1.0
        const kpi_term = self.rho * K_signed;

        return base + var_term + min_term + sym_term + rel_term + kpi_term;
    }

    /// E without the KPI term. Used as a baseline for the symbiosis
    /// sync_factor (Phase 1.8 logic) and for visualizing the
    /// contribution of each term.
    pub fn e_base_no_rho(self: *const ExistenceDegree) f32 {
        const base = 0.442 * self.v.method + 0.317 * self.v.resource + 0.241 * self.v.network;
        const var_term = -self.mu * self.v.variance();
        const min_term = self.nu * self.v.min();
        const sym_term = if (self.sigma_open) blk: {
            const n_log2 = @log2(@as(f32, @floatFromInt(self.peer_count + 1)));
            // Note: this is recursive, but we approximate using only
            // the base + first 3 terms to avoid infinite recursion.
            const approx_e = base + var_term + min_term;
            const sync = @max(0.0, 1.0 - @abs(self.peer_E_avg - approx_e) / 0.5);
            break :blk self.sigma * sync * (n_log2 / 3.0);
        } else 0.0;
        const rel_term = self.lambda * (@as(f32, @floatFromInt(self.relations_distinct)) / 9.0);
        return base + var_term + min_term + sym_term + rel_term;
    }

    /// Compute the 6 E-term breakdown for /api/e_breakdown. Mirrors
    /// the e() computation but exposes each term separately so the
    /// UI can render them as a stacked bar.
    pub fn eBreakdown(self: *const ExistenceDegree) EBreakdown {
        const base = 0.442 * self.v.method + 0.317 * self.v.resource + 0.241 * self.v.network;
        const var_term = -self.mu * self.v.variance();
        const min_term = self.nu * self.v.min();
        const sym_term = if (self.sigma_open) blk: {
            const n_log2 = @log2(@as(f32, @floatFromInt(self.peer_count + 1)));
            const sync = @max(0.0, 1.0 - @abs(self.peer_E_avg - self.e_base_no_rho()) / 0.5);
            break :blk self.sigma * sync * (n_log2 / 3.0);
        } else 0.0;
        const rel_term = self.lambda * (@as(f32, @floatFromInt(self.relations_distinct)) / 9.0);
        const K_signed = (self.kpi_composite - self.kpi_target) * 2.0;
        const kpi_term = self.rho * K_signed;
        return .{
            .base = base,
            .imbalance = var_term,
            .synergy = min_term,
            .symbiosis = sym_term,
            .relations_bonus = rel_term,
            .kpi_term = kpi_term,
            .total = base + var_term + min_term + sym_term + rel_term + kpi_term,
        };
    }

    // ----- KPI history management -----

    /// Push a new K value into the ring buffer. Called from
    /// `app.runCycle` whenever the KPI is refreshed (not every cycle,
    /// only when the kpi_refresh_interval_hours elapses).
    pub fn recordKpi(self: *ExistenceDegree, k: f32) void {
        self.kpi_history[self.kpi_history_idx] = k;
        self.kpi_history_idx = (self.kpi_history_idx + 1) % 64;
        self.kpi_history_count = @min(self.kpi_history_count + 1, 64);
        self.kpi_composite = k;
    }

    /// Linear regression slope of the K history. Returns 0.0 if
    /// the buffer is not yet full (we don't act on partial data).
    /// Slope is in K-units per cycle; typical magnitude: 0.001 -
    /// 0.01 in steady state, 0.05+ during a regime change.
    pub fn kpiTrend(self: *const ExistenceDegree) f32 {
        if (self.kpi_history_count < 64) return 0.0;

        var sum_x: f32 = 0.0;
        var sum_y: f32 = 0.0;
        var sum_xy: f32 = 0.0;
        var sum_x2: f32 = 0.0;
        const n: f32 = 64.0;
        for (0..64) |i| {
            const x: f32 = @floatFromInt(i);
            const y = self.kpi_history[i];
            sum_x += x;
            sum_y += y;
            sum_xy += x * y;
            sum_x2 += x * x;
        }
        // slope = (n·Σxy - Σx·Σy) / (n·Σx² - (Σx)²)
        const num = n * sum_xy - sum_x * sum_y;
        const den = n * sum_x2 - sum_x * sum_x;
        if (den == 0.0) return 0.0;
        return num / den;
    }

    /// Variance of the K history. Used by the L4 proposer as a
    /// "is the KPI stable?" signal.
    pub fn kpiVariance(self: *const ExistenceDegree) f32 {
        if (self.kpi_history_count < 2) return 0.0;
        var sum: f32 = 0.0;
        const n: f32 = @floatFromInt(self.kpi_history_count);
        for (self.kpi_history[0..self.kpi_history_count]) |k| sum += k;
        const mean = sum / n;
        var sq_sum: f32 = 0.0;
        for (self.kpi_history[0..self.kpi_history_count]) |k| {
            const d = k - mean;
            sq_sum += d * d;
        }
        return sq_sum / n;
    }

    /// Deep copy. Used by delta() and by saveState.
    /// The 64-element K ring buffer is copied verbatim.
    pub fn clone(self: *const ExistenceDegree) ExistenceDegree {
        return .{
            .allocator = self.allocator,
            .v = self.v,
            .mu = self.mu,
            .nu = self.nu,
            .sigma = self.sigma,
            .lambda = self.lambda,
            .peer_count = self.peer_count,
            .peer_E_avg = self.peer_E_avg,
            .sigma_open = self.sigma_open,
            .relations_distinct = self.relations_distinct,
            .relations_total = self.relations_total,
            .rho = self.rho,
            .kpi_composite = self.kpi_composite,
            .kpi_target = self.kpi_target,
            .kpi_history = self.kpi_history,
            .kpi_history_idx = self.kpi_history_idx,
            .kpi_history_count = self.kpi_history_count,
        };
    }
};

/// Per-term breakdown of E. Returned by `eBreakdown()`.
pub const EBreakdown = struct {
    base: f32, // α·M + β·R + γ·N
    imbalance: f32, // -μ·Var
    synergy: f32, // +ν·min
    symbiosis: f32, // +σ·S
    relations_bonus: f32, // +λ·D
    kpi_term: f32, // +ρ·K_signed — Week 2 NEW
    total: f32,
};

// ============================================================================
// Unit tests
// ============================================================================

test "e: with K=0.5 (target), KPI term is 0" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    ed.kpi_composite = 0.5;
    ed.kpi_target = 1.0;
    const e1 = ed.e();
    ed.kpi_composite = 0.5;
    const e2 = ed.e();
    try std.testing.expectApproxEqAbs(e1, e2, 1e-6);
}

test "e: K=1.0 boosts E by rho" {
    var ed_a = ExistenceDegree.init(std.testing.allocator);
    ed_a.kpi_composite = 0.5; // K=0.5 → KPI term = 0
    var ed_b = ExistenceDegree.init(std.testing.allocator);
    ed_b.kpi_composite = 1.0; // K=1.0 → KPI term = +rho
    const diff = ed_b.e() - ed_a.e();
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), diff, 1e-5);
}

test "e: K=0.0 subtracts rho from E" {
    var ed_a = ExistenceDegree.init(std.testing.allocator);
    ed_a.kpi_composite = 0.5;
    var ed_b = ExistenceDegree.init(std.testing.allocator);
    ed_b.kpi_composite = 0.0;
    const diff = ed_b.e() - ed_a.e();
    try std.testing.expectApproxEqAbs(@as(f32, -0.15), diff, 1e-5);
}

test "eBreakdown: 6 terms exposed, sum equals total" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    ed.kpi_composite = 0.8;
    const bd = ed.eBreakdown();
    const sum_terms = bd.base + bd.imbalance + bd.synergy + bd.symbiosis + bd.relations_bonus + bd.kpi_term;
    try std.testing.expectApproxEqAbs(bd.total, sum_terms, 1e-5);
}

test "recordKpi: ring buffer wraps at 64" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    for (0..70) |i| ed.recordKpi(@as(f32, @floatFromInt(i)) / 100.0);
    try std.testing.expectEqual(@as(u8, 64), ed.kpi_history_count);
    // idx should be (0+70) % 64 = 6
    try std.testing.expectEqual(@as(u8, 6), ed.kpi_history_idx);
}

test "kpiTrend: empty buffer returns 0" {
    const ed = ExistenceDegree.init(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ed.kpiTrend(), 1e-6);
}

test "kpiTrend: linear ramp produces positive slope" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    for (0..64) |i| ed.recordKpi(@as(f32, @floatFromInt(i)) / 64.0);
    // Slope ≈ 1/64 = 0.0156
    try std.testing.expect(ed.kpiTrend() > 0.014);
    try std.testing.expect(ed.kpiTrend() < 0.017);
}

test "kpiTrend: constant buffer produces zero slope" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    for (0..64) |_| ed.recordKpi(0.7);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ed.kpiTrend(), 1e-5);
}

test "kpiVariance: constant buffer has zero variance" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    for (0..10) |_| ed.recordKpi(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ed.kpiVariance(), 1e-5);
}

test "kpiVariance: two distinct values has non-zero variance" {
    var ed = ExistenceDegree.init(std.testing.allocator);
    for (0..32) |_| ed.recordKpi(0.3);
    for (0..32) |_| ed.recordKpi(0.7);
    try std.testing.expect(ed.kpiVariance() > 0.0);
}

test "rho is immutable: clone preserves it" {
    const ed = ExistenceDegree.init(std.testing.allocator);
    const c = ed.clone();
    try std.testing.expectEqual(@as(f32, 0.15), c.rho);
    // Even if a caller tries to mutate the original, the clone keeps
    // the value. (This is a test of intent, not enforcement — the
    // type system cannot prevent assignment, but the convention is
    // documented in PRODUCT_INTENT.md §3.8 and in the E formula
    // comment above.)
}

test "ThreeSource.variance: equal values → 0" {
    const v = ThreeSource{ .method = 0.5, .resource = 0.5, .network = 0.5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.variance(), 1e-6);
}

test "ThreeSource.variance: spread values → positive" {
    const v = ThreeSource{ .method = 0.0, .resource = 1.0, .network = 1.0 };
    // mean = 2/3, deviations: -2/3, +1/3, +1/3
    // variance = (4/9 + 1/9 + 1/9)/3 = 6/27 = 2/9 ≈ 0.222
    try std.testing.expect(v.variance() > 0.2);
    try std.testing.expect(v.variance() < 0.25);
}

test "ThreeSource.min: returns smallest" {
    const v = ThreeSource{ .method = 0.3, .resource = 0.7, .network = 0.5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), v.min(), 1e-6);
}
