//! ProductIntent — the product-level declaration that tells GHW what
//! product it lives inside and what success looks like.
//!
//! Status: Week 1 of Phase 1 (GHW-as-CRM). SKELETON. See INTEGRATION_WEEK1.md
//! for the exact integration points with the existing codebase.
//!
//! This file is intentionally self-contained and does NOT depend on any
//! existing GHW internal modules. It is meant to be dropped into
//! `src/harness/` and wired up incrementally over the next 4 weeks.

const std = @import("std");

// ============================================================================
// Public types
// ============================================================================

/// The loaded product intent, held in memory for the daemon's lifetime.
///
/// Loader: `ProductIntent.load(alloc, path)`
/// Accessor: usually stored on `App` (in ui_server.zig) or daemon's main state.
pub const ProductIntent = struct {
    allocator: std.mem.Allocator,

    // ---- Top-level identity ----
    schema_version: u32,
    product_id: []const u8,
    product_type: ProductType,
    version: []const u8,
    update_epoch: u64,
    last_updated: i64,
    approved_by: []const u8,

    // ---- Product "why" ----
    manifesto: []const u8,
    sacrosanct: []const []const u8,

    // ---- KPI ----
    north_star_kpi: []const u8,
    secondary_kpis: []const []const u8,
    kpi_aggregator: KpiAggregator,
    kpi_evaluation_window: EvaluationWindow,

    // ---- E-formula weights ----
    value_weights: ValueWeights,

    // ---- Consent ----
    consent_defaults: ConsentDefaults,

    // ---- Experiment ----
    experiment_defaults: ExperimentDefaults,

    // ---- Channel routing ----
    channel_routing: ChannelRouting,

    // ---- Rhythm ----
    rhythm: Rhythm,

    // ---- Cohort policy (CRM-specific, optional) ----
    cohort_policy: ?CohortPolicy,

    // ---- Audit log policy ----
    audit_log: AuditLogConfig,

    /// Free all owned strings. Call from `App.deinit` or daemon shutdown.
    pub fn deinit(self: *ProductIntent) void {
        const a = self.allocator;
        a.free(self.product_id);
        a.free(self.version);
        a.free(self.approved_by);
        a.free(self.manifesto);
        for (self.sacrosanct) |s| a.free(s);
        a.free(self.sacrosanct);
        a.free(self.north_star_kpi);
        for (self.secondary_kpis) |s| a.free(s);
        a.free(self.secondary_kpis);
        freeChannelRouting(a, self.channel_routing);
        if (self.cohort_policy) |*cp| {
            for (cp.industry_cohorts_supported) |s| a.free(s);
            a.free(cp.industry_cohorts_supported);
            if (cp.this_tenant_cohort) |c| a.free(c);
        }
        // value_weights/consent_defaults/experiment_defaults/audit_log/
        // channel_routing/cohort_policy all use `_raw_buf: []u8 = &.{}`
        // as a placeholder for future "raw JSON storage" — currently
        // empty static slices, nothing to free.
    }

    // ----- Accessors for downstream consumers -----

    /// True if a `*_tier` is auto-revert-on-timeout. Mirrors CONSENT_DEFAULTS.md §3.3.
    pub fn tierTimeoutHours(self: *const ProductIntent, tier: ConsentTier) u32 {
        return switch (tier) {
            .minor => self.consent_defaults.minor_tier_timeout_hours,
            .standard => self.consent_defaults.standard_tier_timeout_hours,
            .major => self.consent_defaults.major_tier_timeout_hours,
            .critical => 0, // critical never auto-times-out
        };
    }

    /// Returns the channels configured for a given trigger.
    /// Returns empty slice if not configured (caller should treat as load error).
    pub fn channelsFor(self: *const ProductIntent, trigger: ChannelTrigger) []const []const u8 {
        return switch (trigger) {
            .e_saturated => self.channel_routing.e_saturated,
            .user_quiet_24h => self.channel_routing.user_quiet_24h,
            .l5_about_to_apply => self.channel_routing.l5_about_to_apply,
            .anomaly => self.channel_routing.anomaly,
            .experiment_done => self.channel_routing.experiment_done,
        };
    }
};

