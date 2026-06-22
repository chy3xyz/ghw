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
const state_json = @import("human_symbiosis/state_json.zig");
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
    AuditHashMismatch,
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
    change_apply_failed,
    change_rollback_failed,
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
    previous_hash: []const u8,
    current_hash: []const u8,

    fn deinit(self: *AuditEntry, alloc: Allocator) void {
        alloc.free(self.tenant_id);
        alloc.free(self.detail);
        alloc.free(self.previous_hash);
        alloc.free(self.current_hash);
    }
};

pub const ProductAdapter = struct {
    ctx: *anyopaque,
    validateFn: *const fn (*anyopaque, *const ChangeProposal) anyerror!void,
    applyFn: *const fn (*anyopaque, *const ChangeProposal) anyerror!void,
    verifyFn: *const fn (*anyopaque, *const ChangeProposal) anyerror!void,
    rollbackFn: *const fn (*anyopaque, *const ChangeProposal) anyerror!void,

    pub fn validate(self: ProductAdapter, change: *const ChangeProposal) !void {
        try self.validateFn(self.ctx, change);
    }

    pub fn apply(self: ProductAdapter, change: *const ChangeProposal) !void {
        try self.applyFn(self.ctx, change);
    }

    pub fn verify(self: ProductAdapter, change: *const ChangeProposal) !void {
        try self.verifyFn(self.ctx, change);
    }

    pub fn rollback(self: ProductAdapter, change: *const ChangeProposal) !void {
        try self.rollbackFn(self.ctx, change);
    }
};

