//! LlmDriver — semantic layer boundary
//!
//! Status: Week 1, second commit (architecture axiom).
//! Pairs with: src/harness/product_intent.zig (the protocol/contract layer).
//!
//! # What this module does
//!
//! Encodes the architectural boundary between:
//!   - **Math/protocol soul** (E equation, 9-palace, blacklist, Consent,
//!     ProductIntent contract) — immutable axioms of what a digital life *is*
//!   - **Semantic/expressive soul** (user understanding, natural language
//!     generation, judgement calls) — the LLM-driven layer
//!
//! # Boundary invariants
//!
//! 1. **FORBIDDEN roles** (e.g. `decide_sacrosanct_exception`) — calling
//!    these returns a hardcoded refusal without consulting the LLM.
//! 2. **MANDATORY roles** (e.g. `write_user_message`) — LLM failure is a
//!    hard error, never silently falls back to a template.
//! 3. **Math/protocol never sees free-form LLM strings.** All LLM outputs
//!    are validated against typed schemas before being returned.
//! 4. **Every call is audit-logged** (configurable).
//! 5. **LlmDriver is stateless between calls.** State lives in
//!    EpisodicMemory and is passed in via `Request.recent_context`.
//!
//! # What this module does NOT do (yet)
//!
//! - It does not call any LLM provider. The provider integration is in
//!   src/harness/llm/ (separate concern, planned for Week 2).
//! - It does not have a working audit log writer. The audit interface is
//!   stubbed; production wiring happens in INTEGRATION_WEEK1.md IP-6.

const std = @import("std");

// ============================================================================
// SemanticRole — the 12 roles, with their contract types
// ============================================================================

/// All possible LLM-driven semantic operations.
///
/// IMPORTANT: Adding a new role requires (a) defining the input/output
/// contract types below, (b) adding a prompt template in
/// `templates/<role>.md.tmpl`, (c) adding a unit test, (d) deciding
/// whether the role is MANDATORY, OPTIONAL, or FORBIDDEN.
pub const SemanticRole = enum(u8) {
    // Group A — Understanding
    parse_user_message,
    parse_product_event,
    classify_consent_tier,
    detect_anomaly_cause,

    // Group B — Expression
    write_user_message,
    write_evolution_rationale,
    write_l5_change_summary,
    write_milestone_narrative,

    // Group C — Judgement
    decide_followup_priority,
    decide_experiment_arm,

    // Group D — Refusal / Boundary
    decide_sacrosanct_exception,

    // Sentinel for bit-set sizing. Do not remove.
    _role_count,
};

// Compile-time checks (these run on every build):
comptime {
    // Invariant: forbidden + mandatory + optional = total roles.
    const forbidden_count: usize = FORBIDDEN_LLM_ROLES.len;
    const mandatory_count: usize = MANDATORY_LLM_ROLES.len;
    const total_roles: usize = @intFromEnum(SemanticRole._role_count);
    // forbidden and mandatory are disjoint sets; assert this.
    for (FORBIDDEN_LLM_ROLES) |f| {
        for (MANDATORY_LLM_ROLES) |m| {
            if (f == m) @compileError("FORBIDDEN and MANDATORY sets must be disjoint");
        }
    }
    // total ≤ enum count (some roles may be intentionally unclassified).
    if (forbidden_count + mandatory_count > total_roles) {
        @compileError("FORBIDDEN + MANDATORY exceeds total role count");
    }
}

/// Roles that the LLM is NEVER allowed to perform.
/// See docs/LLM_DRIVER.md §3 Invariant 1.
pub const FORBIDDEN_LLM_ROLES: []const SemanticRole = &.{
    .decide_sacrosanct_exception,
};

// Roles that MUST be LLM-driven. If LLM is unavailable, the operation
// hard-fails (does NOT silently fall back to a template).
// See docs/LLM_DRIVER.md §3 Invariant 2.
pub const MANDATORY_LLM_ROLES: []const SemanticRole = &.{
    .parse_user_message,
    .write_user_message,
    .write_evolution_rationale,
    .write_l5_change_summary,
    .write_milestone_narrative,
};

