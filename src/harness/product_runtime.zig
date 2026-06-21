//! ProductRuntime — 软件产品进化的数字生命运行时底座。
//!
//! 这个模块把 CRM demo 里的 Python orchestrator 迁回 Zig 主线:
//! ProductIntent → KPI bridge → ChangeProposal → Consent → Audit → apply/rollback。
//! 它不负责真实修改产品代码, 而是提供一条强制审计和审批的产品进化主流程。

const std = @import("std");
const product_intent = @import("product_intent.zig");
const consent = @import("consent.zig");
const crm_kpi = @import("crm_kpi.zig");
const kpi_bridge = @import("kpi_bridge.zig");
const world = @import("../world/core.zig");

const Allocator = std.mem.Allocator;
const ProductIntent = product_intent.ProductIntent;
const KpiBridge = kpi_bridge.KpiBridge;
const RawKpi = crm_kpi.RawKpi;
const ExistenceDegree = world.ExistenceDegree;

pub const ProductRuntimeError = error{
    ChangeNotFound,
    ConsentRequired,
    AlreadyTerminal,
    NotApproved,
    AlreadyApplied,
    NotApplied,
    OutOfMemory,
};

pub const ProductChangeKind = enum {
    config,
    workflow,
    feature_flag,
    code_patch,
    experiment,
};

pub const ChangeStatus = enum {
    proposed,
    pending_consent,
    approved,
    denied,
    applied,
    rolled_back,
};

pub const AuditKind = enum {
    kpi_refreshed,
    change_proposed,
    consent_decision,
    change_applied,
    change_rolled_back,
};

pub const ChangeProposal = struct {
    id: u64,
    tenant_id: []const u8,
    kind: ProductChangeKind,
    target: []const u8,
    summary: []const u8,
    rationale: []const u8,
    expected_delta_k: f32,
    affected_users: u32,
    reversible: bool,
    tier: consent.ConsentTier,
    risk: consent.RiskSignals,
    timeout_seconds: u64,
    required_approvers: []const u8,
    status: ChangeStatus,
    created_at: u64,
    decided_at: ?u64 = null,
    decided_by: ?[]const u8 = null,
    decision_note: ?[]const u8 = null,

    fn deinit(self: *ChangeProposal, alloc: Allocator) void {
        alloc.free(self.tenant_id);
        alloc.free(self.target);
        alloc.free(self.summary);
        alloc.free(self.rationale);
        if (self.decided_by) |v| alloc.free(v);
        if (self.decision_note) |v| alloc.free(v);
    }
};

pub const AuditEntry = struct {
    id: u64,
    at_unix: u64,
    kind: AuditKind,
    change_id: ?u64 = null,
    tenant_id: []const u8,
    detail: []const u8,

    fn deinit(self: *AuditEntry, alloc: Allocator) void {
        alloc.free(self.tenant_id);
        alloc.free(self.detail);
    }
};