pub const ProductType = enum {
    mobile_app,
    desktop_app,
    saas_web,
    saas_api,

    pub fn fromString(s: []const u8) !ProductType {
        if (std.mem.eql(u8, s, "mobile_app")) return .mobile_app;
        if (std.mem.eql(u8, s, "desktop_app")) return .desktop_app;
        if (std.mem.eql(u8, s, "saas_web")) return .saas_web;
        if (std.mem.eql(u8, s, "saas_api")) return .saas_api;
        return error.UnknownProductType;
    }
};

pub const KpiAggregator = enum {
    mean,
    median,
    p50,
    weighted,

    pub fn fromString(s: []const u8) !KpiAggregator {
        if (std.mem.eql(u8, s, "mean")) return .mean;
        if (std.mem.eql(u8, s, "median")) return .median;
        if (std.mem.eql(u8, s, "p50")) return .p50;
        if (std.mem.eql(u8, s, "weighted")) return .weighted;
        return error.UnknownAggregator;
    }
};

pub const EvaluationWindow = enum {
    hourly,
    daily,
    weekly,
    monthly,

    pub fn fromString(s: []const u8) !EvaluationWindow {
        if (std.mem.eql(u8, s, "hourly")) return .hourly;
        if (std.mem.eql(u8, s, "daily")) return .daily;
        if (std.mem.eql(u8, s, "weekly")) return .weekly;
        if (std.mem.eql(u8, s, "monthly")) return .monthly;
        return error.UnknownWindow;
    }

    /// Minimum seconds between two KPI refreshes. Used to validate the
    /// `kpi_refresh_interval_hours >= this/3600` invariant.
    pub fn minSeconds(self: EvaluationWindow) u64 {
        return switch (self) {
            .hourly => 3600,
            .daily => 86_400,
            .weekly => 7 * 86_400,
            .monthly => 30 * 86_400,
        };
    }
};

pub const ValueWeights = struct {
    user_satisfaction: f32,
    retention: f32,
    revenue: f32,
    safety: f32,

    // Internal: backing slice used for arena-free deinit.
    _raw_buf: []u8,

    pub fn sum(self: *const ValueWeights) f32 {
        return self.user_satisfaction + self.retention + self.revenue + self.safety;
    }
};

pub const ConsentTier = enum {
    minor,
    standard,
    major,
    critical,
};

pub const ConsentDefaults = struct {
    minor_tier_timeout_hours: u32,
    standard_tier_timeout_hours: u32,
    major_tier_timeout_hours: u32,
    critical_tier_requires_double_approval: bool,
    auto_approve_within_window: bool,

    _raw_buf: []u8,
};

pub const CohortSplitBy = enum {
    tenant_user_id,
    deal_segment,
    deal_size_bucket,

    pub fn fromString(s: []const u8) !CohortSplitBy {
        if (std.mem.eql(u8, s, "tenant_user_id")) return .tenant_user_id;
        if (std.mem.eql(u8, s, "deal_segment")) return .deal_segment;
        if (std.mem.eql(u8, s, "deal_size_bucket")) return .deal_size_bucket;
        return error.UnknownCohortSplit;
    }
};

pub const ExperimentDefaults = struct {
    min_sample_size: u32,
    min_duration_days: u32,
    max_concurrent_experiments_per_tenant: u8,
    cohort_split_by: CohortSplitBy,

    _raw_buf: []u8,
};

pub const ChannelTrigger = enum {
    e_saturated,
    user_quiet_24h,
    l5_about_to_apply,
    anomaly,
    experiment_done,
};

pub const ChannelRouting = struct {
    e_saturated: []const []const u8,
    user_quiet_24h: []const []const u8,
    l5_about_to_apply: []const []const u8,
    anomaly: []const []const u8,
    experiment_done: []const []const u8,

    _raw_buf: []u8,
};

pub const Rhythm = struct {
    cycle_interval_seconds: u32,
    kpi_refresh_interval_hours: u32,
    experiment_default_duration_days: u32,
    consent_batch_window_days: u32,

    _raw_buf: []u8,
};

pub const PrivacyFloor = enum {
    k_anonymous_5,
    k_anonymous_20,
    full_isolation,

    pub fn fromString(s: []const u8) !PrivacyFloor {
        if (std.mem.eql(u8, s, "k_anonymous_5")) return .k_anonymous_5;
        if (std.mem.eql(u8, s, "k_anonymous_20")) return .k_anonymous_20;
        if (std.mem.eql(u8, s, "full_isolation")) return .full_isolation;
        return error.UnknownPrivacyFloor;
    }
};