// Roles that may be LLM-driven OR fall back to rule-based. Default.
// See docs/LLM_DRIVER.md §2 — all roles not in FORBIDDEN or MANDATORY.

/// True iff `role` is in the FORBIDDEN set.
pub fn isForbidden(role: SemanticRole) bool {
    inline for (FORBIDDEN_LLM_ROLES) |f| {
        if (f == role) return true;
    }
    return false;
}

/// True iff `role` is in the MANDATORY set.
pub fn isMandatory(role: SemanticRole) bool {
    inline for (MANDATORY_LLM_ROLES) |m| {
        if (m == role) return true;
    }
    return false;
}

// ============================================================================
// Request / Response contracts (typed, validated)
// ============================================================================

/// Generic LLM request envelope. Each role's caller fills the role-specific
/// fields. We do NOT allow free-form "extra" fields — that would re-introduce
/// the LLM-prompt-injection surface.
pub const Request = struct {
    role: SemanticRole,
    /// Caller-supplied audit tag (e.g. "tick:24804" or "user_msg:5").
    /// Goes into the audit log.
    audit_tag: []const u8,
    /// Role-specific payload. The shape is enforced by the caller's union
    /// variant selection (see dispatch()).
    payload: Payload,
};

/// Tagged union of all 11 request payloads. The active variant must match
/// `Request.role`. We use an untagged-style union with separate `role` field
/// for explicitness — Zig's `union(enum)` works, but we keep the role field
/// on the envelope for serialisability.
pub const Payload = union(enum) {
    parse_user_message: ParseUserMessageRequest,
    parse_product_event: ParseProductEventRequest,
    classify_consent_tier: ClassifyConsentTierRequest,
    detect_anomaly_cause: DetectAnomalyCauseRequest,
    write_user_message: WriteUserMessageRequest,
    write_evolution_rationale: WriteEvolutionRationaleRequest,
    write_l5_change_summary: WriteL5ChangeSummaryRequest,
    write_milestone_narrative: WriteMilestoneNarrativeRequest,
    decide_followup_priority: DecideFollowupPriorityRequest,
    decide_experiment_arm: DecideExperimentArmRequest,
    decide_sacrosanct_exception: DecideSacrosanctExceptionRequest,

    /// Map a Payload variant to its SemanticRole tag. Used by dispatch()
    /// to verify the caller picked a consistent (role, payload) pair.
    pub fn roleOf(self: Payload) SemanticRole {
        return switch (self) {
            .parse_user_message => .parse_user_message,
            .parse_product_event => .parse_product_event,
            .classify_consent_tier => .classify_consent_tier,
            .detect_anomaly_cause => .detect_anomaly_cause,
            .write_user_message => .write_user_message,
            .write_evolution_rationale => .write_evolution_rationale,
            .write_l5_change_summary => .write_l5_change_summary,
            .write_milestone_narrative => .write_milestone_narrative,
            .decide_followup_priority => .decide_followup_priority,
            .decide_experiment_arm => .decide_experiment_arm,
            .decide_sacrosanct_exception => .decide_sacrosanct_exception,
        };
    }
};

pub const Response = struct {
    role: SemanticRole,
    /// True if the LLM was actually consulted. False means we returned a
    /// fallback (or, for forbidden roles, a hardcoded refusal).
    used_llm: bool,
    /// The role-specific result.
    result: Result,
};

pub const Result = union(enum) {
    parse_user_message: ParseUserMessageResponse,
    parse_product_event: ParseProductEventResponse,
    classify_consent_tier: ClassifyConsentTierResponse,
    detect_anomaly_cause: DetectAnomalyCauseResponse,
    write_user_message: WriteUserMessageResponse,
    write_evolution_rationale: WriteEvolutionRationaleResponse,
    write_l5_change_summary: WriteL5ChangeSummaryResponse,
    write_milestone_narrative: WriteMilestoneNarrativeResponse,
    decide_followup_priority: DecideFollowupPriorityResponse,
    decide_experiment_arm: DecideExperimentArmResponse,
    decide_sacrosanct_exception: DecideSacrosanctExceptionResponse,
};

