//! 一产品一 GHW — 实例身份与绑定契约。
//!
//! 每个 GHW 进程在 product mode 下只服务一个 ProductIntent.product_id。
//! instance_id 区分同一产品的多副本/多区域部署; node_id 用于 GHW Link 寻址。

const std = @import("std");
const product_intent = @import("product_intent.zig");

const Allocator = std.mem.Allocator;
const ProductIntent = product_intent.ProductIntent;
const ProductType = product_intent.ProductType;

pub const ProductInstanceError = error{
    ProductIdMismatch,
    InstanceIdEmpty,
    NodeIdEmpty,
    OutOfMemory,
};

/// 部署绑定模式。当前只支持一产品一 GHW。
pub const BindingMode = enum {
    one_product_one_ghw,

    pub fn tag(self: BindingMode) []const u8 {
        return switch (self) {
            .one_product_one_ghw => "one_product_one_ghw",
        };
    }
};

pub const ProductInstanceIdentity = struct {
    alloc: Allocator,
    product_id: []const u8,
    product_type: ProductType,
    instance_id: []const u8,
    node_id: []const u8,
    binding_mode: BindingMode = .one_product_one_ghw,

    pub fn init(
        alloc: Allocator,
        intent: *const ProductIntent,
        node_id: []const u8,
        instance_id: []const u8,
    ) ProductInstanceError!ProductInstanceIdentity {
        if (node_id.len == 0) return error.NodeIdEmpty;
        if (instance_id.len == 0) return error.InstanceIdEmpty;
        const product_id = try alloc.dupe(u8, intent.product_id);
        errdefer alloc.free(product_id);
        const node_owned = try alloc.dupe(u8, node_id);
        errdefer alloc.free(node_owned);
        const instance_owned = try alloc.dupe(u8, instance_id);
        errdefer alloc.free(instance_owned);
        return .{
            .alloc = alloc,
            .product_id = product_id,
            .product_type = intent.product_type,
            .instance_id = instance_owned,
            .node_id = node_owned,
        };
    }

    /// 未显式传 instance_id 时: `{product_id}@{node_id}`。
    pub fn initDefault(alloc: Allocator, intent: *const ProductIntent, node_id: []const u8) ProductInstanceError!ProductInstanceIdentity {
        const derived = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ intent.product_id, node_id });
        defer alloc.free(derived);
        return init(alloc, intent, node_id, derived);
    }

    pub fn deinit(self: *ProductInstanceIdentity) void {
        self.alloc.free(self.product_id);
        self.alloc.free(self.instance_id);
        self.alloc.free(self.node_id);
    }

    /// 持久化快照里的 product_id 必须与当前 ProductIntent 一致。
    pub fn verifyStoredProductId(self: *const ProductInstanceIdentity, stored: []const u8) ProductInstanceError!void {
        if (stored.len == 0) return;
        if (!std.mem.eql(u8, stored, self.product_id)) return error.ProductIdMismatch;
    }

    pub fn appendJsonFields(self: *const ProductInstanceIdentity, out: *std.ArrayList(u8)) !void {
        try out.print(self.alloc, "\"binding_mode\":\"{s}\",\"product_id\":\"", .{self.binding_mode.tag()});
        try writeJsonString(self.alloc, out, self.product_id);
        try out.appendSlice(self.alloc, "\",\"product_type\":\"");
        try out.appendSlice(self.alloc, @tagName(self.product_type));
        try out.appendSlice(self.alloc, "\",\"instance_id\":\"");
        try writeJsonString(self.alloc, out, self.instance_id);
        try out.appendSlice(self.alloc, "\",\"node_id\":\"");
        try writeJsonString(self.alloc, out, self.node_id);
        try out.appendSlice(self.alloc, "\"");
    }
};

fn writeJsonString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

const testing = std.testing;

test "ProductInstanceIdentity: default instance_id is product@node" {
    const alloc = testing.allocator;
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "crm-a",
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
    var intent = try product_intent.parse(alloc, json);
    defer intent.deinit();
    var id = try ProductInstanceIdentity.initDefault(alloc, &intent, "node-east");
    defer id.deinit();
    try testing.expectEqualStrings("crm-a@node-east", id.instance_id);
    try id.verifyStoredProductId("crm-a");
    try testing.expectError(error.ProductIdMismatch, id.verifyStoredProductId("other"));
}
