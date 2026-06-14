//! MockLlmProvider — a deterministic LLM replacement for tests and
//! the "no-LLM" embed mode.
//!
//! Status: Week 3 of Phase 1 (GHW-as-CRM). Wires into LlmDriver's
//! `callProvider` slot to produce real (template-based) responses
//! for the 11 semantic roles.
//!
//! # What this module does
//!
//! Provides `MockProvider` that, when configured as the
//! `LlmDriver.provider`, produces real responses for any of the
//! 11 roles. The responses are NOT LLM-generated; they are
//! deterministic template strings parameterized by the request
//! context. This lets:
//!
//! 1. Tests exercise the full LlmDriver path (semantic layer +
//!    math/protocol layer integration) without any network.
//! 2. Embedded use cases (no LLM dependency) get a working
//!    digital life, just one with lower-quality prose.
//!
//! # What this module does NOT do
//!
//! - It does NOT make any network calls.
//! - It does NOT cover the LLM's role in *judgement* (e.g.
//!   `classify_consent_tier`). For optional roles we return
//!   conservative defaults; for MANDATORY roles we return
//!   template prose.
//! - It does NOT implement real provider wiring (Anthropic,
//!   OpenAI, DeepSeek). Those are Week 4 deliverables.

const std = @import("std");
const llm_driver = @import("llm_driver.zig");

// ============================================================================
// Provider function
// ============================================================================

/// Provider function shape: takes a typed Request, returns a
/// typed Response. The LlmDriver calls this when provider == .mock.
pub fn call(
    allocator: std.mem.Allocator,
    request: llm_driver.Request,
) anyerror!llm_driver.Response {
    return switch (request.role) {
        // Group A — Understanding
        .parse_user_message => mockParseUserMessage(allocator, request.payload.parse_user_message),
        .parse_product_event => mockParseProductEvent(allocator, request.payload.parse_product_event),
        .classify_consent_tier => mockClassifyConsentTier(allocator, request.payload.classify_consent_tier),
        .detect_anomaly_cause => mockDetectAnomalyCause(allocator, request.payload.detect_anomaly_cause),

        // Group B — Expression
        .write_user_message => mockWriteUserMessage(allocator, request.payload.write_user_message),
        .write_evolution_rationale => mockWriteEvolutionRationale(allocator, request.payload.write_evolution_rationale),
        .write_l5_change_summary => mockWriteL5ChangeSummary(allocator, request.payload.write_l5_change_summary),
        .write_milestone_narrative => mockWriteMilestoneNarrative(allocator, request.payload.write_milestone_narrative),

        // Group C — Judgement
        .decide_followup_priority => mockDecideFollowupPriority(allocator, request.payload.decide_followup_priority),
        .decide_experiment_arm => mockDecideExperimentArm(allocator, request.payload.decide_experiment_arm),

        // Group D — Refusal (handled by LlmDriver itself, not here)
        .decide_sacrosanct_exception => unreachable, // LlmDriver handles FORBIDDEN
        ._role_count => unreachable,
    };
}

// ============================================================================
// Per-role mock implementations
// ============================================================================

fn mockParseUserMessage(allocator: std.mem.Allocator, req: llm_driver.ParseUserMessageRequest) anyerror!llm_driver.Response {
    // Naive keyword classifier. Real LLM would do better.
    const intent = if (std.mem.indexOf(u8, req.text, "?") != null)
        "question"
    else if (std.mem.indexOf(u8, req.text, "schedule") != null or std.mem.indexOf(u8, req.text, "follow up") != null)
        "schedule_followup"
    else if (std.mem.indexOf(u8, req.text, "score") != null or std.mem.indexOf(u8, req.text, "rate") != null)
        "score"
    else
        "unknown";

    const resp_text = try std.fmt.allocPrint(
        allocator,
        \\{{"intent":"{s}","confidence":0.5,"entities":{{}}}}
    ,
        .{intent}
    );
    return .{
        .role = .parse_user_message,
        .used_llm = true, // mock counts as LLM
        .result = .{ .parse_user_message = .{
            .intent = intent,
            .confidence = 0.5,
            .entities = resp_text,
        } },
    };
}

fn mockParseProductEvent(allocator: std.mem.Allocator, req: llm_driver.ParseProductEventRequest) anyerror!llm_driver.Response {
    _ = req;
    _ = allocator;
    return .{
        .role = .parse_product_event,
        .used_llm = true,
        .result = .{ .parse_product_event = .{
            .event_kind = "untyped",
            .severity = 0.0,
            .attributable = false,
        } },
    };
}