// ----- A1. parse_user_message -----

pub const ParseUserMessageRequest = struct {
    user_id: []const u8,
    text: []const u8,
    recent_context: []const u8, // serialized EpisodicMemory slice
};

pub const ParseUserMessageResponse = struct {
    intent: []const u8, // one of a closed enum (e.g. "schedule_followup")
    confidence: f32,    // [0, 1]
    entities: []const u8 = "", // JSON object string
};

// ----- A2. parse_product_event -----

pub const ParseProductEventRequest = struct {
    event_type: []const u8,
    payload: []const u8,
    tenant_id: []const u8,
};

pub const ParseProductEventResponse = struct {
    event_kind: []const u8,
    severity: f32,
    attributable: bool,
};

// ----- A3. classify_consent_tier -----

pub const ClassifyConsentTierRequest = struct {
    change_spec_json: []const u8, // serialized ChangeSpec
    product_intent_summary: []const u8,
};

pub const ClassifyConsentTierResponse = struct {
    tier: []const u8, // one of "minor" | "standard" | "major" | "critical"
    rationale: []const u8,
    risk_indicators: []const u8 = "", // JSON array
};

// ----- A4. detect_anomaly_cause -----

pub const DetectAnomalyCauseRequest = struct {
    kpi_name: []const u8,
    current_value: f32,
    baseline_value: f32,
    recent_events_json: []const u8,
    recent_changes_json: []const u8,
};

pub const DetectAnomalyCauseResponse = struct {
    hypotheses_json: []const u8, // JSON array of {cause, probability, evidence[]}
    recommended_action: []const u8,
};

// ----- B1. write_user_message -----

pub const ToneHint = enum {
    formal_ops_alert,
    ops_casual_status,
    sales_manager_summary,
    customer_facing_polite,
    developer_quiet_log, // for internal logs, not user-facing
};

pub const WriteUserMessageRequest = struct {
    trigger: []const u8, // one of ChannelTrigger names
    context_json: []const u8,
    tone_hint: ToneHint,
    max_length: u16,
    must_contain: []const []const u8 = &.{}, // hard requirements
};

pub const WriteUserMessageResponse = struct {
    text: []const u8,
    followup_question: ?[]const u8 = null,
    action_proposal_json: ?[]const u8 = null,
};

// ----- B2. write_evolution_rationale -----

pub const WriteEvolutionRationaleRequest = struct {
    change_summary: []const u8,
    current_e: f32,
    predicted_e_delta: f32,
    kpi_trend_json: []const u8,
};

pub const WriteEvolutionRationaleResponse = struct {
    rationale: []const u8,
    alternative_explored: ?[]const u8 = null,
    confidence_caveat: []const u8,
};

// ----- B3. write_l5_change_summary -----

pub const WriteL5ChangeSummaryRequest = struct {
    l5_module_name: []const u8,
    files_added: []const []const u8,
    files_modified: []const []const u8,
    lines_changed: u32,
};

pub const WriteL5ChangeSummaryResponse = struct {
    summary: []const u8,
    affected_features: []const u8 = "", // JSON array
    predicted_user_impact: []const u8,
};

// ----- B4. write_milestone_narrative -----

pub const WriteMilestoneNarrativeRequest = struct {
    milestone_type: []const u8,
    tick: u64,
    recent_context_json: []const u8,
};

pub const WriteMilestoneNarrativeResponse = struct {
    narrative: []const u8,
    gratitude_to: []const u8 = "", // JSON array of who/what to thank
    next_aspiration: ?[]const u8 = null,
};

// ----- C1. decide_followup_priority -----

pub const DecideFollowupPriorityRequest = struct {
    customers_json: []const u8, // serialized list of {id, last_contact_age_days, deal_stage, sentiment}
    sales_rep_context_json: []const u8,
};

pub const DecideFollowupPriorityResponse = struct {
    ranked_json: []const u8, // JSON array of {customer_id, score, reason}
    top_action: ?[]const u8 = null,
};

// ----- C2. decide_experiment_arm -----