pub const ProductEvolutionRuntime = struct {
    alloc: Allocator,
    product: *const ProductIntent,
    bridge: KpiBridge,
    adapter: ?ProductAdapter = null,
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

    pub fn setAdapter(self: *ProductEvolutionRuntime, adapter: ProductAdapter) void {
        self.adapter = adapter;
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
        const approver_owned = try self.alloc.dupe(u8, approver);
        const note_owned = self.alloc.dupe(u8, note) catch |err| {
            self.alloc.free(approver_owned);
            return err;
        };
        errdefer self.alloc.free(approver_owned);
        errdefer self.alloc.free(note_owned);
        try self.appendAudit(.consent_decision, change_id, p.tenant_id, "approved", now_unix);
        p.status = .approved;
        p.decided_at = now_unix;
        if (p.decided_by) |v| self.alloc.free(v);
        if (p.decision_note) |v| self.alloc.free(v);
        p.decided_by = approver_owned;
        p.decision_note = note_owned;
    }

    pub fn deny(self: *ProductEvolutionRuntime, change_id: u64, approver: []const u8, note: []const u8, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status == .applied or p.status == .rolled_back) return error.AlreadyTerminal;
        const approver_owned = try self.alloc.dupe(u8, approver);
        const note_owned = self.alloc.dupe(u8, note) catch |err| {
            self.alloc.free(approver_owned);
            return err;
        };
        errdefer self.alloc.free(approver_owned);
        errdefer self.alloc.free(note_owned);
        try self.appendAudit(.consent_decision, change_id, p.tenant_id, "denied", now_unix);
        p.status = .denied;
        p.decided_at = now_unix;
        if (p.decided_by) |v| self.alloc.free(v);
        if (p.decision_note) |v| self.alloc.free(v);
        p.decided_by = approver_owned;
        p.decision_note = note_owned;
    }

    pub fn applyApproved(self: *ProductEvolutionRuntime, change_id: u64, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status == .applied) return error.AlreadyApplied;
        if (p.status != .approved) return error.NotApproved;
        if (self.adapter) |adapter| {
            adapter.validate(p) catch |err| {
                try self.appendAudit(.change_apply_failed, change_id, p.tenant_id, @errorName(err), now_unix);
                return err;
            };
            adapter.apply(p) catch |err| {
                try self.appendAudit(.change_apply_failed, change_id, p.tenant_id, @errorName(err), now_unix);
                return err;
            };
            adapter.verify(p) catch |err| {
                adapter.rollback(p) catch |rollback_err| {
                    try self.appendAudit(.change_rollback_failed, change_id, p.tenant_id, @errorName(rollback_err), now_unix);
                };
                try self.appendAudit(.change_apply_failed, change_id, p.tenant_id, @errorName(err), now_unix);
                return err;
            };
        }
        try self.appendAudit(.change_applied, change_id, p.tenant_id, p.summary, now_unix);
        p.status = .applied;
    }

    pub fn rollbackApplied(self: *ProductEvolutionRuntime, change_id: u64, now_unix: u64) !void {
        const p = self.findChange(change_id) orelse return error.ChangeNotFound;
        if (p.status != .applied) return error.NotApplied;
        if (!p.reversible) return error.ConsentRequired;
        if (self.adapter) |adapter| {
            adapter.rollback(p) catch |err| {
                try self.appendAudit(.change_rollback_failed, change_id, p.tenant_id, @errorName(err), now_unix);
                return err;
            };
        }
        try self.appendAudit(.change_rolled_back, change_id, p.tenant_id, p.summary, now_unix);
        p.status = .rolled_back;
    }

    pub fn auditJson(self: *const ProductEvolutionRuntime, alloc: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"audit\":");
        try self.appendAuditArrayJson(alloc, &out);
        try out.appendSlice(alloc, "}");
        return out.toOwnedSlice(alloc);
    }

    /// 完整 runtime 状态: changes + audit + next ids。
    /// ui_server/daemon 把它包进 state.json 的 `"product_runtime"` 字段。
    pub fn toJson(self: *const ProductEvolutionRuntime, alloc: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.print(alloc, "{{\"next_change_id\":{d},\"next_audit_id\":{d},\"changes\":[", .{
            self.next_change_id,
            self.next_audit_id,
        });
        for (self.changes.items, 0..) |change, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendChangeJson(alloc, &out, &change);
        }
        try out.appendSlice(alloc, "],\"audit\":");
        try self.appendAuditArrayJson(alloc, &out);
        try out.appendSlice(alloc, "}");
        return out.toOwnedSlice(alloc);
    }

    /// 从 state.json 的 `"product_runtime"` 块恢复。旧状态无该块时返回 false。
    pub fn loadFromJson(self: *ProductEvolutionRuntime, json: []const u8) !bool {
        const obj = state_json.extractObjectBlock(json, "product_runtime") orelse return false;
        self.clearAll();

        if (state_json.extractJsonNumber(obj, "next_change_id")) |n| {
            self.next_change_id = std.fmt.parseInt(u64, n, 10) catch 1;
        }
        if (state_json.extractJsonNumber(obj, "next_audit_id")) |n| {
            self.next_audit_id = std.fmt.parseInt(u64, n, 10) catch 1;
        }

        if (std.mem.indexOf(u8, obj, "\"changes\"")) |changes_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, changes_pos, "[") orelse return true;
            const arr_end = state_json.findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = state_json.findMatchingBrace(arr, os) orelse break;
                try self.loadOneChange(arr[os .. oe + 1]);
                i = oe + 1;
            }
        }

        if (std.mem.indexOf(u8, obj, "\"audit\"")) |audit_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, audit_pos, "[") orelse return true;
            const arr_end = state_json.findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = state_json.findMatchingBrace(arr, os) orelse break;
                try self.loadOneAudit(arr[os .. oe + 1]);
                i = oe + 1;
            }
        }

        self.recomputeNextIds();
        if (!try self.verifyAuditChain()) {
            self.clearAll();
            return error.AuditHashMismatch;
        }
        return true;
    }

    fn appendAuditArrayJson(self: *const ProductEvolutionRuntime, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        try out.append(alloc, '[');
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
            try writeJsonString(alloc, out, entry.tenant_id);
            try out.appendSlice(alloc, "\",\"detail\":\"");
            try writeJsonString(alloc, out, entry.detail);
            try out.appendSlice(alloc, "\",\"previous_hash\":\"");
            try writeJsonString(alloc, out, entry.previous_hash);
            try out.appendSlice(alloc, "\",\"current_hash\":\"");
            try writeJsonString(alloc, out, entry.current_hash);
            try out.appendSlice(alloc, "\"}");
        }
        try out.append(alloc, ']');
    }

    pub fn verifyAuditChain(self: *const ProductEvolutionRuntime) !bool {
        var previous: []const u8 = "genesis";
        for (self.audit.items) |entry| {
            if (!std.mem.eql(u8, entry.previous_hash, previous)) return false;
            const expected = try computeAuditHash(
                self.alloc,
                entry.previous_hash,
                entry.id,
                entry.at_unix,
                entry.kind,
                entry.change_id,
                entry.tenant_id,
                entry.detail,
            );
            defer self.alloc.free(expected);
            if (!std.mem.eql(u8, expected, entry.current_hash)) return false;
            previous = entry.current_hash;
        }
        return true;
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
        const previous_hash = if (self.audit.items.len > 0) self.audit.items[self.audit.items.len - 1].current_hash else "genesis";
        const current_hash = try computeAuditHash(self.alloc, previous_hash, self.next_audit_id, at_unix, kind, change_id, tenant_id, detail);
        errdefer self.alloc.free(current_hash);
        const previous_owned = try self.alloc.dupe(u8, previous_hash);
        errdefer self.alloc.free(previous_owned);
        const tenant_owned = try self.alloc.dupe(u8, tenant_id);
        errdefer self.alloc.free(tenant_owned);
        const detail_owned = try self.alloc.dupe(u8, detail);
        errdefer self.alloc.free(detail_owned);
        try self.audit.append(self.alloc, .{
            .id = self.next_audit_id,
            .at_unix = at_unix,
            .kind = kind,
            .change_id = change_id,
            .tenant_id = tenant_owned,
            .detail = detail_owned,
            .previous_hash = previous_owned,
            .current_hash = current_hash,
        });
        self.next_audit_id += 1;
    }

    fn clearAll(self: *ProductEvolutionRuntime) void {
        for (self.changes.items) |*c| c.deinit(self.alloc);
        self.changes.clearRetainingCapacity();
        for (self.audit.items) |*a| a.deinit(self.alloc);
        self.audit.clearRetainingCapacity();
        self.next_change_id = 1;
        self.next_audit_id = 1;
    }

    fn recomputeNextIds(self: *ProductEvolutionRuntime) void {
        var max_change: u64 = 0;
        var max_audit: u64 = 0;
        for (self.changes.items) |c| max_change = @max(max_change, c.id);
        for (self.audit.items) |a| max_audit = @max(max_audit, a.id);
        if (max_change >= self.next_change_id) self.next_change_id = max_change + 1;
        if (max_audit >= self.next_audit_id) self.next_audit_id = max_audit + 1;
    }

    fn loadOneChange(self: *ProductEvolutionRuntime, one: []const u8) !void {
        const id = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "id") orelse return, 10) catch return;
        const tenant_id = state_json.extractJsonString(self.alloc, one, "tenant_id") orelse return;
        errdefer self.alloc.free(tenant_id);
        const target = state_json.extractJsonString(self.alloc, one, "target") orelse {
            self.alloc.free(tenant_id);
            return;
        };
        errdefer self.alloc.free(target);
        const summary = state_json.extractJsonString(self.alloc, one, "summary") orelse {
            self.alloc.free(tenant_id);
            self.alloc.free(target);
            return;
        };
        errdefer self.alloc.free(summary);
        const rationale = state_json.extractJsonString(self.alloc, one, "rationale") orelse {
            self.alloc.free(tenant_id);
            self.alloc.free(target);
            self.alloc.free(summary);
            return;
        };
        errdefer self.alloc.free(rationale);

        const kind_owned = state_json.extractJsonString(self.alloc, one, "kind");
        const tier_owned = state_json.extractJsonString(self.alloc, one, "tier");
        const status_owned = state_json.extractJsonString(self.alloc, one, "status");
        defer if (kind_owned) |v| self.alloc.free(v);
        defer if (tier_owned) |v| self.alloc.free(v);
        defer if (status_owned) |v| self.alloc.free(v);

        const decided_by = state_json.extractJsonString(self.alloc, one, "decided_by");
        errdefer if (decided_by) |v| self.alloc.free(v);
        const decision_note = state_json.extractJsonString(self.alloc, one, "decision_note");
        errdefer if (decision_note) |v| self.alloc.free(v);

        const tier = parseTier(if (tier_owned) |v| v else "minor");
        try self.changes.append(self.alloc, .{
            .id = id,
            .tenant_id = tenant_id,
            .kind = parseKind(if (kind_owned) |v| v else "config"),
            .target = target,
            .summary = summary,
            .rationale = rationale,
            .expected_delta_k = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "expected_delta_k") orelse "0") catch 0,
            .affected_users = @intCast(std.fmt.parseInt(u32, state_json.extractJsonNumber(one, "affected_users") orelse "0", 10) catch 0),
            .reversible = parseBool(one, "reversible", true),
            .tier = tier,
            .risk = .{
                .severity = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "risk_severity") orelse "0") catch 0,
                .blast = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "risk_blast") orelse "0") catch 0,
                .reversibility = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "risk_reversibility") orelse "0") catch 0,
            },
            .timeout_seconds = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "timeout_seconds") orelse "0", 10) catch 0,
            .required_approvers = consent.requiredApprovers(tier, self.product),
            .status = parseStatus(if (status_owned) |v| v else "proposed"),
            .created_at = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "created_at") orelse "0", 10) catch 0,
            .decided_at = if (std.mem.indexOf(u8, one, "\"decided_at\":null") != null) null else std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "decided_at") orelse "0", 10) catch null,
            .decided_by = decided_by,
            .decision_note = decision_note,
        });
    }

    fn loadOneAudit(self: *ProductEvolutionRuntime, one: []const u8) !void {
        const id = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "id") orelse return, 10) catch return;
        const kind_owned = state_json.extractJsonString(self.alloc, one, "kind");
        defer if (kind_owned) |v| self.alloc.free(v);
        const tenant_id = state_json.extractJsonString(self.alloc, one, "tenant_id") orelse return;
        errdefer self.alloc.free(tenant_id);
        const detail = state_json.extractJsonString(self.alloc, one, "detail") orelse {
            self.alloc.free(tenant_id);
            return;
        };
        errdefer self.alloc.free(detail);
        const default_previous_hash = if (self.audit.items.len > 0) self.audit.items[self.audit.items.len - 1].current_hash else "genesis";
        const previous_hash = state_json.extractJsonString(self.alloc, one, "previous_hash") orelse try self.alloc.dupe(u8, default_previous_hash);
        errdefer self.alloc.free(previous_hash);
        const current_hash = state_json.extractJsonString(self.alloc, one, "current_hash") orelse try computeAuditHash(
            self.alloc,
            previous_hash,
            id,
            std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "at") orelse "0", 10) catch 0,
            parseAuditKind(if (kind_owned) |v| v else "change_proposed"),
            if (std.mem.indexOf(u8, one, "\"change_id\":null") != null) null else std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "change_id") orelse "0", 10) catch null,
            tenant_id,
            detail,
        );
        errdefer self.alloc.free(current_hash);
        try self.audit.append(self.alloc, .{
            .id = id,
            .at_unix = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "at") orelse "0", 10) catch 0,
            .kind = parseAuditKind(if (kind_owned) |v| v else "change_proposed"),
            .change_id = if (std.mem.indexOf(u8, one, "\"change_id\":null") != null) null else std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "change_id") orelse "0", 10) catch null,
            .tenant_id = tenant_id,
            .detail = detail,
            .previous_hash = previous_hash,
            .current_hash = current_hash,
        });
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

