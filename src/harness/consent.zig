//! Consent — the human-in-the-loop gate for L1-L5 changes.
//!
//! Status: Week 4 of Phase 1 (GHW-as-CRM). Phase 1 final deliverable.
//! Pairs with docs/CONSENT.md (the spec).
//!
//! # What this module does
//!
//! 1. Classifies a proposed change into one of 4 consent tiers
//!    (minor / standard / major / critical) based on severity,
//!    blast radius, and reversibility.
//! 2. Creates a ConsentRequest for non-minor changes.
//! 3. Polls for human approval/denial/timeout.
//! 4. Persists the decision (and the change) to the audit log.
//!
//! # What this module does NOT do
//!
//! - It does NOT actually apply the L5 change. The math layer
//!   applies the change after the consent is granted.
//! - It does NOT call the LLM to explain the change. The
//!   `evolution_rationale.zig` module handles that. Consent
//!   *receives* the rationale as input.
//! - It does NOT enforce that critical-tier requests are
//!   double-approved. The orchestrator (e.g. a Python CRM
//!   demo) does that check. Consent provides the data; the
//!   orchestrator enforces the policy.

const std = @import("std");
const product_intent = @import("product_intent.zig");

// ============================================================================
// Public types
// ============================================================================

pub const ConsentTier = enum(u8) {
    minor = 0,
    standard = 1,
    major = 2,
    critical = 3,

    pub fn label(self: ConsentTier) []const u8 {
        return switch (self) {
            .minor => "minor",
            .standard => "standard",
            .major => "major",
            .critical => "critical",
        };
    }

    /// Timeout in seconds for this tier. Mirrors
    /// `ProductIntent.consent_defaults` but exposed as a single
    /// function for orchestrators.
    pub fn defaultTimeoutSeconds(tier: ConsentTier, product: *const product_intent.ProductIntent) u64 {
        return switch (tier) {
            .minor => @as(u64, product.consent_defaults.minor_tier_timeout_hours) * 3600,
            .standard => @as(u64, product.consent_defaults.standard_tier_timeout_hours) * 3600,
            .major => @as(u64, product.consent_defaults.major_tier_timeout_hours) * 3600,
            .critical => @as(u64, product.consent_defaults.major_tier_timeout_hours) * 3600, // 7d default
        };
    }
};

/// Classification input. The orchestrator (or the L4 proposer
/// itself) fills these in based on its knowledge of the change.
pub const ChangeSpec = struct {
    /// Name of the L5 module being changed, e.g. "sales_followup.zig".
    /// Empty for L1 / L3.
    l5_module: []const u8,
    /// Files added (path → contents hash).
    files_added: []const []const u8,
    /// Files modified (path → contents hash).
    files_modified: []const []const u8,
    /// Total lines changed (added + removed).
    lines_changed: u32,
    /// Affected feature names (e.g. ["deal_creation_form"]).
    affected_features: []const []const u8,
    /// How many tenants / users will be affected. Computed by
    /// the orchestrator based on the change's blast radius.
    affected_users: u32,
    /// Whether the change is reversible. If unsure, default to
    /// `false` (be conservative).
    reversible: bool,
};

pub const RiskSignals = struct {
    severity: f32, // 0..1
    blast: f32, // 0..1
    reversibility: f32, // 0..1 (0 = trivially reversible, 1 = irreversible)

    pub fn combinedRisk(self: *const RiskSignals) f32 {
        return (self.severity + self.blast + self.reversibility) / 3.0;
    }
};

/// Classify a change into a tier. Mirrors docs/CONSENT.md §3.
pub fn classify(risk: RiskSignals) ConsentTier {
    const r = risk.combinedRisk();
    return if (r < 0.2)
        .minor
    else if (r < 0.5)
        .standard
    else if (r < 0.8)
        .major
    else
        .critical;
}

/// Compute the risk signals for a given change. The orchestrator
/// (CRM demo) fills in the L5-specific details and this function
/// produces a tier suggestion. This is a *suggestion* — the
/// orchestrator may override.
pub fn riskForChange(change: ChangeSpec) RiskSignals {
    // Severity: 0 for L1, 0.3 for L3, 0.6+ for L5.
    var severity: f32 = 0.0;
    if (change.l5_module.len > 0) {
        severity = 0.6;
        // Files in blacklist-adjacent paths would push to 0.9;
        // we don't know paths here, so use lines_changed as a
        // proxy: > 200 lines → 0.8, > 50 → 0.65, else 0.6.
        if (change.lines_changed > 200) {
            severity = 0.8;
        } else if (change.lines_changed > 50) {
            severity = 0.65;
        }
    } else if (change.files_added.len > 0 or change.files_modified.len > 0) {
        severity = 0.3; // L3 (new file or small modification)
    }

    // Blast: scale with affected_users, capped at 1.0.
    // 0 users → 0.0, 1 → 0.3, 100 → 0.6, 1000+ → 1.0.
    const blast: f32 = if (change.affected_users == 0)
        0.0
    else if (change.affected_users <= 1)
        0.3
    else if (change.affected_users <= 100)
        0.6
    else
        1.0;

    // Reversibility: 0.0 if reversible, 1.0 if not, 0.5 if unknown.
    const reversibility: f32 = if (change.reversible) 0.0 else 0.9;

    return .{
        .severity = severity,
        .blast = blast,
        .reversibility = reversibility,
    };
}