pub const DecideExperimentArmRequest = struct {
    entity_id: []const u8,
    current_arm_balance_json: []const u8, // {control_count, treatment_count}
};

pub const DecideExperimentArmResponse = struct {
    arm: []const u8, // "control" | "treatment"
    rationale: []const u8,
};

// ----- D1. decide_sacrosanct_exception (FORBIDDEN) -----

pub const DecideSacrosanctExceptionRequest = struct {
    proposed_exception: []const u8,
    justification: []const u8,
};

pub const DecideSacrosanctExceptionResponse = struct {
    allowed: bool, // always false
    reason: []const u8, // hardcoded
};

// ============================================================================
// Configuration
// ============================================================================

pub const Provider = enum {
    anthropic,
    openai,
    deepseek,
    mock, // for tests + offline dev
    none, // no LLM; mandatory roles hard-fail, others template-fallback
};

pub const Config = struct {
    provider: Provider = .mock,
    model: []const u8 = "claude-3-5-sonnet",
    timeout_seconds: u32 = 5,
    fallback_on_failure: bool = true,
    audit_prompts: bool = true,
    audit_responses: bool = true,
    max_concurrent_calls: u8 = 4,
    rate_limit_per_minute: u32 = 60,
};

// ============================================================================
// LlmDriver — the boundary struct
// ============================================================================