fn computeAuditHash(
    alloc: Allocator,
    previous_hash: []const u8,
    id: u64,
    at_unix: u64,
    kind: AuditKind,
    change_id: ?u64,
    tenant_id: []const u8,
    detail: []const u8,
) ![]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var scratch: [64]u8 = undefined;

    hasher.update(previous_hash);
    hasher.update("|");
    const id_s = try std.fmt.bufPrint(&scratch, "{d}", .{id});
    hasher.update(id_s);
    hasher.update("|");
    const at_s = try std.fmt.bufPrint(&scratch, "{d}", .{at_unix});
    hasher.update(at_s);
    hasher.update("|");
    hasher.update(@tagName(kind));
    hasher.update("|");
    if (change_id) |cid| {
        const cid_s = try std.fmt.bufPrint(&scratch, "{d}", .{cid});
        hasher.update(cid_s);
    } else {
        hasher.update("null");
    }
    hasher.update("|");
    hasher.update(tenant_id);
    hasher.update("|");
    hasher.update(detail);
    hasher.final(&digest);

    const out = try alloc.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

fn appendChangeJson(alloc: Allocator, buf: *std.ArrayList(u8), c: *const ChangeProposal) !void {
    try buf.print(alloc, "{{\"id\":{d},\"tenant_id\":\"", .{c.id});
    try writeJsonString(alloc, buf, c.tenant_id);
    try buf.print(alloc, "\",\"kind\":\"{s}\",\"target\":\"", .{@tagName(c.kind)});
    try writeJsonString(alloc, buf, c.target);
    try buf.appendSlice(alloc, "\",\"summary\":\"");
    try writeJsonString(alloc, buf, c.summary);
    try buf.appendSlice(alloc, "\",\"rationale\":\"");
    try writeJsonString(alloc, buf, c.rationale);
    try buf.print(alloc, "\",\"expected_delta_k\":{d:.6},\"affected_users\":{d},\"reversible\":{s},\"tier\":\"{s}\",\"risk_severity\":{d:.6},\"risk_blast\":{d:.6},\"risk_reversibility\":{d:.6},\"timeout_seconds\":{d},\"status\":\"{s}\",\"created_at\":{d},\"decided_at\":", .{
        c.expected_delta_k,
        c.affected_users,
        if (c.reversible) "true" else "false",
        @tagName(c.tier),
        c.risk.severity,
        c.risk.blast,
        c.risk.reversibility,
        c.timeout_seconds,
        @tagName(c.status),
        c.created_at,
    });
    if (c.decided_at) |v| try buf.print(alloc, "{d}", .{v}) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"decided_by\":");
    if (c.decided_by) |v| {
        try buf.append(alloc, '"');
        try writeJsonString(alloc, buf, v);
        try buf.append(alloc, '"');
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"decision_note\":");
    if (c.decision_note) |v| {
        try buf.append(alloc, '"');
        try writeJsonString(alloc, buf, v);
        try buf.append(alloc, '"');
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
}

