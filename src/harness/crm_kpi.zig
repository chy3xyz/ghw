//! CrmKpi — the 4-KPI composite for GHW-as-CRM.
//!
//! Status: Week 2 of Phase 1 (GHW-as-CRM). Pairs with
//! src/world/existence_degree.zig (the ρ term) and
//! docs/KPI.md (the spec).
//!
//! # What this module does
//!
//! 1. Defines the 4 CRM-specific KPI structs (nrr, deal_win_rate,
//!    sales_cycle_days, weekly_active_sales_pct).
//! 2. Normalizes each to a [0, 1] score per the spec in docs/KPI.md §3.
//! 3. Computes a composite K in [0, 1] from the 4 normalized scores
//!    weighted by `ProductIntent.value_weights`.
//!
//! # What this module does NOT do
//!
//! - It does NOT fetch the raw KPI values from the CRM database.
//!   That is the responsibility of the CRM product's KPI provider
//!   callback (registered via ghw_kpi_register_source).
//! - It does NOT decide what to do with the composite. The E
//!   formula in existence_degree.zig consumes the composite.

const std = @import("std");
const product_intent = @import("product_intent.zig");

// ============================================================================
// RawKpi — the 4 raw KPI values (as fed by the product backend)
// ============================================================================

pub const RawKpi = struct {
    nrr_quarterly: f32 = 0.0, // typically 0.85 - 1.30
    deal_win_rate: f32 = 0.0, // 0.10 - 0.40
    sales_cycle_days_p50: f32 = 0.0, // 20 - 90 days
    weekly_active_sales_pct: f32 = 0.0, // 0.40 - 0.95

    /// True iff all 4 values are within the documented valid range.
    /// Used to reject bad upstream data.
    pub fn isValid(self: *const RawKpi) bool {
        return self.nrr_quarterly >= 0.0 and self.nrr_quarterly <= 2.0 and
            self.deal_win_rate >= 0.0 and self.deal_win_rate <= 1.0 and
            self.sales_cycle_days_p50 >= 0.0 and self.sales_cycle_days_p50 <= 365.0 and
            self.weekly_active_sales_pct >= 0.0 and self.weekly_active_sales_pct <= 1.0;
    }
};

// ============================================================================
// NormalizedKpi — each KPI mapped to [0, 1]
// ============================================================================

pub const NormalizedKpi = struct {
    nrr: f32, // 0.85 → 0.0, 1.00 → 0.5, 1.20 → 1.0
    deal_win_rate: f32, // 0.10 → 0.0, 0.40 → 1.0
    sales_cycle_days: f32, // 20 → 1.0, 60 → 0.5, 90 → 0.0 (inverted)
    weekly_active_sales: f32, // 0.40 → 0.0, 0.95 → 1.0
};

/// Normalize a RawKpi to [0, 1] scores per docs/KPI.md §3.
///
/// Range mapping rationale:
///   NRR: 0.85 = gross churn, 1.00 = breakeven, 1.15 = solid SaaS, 1.20+ = best-in-class
///        Linear: 0.85 → 0.0, 1.00 → 0.5, 1.15 → 1.0 (clamped above)
///   Win rate: 0.10 = low, 0.25 = typical, 0.40 = excellent
///        Linear: 0.10 → 0.0, 0.40 → 1.0
///   Sales cycle: 20 days = excellent, 60 = average, 90 = slow
///        Inverted: 20 → 1.0, 90 → 0.0
///   Active sales: 0.40 = concerning, 0.95 = healthy
///        Linear: 0.40 → 0.0, 0.95 → 1.0
pub fn normalize(raw: RawKpi) NormalizedKpi {
    return .{
        // NRR: 0.85 → 0.0, 1.00 → 0.5, 1.15 → 1.0 (clamped above)
        .nrr = clamp01((raw.nrr_quarterly - 0.85) / (1.15 - 0.85)),
        // Win rate: 0.10 → 0.0, 0.40 → 1.0
        .deal_win_rate = clamp01((raw.deal_win_rate - 0.10) / (0.40 - 0.10)),
        // Sales cycle: 20 → 1.0, 90 → 0.0 (inverted)
        .sales_cycle_days = clamp01((90.0 - raw.sales_cycle_days_p50) / (90.0 - 20.0)),
        // Active sales: 0.40 → 0.0, 0.95 → 1.0
        .weekly_active_sales = clamp01((raw.weekly_active_sales_pct - 0.40) / (0.95 - 0.40)),
    };
}

fn clamp01(x: f32) f32 {
    return @max(0.0, @min(1.0, x));
}

// ============================================================================
// CompositeKpi — the weighted sum K ∈ [0, 1]
// ============================================================================