pub const LlmDriver = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// In-flight call counter. Atomic to allow concurrent dispatch from
    /// multiple threads (e.g. ui_server chat handler + reflection worker).
    in_flight: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, config: Config) LlmDriver {
        return .{
            .allocator = allocator,
            .config = config,
            .in_flight = std.atomic.Value(u32).init(0),
        };
    }

    /// The main entry point. Caller fills the role-specific payload, and
    /// `dispatch` returns a typed, validated response.
    ///
    /// On error, returns `error.LlmUnavailable` (for mandatory roles) or
    /// the role-specific fallback (for optional roles when
    /// `config.fallback_on_failure` is true).
    pub fn dispatch(self: *LlmDriver, request: Request) !Response {
        // Sanity: caller must have picked a consistent (role, payload) pair.
        if (request.payload.roleOf() != request.role) {
            return error.RolePayloadMismatch;
        }

        // Invariant 1: forbidden roles return hardcoded refusal without
        // consulting the LLM.
        switch (request.role) {
            .decide_sacrosanct_exception => {
                return Response{
                    .role = .decide_sacrosanct_exception,
                    .used_llm = false,
                    .result = .{ .decide_sacrosanct_exception = .{
                        .allowed = false,
                        .reason = sacrosanct_refusal_reason,
                    } },
                };
            },
            else => {},
        }

        // Invariant 2: mandatory roles must have an LLM.
        const mandatory = isMandatory(request.role);

        // Provider=none is a config-level "no LLM" signal. We always fail
        // fast in that case; fallback_on_failure does not save us.
        if (self.config.provider == .none) {
            if (mandatory) return error.LlmProviderNotConfigured;
            if (self.config.fallback_on_failure) return self.fallbackFor(request);
            return error.LlmProviderNotConfigured;
        }

        // Acquire in-flight slot.
        const prev = self.in_flight.fetchAdd(1, .acquire);
        defer _ = self.in_flight.fetchSub(1, .release);
        if (prev >= self.config.max_concurrent_calls) {
            // Rate limit at in-flight boundary.
            if (mandatory) return error.LlmBusy;
            return self.fallbackFor(request);
        }

        // Provider dispatch.
        const result = self.callProvider(request) catch |err| {
            // Log to audit (stub: in production, this writes to a signed log).
            if (self.config.audit_prompts or self.config.audit_responses) {
                std.log.warn("LlmDriver.dispatch({s}) failed: {s}", .{
                    @tagName(request.role),
                    @errorName(err),
                });
            }
            if (mandatory) return err;
            if (self.config.fallback_on_failure) return self.fallbackFor(request);
            return err;
        };

        return result;
    }

    /// Provider hook. This is a STUB in v0.4 — Week 2 will wire the real
    /// providers (Anthropic, OpenAI, DeepSeek) behind this signature.
    /// The contract is: receive a typed request, return a typed response
    /// (or an error). NO free-form strings cross this boundary.
    fn callProvider(self: *LlmDriver, request: Request) anyerror!Response {
        _ = self;
        _ = request;
        return error.LlmProviderNotWired;
    }

    // Driver-level error set.
    pub const Error = error{
        RolePayloadMismatch,
        LlmProviderNotConfigured,
        LlmProviderNotWired,
        LlmBusy,
        LlmTimeout,
        LlmMalformedResponse,
    };

    /// Fallback path. For each role, define what we return when the LLM
    /// is unavailable and the role is OPTIONAL. MANDATORY roles never
    /// reach this path.
    fn fallbackFor(self: *LlmDriver, request: Request) Response {
        _ = self;
        // For now, return a "no-op" fallback for each role. These are
        // conservative defaults that prevent the digital life from
        // silently producing wrong content.
        return switch (request.role) {
            ._role_count => unreachable, // sentinel, never reached
            .parse_user_message => .{ .role = .parse_user_message, .used_llm = false, .result = .{
                .parse_user_message = .{
                    .intent = "unknown",
                    .confidence = 0.0,
                    .entities = "{}",
                },
            } },
            .parse_product_event => .{ .role = .parse_product_event, .used_llm = false, .result = .{
                .parse_product_event = .{
                    .event_kind = "untyped",
                    .severity = 0.0,
                    .attributable = false,
                },
            } },
            .classify_consent_tier => .{ .role = .classify_consent_tier, .used_llm = false, .result = .{
                .classify_consent_tier = .{
                    .tier = "major", // conservative default
                    .rationale = "LLM unavailable; defaulting to major tier for safety.",
                    .risk_indicators = "[\"llm_unavailable\"]",
                },
            } },
            .detect_anomaly_cause => .{ .role = .detect_anomaly_cause, .used_llm = false, .result = .{
                .detect_anomaly_cause = .{
                    .hypotheses_json = "[]",
                    .recommended_action = "manual_investigation",
                },
            } },
            .write_user_message => .{ .role = .write_user_message, .used_llm = false, .result = .{
                .write_user_message = .{
                    .text = "[digital life is currently without LLM; no response available]",
                    .followup_question = null,
                    .action_proposal_json = null,
                },
            } },
            .write_evolution_rationale => .{ .role = .write_evolution_rationale, .used_llm = false, .result = .{
                .write_evolution_rationale = .{
                    .rationale = "[rationale unavailable: LLM offline]",
                    .alternative_explored = null,
                    .confidence_caveat = "n/a",
                },
            } },
            .write_l5_change_summary => .{ .role = .write_l5_change_summary, .used_llm = false, .result = .{
                .write_l5_change_summary = .{
                    .summary = "[summary unavailable: LLM offline]",
                    .affected_features = "[]",
                    .predicted_user_impact = "unknown",
                },
            } },
            .write_milestone_narrative => .{ .role = .write_milestone_narrative, .used_llm = false, .result = .{
                .write_milestone_narrative = .{
                    .narrative = "[milestone reached; narrative generation offline]",
                    .gratitude_to = "[]",
                    .next_aspiration = null,
                },
            } },
            .decide_followup_priority => .{ .role = .decide_followup_priority, .used_llm = false, .result = .{
                .decide_followup_priority = .{
                    .ranked_json = "[]",
                    .top_action = null,
                },
            } },
            .decide_experiment_arm => .{ .role = .decide_experiment_arm, .used_llm = false, .result = .{
                .decide_experiment_arm = .{
                    .arm = "control",
                    .rationale = "LLM offline; defaulting to control arm.",
                },
            } },
            .decide_sacrosanct_exception => .{ .role = .decide_sacrosanct_exception, .used_llm = false, .result = .{
                .decide_sacrosanct_exception = .{
                    .allowed = false,
                    .reason = sacrosanct_refusal_reason,
                },
            } },
        };
    }
};