fn parseKind(s: []const u8) ProductChangeKind {
    inline for (std.enums.values(ProductChangeKind)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .config;
}

fn parseStatus(s: []const u8) ChangeStatus {
    inline for (std.enums.values(ChangeStatus)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .proposed;
}

fn parseAuditKind(s: []const u8) AuditKind {
    inline for (std.enums.values(AuditKind)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .change_proposed;
}

fn parseTier(s: []const u8) consent.ConsentTier {
    inline for (std.enums.values(consent.ConsentTier)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .minor;
}

fn parseBool(obj: []const u8, key: []const u8, default: bool) bool {
    var needle: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return default;
    const pos = std.mem.indexOf(u8, obj, prefix) orelse return default;
    var i = pos + prefix.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t' or obj[i] == '\n')) : (i += 1) {}
    if (std.mem.startsWith(u8, obj[i..], "true")) return true;
    if (std.mem.startsWith(u8, obj[i..], "false")) return false;
    return default;
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

test "ProductEvolutionRuntime: toJson/loadFromJson changes and audit roundtrip" {
    const alloc = testing.allocator;
    var intent = try product_intent.parse(alloc, crm_intent_json);
    defer intent.deinit();
    var rt = ProductEvolutionRuntime.init(alloc, &intent);
    defer rt.deinit();

    const id = try rt.proposeCrmFollowupTightening("charlie", 45, 0.04, 100);
    try rt.approve(id, "ops", "ship behind flag", 200);

    const json = try rt.toJson(alloc);
    defer alloc.free(json);
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"product_runtime\":{s}}}", .{json});
    defer alloc.free(wrapped);

    var restored = ProductEvolutionRuntime.init(alloc, &intent);
    defer restored.deinit();
    try testing.expect(try restored.loadFromJson(wrapped));
    try testing.expectEqual(@as(usize, 1), restored.changes.items.len);
    try testing.expectEqual(@as(usize, 2), restored.audit.items.len);
    try testing.expectEqual(ChangeStatus.approved, restored.findChange(id).?.status);
    try testing.expectEqualStrings("charlie", restored.findChange(id).?.tenant_id);
    try testing.expect(restored.next_change_id > id);
    try testing.expect(restored.next_audit_id > 2);
}