pub const CohortPolicy = struct {
    industry_cohorts_supported: []const []const u8,
    this_tenant_cohort: ?[]const u8,
    min_cohort_size_for_l1_propose: u8,
    privacy_floor: PrivacyFloor,

    _raw_buf: []u8,
};

pub const AuditLogConfig = struct {
    enabled: bool,
    retention_days: u32,
    include_llm_prompts: bool,
    include_llm_responses: bool,

    _raw_buf: []u8,
};

// ============================================================================
// Loader
// ============================================================================

pub const LoadError = error{
    FileNotFound,
    PermissionDenied,
    InvalidJson,
    SchemaVersionMismatch,
    UnknownProductType,
    UnknownAggregator,
    UnknownWindow,
    UnknownCohortSplit,
    UnknownPrivacyFloor,
    ValueWeightsDoNotSumToOne,
    CycleTooFast,
    KpiTooFast,
    KpiFlickersIntoE,
    MissingChannel,
    UnknownKpi,
    OutOfMemory,
};

/// Load a ProductIntent from a JSON file on disk.
///
/// The function is intentionally tolerant: it copies all strings into the
/// provided allocator so the caller can free the file buffer immediately.
/// On error, partial allocations are freed before returning.
///
/// 0.17 migration note: `std.fs.cwd()` was removed in Zig 0.17 dev
/// (see zig-0.17-compat memory). We use `std.c.open` directly, which
/// requires a sentinel-terminated path (`[:0]const u8`).
pub fn load(allocator: std.mem.Allocator, path: []const u8) LoadError!ProductIntent {
    // 0.17: std.fs.cwd() removed. std.c.open needs a sentinel-terminated
    // path; convert by duplicating with a null terminator.
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    // 0.17: std.c.O is a packed struct(u32) and exposes the per-target
    // O_* flags as packed-struct fields, but the field names differ by
    // target. The most portable approach is to construct the flag via
    // `@bitCast` from the bare POSIX integer. O_RDONLY = 0 on every
    // supported target. CLOEXEC is the default on Darwin so we omit it.
    const oflag: std.c.O = @bitCast(@as(u32, 0));
    const fd = std.c.open(path_z, oflag, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound; // coarse-grained; refine in v0.5
    defer _ = std.c.close(fd);

    // Read incrementally up to the 1 MB cap (+1 byte to detect overflow).
    // No std.c.Stat: its linux-gnu shape differs from darwin and we don't
    // need the size up front — read-to-EOF also removes the stat/read TOCTOU.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (buf.items.len > 1 * 1024 * 1024) return error.InvalidJson; // 1 MB hard cap
        const remaining = 1 * 1024 * 1024 + 1 - buf.items.len;
        const n = std.c.read(fd, &chunk, @min(chunk.len, remaining));
        if (n < 0) return error.InvalidJson;
        if (n == 0) break; // EOF
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    if (buf.items.len == 0) return error.InvalidJson;
    if (buf.items.len > 1 * 1024 * 1024) return error.InvalidJson;

    return parse(allocator, buf.items);
}

/// Parse a ProductIntent from an in-memory JSON buffer.
///
/// Public so callers can validate without touching disk (e.g. CI tests).
pub fn parse(allocator: std.mem.Allocator, json_buf: []const u8) LoadError!ProductIntent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_buf, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const obj = root.object;

    // schema_version
    const schema_version = getInt(obj, "schema_version") orelse return error.InvalidJson;
    if (schema_version != 1) return error.SchemaVersionMismatch;

    // top-level strings (duplicated to allocator)
    const product_id = try dupString(allocator, getString(obj, "product_id") orelse return error.InvalidJson);
    errdefer allocator.free(product_id);
    if (product_id.len == 0) return error.InvalidJson;

    const product_type_str = getString(obj, "product_type") orelse return error.InvalidJson;
    const product_type = ProductType.fromString(product_type_str) catch return error.UnknownProductType;

    const version = try dupString(allocator, getString(obj, "version") orelse return error.InvalidJson);
    errdefer allocator.free(version);
    if (version.len == 0) return error.InvalidJson;

    const update_epoch_raw = getInt(obj, "update_epoch") orelse return error.InvalidJson;
    if (update_epoch_raw <= 0) return error.InvalidJson;
    const update_epoch = @as(u64, @intCast(update_epoch_raw));
    const last_updated = @as(i64, @intCast(getInt(obj, "last_updated") orelse return error.InvalidJson));

    const approved_by = try dupString(allocator, getString(obj, "approved_by") orelse return error.InvalidJson);
    errdefer allocator.free(approved_by);
    if (approved_by.len == 0) return error.InvalidJson;

    // manifesto + sacrosanct
    const manifesto = try dupString(allocator, getString(obj, "manifesto") orelse return error.InvalidJson);
    errdefer allocator.free(manifesto);

    const sacrosanct_arr = getArray(obj, "sacrosanct") orelse return error.InvalidJson;
    var sacrosanct = try allocator.alloc([]const u8, sacrosanct_arr.items.len);
    var sacrosanct_filled: usize = 0;
    errdefer {
        for (sacrosanct[0..sacrosanct_filled]) |s| allocator.free(s);
        allocator.free(sacrosanct);
    }
    for (sacrosanct_arr.items, 0..) |item, i| {
        if (item != .string) return error.InvalidJson;
        sacrosanct[i] = try dupString(allocator, item.string);
        sacrosanct_filled = i + 1;
    }

    // KPI
    const north_star_kpi = try dupString(allocator, getString(obj, "north_star_kpi") orelse return error.InvalidJson);
    errdefer allocator.free(north_star_kpi);

    var secondary_kpis: []const []const u8 = &[_][]const u8{};
    var secondary_filled: usize = 0;
    errdefer {
        for (secondary_kpis[0..secondary_filled]) |s| allocator.free(s);
        allocator.free(secondary_kpis);
    }
    if (getArray(obj, "secondary_kpis")) |arr| {
        // Use mutable slice for fill; the eventual type is const.
        const allocated = try allocator.alloc([]const u8, arr.items.len);
        secondary_kpis = allocated;
        for (arr.items, 0..) |item, i| {
            if (item != .string) return error.InvalidJson;
            // alloc() returned *[]const u8; to write through it we cast
            // to a mutable view. The const-ness is restored once we
            // assign back to secondary_kpis on the next iteration.
            const slot: *[]const u8 = &allocated[i];
            slot.* = try dupString(allocator, item.string);
            secondary_filled = i + 1;
        }
    }

    const kpi_aggregator_str = getString(obj, "kpi_aggregator") orelse return error.InvalidJson;
    const kpi_aggregator = KpiAggregator.fromString(kpi_aggregator_str) catch return error.UnknownAggregator;

    const kpi_evaluation_window_str = getString(obj, "kpi_evaluation_window") orelse return error.InvalidJson;
    const kpi_evaluation_window = EvaluationWindow.fromString(kpi_evaluation_window_str) catch return error.UnknownWindow;

    // value_weights
    const vw_obj = getObject(obj, "value_weights") orelse return error.InvalidJson;
    const value_weights = ValueWeights{
        .user_satisfaction = getFloat(vw_obj, "user_satisfaction") orelse 0.0,
        .retention = getFloat(vw_obj, "retention") orelse 0.0,
        .revenue = getFloat(vw_obj, "revenue") orelse 0.0,
        .safety = getFloat(vw_obj, "safety") orelse 0.0,
        ._raw_buf = &.{},
    };
    if (@abs(value_weights.sum() - 1.0) > 0.001) return error.ValueWeightsDoNotSumToOne;

    // consent_defaults
    const cd_obj = getObject(obj, "consent_defaults") orelse return error.InvalidJson;
    const consent_defaults = ConsentDefaults{
        .minor_tier_timeout_hours = @as(u32, @intCast(getInt(cd_obj, "minor_tier_timeout_hours") orelse 24)),
        .standard_tier_timeout_hours = @as(u32, @intCast(getInt(cd_obj, "standard_tier_timeout_hours") orelse 72)),
        .major_tier_timeout_hours = @as(u32, @intCast(getInt(cd_obj, "major_tier_timeout_hours") orelse 168)),
        .critical_tier_requires_double_approval = getBool(cd_obj, "critical_tier_requires_double_approval") orelse true,
        .auto_approve_within_window = getBool(cd_obj, "auto_approve_within_window") orelse false,
        ._raw_buf = &.{},
    };

    // experiment_defaults (optional)
    var experiment_defaults = ExperimentDefaults{
        .min_sample_size = 30,
        .min_duration_days = 14,
        .max_concurrent_experiments_per_tenant = 2,
        .cohort_split_by = .tenant_user_id,
        ._raw_buf = &.{},
    };
    if (getObject(obj, "experiment_defaults")) |ed_obj| {
        experiment_defaults.min_sample_size = @as(u32, @intCast(getInt(ed_obj, "min_sample_size") orelse 30));
        experiment_defaults.min_duration_days = @as(u32, @intCast(getInt(ed_obj, "min_duration_days") orelse 14));
        experiment_defaults.max_concurrent_experiments_per_tenant = @as(u8, @intCast(getInt(ed_obj, "max_concurrent_experiments_per_tenant") orelse 2));
        if (getString(ed_obj, "cohort_split_by")) |cs| {
            experiment_defaults.cohort_split_by = CohortSplitBy.fromString(cs) catch return error.UnknownCohortSplit;
        }
    }

    // channel_routing
    const cr_obj = getObject(obj, "channel_routing") orelse return error.InvalidJson;
    const channel_routing = try parseChannelRouting(allocator, cr_obj);
    // Errdefer for cleanup if a later step fails. The ChannelRouting has
    // 5 trigger slices; we own the slices + the strings inside them.
    errdefer freeChannelRouting(allocator, channel_routing);

    // rhythm
    const r_obj = getObject(obj, "rhythm") orelse return error.InvalidJson;
    const rhythm = Rhythm{
        .cycle_interval_seconds = @as(u32, @intCast(getInt(r_obj, "cycle_interval_seconds") orelse 300)),
        .kpi_refresh_interval_hours = @as(u32, @intCast(getInt(r_obj, "kpi_refresh_interval_hours") orelse 24)),
        .experiment_default_duration_days = @as(u32, @intCast(getInt(r_obj, "experiment_default_duration_days") orelse 14)),
        .consent_batch_window_days = @as(u32, @intCast(getInt(r_obj, "consent_batch_window_days") orelse 7)),
        ._raw_buf = &.{},
    };
    if (rhythm.cycle_interval_seconds < 5) return error.CycleTooFast;
    if (rhythm.kpi_refresh_interval_hours < 1) return error.KpiTooFast;
    // Invariant: kpi_refresh * 3600 >= cycle * 10
    if (@as(u64, rhythm.kpi_refresh_interval_hours) * 3600 <
        @as(u64, rhythm.cycle_interval_seconds) * 10)
    {
        return error.KpiFlickersIntoE;
    }

    // cohort_policy (optional)
    var cohort_policy: ?CohortPolicy = null;
    if (getObject(obj, "cohort_policy")) |cp_obj| {
        const ic = getArray(cp_obj, "industry_cohorts_supported") orelse return error.InvalidJson;
        var cohorts = try allocator.alloc([]const u8, ic.items.len);
        // Errdefer: free individual strings + outer slice if a later
        // step fails. We track filled count via inline state.
        var filled: usize = 0;
        errdefer {
            for (cohorts[0..filled]) |s| allocator.free(s);
            allocator.free(cohorts);
        }
        for (ic.items, 0..) |item, i| {
            if (item != .string) return error.InvalidJson;
            const slot: *[]const u8 = @constCast(&cohorts[i]);
            slot.* = try dupString(allocator, item.string);
            filled = i + 1;
        }
        var this_cohort: ?[]const u8 = null;
        if (getString(cp_obj, "this_tenant_cohort")) |s| {
            this_cohort = try dupString(allocator, s);
        }
        errdefer if (this_cohort) |c| allocator.free(c);

        const pf_str = getString(cp_obj, "privacy_floor") orelse return error.InvalidJson;
        const privacy_floor = PrivacyFloor.fromString(pf_str) catch return error.UnknownPrivacyFloor;
        cohort_policy = CohortPolicy{
            .industry_cohorts_supported = cohorts,
            .this_tenant_cohort = this_cohort,
            .min_cohort_size_for_l1_propose = @as(u8, @intCast(getInt(cp_obj, "min_cohort_size_for_l1_propose") orelse 5)),
            .privacy_floor = privacy_floor,
            ._raw_buf = &.{},
        };
    }

    // audit_log
    const al_obj = getObject(obj, "audit_log") orelse return error.InvalidJson;
    const audit_log = AuditLogConfig{
        .enabled = getBool(al_obj, "enabled") orelse true,
        .retention_days = @as(u32, @intCast(getInt(al_obj, "retention_days") orelse 365)),
        .include_llm_prompts = getBool(al_obj, "include_llm_prompts") orelse true,
        .include_llm_responses = getBool(al_obj, "include_llm_responses") orelse true,
        ._raw_buf = &.{},
    };

    return ProductIntent{
        .allocator = allocator,
        .schema_version = @as(u32, @intCast(schema_version)),
        .product_id = product_id,
        .product_type = product_type,
        .version = version,
        .update_epoch = update_epoch,
        .last_updated = last_updated,
        .approved_by = approved_by,
        .manifesto = manifesto,
        .sacrosanct = sacrosanct,
        .north_star_kpi = north_star_kpi,
        .secondary_kpis = secondary_kpis,
        .kpi_aggregator = kpi_aggregator,
        .kpi_evaluation_window = kpi_evaluation_window,
        .value_weights = value_weights,
        .consent_defaults = consent_defaults,
        .experiment_defaults = experiment_defaults,
        .channel_routing = channel_routing,
        .rhythm = rhythm,
        .cohort_policy = cohort_policy,
        .audit_log = audit_log,
    };
}