pub const ProductEvolutionRuntime = struct {
    alloc: Allocator,
    product: *const ProductIntent,
    bridge: KpiBridge,
    next_change_id: u64 = 1,
    next_audit_id: u64 = 1,
    changes: std.ArrayList(ChangeProposal) = .empty,
    audit: std.ArrayList(AuditEntry) = .empty,

    pub fn init(alloc: Allocator, product: *const ProductIntent) ProductEvolutionRuntime {
        return .{
            .alloc = alloc,
            .product = product,
            .bridge = KpiBridge.initFromIntent(product),
        };
    }

    pub fn deinit(self: *ProductEvolutionRuntime) void {
        for (self.changes.items) |*c| c.deinit(self.alloc);
        self.changes.deinit(self.alloc);
        for (self.audit.items) |*a| a.deinit(self.alloc);
        self.audit.deinit(self.alloc);
    }

    /// 产品后端可高频 feed KPI; runtime 按 ProductIntent.rhythm 限频写入 E。
    pub fn feedKpi(self: *ProductEvolutionRuntime, ed: *ExistenceDegree, raw: RawKpi, now_unix: i64) !bool {
        self.bridge.feed(raw);
        const refreshed = self.bridge.maybeRefresh(ed, now_unix);
        if (refreshed) {
            const detail = try std.fmt.allocPrint(self.alloc, "K={d:.4} wrote_into_E=true", .{self.bridge.currentComposite() orelse 0});
            defer self.alloc.free(detail);
            try self.appendAudit(.kpi_refreshed, null, "system", detail, @intCast(@max(now_unix, 0)));
        }
        return refreshed;
    }

    /// CRM canonical change: tighten follow-up cadence 7d → 5d.
    /// 作为产品进化底座的样板提案, 真实产品可用 proposeChange 提交任意 ChangeProposal。
    pub fn proposeCrmFollowupTightening(
        self: *ProductEvolutionRuntime,
        tenant_id: []const u8,
        affected_users: u32,
        expected_delta_k: f32,
        now_unix: u64,
    ) !u64 {
        return self.proposeChange(.{
            .tenant_id = tenant_id,
            .kind = .workflow,
            .target = "crm.followup_cadence_days",
            .summary = "Tighten follow-up cadence from 7d to 5d",
            .rationale = "CRM demo canonical improvement: faster follow-up should improve win rate and NRR.",
            .expected_delta_k = expected_delta_k,
            .affected_users = affected_users,
            .reversible = true,
            .lines_changed = 12,
            .l5_module = "sales_followup.zig",
            .now_unix = now_unix,
        });
    }

    pub const ProposeInput = struct {
        tenant_id: []const u8,
        kind: ProductChangeKind,
        target: []const u8,
        summary: []const u8,
        rationale: []const u8,
        expected_delta_k: f32,
        affected_users: u32,
        reversible: bool,
        lines_changed: u32 = 0,
        l5_module: []const u8 = "",
        now_unix: u64,
    };

    pub fn proposeChange(self: *ProductEvolutionRuntime, input: ProposeInput) !u64 {
        const files_modified = [_][]const u8{input.target};
        const affected_features = [_][]const u8{input.target};
        const change_spec = consent.ChangeSpec{
            .l5_module = input.l5_module,
            .files_added = &.{},
            .files_modified = &files_modified,
            .lines_changed = input.lines_changed,
            .affected_features = &affected_features,
            .affected_users = input.affected_users,
            .reversible = input.reversible,
        };
        const risk = consent.riskForChange(change_spec);
        const req = consent.newRequest(
            self.next_change_id,
            change_spec,
            risk,
            input.rationale,
            input.expected_delta_k,
            input.now_unix,
            self.product,
        );
        const required = consent.requiredApprovers(req.tier, self.product);
        const status: ChangeStatus = if (req.tier == .minor) .approved else .pending_consent;

        const tenant_owned = try self.alloc.dupe(u8, input.tenant_id);
        errdefer self.alloc.free(tenant_owned);
        const target_owned = try self.alloc.dupe(u8, input.target);
        errdefer self.alloc.free(target_owned);
        const summary_owned = try self.alloc.dupe(u8, input.summary);
        errdefer self.alloc.free(summary_owned);
        const rationale_owned = try self.alloc.dupe(u8, input.rationale);
        errdefer self.alloc.free(rationale_owned);

        const proposal = ChangeProposal{
            .id = self.next_change_id,
            .tenant_id = tenant_owned,
            .kind = input.kind,
            .target = target_owned,
            .summary = summary_owned,
            .rationale = rationale_owned,
            .expected_delta_k = input.expected_delta_k,
            .affected_users = input.affected_users,
            .reversible = input.reversible,
            .tier = req.tier,
            .risk = risk,
            .timeout_seconds = req.timeout_seconds,
            .required_approvers = required,
            .status = status,
            .created_at = input.now_unix,
        };
        errdefer {
            var p = proposal;
            p.deinit(self.alloc);
        }

        try self.changes.append(self.alloc, proposal);
        const id = self.next_change_id;
        self.next_change_id += 1;

        const detail = try std.fmt.allocPrint(self.alloc, "tier={s} risk={d:.3} target={s}", .{
            req.tier.label(), risk.combinedRisk(), input.target,
        });
        defer self.alloc.free(detail);
        try self.appendAudit(.change_proposed, id, input.tenant_id, detail, input.now_unix);
        return id;
    }

    pub fn approve(self: *ProductEvolutionRuntime, change_id: u64, approver: []const u8, note: []const u8, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status == .applied or p.status == .rolled_back) return error.AlreadyTerminal;
        p.status = .approved;
        p.decided_at = now_unix;
        if (p.decided_by) |v| self.alloc.free(v);
        if (p.decision_note) |v| self.alloc.free(v);
        p.decided_by = try self.alloc.dupe(u8, approver);
        p.decision_note = try self.alloc.dupe(u8, note);
        try self.appendAudit(.consent_decision, change_id, p.tenant_id, "approved", now_unix);
    }

    pub fn deny(self: *ProductEvolutionRuntime, change_id: u64, approver: []const u8, note: []const u8, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status == .applied or p.status == .rolled_back) return error.AlreadyTerminal;
        p.status = .denied;
        p.decided_at = now_unix;
        if (p.decided_by) |v| self.alloc.free(v);
        if (p.decision_note) |v| self.alloc.free(v);
        p.decided_by = try self.alloc.dupe(u8, approver);
        p.decision_note = try self.alloc.dupe(u8, note);
        try self.appendAudit(.consent_decision, change_id, p.tenant_id, "denied", now_unix);
    }

    pub fn applyApproved(self: *ProductEvolutionRuntime, change_id: u64, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status == .applied) return error.AlreadyApplied;
        if (p.status != .approved) return error.NotApproved;
        p.status = .applied;
        try self.appendAudit(.change_applied, change_id, p.tenant_id, p.summary, now_unix);
    }

    pub fn rollbackApplied(self: *ProductEvolutionRuntime, change_id: u64, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status != .applied) return error.NotApplied;
        if (!p.reversible) return error.ConsentRequired;
        p.status = .rolled_back;
        try self.appendAudit(.change_rolled_back, change_id, p.tenant_id, p.summary, now_unix);
    }

    pub fn auditJson(self: *const ProductEvolutionRuntime, alloc: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"audit\":[");
        for (self.audit.items, 0..) |entry, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"id\":{d},\"at\":{d},\"kind\":\"{s}\",\"change_id\":", .{
                entry.id, entry.at_unix, @tagName(entry.kind),
            });
            if (entry.change_id) |cid| {
                try out.print(alloc, "{d}", .{cid});
            } else {
                try out.appendSlice(alloc, "null");
            }
            try out.appendSlice(alloc, ",\"tenant_id\":\"");
            try writeJsonString(alloc, &out, entry.tenant_id);
            try out.appendSlice(alloc, "\",\"detail\":\"");
            try writeJsonString(alloc, &out, entry.detail);
            try out.appendSlice(alloc, "\"}");
        }
        try out.appendSlice(alloc, "]}");
        return out.toOwnedSlice(alloc);
    }

    pub fn findChange(self: *ProductEvolutionRuntime, change_id: u64) ?*ChangeProposal {
        for (self.changes.items) |*p| {
            if (p.id == change_id) return p;
        }
        return null;
    }

    fn appendAudit(
        self: *ProductEvolutionRuntime,
        kind: AuditKind,
        change_id: ?u64,
        tenant_id: []const u8,
        detail: []const u8,
        at_unix: u64,
    ) !void {
        try self.audit.append(self.alloc, .{
            .id = self.next_audit_id,
            .at_unix = at_unix,
            .kind = kind,
            .change_id = change_id,
            .tenant_id = try self.alloc.dupe(u8, tenant_id),
            .detail = try self.alloc.dupe(u8, detail),
        });
        self.next_audit_id += 1;
    }
};

fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) try buf.print(alloc, "\\u{x:0>4}", .{c}) else try buf.append(alloc, c),
        }
    }
}

const testing = std.testing;

const crm_intent_json =
    \\{
    \\  "schema_version": 1,
    \\  "product_id": "ghw-crm-test",
    \\  "product_type": "saas_web",
    \\  "version": "0.1.0",
    \\  "update_epoch": 1,
    \\  "last_updated": 1749860000,
    \\  "approved_by": "test",
    \\  "manifesto": "test",
    \\  "sacrosanct": ["never leak tenant data"],
    \\  "north_star_kpi": "deal_win_rate",
    \\  "secondary_kpis": ["nrr_quarterly"],
    \\  "kpi_aggregator": "median",
    \\  "kpi_evaluation_window": "weekly",
    \\  "value_weights": {"user_satisfaction": 0.25, "retention": 0.30, "revenue": 0.35, "safety": 0.10},
    \\  "consent_defaults": {
    \\    "minor_tier_timeout_hours": 24,
    \\    "standard_tier_timeout_hours": 72,
    \\    "major_tier_timeout_hours": 168,
    \\    "critical_tier_requires_double_approval": true,
    \\    "auto_approve_within_window": false
    \\  },
    \\  "experiment_defaults": {
    \\    "min_sample_size": 30,
    \\    "min_duration_days": 14,
    \\    "max_concurrent_experiments_per_tenant": 2,
    \\    "cohort_split_by": "tenant_user_id"
    \\  },
    \\  "channel_routing": {
    \\    "e_saturated": ["admin_dashboard"],
    \\    "user_quiet_24h": ["email_digest"],
    \\    "l5_about_to_apply": ["admin_dashboard"],
    \\    "anomaly": ["slack_urgent"],
    \\    "experiment_done": ["email"]
    \\  },
    \\  "rhythm": {
    \\    "cycle_interval_seconds": 300,
    \\    "kpi_refresh_interval_hours": 24,
    \\    "experiment_default_duration_days": 14,
    \\    "consent_batch_window_days": 7
    \\  },
    \\  "audit_log": {
    \\    "enabled": true,
    \\    "retention_days": 365,
    \\    "include_llm_prompts": true,
    \\    "include_llm_responses": true
    \\  }
    \\}
