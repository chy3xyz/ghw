//! GHW 互联共同进化 — 跨节点共享已验证的产品变更洞察。
//!
//! 同一 product_id 的 peer 优先; 同 product_type 次之。LLM/规则层可读这些洞察作偏置输入。

const std = @import("std");
const state_json = @import("human_symbiosis/state_json.zig");

const Allocator = std.mem.Allocator;

pub const PeerEvolutionInsight = struct {
    peer_id: []const u8,
    product_id: []const u8,
    product_type: []const u8,
    target: []const u8,
    summary: []const u8,
    expected_delta_k: f32,
    trust: f32,
    received_at: u64,

    fn deinit(self: *PeerEvolutionInsight, alloc: Allocator) void {
        alloc.free(self.peer_id);
        alloc.free(self.product_id);
        alloc.free(self.product_type);
        alloc.free(self.target);
        alloc.free(self.summary);
    }
};

pub const CoEvolutionRegistry = struct {
    alloc: Allocator,
    local_product_id: []const u8,
    local_product_type: []const u8,
    insights: std.ArrayList(PeerEvolutionInsight) = .empty,
    max_insights: usize = 64,

    pub fn init(alloc: Allocator, local_product_id: []const u8, local_product_type: []const u8) !CoEvolutionRegistry {
        return .{
            .alloc = alloc,
            .local_product_id = try alloc.dupe(u8, local_product_id),
            .local_product_type = try alloc.dupe(u8, local_product_type),
        };
    }

    pub fn deinit(self: *CoEvolutionRegistry) void {
        for (self.insights.items) |*ins| ins.deinit(self.alloc);
        self.insights.deinit(self.alloc);
        self.alloc.free(self.local_product_id);
        self.alloc.free(self.local_product_type);
    }

    pub fn acceptPolicy(
        local_product_id: []const u8,
        local_product_type: []const u8,
        peer_product_id: []const u8,
        peer_product_type: []const u8,
    ) f32 {
        if (std.mem.eql(u8, peer_product_id, local_product_id)) return 1.0;
        if (std.mem.eql(u8, peer_product_type, local_product_type)) return 0.55;
        return 0.0;
    }

    pub fn recordInsight(
        self: *CoEvolutionRegistry,
        peer_id: []const u8,
        product_id: []const u8,
        product_type: []const u8,
        target: []const u8,
        summary: []const u8,
        expected_delta_k: f32,
        received_at: u64,
    ) !bool {
        const trust = acceptPolicy(self.local_product_id, self.local_product_type, product_id, product_type);
        if (trust <= 0.0) return false;
        const peer_owned = try self.alloc.dupe(u8, peer_id);
        errdefer self.alloc.free(peer_owned);
        const pid = try self.alloc.dupe(u8, product_id);
        errdefer self.alloc.free(pid);
        const ptype = try self.alloc.dupe(u8, product_type);
        errdefer self.alloc.free(ptype);
        const target_owned = try self.alloc.dupe(u8, target);
        errdefer self.alloc.free(target_owned);
        const summary_owned = try self.alloc.dupe(u8, summary);
        errdefer self.alloc.free(summary_owned);
        try self.insights.append(self.alloc, .{
            .peer_id = peer_owned,
            .product_id = pid,
            .product_type = ptype,
            .target = target_owned,
            .summary = summary_owned,
            .expected_delta_k = expected_delta_k,
            .trust = trust,
            .received_at = received_at,
        });
        while (self.insights.items.len > self.max_insights) {
            var old = self.insights.orderedRemove(0);
            old.deinit(self.alloc);
        }
        return true;
    }

    pub fn toJson(self: *const CoEvolutionRegistry, alloc: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"local_product_id\":\"");
        try writeJsonString(alloc, &out, self.local_product_id);
        try out.appendSlice(alloc, "\",\"local_product_type\":\"");
        try writeJsonString(alloc, &out, self.local_product_type);
        try out.appendSlice(alloc, "\",\"insights\":[");
        for (self.insights.items, 0..) |ins, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"peer_id\":\"", .{});
            try writeJsonString(alloc, &out, ins.peer_id);
            try out.appendSlice(alloc, "\",\"product_id\":\"");
            try writeJsonString(alloc, &out, ins.product_id);
            try out.appendSlice(alloc, "\",\"product_type\":\"");
            try writeJsonString(alloc, &out, ins.product_type);
            try out.appendSlice(alloc, "\",\"target\":\"");
            try writeJsonString(alloc, &out, ins.target);
            try out.appendSlice(alloc, "\",\"summary\":\"");
            try writeJsonString(alloc, &out, ins.summary);
            try out.print(alloc, "\",\"expected_delta_k\":{d:.6},\"trust\":{d:.3},\"received_at\":{d}}}", .{
                ins.expected_delta_k,
                ins.trust,
                ins.received_at,
            });
        }
        try out.appendSlice(alloc, "]}");
        return out.toOwnedSlice(alloc);
    }

    pub fn loadFromJson(self: *CoEvolutionRegistry, json: []const u8) (error{ProductIdMismatch, OutOfMemory})!bool {
        const obj = state_json.extractObjectBlock(json, "co_evolution") orelse return false;
        if (state_json.extractJsonString(self.alloc, obj, "local_product_id")) |stored| {
            defer self.alloc.free(stored);
            if (!std.mem.eql(u8, stored, self.local_product_id)) return error.ProductIdMismatch;
        }
        if (std.mem.indexOf(u8, obj, "\"insights\"")) |pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, pos, "[") orelse return true;
            const arr_end = state_json.findMatchingBracket(obj, arr_start) orelse return true;
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = state_json.findMatchingBrace(arr, os) orelse break;
                try self.loadOneInsight(arr[os .. oe + 1]);
                i = oe + 1;
            }
        }
        return true;
    }

    fn loadOneInsight(self: *CoEvolutionRegistry, one: []const u8) !void {
        const peer_id = state_json.extractJsonString(self.alloc, one, "peer_id") orelse return;
        errdefer self.alloc.free(peer_id);
        const product_id = state_json.extractJsonString(self.alloc, one, "product_id") orelse {
            self.alloc.free(peer_id);
            return;
        };
        errdefer self.alloc.free(product_id);
        const product_type = state_json.extractJsonString(self.alloc, one, "product_type") orelse {
            self.alloc.free(peer_id);
            self.alloc.free(product_id);
            return;
        };
        errdefer self.alloc.free(product_type);
        const target = state_json.extractJsonString(self.alloc, one, "target") orelse {
            self.alloc.free(peer_id);
            self.alloc.free(product_id);
            self.alloc.free(product_type);
            return;
        };
        errdefer self.alloc.free(target);
        const summary = state_json.extractJsonString(self.alloc, one, "summary") orelse {
            self.alloc.free(peer_id);
            self.alloc.free(product_id);
            self.alloc.free(product_type);
            self.alloc.free(target);
            return;
        };
        errdefer self.alloc.free(summary);
        const expected_delta_k = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "expected_delta_k") orelse "0") catch 0;
        const trust = std.fmt.parseFloat(f32, state_json.extractJsonNumber(one, "trust") orelse "0") catch 0;
        const received_at = std.fmt.parseInt(u64, state_json.extractJsonNumber(one, "received_at") orelse "0", 10) catch 0;
        try self.insights.append(self.alloc, .{
            .peer_id = peer_id,
            .product_id = product_id,
            .product_type = product_type,
            .target = target,
            .summary = summary,
            .expected_delta_k = expected_delta_k,
            .trust = trust,
            .received_at = received_at,
        });
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

