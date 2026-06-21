//! KpiBridge — 把产品 KPI 喂给数字生命的存在度 (ρ·K 项), 带防抖限频。
//!
//! 数据流:
//!   产品后端 (CRM/...) → feed(RawKpi)         [随时, 高频]
//!                       → maybeRefresh(ed, now) [按 kpi_refresh_interval 限频]
//!                       → crm_kpi.normalize + composite → K∈[0,1]
//!                       → ExistenceDegree.recordKpi(K)  → ρ·K 进入 E
//!
//! ## 为什么要限频 (anti-flicker 不变量)
//! 若每个 cycle 都把最新 KPI 灌进 E, E 会随 KPI 噪声抖动, 反而误导 L4 提议器。
//! ProductIntent.rhythm.kpi_refresh_interval_hours 被校验为 ≥ 10× cycle 间隔
//! (见 product_intent.zig)。本桥按该间隔限频: 两次 recordKpi 之间至少间隔
//! refresh_interval_seconds 秒。产品可任意高频 feed, 真正写入 E 的节奏由桥控制。

const std = @import("std");
const crm_kpi = @import("crm_kpi.zig");
const product_intent = @import("product_intent.zig");
const core = @import("../world/core.zig");

const ExistenceDegree = core.ExistenceDegree;
const RawKpi = crm_kpi.RawKpi;
const ValueWeights = product_intent.ValueWeights;
const ProductIntent = product_intent.ProductIntent;

pub const KpiBridge = struct {
    /// 复合 KPI 的价值权重 (来自 ProductIntent.value_weights)
    weights: ValueWeights,
    /// 北极星 KPI 是否是营收类 (决定 composite 是否给 revenue 轴 1.5× 加权)
    north_star_is_revenue: bool,
    /// 两次写入 E 的最小间隔 (秒) = kpi_refresh_interval_hours · 3600
    refresh_interval_seconds: u64,

    /// 上次写入 E 的 unix 时间 (仅在 ever_refreshed 为 true 时有意义)
    last_refresh_unix: i64 = 0,
    /// 是否曾写入过 E (首次 feed 后立即可刷新; 不用 0 当哨兵, 因 0 是合法时间戳)
    ever_refreshed: bool = false,
    /// 最近一次 feed 的原始 KPI
    last_raw: RawKpi = .{},
    /// 是否已有过有效 feed
    has_valid: bool = false,
    /// 已写入 E 的次数 (诊断)
    refresh_count: u64 = 0,

    pub fn init(weights: ValueWeights, north_star_is_revenue: bool, refresh_interval_seconds: u64) KpiBridge {
        return .{
            .weights = weights,
            .north_star_is_revenue = north_star_is_revenue,
            .refresh_interval_seconds = refresh_interval_seconds,
        };
    }

    /// 从 ProductIntent 构造 (取 value_weights / north_star / rhythm)。
    pub fn initFromIntent(intent: *const ProductIntent) KpiBridge {
        return init(
            intent.value_weights,
            isRevenueNorthStar(intent.north_star_kpi),
            @as(u64, intent.rhythm.kpi_refresh_interval_hours) * 3600,
        );
    }

    /// 产品后端喂入最新原始 KPI (高频可调; 非法值被忽略)。
    pub fn feed(self: *KpiBridge, raw: RawKpi) void {
        if (raw.isValid()) {
            self.last_raw = raw;
            self.has_valid = true;
        }
    }

    /// 当前复合 K∈[0,1] (不写入 E, 供 UI / 诊断)。无有效 feed 返回 null。
    pub fn currentComposite(self: *const KpiBridge) ?f32 {
        if (!self.has_valid) return null;
        const norm = crm_kpi.normalize(self.last_raw);
        return crm_kpi.composite(norm, self.weights, self.north_star_is_revenue);
    }

    /// 按限频把最新 K 写入 ed.recordKpi。返回是否真的写入了。
    /// 首次立即写; 之后需间隔 ≥ refresh_interval_seconds。
    pub fn maybeRefresh(self: *KpiBridge, ed: *ExistenceDegree, now_unix: i64) bool {
        const k = self.currentComposite() orelse return false;
        if (self.ever_refreshed) {
            const elapsed = now_unix - self.last_refresh_unix;
            if (elapsed < @as(i64, @intCast(self.refresh_interval_seconds))) return false;
        }
        ed.recordKpi(k);
        self.last_refresh_unix = now_unix;
        self.ever_refreshed = true;
        self.refresh_count += 1;
        return true;
    }
};