fn mockClassifyConsentTier(allocator: std.mem.Allocator, req: llm_driver.ClassifyConsentTierRequest) anyerror!llm_driver.Response {
    _ = req;
    // Conservative default: major tier for any L5-class change.
    const rationale = try allocator.dupe(u8, "[mock] defaulting to major tier for safety");
    return .{
        .role = .classify_consent_tier,
        .used_llm = true,
        .result = .{ .classify_consent_tier = .{
            .tier = "major",
            .rationale = rationale,
            .risk_indicators = "[\"mock_default\"]",
        } },
    };
}

fn mockDetectAnomalyCause(allocator: std.mem.Allocator, req: llm_driver.DetectAnomalyCauseRequest) anyerror!llm_driver.Response {
    _ = req;
    const hypotheses = try std.fmt.allocPrint(
        allocator,
        \\{{"hypotheses":[],"recommended_action":"manual_investigation"}}
    ,
        .{}
    );
    return .{
        .role = .detect_anomaly_cause,
        .used_llm = true,
        .result = .{ .detect_anomaly_cause = .{
            .hypotheses_json = hypotheses,
            .recommended_action = "manual_investigation",
        } },
    };
}

fn mockWriteUserMessage(allocator: std.mem.Allocator, req: llm_driver.WriteUserMessageRequest) anyerror!llm_driver.Response {
    // Template: extract the "e" and "kpi_composite" fields from the
    // context_json if present. The real LLM would do better; this is
    // a best-effort baseline.
    const e_str = extractField(req.context_json, "e") orelse "stable";
    const kpi_str = extractField(req.context_json, "kpi_composite") orelse "steady";

    var text_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text_buf);
    try w.print(
        \\[mock:{s}] E is {s}, KPI composite is {s}. I am alive and paying attention.
    , .{ req.trigger, e_str, kpi_str });
    const text = w.buffered();
    const text_dup = try allocator.dupe(u8, text);

    return .{
        .role = .write_user_message,
        .used_llm = true,
        .result = .{ .write_user_message = .{
            .text = text_dup,
            .followup_question = null,
            .action_proposal_json = null,
        } },
    };
}

fn mockWriteEvolutionRationale(allocator: std.mem.Allocator, req: llm_driver.WriteEvolutionRationaleRequest) anyerror!llm_driver.Response {
    const rationale = try std.fmt.allocPrint(
        allocator,
        \\[mock] Proposing {s}. Predicted ΔE: {d}. This rationale is generated by MockProvider, not a real LLM.
    ,
        .{ req.change_summary, req.predicted_e_delta }
    );
    return .{
        .role = .write_evolution_rationale,
        .used_llm = true,
        .result = .{ .write_evolution_rationale = .{
            .rationale = rationale,
            .alternative_explored = null,
            .confidence_caveat = "mock provider, real LLM would provide stronger reasoning",
        } },
    };
}

fn mockWriteL5ChangeSummary(allocator: std.mem.Allocator, req: llm_driver.WriteL5ChangeSummaryRequest) anyerror!llm_driver.Response {
    const summary = try std.fmt.allocPrint(
        allocator,
        \\[mock] L5 module {s} is proposing to change {d} files. Real LLM would summarize the business impact.
    ,
        .{ req.l5_module_name, req.files_modified.len + req.files_added.len }
    );
    return .{
        .role = .write_l5_change_summary,
        .used_llm = true,
        .result = .{ .write_l5_change_summary = .{
            .summary = summary,
            .affected_features = "[]",
            .predicted_user_impact = "[mock] unknown",
        } },
    };
}

fn mockWriteMilestoneNarrative(allocator: std.mem.Allocator, req: llm_driver.WriteMilestoneNarrativeRequest) anyerror!llm_driver.Response {
    const narrative = try std.fmt.allocPrint(
        allocator,
        \\[mock] I have reached {s} at tick {d}. This is a mock narrative; a real LLM would write a more reflective account.
    ,
        .{ req.milestone_type, req.tick }
    );
    return .{
        .role = .write_milestone_narrative,
        .used_llm = true,
        .result = .{ .write_milestone_narrative = .{
            .narrative = narrative,
            .gratitude_to = "[]",
            .next_aspiration = null,
        } },
    };
}

fn mockDecideFollowupPriority(allocator: std.mem.Allocator, req: llm_driver.DecideFollowupPriorityRequest) anyerror!llm_driver.Response {
    _ = req;
    const ranked = try allocator.dupe(u8, "[]");
    return .{
        .role = .decide_followup_priority,
        .used_llm = true,
        .result = .{ .decide_followup_priority = .{
            .ranked_json = ranked,
            .top_action = null,
        } },
    };
}

