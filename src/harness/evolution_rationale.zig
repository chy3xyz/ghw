//! EvolutionRationale — bridge between the math layer's L4 propose
//! decision and the LLM-driven explanation layer.
//!
//! Status: Week 2 of Phase 1 (GHW-as-CRM). Pairs with
//! the ρ·K term in src/world/core.zig and src/harness/llm_driver.zig.
//!
//! # Why this module exists
//!
//! When the math layer decides to accept an L4 proposal (e.g. "tweak
//! μ from 0.30 to 0.34"), it must produce a human-readable
//! rationale. The math layer is *not allowed* to write that rationale
//! itself (that would violate the math/protocol vs semantic
//! separation; see docs/LLM_DRIVER.md §3 Invariant 3).
//!
//! This module calls `LlmDriver.dispatch(.write_evolution_rationale, ...)`
//! and returns the typed result. The math layer writes the result
//! to its proposal log; the LLM (via LlmDriver) handles the prose.
//!
//! # What this module does
//!
//! - Assembles the typed context that the LLM needs (proposal diff,
//!   current E, predicted ΔE, KPI trend, KPI variance).
//! - Calls LlmDriver with a stable audit tag.
//! - Validates the LLM's response is non-empty and fits length.
//! - Returns the rationale to the caller for storage in the proposal
//!   log.
//!
//! # What this module does NOT do
//!
//! - It does NOT decide whether the proposal is good. That is the
//!   math layer's job (E formula + L4 admissibility check).
//! - It does NOT fall back to a template if the LLM is unavailable.
//!   `write_evolution_rationale` is a MANDATORY role (per
//!   docs/LLM_DRIVER.md §3 Invariant 2). If the LLM is down, the
//!   daemon refuses to propose at all — better to be silent than
//!   to ship a generic rationale.

const std = @import("std");
const llm_driver = @import("llm_driver.zig");

// ============================================================================
// ProposalDiff — typed description of an L4 change
// ============================================================================

/// What changed. Each field is `null` if the corresponding
/// coefficient was not touched. The LLM uses the diff to write
/// the rationale.
pub const ProposalDiff = struct {
    mu_old: f32,
    mu_new: ?f32,
    nu_old: f32,
    nu_new: ?f32,
    sigma_old: f32,
    sigma_new: ?f32,
    lambda_old: f32,
    lambda_new: ?f32,

    /// True iff any coefficient was actually changed.
    pub fn hasChange(self: *const ProposalDiff) bool {
        return self.mu_new != null or self.nu_new != null or
            self.sigma_new != null or self.lambda_new != null;
    }

    /// Render the diff as a compact human-readable string for
    /// inclusion in the LLM prompt and the audit log.
    pub fn describe(self: *const ProposalDiff, buf: []u8) ![]u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.mu_new) |new| {
            const delta = new - self.mu_old;
            try w.print("μ: {d:.3} → {d:.3} (Δ {s}{d:.3}); ", .{
                self.mu_old, new, if (delta >= 0) "+" else "", delta,
            });
        }
        if (self.nu_new) |new| {
            const delta = new - self.nu_old;
            try w.print("ν: {d:.3} → {d:.3} (Δ {s}{d:.3}); ", .{
                self.nu_old, new, if (delta >= 0) "+" else "", delta,
            });
        }
        if (self.sigma_new) |new| {
            const delta = new - self.sigma_old;
            try w.print("σ: {d:.3} → {d:.3} (Δ {s}{d:.3}); ", .{
                self.sigma_old, new, if (delta >= 0) "+" else "", delta,
            });
        }
        if (self.lambda_new) |new| {
            const delta = new - self.lambda_old;
            try w.print("λ: {d:.3} → {d:.3} (Δ {s}{d:.3}); ", .{
                self.lambda_old, new, if (delta >= 0) "+" else "", delta,
            });
        }
        return w.buffered();
    }
};

// ============================================================================
// ProposalContext — the full context fed to the LLM
// ============================================================================

pub const ProposalContext = struct {
    diff: ProposalDiff,
    current_e: f32,
    predicted_e_delta: f32, // positive = improvement
    kpi_now: f32,
    kpi_target: f32,
    kpi_trend: f32, // slope of kpi_history, K-units per cycle
    kpi_variance: f32, // variance of kpi_history

    /// Serialize to a compact JSON for the LLM prompt. The LLM
    /// driver accepts JSON in `context_json` (see
    /// WriteEvolutionRationaleRequest).
    pub fn toJson(self: *const ProposalContext, buf: []u8) ![]u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.print(
            \\{{"diff_mu":{?d},"diff_nu":{?d},"diff_sigma":{?d},"diff_lambda":{?d},
            \\"current_e":{d},"predicted_e_delta":{d},
            \\"kpi_now":{d},"kpi_target":{d},"kpi_trend":{d},"kpi_variance":{d}}}
        , .{
            if (self.diff.mu_new) |v| @as(f32, v - self.diff.mu_old) else null,
            if (self.diff.nu_new) |v| @as(f32, v - self.diff.nu_old) else null,
            if (self.diff.sigma_new) |v| @as(f32, v - self.diff.sigma_old) else null,
            if (self.diff.lambda_new) |v| @as(f32, v - self.diff.lambda_old) else null,
            self.current_e,
            self.predicted_e_delta,
            self.kpi_now,
            self.kpi_target,
            self.kpi_trend,
            self.kpi_variance,
        });
        return w.buffered();
    }
};

// ============================================================================
// generateRationale — the main entry point
// ============================================================================