fn parseChannelRouting(allocator: std.mem.Allocator, obj: std.json.ObjectMap) LoadError!ChannelRouting {
    var result = ChannelRouting{
        .e_saturated = &.{},
        .user_quiet_24h = &.{},
        .l5_about_to_apply = &.{},
        .anomaly = &.{},
        .experiment_done = &.{},
        ._raw_buf = &.{},
    };

    // Track completed triggers so errdefer can free all owned strings +
    // slices if a later trigger fails.
    const Completed = struct {
        slice: []const []const u8,
        filled: usize,
    };
    var completed: [5]Completed = undefined;
    var completed_count: usize = 0;
    errdefer {
        for (completed[0..completed_count]) |c| {
            for (c.slice[0..c.filled]) |s| allocator.free(s);
            allocator.free(c.slice);
        }
    }

    // Inline over triggers so @field can use comptime tag names.
    inline for (.{ .e_saturated, .user_quiet_24h, .l5_about_to_apply, .anomaly, .experiment_done }) |t| {
        const key = @tagName(t);
        const arr = getArray(obj, key) orelse return error.MissingChannel;
        if (arr.items.len == 0) return error.MissingChannel;
        const slice = try allocator.alloc([]const u8, arr.items.len);
        var filled: usize = 0;
        var committed = false;
        errdefer if (!committed) {
            for (slice[0..filled]) |s| allocator.free(s);
            allocator.free(slice);
        };
        for (arr.items, 0..) |item, i| {
            if (item != .string) return error.InvalidJson;
            const slot: *[]const u8 = @constCast(&slice[i]);
            slot.* = try dupString(allocator, item.string);
            filled = i + 1;
        }
        @field(result, key) = slice;
        completed[completed_count] = .{ .slice = slice, .filled = filled };
        completed_count += 1;
        committed = true;
    }
    return result;
}