/// 北极星 KPI 名是否营收类 (用于 composite 的 revenue 轴加权)。
fn isRevenueNorthStar(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "revenue") != null or
        std.mem.indexOf(u8, name, "win") != null or
        std.mem.indexOf(u8, name, "deal") != null or
        std.mem.indexOf(u8, name, "arr") != null;
}

// ===================== Tests =====================

const testing = std.testing;

fn testWeights() ValueWeights {
    return .{
        .user_satisfaction = 0.25,
        .retention = 0.30,
        .revenue = 0.35,
        .safety = 0.10,
        ._raw_buf = &.{},
    };
}

test "KpiBridge: feed + 首次 maybeRefresh 写入 E (ρ·K 生效)" {
    var ed: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };
    const e_before = ed.e();
    try testing.expect(!ed.kpi_enabled);

    var bridge = KpiBridge.init(testWeights(), true, 24 * 3600);
    // best-in-class KPI ⇒ K≈1.0 ⇒ kpi_term≈0 ⇒ E 几乎不变
    bridge.feed(.{ .nrr_quarterly = 1.20, .deal_win_rate = 0.40, .sales_cycle_days_p50 = 20, .weekly_active_sales_pct = 0.95 });
    try testing.expect(bridge.maybeRefresh(&ed, 1000));
    try testing.expect(ed.kpi_enabled);
    try testing.expectApproxEqAbs(e_before, ed.e(), 1e-4);

    // 差 KPI ⇒ K 低 ⇒ E 被扣分。但 24h 内不会再刷新 (限频)
    bridge.feed(.{ .nrr_quarterly = 0.85, .deal_win_rate = 0.10, .sales_cycle_days_p50 = 90, .weekly_active_sales_pct = 0.40 });
    try testing.expect(!bridge.maybeRefresh(&ed, 1000 + 3600)); // 仅过 1h < 24h
    try testing.expectApproxEqAbs(e_before, ed.e(), 1e-4); // E 未变 (还是上次的 K)
}

test "KpiBridge: 限频 — 间隔不足拒绝, 足够才写入" {
    var ed: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };
    var bridge = KpiBridge.init(testWeights(), true, 24 * 3600);

    bridge.feed(.{ .nrr_quarterly = 1.00, .deal_win_rate = 0.25, .sales_cycle_days_p50 = 55, .weekly_active_sales_pct = 0.675 });
    try testing.expect(bridge.maybeRefresh(&ed, 0)); // 首次写入
    try testing.expectEqual(@as(u64, 1), bridge.refresh_count);

    // 23h59m 后仍拒绝
    try testing.expect(!bridge.maybeRefresh(&ed, 24 * 3600 - 60));
    try testing.expectEqual(@as(u64, 1), bridge.refresh_count);
    // 满 24h 后写入
    try testing.expect(bridge.maybeRefresh(&ed, 24 * 3600));
    try testing.expectEqual(@as(u64, 2), bridge.refresh_count);
}

test "KpiBridge: 无 feed 时 maybeRefresh 不写入" {
    var ed: ExistenceDegree = .{};
    var bridge = KpiBridge.init(testWeights(), true, 3600);
    try testing.expect(!bridge.maybeRefresh(&ed, 9999));
    try testing.expect(!ed.kpi_enabled);
    try testing.expectEqual(@as(?f32, null), bridge.currentComposite());
}

test "KpiBridge: 非法 KPI 被忽略" {
    var bridge = KpiBridge.init(testWeights(), true, 3600);
    bridge.feed(.{ .nrr_quarterly = 5.0 }); // 越界
    try testing.expect(!bridge.has_valid);
    try testing.expectEqual(@as(?f32, null), bridge.currentComposite());
}

test "KpiBridge: 差 KPI 通过桥确实压低 E" {
    var ed: ExistenceDegree = .{ .v = .{ .material = 0.5, .representation = 0.5, .nature = 0.5 } };
    const e_neutral = ed.e();
    var bridge = KpiBridge.init(testWeights(), true, 3600);
    bridge.feed(.{ .nrr_quarterly = 0.85, .deal_win_rate = 0.10, .sales_cycle_days_p50 = 90, .weekly_active_sales_pct = 0.40 });
    try testing.expect(bridge.maybeRefresh(&ed, 0));
    try testing.expect(ed.e() < e_neutral); // K≈0 ⇒ ρ·K_signed = 0.15·(0-1)·2 = -0.30
}

test "isRevenueNorthStar" {
    try testing.expect(isRevenueNorthStar("deal_win_rate"));
    try testing.expect(isRevenueNorthStar("quarterly_revenue"));
    try testing.expect(!isRevenueNorthStar("nrr_quarterly"));
}