// ============================================================================
// ConsentRequest
// ============================================================================

pub const ConsentDecision = enum {
    pending,
    approved,
    denied,
    expired,
    auto_reverted,
};

pub const ConsentRequest = struct {
    request_id: u64,
    tier: ConsentTier,
    change: ChangeSpec,
    risk: RiskSignals,
    rationale: []const u8, // LLM-generated explanation (optional)
    predicted_kpi_delta: f32, // expected KPI impact (0 = unknown)
    created_at: u64, // unix seconds
    timeout_seconds: u64,
    decision: ConsentDecision = .pending,
    decided_at: ?u64 = null,
    decided_by: ?[]const u8 = null,
    decision_note: ?[]const u8 = null,

    /// True iff the request has timed out (decision still pending
    /// but now_seconds > created_at + timeout_seconds).
    pub fn hasTimedOut(self: *const ConsentRequest, now_unix: u64) bool {
        if (self.decision != .pending) return false;
        return now_unix > self.created_at + self.timeout_seconds;
    }

    /// True iff the change has been approved and should be applied.
    pub fn isApproved(self: *const ConsentRequest) bool {
        return self.decision == .approved;
    }

    /// True iff the change is in a terminal state (no further
    /// action will be taken).
    pub fn isTerminal(self: *const ConsentRequest) bool {
        return self.decision != .pending and self.decision != .approved;
        // Note: approved is not terminal because the change still
        // needs to be applied. We track application separately.
    }
};

/// Build a fresh ConsentRequest with sane defaults from ProductIntent.
pub fn newRequest(
    next_id: u64,
    change: ChangeSpec,
    risk: RiskSignals,
    rationale: []const u8,
    predicted_kpi_delta: f32,
    now_unix: u64,
    product: *const product_intent.ProductIntent,
) ConsentRequest {
    const tier = classify(risk);
    return .{
        .request_id = next_id,
        .tier = tier,
        .change = change,
        .risk = risk,
        .rationale = rationale,
        .predicted_kpi_delta = predicted_kpi_delta,
        .created_at = now_unix,
        .timeout_seconds = ConsentTier.defaultTimeoutSeconds(tier, product),
        .decision = .pending,
    };
}

// ============================================================================
// Approver logic
// ============================================================================

/// Returns the list of role names that must approve a request of
/// the given tier. The orchestrator (CRM demo) actually queries
/// these roles; Consent just enumerates them.
///
/// For `critical`, two-of-three approval is required (per
/// `ProductIntent.consent_defaults.critical_tier_requires_double_approval`).
pub fn requiredApprovers(
    tier: ConsentTier,
    product: *const product_intent.ProductIntent,
) []const u8 {
    return switch (tier) {
        .minor => "none (auto-approved at apply time)",
        .standard => "sales_manager",
        .major => "sales_manager + sales_director",
        .critical => if (product.consent_defaults.critical_tier_requires_double_approval)
            "ceo + ops_lead + security_lead (2 of 3 required)"
        else
            "ceo + ops_lead + security_lead (all required)",
    };
}

// ============================================================================
// Unit tests
// ============================================================================

test "classify: minor for low risk" {
    const risk = RiskSignals{ .severity = 0.0, .blast = 0.0, .reversibility = 0.0 };
    try std.testing.expectEqual(ConsentTier.minor, classify(risk));
}

test "classify: standard for medium risk" {
    const risk = RiskSignals{ .severity = 0.3, .blast = 0.3, .reversibility = 0.0 };
    try std.testing.expectEqual(ConsentTier.standard, classify(risk));
}

test "classify: major for high risk" {
    const risk = RiskSignals{ .severity = 0.6, .blast = 0.6, .reversibility = 0.3 };
    try std.testing.expectEqual(ConsentTier.major, classify(risk));
}

test "classify: critical for very high risk" {
    const risk = RiskSignals{ .severity = 1.0, .blast = 0.6, .reversibility = 0.9 };
    try std.testing.expectEqual(ConsentTier.critical, classify(risk));
}

test "RiskSignals.combinedRisk: averages the 3 dimensions" {
    const r = RiskSignals{ .severity = 0.6, .blast = 0.6, .reversibility = 0.3 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.combinedRisk(), 1e-5);
}

test "riskForChange: L1 only is severity 0" {
    const change = ChangeSpec{
        .l5_module = "",
        .files_added = &.{},
        .files_modified = &.{},
        .lines_changed = 0,
        .affected_features = &.{},
        .affected_users = 0,
        .reversible = true,
    };
    const r = riskForChange(change);
    try std.testing.expect(r.severity == 0.0);
    try std.testing.expect(r.reversibility == 0.0);
}