test "CoEvolutionRegistry: same product_id insight accepted" {
    const alloc = testing.allocator;
    var reg = try CoEvolutionRegistry.init(alloc, "crm-a", "saas_web");
    defer reg.deinit();
    try testing.expect(try reg.recordInsight("peer-b", "crm-a", "saas_web", "crm.followup", "tighten cadence", 0.04, 100));
    try testing.expectEqual(@as(usize, 1), reg.insights.items.len);
    try testing.expect(!try reg.recordInsight("peer-c", "other", "mobile_app", "x", "y", 0.1, 101));
}

test "CoEvolutionRegistry: toJson/loadFromJson roundtrip" {
    const alloc = testing.allocator;
    var reg = try CoEvolutionRegistry.init(alloc, "crm-a", "saas_web");
    defer reg.deinit();
    _ = try reg.recordInsight("peer-b", "crm-a", "saas_web", "target", "summary", 0.02, 200);
    const json = try reg.toJson(alloc);
    defer alloc.free(json);
    var restored = try CoEvolutionRegistry.init(alloc, "crm-a", "saas_web");
    defer restored.deinit();
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"co_evolution\":{s}}}", .{json});
    defer alloc.free(wrapped);
    try testing.expect(try restored.loadFromJson(wrapped));
    try testing.expectEqual(@as(usize, 1), restored.insights.items.len);
}