/// Free all owned strings + slices in a ChannelRouting.
/// Mirrors the layout in parseChannelRouting.
fn freeChannelRouting(allocator: std.mem.Allocator, cr: ChannelRouting) void {
    const slices = [_][]const []const u8{
        cr.e_saturated,
        cr.user_quiet_24h,
        cr.l5_about_to_apply,
        cr.anomaly,
        cr.experiment_done,
    };
    for (slices) |slice| {
        for (slice) |s| allocator.free(s);
        allocator.free(slice);
    }
}

// ============================================================================
// JSON helper utilities (minimal, no external deps — fits zero-deps GHW style)
// ============================================================================

fn dupString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .integer => v.integer,
            .float => @as(i64, @intFromFloat(v.float)),
            else => null,
        };
    }
    return null;
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .float => @as(f32, @floatCast(v.float)),
            .integer => @as(f32, @floatFromInt(v.integer)),
            else => null,
        };
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |v| {
        if (v == .bool) return v.bool;
    }
    return null;
}

fn getArray(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    if (obj.get(key)) |v| {
        if (v == .array) return v.array;
    }
    return null;
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    if (obj.get(key)) |v| {
        if (v == .object) return v.object;
    }
    return null;
}

// ============================================================================
// Unit tests
// ============================================================================