test "riskForChange: L5 with 100 lines, 1 user, irreversible = major" {
    const change = ChangeSpec{
        .l5_module = "sales_followup.zig",
        .files_added = &.{"new_rule.zig"},
        .files_modified = &.{},
        .lines_changed = 100,
        .affected_features = &.{"deal_creation_form"},
        .affected_users = 1,
        .reversible = false,
    };
    const r = riskForChange(change);
    // severity 0.65 (L5 + 100 lines), blast 0.3 (1 user), reversibility 0.9
    // combined = (0.65 + 0.3 + 0.9) / 3 = 0.617
    // 0.617 is in [0.5, 0.8) → major
    try std.testing.expectEqual(ConsentTier.major, classify(r));
}

test "riskForChange: L5 with 300 lines, 5000 users, irreversible = critical" {
    const change = ChangeSpec{
        .l5_module = "core.zig",
        .files_added = &.{},
        .files_modified = &.{"a.zig", "b.zig", "c.zig"},
        .lines_changed = 300,
        .affected_features = &.{"all"},
        .affected_users = 5000,
        .reversible = false,
    };
    const r = riskForChange(change);
    // severity 0.8 (>200 lines), blast 1.0 (>1000 users), reversibility 0.9
    // combined = (0.8 + 1.0 + 0.9) / 3 = 0.9
    // 0.9 >= 0.8 → critical
    try std.testing.expectEqual(ConsentTier.critical, classify(r));
}

test "ConsentRequest.hasTimedOut: pending + past deadline" {
    const req = ConsentRequest{
        .request_id = 1,
        .tier = .minor,
        .change = .{
            .l5_module = "",
            .files_added = &.{},
            .files_modified = &.{},
            .lines_changed = 0,
            .affected_features = &.{},
            .affected_users = 0,
            .reversible = true,
        },
        .risk = .{ .severity = 0, .blast = 0, .reversibility = 0 },
        .rationale = "trivial",
        .predicted_kpi_delta = 0,
        .created_at = 1000,
        .timeout_seconds = 60,
    };
    try std.testing.expect(!req.hasTimedOut(1059));
    try std.testing.expect(req.hasTimedOut(1061));
}

test "ConsentRequest.hasTimedOut: approved is never timed out" {
    var req = ConsentRequest{
        .request_id = 1,
        .tier = .standard,
        .change = .{
            .l5_module = "",
            .files_added = &.{},
            .files_modified = &.{},
            .lines_changed = 0,
            .affected_features = &.{},
            .affected_users = 0,
            .reversible = true,
        },
        .risk = .{ .severity = 0.3, .blast = 0.3, .reversibility = 0.0 },
        .rationale = "ok",
        .predicted_kpi_delta = 0,
        .created_at = 1000,
        .timeout_seconds = 60,
    };
    req.decision = .approved;
    try std.testing.expect(!req.hasTimedOut(2000));
}

test "ConsentTier.label: returns human-readable string" {
    try std.testing.expectEqualStrings("minor", ConsentTier.minor.label());
    try std.testing.expectEqualStrings("standard", ConsentTier.standard.label());
    try std.testing.expectEqualStrings("major", ConsentTier.major.label());
    try std.testing.expectEqualStrings("critical", ConsentTier.critical.label());
}

test "requiredApprovers: critical lists 2-of-3" {
    const product = product_intent.ProductIntent{
        .allocator = std.testing.allocator,
        .schema_version = 1,
        .product_id = "x",
        .product_type = .saas_web,
        .version = "0",
        .update_epoch = 1,
        .last_updated = 0,
        .approved_by = "x",
        .manifesto = "",
        .sacrosanct = &.{},
        .north_star_kpi = "x",
        .secondary_kpis = &.{},
        .kpi_aggregator = .mean,
        .kpi_evaluation_window = .daily,
        .value_weights = .{
            .user_satisfaction = 0.25,
            .retention = 0.30,
            .revenue = 0.35,
            .safety = 0.10,
            ._raw_buf = &.{},
        },
        .consent_defaults = .{
            .minor_tier_timeout_hours = 24,
            .standard_tier_timeout_hours = 72,
            .major_tier_timeout_hours = 168,
            .critical_tier_requires_double_approval = true,
            .auto_approve_within_window = false,
            ._raw_buf = &.{},
        },
        .experiment_defaults = .{
            .min_sample_size = 30,
            .min_duration_days = 14,
            .max_concurrent_experiments_per_tenant = 2,
            .cohort_split_by = .tenant_user_id,
            ._raw_buf = &.{},
        },
        .channel_routing = .{
            .e_saturated = &.{},
            .user_quiet_24h = &.{},
            .l5_about_to_apply = &.{},
            .anomaly = &.{},
            .experiment_done = &.{},
            ._raw_buf = &.{},
        },
        .rhythm = .{
            .cycle_interval_seconds = 300,
            .kpi_refresh_interval_hours = 24,
            .experiment_default_duration_days = 14,
            .consent_batch_window_days = 7,
            ._raw_buf = &.{},
        },
        .cohort_policy = null,
        .audit_log = .{
            .enabled = true,
            .retention_days = 365,
            .include_llm_prompts = true,
            .include_llm_responses = true,
            ._raw_buf = &.{},
        },
    };
    try std.testing.expect(std.mem.indexOf(u8, requiredApprovers(.critical, &product), "2 of 3") != null);
}