fn mockDecideExperimentArm(allocator: std.mem.Allocator, req: llm_driver.DecideExperimentArmRequest) anyerror!llm_driver.Response {
    const arm = if (std.mem.indexOf(u8, req.entity_id, "0") != null) "control" else "treatment";
    const rationale = try std.fmt.allocPrint(
        allocator,
        \\[mock] entity_id hash-based assignment to {s} arm
    ,
        .{arm}
    );
    return .{
        .role = .decide_experiment_arm,
        .used_llm = true,
        .result = .{ .decide_experiment_arm = .{
            .arm = arm,
            .rationale = rationale,
        } },
    };
}

// ============================================================================
// JSON field extraction (tiny helper)
// ============================================================================

/// Naive extraction of a JSON string/number field value.
/// Returns the value text or null if not found. The mock provider
/// uses this to pluck a few values from the context_json without
/// implementing a full JSON parser.
fn extractField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = idx + needle.len;
    // skip whitespace
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    // find value end
    var end = pos;
    if (pos < json.len and json[pos] == '"') {
        // string value: find next unescaped "
        end = pos + 1;
        while (end < json.len and json[end] != '"') end += 1;
        return json[pos + 1 .. end];
    } else {
        // number/bool value
        while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ' ' and json[end] != '\n') end += 1;
        return json[pos..end];
    }
}

// ============================================================================
// Unit tests
// ============================================================================

test "extractField: extracts number" {
    const v = extractField("{\"e\":0.85,\"kpi_composite\":0.7}", "e").?;
    try std.testing.expectEqualStrings("0.85", v);
}

test "extractField: extracts string" {
    const v = extractField("{\"name\":\"acme\",\"id\":42}", "name").?;
    try std.testing.expectEqualStrings("acme", v);
}

test "extractField: returns null for missing key" {
    try std.testing.expect(extractField("{\"a\":1}", "z") == null);
}

test "mock: parse_user_message with question mark → intent=question" {
    const gpa = std.testing.allocator;
    defer _ = .{ };
    const resp = try call(gpa, .{
        .role = .parse_user_message,
        .audit_tag = "test",
        .payload = .{ .parse_user_message = .{
            .user_id = "u1",
            .text = "How is Q4 looking?",
            .recent_context = "[]",
        } },
    });
    try std.testing.expectEqualStrings("question", resp.result.parse_user_message.intent);
    // Free the entities string we allocated
    gpa.free(resp.result.parse_user_message.entities);
}

test "mock: write_user_message includes trigger and E" {
    const gpa = std.testing.allocator;
    defer _ = .{ };
    const resp = try call(gpa, .{
        .role = .write_user_message,
        .audit_tag = "test",
        .payload = .{ .write_user_message = .{
            .trigger = "e_saturated",
            .context_json = "{\"e\":0.85,\"kpi_composite\":0.7}",
            .tone_hint = .ops_casual_status,
            .max_length = 200,
        } },
    });
    try std.testing.expect(std.mem.indexOf(u8, resp.result.write_user_message.text, "0.85") != null);
    gpa.free(resp.result.write_user_message.text);
}

test "mock: write_evolution_rationale mentions change summary" {
    const gpa = std.testing.allocator;
    defer _ = .{ };
    const resp = try call(gpa, .{
        .role = .write_evolution_rationale,
        .audit_tag = "test",
        .payload = .{ .write_evolution_rationale = .{
            .change_summary = "increase mu to 0.34",
            .current_e = 0.85,
            .predicted_e_delta = 0.02,
            .kpi_trend_json = "{}",
        } },
    });
    try std.testing.expect(std.mem.indexOf(u8, resp.result.write_evolution_rationale.rationale, "increase mu") != null);
    gpa.free(resp.result.write_evolution_rationale.rationale);
}

test "mock: decide_experiment_arm is deterministic by entity_id" {
    const gpa = std.testing.allocator;
    defer _ = .{ };
    const resp_a = try call(gpa, .{
        .role = .decide_experiment_arm,
        .audit_tag = "test",
        .payload = .{ .decide_experiment_arm = .{
            .entity_id = "u_0",
            .current_arm_balance_json = "{}",
        } },
    });
    const resp_b = try call(gpa, .{
        .role = .decide_experiment_arm,
        .audit_tag = "test",
        .payload = .{ .decide_experiment_arm = .{
            .entity_id = "u_1",
            .current_arm_balance_json = "{}",
        } },
    });
    // u_0 has "0" → control; u_1 doesn't → treatment
    try std.testing.expectEqualStrings("control", resp_a.result.decide_experiment_arm.arm);
    try std.testing.expectEqualStrings("treatment", resp_b.result.decide_experiment_arm.arm);
    gpa.free(resp_a.result.decide_experiment_arm.rationale);
    gpa.free(resp_b.result.decide_experiment_arm.rationale);
}
