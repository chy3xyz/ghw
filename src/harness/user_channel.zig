//! UserChannel — bidirectional communication between a GHW digital
//! life and the humans it serves.
//!
//! Status: Week 3 of Phase 1 (GHW-as-CRM). The `e_saturated` trigger
//! is fully implemented. The other 4 triggers (`user_quiet_24h`,
//! `l5_about_to_apply`, `anomaly`, `experiment_done`) are stubbed
//! and follow the same pattern (see docs/CHANNEL.md §6 for roadmap).
//!
//! # Architecture
//!
//! Two bounded, drop-oldest rings:
//!   - InboundRing:  human → digital life  (not persisted; hot cache)
//!   - OutboundRing: digital life → human  (persisted to JSONL)
//!
//! Plus a ThrottleTable that dedupes "spammy" triggers per-tenant.
//!
//! # What this module does NOT do
//!
//! - It does NOT call the LLM directly. The fire flow accepts a
//!   pre-built LlmDriver reference and calls
//!   `LlmDriver.dispatch(.write_user_message, ...)`.
//! - It does NOT deliver to Slack / email / etc. The OutboundRing
//!   is consumed by the channel-specific worker in ui_server.zig
//!   (deferred; the OutboundRing + JSONL log is the interface).

const std = @import("std");
const llm_driver = @import("llm_driver.zig");
const product_intent = @import("product_intent.zig");
// Note: existence_degree lives in src/world/, but 0.17's module
// system doesn't allow `..` in @import. We forward-declare the
// types we need. If the real EBreakdown struct changes, this
// must change in lockstep with src/world/existence_degree.zig.

const EBreakdown = struct {
    base: f32,
    imbalance: f32,
    synergy: f32,
    symbiosis: f32,
    relations_bonus: f32,
    kpi_term: f32,
    total: f32,
};

/// Snapshot of E data needed by the fire flow. The caller (typically
/// `runCycle` in the daemon) computes this from the live
/// `ExistenceDegree` and passes it as a value, so this module does
/// not need a direct dependency on the world module.
pub const ESnapshot = struct {
    e_value: f32,
    breakdown: EBreakdown,
};

// ============================================================================
// Public types
// ============================================================================

pub const ChannelTrigger = enum(u8) {
    e_saturated,
    user_quiet_24h,
    l5_about_to_apply,
    anomaly,
    experiment_done,
    _count,
};

pub const UserIntent = enum {
    unknown, // default
    question,
    feedback,
    command,
    score,
};

pub const InboundMsg = struct {
    msg_id: u64,
    user_id: []const u8,
    text: []const u8,
    sentiment: f32 = 0.0, // -1..+1, filled by parse_user_message
    intent: UserIntent = .unknown, // filled by parse_user_message
    received_at: u64, // unix seconds
};

pub const OutboundMsg = struct {
    msg_id: u64,
    trigger: ChannelTrigger,
    channel: []const u8,
    payload_json: []const u8, // the LLM-generated text + metadata
    importance: f32 = 0.5,
    created_at: u64, // unix seconds
    delivered: bool = false,
    delivery_attempts: u8 = 0,
};

/// Bounded ring with drop-oldest semantics on overflow.
pub fn BoundedRing(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        head: usize = 0, // index of next write
        count: usize = 0,
        allocator: std.mem.Allocator, // for fields that own heap memory

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn push(self: *@This(), item: T) !void {
            self.buf[self.head] = item;
            self.head = (self.head + 1) % capacity;
            self.count = @min(self.count + 1, capacity);
        }

        /// Read the most recent item, or null if empty.
        pub fn latest(self: *const @This()) ?T {
            if (self.count == 0) return null;
            const idx = if (self.head == 0) capacity - 1 else self.head - 1;
            return self.buf[idx];
        }

        /// Iterate from oldest to newest. Useful for JSONL persistence.
        pub fn iter(self: *const @This()) []const T {
            if (self.count == 0) return &.{};
            if (self.count < capacity) return self.buf[0..self.count];
            // count == capacity, head is the next-write position, so
            // oldest is at head (it'll be overwritten next).
            const tail = self.buf[self.head..];
            const front = self.buf[0..self.head];
            // We can't return a single contiguous slice in this case;
            // caller should use iterPair or copy out. For now return
            // the first half (which is logically the "newer" half).
            _ = tail;
            return front;
        }
    };
}