test "load: crm example parses and validates" {
    const allocator = std.testing.allocator;

    // Try a few candidate paths so the test works whether zig test is
    // run from src/harness/ (worktree-relative) or from the worktree root.
    // The test is skipped (not failed) if no candidate resolves.
    const candidates = [_][]const u8{
        "product_intent.example.crm.json", // worktree root
        "../product_intent.example.crm.json", // src/harness/
    };
    var loaded = false;
    for (candidates) |cand| {
        var intent_opt: ?ProductIntent = null;
        if (load(allocator, cand)) |intent| {
            intent_opt = intent;
        } else |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        }
        if (intent_opt) |*intent| {
            defer intent.deinit();
            try std.testing.expectEqual(@as(u32, 1), intent.schema_version);
            try std.testing.expectEqual(ProductType.saas_web, intent.product_type);
            try std.testing.expectEqualStrings("nrr_quarterly", intent.north_star_kpi);
            try std.testing.expectEqual(@as(usize, 4), intent.secondary_kpis.len);
            try std.testing.expectEqual(@as(usize, 6), intent.sacrosanct.len);
            try std.testing.expect(intent.cohort_policy != null);
            try std.testing.expectEqual(PrivacyFloor.k_anonymous_20, intent.cohort_policy.?.privacy_floor);
            loaded = true;
            break;
        }
    }
    if (!loaded) return error.SkipZigTest;
}