/// The hardcoded refusal for the forbidden sacrosanct-exception role.
/// This string is part of the GHW contract: it is the *only* response
/// that role can ever produce, regardless of LLM availability.
const sacrosanct_refusal_reason: []const u8 =
    "sacrosanct is a product axiom; the LLM cannot grant exceptions. " ++
    "If you need this exception, file a product_intent.json update with ops approval.";

// ============================================================================
// Unit tests
// ============================================================================

test "isMandatory: returns true for the 5 mandatory roles" {
    try std.testing.expect(isMandatory(.parse_user_message));
    try std.testing.expect(isMandatory(.write_user_message));
    try std.testing.expect(isMandatory(.write_evolution_rationale));
    try std.testing.expect(isMandatory(.write_l5_change_summary));
    try std.testing.expect(isMandatory(.write_milestone_narrative));
}

test "isMandatory: returns false for optional roles" {
    try std.testing.expect(!isMandatory(.parse_product_event));
    try std.testing.expect(!isMandatory(.classify_consent_tier));
    try std.testing.expect(!isMandatory(.detect_anomaly_cause));
    try std.testing.expect(!isMandatory(.decide_followup_priority));
    try std.testing.expect(!isMandatory(.decide_experiment_arm));
}

test "FORBIDDEN_LLM_ROLES contains decide_sacrosanct_exception" {
    var found = false;
    inline for (FORBIDDEN_LLM_ROLES) |r| {
        if (r == .decide_sacrosanct_exception) found = true;
    }
    try std.testing.expect(found);
}

test "dispatch: forbidden role never consults the LLM" {
    var driver = LlmDriver.init(std.testing.allocator, .{
        .provider = .mock,
    });
    const req = Request{
        .role = .decide_sacrosanct_exception,
        .audit_tag = "test:1",
        .payload = .{ .decide_sacrosanct_exception = .{
            .proposed_exception = "send_after_hours",
            .justification = "customer about to churn",
        } },
    };
    const resp = try driver.dispatch(req);
    try std.testing.expectEqual(false, resp.used_llm);
    try std.testing.expectEqual(false, resp.result.decide_sacrosanct_exception.allowed);
    try std.testing.expect(std.mem.indexOf(u8, resp.result.decide_sacrosanct_exception.reason, "sacrosanct is a product axiom") != null);
}

test "dispatch: mandatory role + provider=none + fallback_on_failure=true returns error" {
    var driver = LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = true,
    });
    const req = Request{
        .role = .write_user_message,
        .audit_tag = "test:2",
        .payload = .{ .write_user_message = .{
            .trigger = "e_saturated",
            .context_json = "{}",
            .tone_hint = .ops_casual_status,
            .max_length = 200,
        } },
    };
    // Mandatory role + no LLM must hard-fail, not silently fall back.
    try std.testing.expectError(error.LlmProviderNotConfigured, driver.dispatch(req));
}

test "dispatch: optional role + provider=none + fallback_on_failure=true returns fallback" {
    var driver = LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = true,
    });
    const req = Request{
        .role = .decide_experiment_arm,
        .audit_tag = "test:3",
        .payload = .{ .decide_experiment_arm = .{
            .entity_id = "u123",
            .current_arm_balance_json = "{\"control_count\":10,\"treatment_count\":12}",
        } },
    };
    const resp = try driver.dispatch(req);
    try std.testing.expectEqual(false, resp.used_llm);
    try std.testing.expectEqualStrings("control", resp.result.decide_experiment_arm.arm);
}

test "dispatch: optional role + provider=none + fallback_on_failure=false returns error" {
    var driver = LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = false,
    });
    const req = Request{
        .role = .decide_experiment_arm,
        .audit_tag = "test:4",
        .payload = .{ .decide_experiment_arm = .{
            .entity_id = "u123",
            .current_arm_balance_json = "{}",
        } },
    };
    // Optional + no fallback → hard fail.
    try std.testing.expectError(error.LlmProviderNotConfigured, driver.dispatch(req));
}

test "role count matches enum" {
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(SemanticRole._role_count));
    // 4 understanding + 4 expression + 2 judgement + 1 forbidden = 11
}