/// Compute the composite K from normalized scores and ProductIntent
/// value_weights. See docs/KPI.md §5 for the formula.
///
/// For CRM, the `revenue` weight gets a 1.5× boost (configurable via
/// `north_star_kpi = "nrr_quarterly"` in ProductIntent). This makes
/// the composite lean toward the NRR signal — the north star.
pub fn composite(
    norm: NormalizedKpi,
    weights: product_intent.ValueWeights,
    north_star_is_revenue: bool,
) f32 {
    // Map the 4 KPIs to the 4 value_weights dimensions:
    //   user_satisfaction ↔ (placeholder; future CSAT)
    //   retention         ↔ nrr (NRR is a retention signal)
    //   revenue           ↔ deal_win_rate (revenue primary signal)
    //   safety            ↔ (1 - normalized incident rate; future)
    //
    // The third dimension (sales_cycle) and fourth (active_sales) are
    // operational signals not directly mapped to value_weights; we
    // blend them 50/50 with the revenue axis to capture sales-velocity
    // health.
    const revenue_blend = 0.5 * norm.deal_win_rate + 0.25 * norm.sales_cycle_days + 0.25 * norm.weekly_active_sales;
    const retention_blend = norm.nrr; // NRR is the canonical retention signal

    // For CRM, user_satisfaction weight is not yet backed by a real
    // CSAT source; we use weekly_active_sales as a proxy (a healthy
    // team correlates with better customer experience).
    const user_sat_proxy = norm.weekly_active_sales;

    // Safety weight is currently 0.0 — no incident source registered
    // yet. Future: subtract normalized incident rate.
    const safety_blend: f32 = 0.0;

    var w_revenue = weights.revenue;
    if (north_star_is_revenue) {
        w_revenue *= 1.5; // boost the north-star axis
    }

    var sum = weights.user_satisfaction * user_sat_proxy +
        weights.retention * retention_blend +
        w_revenue * revenue_blend +
        weights.safety * safety_blend;

    // Re-normalize: the boosted weight might push sum above 1.0.
    // Clamp, since the E formula downstream expects K ∈ [0, 1].
    sum = clamp01(sum);

    return sum;
}

// ============================================================================
// Unit tests
// ============================================================================

test "normalize: NRR at breakeven (1.00) → 0.5" {
    const norm = normalize(.{ .nrr_quarterly = 1.00 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), norm.nrr, 1e-5);
}

test "normalize: NRR at best (1.20) → 1.0" {
    const norm = normalize(.{ .nrr_quarterly = 1.20 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm.nrr, 1e-5);
}

test "normalize: NRR at churn-floor (0.85) → 0.0" {
    const norm = normalize(.{ .nrr_quarterly = 0.85 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), norm.nrr, 1e-5);
}

test "normalize: NRR at catastrophic (0.50) clamps to 0.0" {
    const norm = normalize(.{ .nrr_quarterly = 0.50 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), norm.nrr, 1e-5);
}

test "normalize: win rate 0.25 (mid) → 0.5" {
    const norm = normalize(.{ .deal_win_rate = 0.25 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), norm.deal_win_rate, 1e-5);
}

test "normalize: sales cycle 20 days → 1.0 (best)" {
    const norm = normalize(.{ .sales_cycle_days_p50 = 20.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm.sales_cycle_days, 1e-5);
}

test "normalize: sales cycle 90 days → 0.0 (worst)" {
    const norm = normalize(.{ .sales_cycle_days_p50 = 90.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), norm.sales_cycle_days, 1e-5);
}

test "normalize: active sales 0.95 → 1.0" {
    const norm = normalize(.{ .weekly_active_sales_pct = 0.95 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm.weekly_active_sales, 1e-5);
}

test "composite: all KPIs at breakeven (0.5) with default weights → ~0.5" {
    const norm = normalize(.{
        .nrr_quarterly = 1.00,
        .deal_win_rate = 0.25,
        .sales_cycle_days_p50 = 55.0,
        .weekly_active_sales_pct = 0.675,
    });
    // All normalized values should be ~0.5
    const weights = product_intent.ValueWeights{
        .user_satisfaction = 0.25,
        .retention = 0.30,
        .revenue = 0.35,
        .safety = 0.10,
        ._raw_buf = &.{},
    };
    const k = composite(norm, weights, true);
    // K should be near 0.5 (within 0.1 because of weight skew)
    try std.testing.expect(k > 0.4);
    try std.testing.expect(k < 0.6);
}

test "composite: all KPIs at best (1.0) with default weights → 1.0" {
    const norm = normalize(.{
        .nrr_quarterly = 1.20,
        .deal_win_rate = 0.40,
        .sales_cycle_days_p50 = 20.0,
        .weekly_active_sales_pct = 0.95,
    });
    const weights = product_intent.ValueWeights{
        .user_satisfaction = 0.25,
        .retention = 0.30,
        .revenue = 0.35,
        .safety = 0.10,
        ._raw_buf = &.{},
    };
    const k = composite(norm, weights, true);
    // north_star boost pushes revenue contribution up; total can
    // exceed 1.0 pre-clamp but is clamped.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), k, 1e-5);
}

test "composite: all KPIs at worst (0.0) → 0.0" {
    const norm = normalize(.{
        .nrr_quarterly = 0.85,
        .deal_win_rate = 0.10,
        .sales_cycle_days_p50 = 90.0,
        .weekly_active_sales_pct = 0.40,
    });
    const weights = product_intent.ValueWeights{
        .user_satisfaction = 0.25,
        .retention = 0.30,
        .revenue = 0.35,
        .safety = 0.10,
        ._raw_buf = &.{},
    };
    const k = composite(norm, weights, true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), k, 1e-5);
}

test "RawKpi.isValid: accepts typical values" {
    const r = RawKpi{
        .nrr_quarterly = 1.10,
        .deal_win_rate = 0.25,
        .sales_cycle_days_p50 = 45.0,
        .weekly_active_sales_pct = 0.75,
    };
    try std.testing.expect(r.isValid());
}

test "RawKpi.isValid: rejects out-of-range" {
    const r = RawKpi{
        .nrr_quarterly = 5.0, // impossible
        .deal_win_rate = 0.25,
        .sales_cycle_days_p50 = 45.0,
        .weekly_active_sales_pct = 0.75,
    };
    try std.testing.expect(!r.isValid());
}