test "parse: rejects bad schema_version" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 99,
        \\  "product_id": "x",
        \\  "product_type": "saas_web",
        \\  "version": "0.1",
        \\  "update_epoch": 1,
        \\  "last_updated": 0,
        \\  "approved_by": "x",
        \\  "manifesto": "",
        \\  "sacrosanct": [],
        \\  "north_star_kpi": "x",
        \\  "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":300,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.SchemaVersionMismatch, res);
}

test "parse: rejects value_weights not summing to 1" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "x", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": 1, "last_updated": 0, "approved_by": "x",
        \\  "manifesto": "", "sacrosanct": [],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.5,"retention":0.5,"revenue":0.5,"safety":0.5},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":300,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.ValueWeightsDoNotSumToOne, res);
}

test "parse: rejects cycle too fast" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "x", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": 1, "last_updated": 0, "approved_by": "x",
        \\  "manifesto": "", "sacrosanct": [],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":1,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.CycleTooFast, res);
}

test "parse: rejects KPI flickers into E" {
    const allocator = std.testing.allocator;
    // cycle=300, kpi=1h: 1*3600=3600 vs 300*10=3000 → 3600<3000 is false,
    // so this passes. We need kpi too small relative to cycle.
    // Try: cycle=600, kpi=1h: 1*3600=3600 vs 600*10=6000 → 3600<6000, fails.
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "x", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": 1, "last_updated": 0, "approved_by": "x",
        \\  "manifesto": "", "sacrosanct": [],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":600,"kpi_refresh_interval_hours":1}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.KpiFlickersIntoE, res);
}

test "parse: rejects missing channel" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "x", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": 1, "last_updated": 0, "approved_by": "x",
        \\  "manifesto": "", "sacrosanct": [],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":300,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.MissingChannel, res);
}

test "parse: rejects empty identity fields" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": 1, "last_updated": 0, "approved_by": "ops",
        \\  "manifesto": "x", "sacrosanct": ["do no harm"],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":300,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.InvalidJson, res);
}

test "parse: rejects non-positive update_epoch" {
    const allocator = std.testing.allocator;
    const bad_json =
        \\{
        \\  "schema_version": 1,
        \\  "product_id": "x", "product_type": "saas_web", "version": "0.1",
        \\  "update_epoch": -1, "last_updated": 0, "approved_by": "ops",
        \\  "manifesto": "x", "sacrosanct": ["do no harm"],
        \\  "north_star_kpi": "x", "kpi_aggregator": "mean",
        \\  "kpi_evaluation_window": "daily",
        \\  "value_weights": {"user_satisfaction":0.25,"retention":0.25,"revenue":0.25,"safety":0.25},
        \\  "consent_defaults": {},
        \\  "channel_routing": {
        \\    "e_saturated":["a"],"user_quiet_24h":["a"],"l5_about_to_apply":["a"],
        \\    "anomaly":["a"],"experiment_done":["a"]
        \\  },
        \\  "rhythm": {"cycle_interval_seconds":300,"kpi_refresh_interval_hours":24}
        \\}
    ;
    const res = parse(allocator, bad_json);
    try std.testing.expectError(error.InvalidJson, res);
}