/// Generate a human-readable rationale for an L4 proposal.
///
/// Returns the LLM's response (the rationale text + caveats).
/// On LLM failure for a MANDATORY role, returns an error — the
/// math layer must NOT accept the proposal without a rationale.
///
/// **Memory ownership**: the returned Rationale wraps string slices
/// owned by the LlmDriver's response buffer. The caller MUST NOT
/// free those slices; they live as long as the response. If the
/// caller needs to keep the rationale past the response, they
/// must dup it.
pub fn generateRationale(
    driver: *llm_driver.LlmDriver,
    allocator: std.mem.Allocator,
    tick: u64,
    ctx: ProposalContext,
) !Rationale {
    var prompt_buf: [1024]u8 = undefined;
    const ctx_json = try ctx.toJson(&prompt_buf);

    const audit_tag = try std.fmt.allocPrintSentinel(allocator, "tick:{d}:l4_propose", .{tick}, 0);
    errdefer allocator.free(audit_tag);

    const resp = try driver.dispatch(.{
        .role = .write_evolution_rationale,
        .audit_tag = audit_tag,
        .payload = .{ .write_evolution_rationale = .{
            .change_summary = try ctx.diff.describe(&prompt_buf),
            .current_e = ctx.current_e,
            .predicted_e_delta = ctx.predicted_e_delta,
            .kpi_trend_json = ctx_json,
        } },
    });

    // Success path: LlmDriver takes ownership of audit_tag's
    // underlying memory (or has already copied it into its own
    // audit log). We free our original allocation.
    allocator.free(audit_tag);

    const rational = resp.result.write_evolution_rationale;
    return .{
        .rationale = rational.rationale,
        .alternative_explored = rational.alternative_explored,
        .confidence_caveat = rational.confidence_caveat,
        .used_llm = resp.used_llm,
    };
}

pub const Rationale = struct {
    rationale: []const u8,
    alternative_explored: ?[]const u8,
    confidence_caveat: []const u8,
    used_llm: bool,

    pub fn format(self: *const Rationale, buf: []u8) ![]u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.print("{s}", .{self.rationale});
        if (self.alternative_explored) |alt| {
            try w.print(" (alt: {s})", .{alt});
        }
        try w.print(" [caveat: {s}]", .{self.confidence_caveat});
        return w.buffered();
    }
};

// ============================================================================
// Unit tests
// ============================================================================

test "ProposalDiff.hasChange: returns false when nothing changed" {
    const d = ProposalDiff{
        .mu_old = 0.3,
        .mu_new = null,
        .nu_old = 0.3,
        .nu_new = null,
        .sigma_old = 0.0,
        .sigma_new = null,
        .lambda_old = 0.1,
        .lambda_new = null,
    };
    try std.testing.expect(!d.hasChange());
}

test "ProposalDiff.hasChange: returns true when one field changed" {
    const d = ProposalDiff{
        .mu_old = 0.3,
        .mu_new = 0.34,
        .nu_old = 0.3,
        .nu_new = null,
        .sigma_old = 0.0,
        .sigma_new = null,
        .lambda_old = 0.1,
        .lambda_new = null,
    };
    try std.testing.expect(d.hasChange());
}

test "ProposalDiff.describe: shows only changed fields" {
    const d = ProposalDiff{
        .mu_old = 0.30,
        .mu_new = 0.34,
        .nu_old = 0.30,
        .nu_new = null,
        .sigma_old = 0.00,
        .sigma_new = null,
        .lambda_old = 0.10,
        .lambda_new = null,
    };
    var buf: [256]u8 = undefined;
    const out = try d.describe(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "μ: 0.300 → 0.340") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ν:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "λ:") == null);
}

test "ProposalContext.toJson: includes all 4 diff fields and KPIs" {
    const ctx = ProposalContext{
        .diff = .{
            .mu_old = 0.3,
            .mu_new = 0.34,
            .nu_old = 0.3,
            .nu_new = null,
            .sigma_old = 0.0,
            .sigma_new = null,
            .lambda_old = 0.1,
            .lambda_new = null,
        },
        .current_e = 0.85,
        .predicted_e_delta = 0.02,
        .kpi_now = 0.7,
        .kpi_target = 1.0,
        .kpi_trend = 0.001,
        .kpi_variance = 0.005,
    };
    var buf: [1024]u8 = undefined;
    const out = try ctx.toJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"diff_mu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"diff_nu\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"current_e\":0.85") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kpi_trend\":0.001") != null);
}

test "generateRationale: provider=none + MANDATORY role returns error" {
    var driver = llm_driver.LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = true, // even with fallback, mandatory role hard-fails
    });
    const ctx = ProposalContext{
        .diff = .{
            .mu_old = 0.3,
            .mu_new = 0.34,
            .nu_old = 0.3,
            .nu_new = null,
            .sigma_old = 0.0,
            .sigma_new = null,
            .lambda_old = 0.1,
            .lambda_new = null,
        },
        .current_e = 0.85,
        .predicted_e_delta = 0.02,
        .kpi_now = 0.7,
        .kpi_target = 1.0,
        .kpi_trend = 0.001,
        .kpi_variance = 0.005,
    };
    try std.testing.expectError(error.LlmProviderNotConfigured, generateRationale(&driver, std.testing.allocator, 100, ctx));
}

test "Rationale.format: includes rationale + caveat" {
    const r = Rationale{
        .rationale = "increase mu to reduce variance",
        .alternative_explored = "increase nu instead",
        .confidence_caveat = "7-day prediction",
        .used_llm = true,
    };
    var buf: [256]u8 = undefined;
    const out = try r.format(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "increase mu") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "caveat:") != null);
}