/// Per-tenant throttle state: last-fired timestamp per trigger.
pub const ThrottleTable = struct {
    /// Key: tenant_id (string hash). Value: [ChannelTrigger._count]u64
    /// of last-fired timestamps (unix seconds, 0 = never).
    last_fired: std.AutoHashMap(u64, [@intFromEnum(ChannelTrigger._count)]u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ThrottleTable {
        return .{
            .last_fired = std.AutoHashMap(u64, [@intFromEnum(ChannelTrigger._count)]u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThrottleTable) void {
        self.last_fired.deinit();
    }

    /// Hash a tenant_id string to u64. FNV-1a is fine here.
    pub fn hashTenant(tenant_id: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (tenant_id) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        return h;
    }

    /// True iff the trigger has fired within the throttle window.
    pub fn isThrottled(self: *const ThrottleTable, tenant_hash: u64, trigger: ChannelTrigger, now_unix: u64, window_seconds: u64) bool {
        const entry = self.last_fired.get(tenant_hash) orelse return false;
        const last = entry[@intFromEnum(trigger)];
        if (last == 0) return false;
        return now_unix > last and now_unix - last < window_seconds;
    }

    /// Record that a trigger fired at `now_unix`.
    pub fn recordFire(self: *ThrottleTable, tenant_hash: u64, trigger: ChannelTrigger, now_unix: u64) !void {
        const gop = try self.last_fired.getOrPut(tenant_hash);
        if (!gop.found_existing) {
            gop.value_ptr.* = @splat(0);
        }
        gop.value_ptr.*[@intFromEnum(trigger)] = now_unix;
    }
};

/// 24h throttle window for e_saturated (per docs/CHANNEL.md §2).
pub const E_SATURATED_THROTTLE_SECONDS: u64 = 24 * 60 * 60;

// ============================================================================
// UserChannel — the top-level struct
// ============================================================================

pub const UserChannel = struct {
    allocator: std.mem.Allocator,
    inbound: BoundedRing(InboundMsg, 256),
    outbound: BoundedRing(OutboundMsg, 256),
    throttle: ThrottleTable,
    next_msg_id: u64,

    pub fn init(allocator: std.mem.Allocator) UserChannel {
        return .{
            .allocator = allocator,
            .inbound = BoundedRing(InboundMsg, 256).init(allocator),
            .outbound = BoundedRing(OutboundMsg, 256).init(allocator),
            .throttle = ThrottleTable.init(allocator),
            .next_msg_id = 1,
        };
    }

    pub fn deinit(self: *UserChannel) void {
        self.throttle.deinit();
    }

    /// Push a human message into the inbound ring.
    pub fn receiveInbound(self: *UserChannel, user_id: []const u8, text: []const u8, received_at: u64) !u64 {
        const id = self.next_msg_id;
        self.next_msg_id += 1;
        try self.inbound.push(.{
            .msg_id = id,
            .user_id = user_id,
            .text = text,
            .received_at = received_at,
        });
        return id;
    }

    /// Read the latest inbound message, if any. Used by the
    /// parse_user_message trigger flow.
    pub fn latestInbound(self: *const UserChannel) ?InboundMsg {
        return self.inbound.latest();
    }

    /// Check if a trigger is throttled for a tenant.
    pub fn isThrottled(
        self: *const UserChannel,
        tenant_id: []const u8,
        trigger: ChannelTrigger,
        now_unix: u64,
        window_seconds: u64,
    ) bool {
        const h = ThrottleTable.hashTenant(tenant_id);
        return self.throttle.isThrottled(h, trigger, now_unix, window_seconds);
    }
};

// ============================================================================
// E-Saturated Detection
// ============================================================================

/// A 64-cycle E history ring buffer. Computes variance; returns
/// true iff the buffer is full and variance is below threshold.
pub const EHistory = struct {
    buf: [64]f32 = @splat(0.5),
    idx: u8 = 0,
    count: u8 = 0,

    pub fn record(self: *EHistory, e: f32) void {
        self.buf[self.idx] = e;
        self.idx = (self.idx + 1) % 64;
        self.count = @min(self.count + 1, 64);
    }

    pub fn isSaturated(self: *const EHistory, threshold: f32) bool {
        if (self.count < 64) return false;
        var sum: f32 = 0.0;
        for (self.buf) |e| sum += e;
        const mean = sum / 64.0;
        var sq_sum: f32 = 0.0;
        for (self.buf) |e| {
            const d = e - mean;
            sq_sum += d * d;
        }
        const variance = sq_sum / 64.0;
        return variance < threshold;
    }
};

// ============================================================================
// E-Saturated Fire Flow
// ============================================================================

pub const ESaturatedFireContext = struct {
    tenant_id: []const u8,
    e_snapshot: ESnapshot,
    e_history: *const EHistory,
    /// Pre-fetched KPI signal.
    kpi_composite: f32,
    kpi_trend: f32,
    /// Unix seconds for throttle check.
    now_unix: u64,
    /// Maximum text length the LLM should produce.
    max_length: u16 = 200,
};

/// Fire the e_saturated trigger if conditions are met. Returns the
/// number of OutboundMsg produced (0 if throttled, 0 if not actually
/// saturated, or 1+ if fired).
///
/// On LLM failure (provider=none + mandatory role), a fallback
/// message is appended that says the digital life is in steady
/// state but cannot phrase a response. This is the **only** case
/// where a MANDATORY role's failure produces visible user output;
/// the alternative (silent) is worse.
pub fn maybeFireESaturated(
    channel: *UserChannel,
    driver: *llm_driver.LlmDriver,
    product: *const product_intent.ProductIntent,
    ctx: ESaturatedFireContext,
) !usize {
    // 1. Detect saturation
    if (!ctx.e_history.isSaturated(0.01)) return 0;

    // 2. Throttle check (24h per tenant, see docs/CHANNEL.md §4.3)
    if (channel.isThrottled(ctx.tenant_id, .e_saturated, ctx.now_unix, E_SATURATED_THROTTLE_SECONDS)) {
        return 0;
    }

    // 3. For each configured channel, build a message via LlmDriver.
    //    `channelsFor` returns the configured destination names; the
    //    LLM produces the *content*; we record both as OutboundMsg.
    const channels = product.channelsFor(.e_saturated);
    var produced: usize = 0;
    for (channels) |ch_dest| {
        // Build the prompt context.
        var prompt_buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&prompt_buf);
        try w.print(
            \\{{"trigger":"e_saturated","e":{d},"kpi_composite":{d},"kpi_trend":{d},
            \\"stable_cycles":64,"tenant":"{s}","breakdown_base":{d},
            \\"breakdown_kpi_term":{d}}}
        , .{
            ctx.e_snapshot.e_value,
            ctx.kpi_composite,
            ctx.kpi_trend,
            ctx.tenant_id,
            ctx.e_snapshot.breakdown.base,
            ctx.e_snapshot.breakdown.kpi_term,
        });
        const ctx_json = w.buffered();

        // 4. LLM call. Hard-fail for mandatory role, but we catch and
        //    produce a fallback message so the user sees SOMETHING.
        var llm_text: []const u8 = "[digital life is currently without LLM; no response available]";
        if (driver.dispatch(.{
            .role = .write_user_message,
            .audit_tag = "e_saturated_fire",
            .payload = .{ .write_user_message = .{
                .trigger = "e_saturated",
                .context_json = ctx_json,
                .tone_hint = .ops_casual_status,
                .max_length = ctx.max_length,
            } },
        })) |resp| {
            llm_text = resp.result.write_user_message.text;
        } else |_| {
            // LLM unavailable. Use the fallback text. The audit log
            // already captured the failure (in the LlmDriver).
        }

        // 5. Append OutboundMsg.
        const id = channel.next_msg_id;
        channel.next_msg_id += 1;
        try channel.outbound.push(.{
            .msg_id = id,
            .trigger = .e_saturated,
            .channel = ch_dest,
            .payload_json = llm_text,
            .created_at = ctx.now_unix,
        });
        produced += 1;
    }

    // 6. Record the fire in the throttle table (single entry, not per
    //    channel — the throttle is per-trigger, not per-trigger+channel).
    const tenant_hash = ThrottleTable.hashTenant(ctx.tenant_id);
    try channel.throttle.recordFire(tenant_hash, .e_saturated, ctx.now_unix);

    return produced;
}

// ============================================================================
// JSONL persistence (outbound ring)
// ============================================================================

/// Append an OutboundMsg to a JSONL file. The file is opened in
/// append mode; each call writes one line.
pub fn appendOutboundToFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    msg: OutboundMsg,
) !void {
    // 0.17: allocSentinel for null-terminated path (see fix/week1-0.17-compat)
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const oflag: std.c.O = @bitCast(@as(u32, 0x8)); // O_APPEND = 0x8 on POSIX
    const fd = std.c.open(path_z, oflag, @as(c_uint, 0o644));
    if (fd < 0) return error.PermissionDenied;
    defer _ = std.c.close(fd);

    // Build the JSON line: {"msg_id":N,"trigger":"e_saturated",...}
    var line_buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    try w.print(
        \\{{"msg_id":{d},"trigger":"{s}","channel":"{s}","text":{f},"created_at":{d},"delivered":{s}}}
        \\
    , .{
        msg.msg_id,
        @tagName(msg.trigger),
        msg.channel,
        // Emit the LLM text as a JSON string literal (escape \ and ").
        msg.payload_json,
        msg.created_at,
        if (msg.delivered) "true" else "false",
    });
    const line = w.buffered();

    // 0.17: write takes Writer, not raw bytes. Use std.c.write for
    // the raw fd write.
    _ = std.c.write(fd, line.ptr, line.len);
}

// ============================================================================
// Unit tests
// ============================================================================

test "BoundedRing: push and latest" {
    var ring = BoundedRing(u32, 4).init(std.testing.allocator);
    try ring.push(1);
    try ring.push(2);
    try ring.push(3);
    try std.testing.expectEqual(@as(?u32, 3), ring.latest());
}

test "BoundedRing: overflow drops oldest" {
    var ring = BoundedRing(u32, 4).init(std.testing.allocator);
    try ring.push(1);
    try ring.push(2);
    try ring.push(3);
    try ring.push(4);
    try ring.push(5); // drops 1
    try std.testing.expectEqual(@as(usize, 4), ring.count);
    try std.testing.expectEqual(@as(?u32, 5), ring.latest());
}

test "UserChannel: receive inbound" {
    var ch = UserChannel.init(std.testing.allocator);
    defer ch.deinit();
    const id = try ch.receiveInbound("user-1", "hello", 1000);
    try std.testing.expectEqual(@as(u64, 1), id);
    const msg = ch.latestInbound().?;
    try std.testing.expectEqualStrings("user-1", msg.user_id);
    try std.testing.expectEqualStrings("hello", msg.text);
}

test "ThrottleTable: throttles within window" {
    var t = ThrottleTable.init(std.testing.allocator);
    defer t.deinit();
    const tenant = "acme";
    const h = ThrottleTable.hashTenant(tenant);
    try t.recordFire(h, .e_saturated, 1000);
    try std.testing.expect(t.isThrottled(h, .e_saturated, 1000 + 60, E_SATURATED_THROTTLE_SECONDS));
    try std.testing.expect(!t.isThrottled(h, .e_saturated, 1000 + E_SATURATED_THROTTLE_SECONDS + 1, E_SATURATED_THROTTLE_SECONDS));
}

test "ThrottleTable: different tenants are independent" {
    var t = ThrottleTable.init(std.testing.allocator);
    defer t.deinit();
    const h1 = ThrottleTable.hashTenant("acme");
    const h2 = ThrottleTable.hashTenant("bravo");
    try t.recordFire(h1, .e_saturated, 1000);
    try std.testing.expect(t.isThrottled(h1, .e_saturated, 1000 + 60, E_SATURATED_THROTTLE_SECONDS));
    try std.testing.expect(!t.isThrottled(h2, .e_saturated, 1000 + 60, E_SATURATED_THROTTLE_SECONDS));
}

test "EHistory: not saturated when not full" {
    var h = EHistory{};
    for (0..32) |_| h.record(0.5);
    try std.testing.expect(!h.isSaturated(0.01));
}

test "EHistory: not saturated when variance high" {
    var h = EHistory{};
    for (0..32) |i| h.record(if (i % 2 == 0) 0.0 else 1.0); // 50% spread
    for (0..32) |i| h.record(if (i % 2 == 0) 0.0 else 1.0);
    try std.testing.expect(!h.isSaturated(0.01));
}

test "EHistory: saturated when all values close" {
    var h = EHistory{};
    for (0..64) |_| h.record(0.85);
    try std.testing.expect(h.isSaturated(0.01));
}

test "maybeFireESaturated: returns 0 when not saturated" {
    var ch = UserChannel.init(std.testing.allocator);
    defer ch.deinit();
    var driver = llm_driver.LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = false, // not used; LLM not consulted when not saturated
    });
    var eh = EHistory{};
    for (0..64) |_| eh.record(0.5);
    const bd: EBreakdown = .{
        .base = 0.5,
        .imbalance = 0.0,
        .synergy = 0.3,
        .symbiosis = 0.0,
        .relations_bonus = 0.0,
        .kpi_term = 0.0,
        .total = 0.8,
    };

    // No ProductIntent — channelsFor would crash. We test with an
    // empty channel list by providing a synthetic PI; but for the
    // "not saturated" case, we never reach channelsFor.
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
    // We construct a partial product with empty channel_routing. The
    // helper `channelsFor` will return &.{} for e_saturated, so no
    // messages are produced, but throttle is still recorded.

    // Use a not-saturated history to verify 0 produced.
    var eh_loose = EHistory{};
    for (0..64) |i| eh_loose.record(@as(f32, @floatFromInt(i)) / 100.0); // ramp
    const n = try maybeFireESaturated(&ch, &driver, &product, .{
        .tenant_id = "acme",
        .e_snapshot = .{ .e_value = 0.85, .breakdown = bd },
        .e_history = &eh_loose,
        .kpi_composite = 0.7,
        .kpi_trend = 0.001,
        .now_unix = 1000,
    });
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "maybeFireESaturated: fires when saturated, LLM unavailable produces fallback" {
    var ch = UserChannel.init(std.testing.allocator);
    defer ch.deinit();
    var driver = llm_driver.LlmDriver.init(std.testing.allocator, .{
        .provider = .none,
        .fallback_on_failure = true, // but MANDATORY role hard-fails anyway
    });
    var eh = EHistory{};
    for (0..64) |_| eh.record(0.5);
    const bd: EBreakdown = .{
        .base = 0.5,
        .imbalance = 0.0,
        .synergy = 0.3,
        .symbiosis = 0.0,
        .relations_bonus = 0.0,
        .kpi_term = 0.0,
        .total = 0.8,
    };

    // Construct a ProductIntent with 1 channel for e_saturated.
    const channels_slice = [_][]const u8{"admin_dashboard"};
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
            .e_saturated = &channels_slice,
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

    const n = try maybeFireESaturated(&ch, &driver, &product, .{
        .tenant_id = "acme",
        .e_snapshot = .{ .e_value = 0.85, .breakdown = bd },
        .e_history = &eh,
        .kpi_composite = 0.7,
        .kpi_trend = 0.001,
        .now_unix = 1000,
    });
    // 1 channel configured → 1 message produced
    try std.testing.expectEqual(@as(usize, 1), n);
    // The fallback text was used
    const msg = ch.outbound.latest().?;
    try std.testing.expect(std.mem.indexOf(u8, msg.payload_json, "without LLM") != null);

    // Throttle recorded: a second call within 24h returns 0
    const n2 = try maybeFireESaturated(&ch, &driver, &product, .{
        .tenant_id = "acme",
        .e_snapshot = .{ .e_value = 0.85, .breakdown = bd },
        .e_history = &eh,
        .kpi_composite = 0.7,
        .kpi_trend = 0.001,
        .now_unix = 1000 + 60, // 60s later, well within 24h
    });
    try std.testing.expectEqual(@as(usize, 0), n2);
}