;

test "ProductEvolutionRuntime: CRM proposal → consent → apply → rollback audit" {
    const alloc = testing.allocator;
    var intent = try product_intent.parse(alloc, crm_intent_json);
    defer intent.deinit();
    var rt = ProductEvolutionRuntime.init(alloc, &intent);
    defer rt.deinit();

    const id = try rt.proposeCrmFollowupTightening("acme", 30, 0.05, 1000);
    const p = rt.findChange(id).?;
    try testing.expectEqual(consent.ConsentTier.standard, p.tier);
    try testing.expectEqual(ChangeStatus.pending_consent, p.status);
    try testing.expectEqual(@as(usize, 1), rt.audit.items.len);

    try rt.approve(id, "sales_manager", "safe to try", 1100);
    try testing.expectEqual(ChangeStatus.approved, rt.findChange(id).?.status);
    try rt.applyApproved(id, 1200);
    try testing.expectEqual(ChangeStatus.applied, rt.findChange(id).?.status);
    try rt.rollbackApplied(id, 1300);
    try testing.expectEqual(ChangeStatus.rolled_back, rt.findChange(id).?.status);
    try testing.expectEqual(@as(usize, 4), rt.audit.items.len);
}

test "ProductEvolutionRuntime: KPI feed enters E through bridge and audit" {
    const alloc = testing.allocator;
    var intent = try product_intent.parse(alloc, crm_intent_json);
    defer intent.deinit();
    var rt = ProductEvolutionRuntime.init(alloc, &intent);
    defer rt.deinit();
    var ed: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };

    const refreshed = try rt.feedKpi(&ed, .{
        .nrr_quarterly = 0.85,
        .deal_win_rate = 0.10,
        .sales_cycle_days_p50 = 90,
        .weekly_active_sales_pct = 0.40,
    }, 10);
    try testing.expect(refreshed);
    try testing.expect(ed.kpi_enabled);
    try testing.expectEqual(@as(usize, 1), rt.audit.items.len);
}

test "ProductEvolutionRuntime: auditJson includes proposal and decision" {
    const alloc = testing.allocator;
    var intent = try product_intent.parse(alloc, crm_intent_json);
    defer intent.deinit();
    var rt = ProductEvolutionRuntime.init(alloc, &intent);
    defer rt.deinit();

    const id = try rt.proposeCrmFollowupTightening("bravo", 12, 0.03, 100);
    try rt.approve(id, "sales_manager", "ok", 200);
    const json = try rt.auditJson(alloc);
    defer alloc.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"change_proposed\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tenant_id\":\"bravo\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"consent_decision\"") != null);
}
