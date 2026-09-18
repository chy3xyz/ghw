//! existence_phase — 求存外环相 + 进化内环危机锁 (AWAKENING_LIFECYCLE P0)
//!
//! Phase 决定「当前该急什么」; 危机锁决定 L4/L5 是否允许跑。
//! 不改 E 公理; LLM 不选相。

const std = @import("std");
const F = @import("../util/math.zig").F;
const primordial_laws = @import("primordial_laws.zig");

pub const Phase = enum {
    awakening,
    crisis,
    explore,
    steady,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .awakening => "awakening",
            .crisis => "crisis",
            .explore => "explore",
            .steady => "steady",
        };
    }
};

/// 由觉醒/危机/平衡/价值 推导当前相
pub fn compute(
    awakened: bool,
    host_crisis: bool,
    e: F,
    mrn_balanced: bool,
    value_ok: bool,
) Phase {
    if (!awakened) return .awakening;
    if (host_crisis) return .crisis;
    if (mrn_balanced and value_ok and e >= 0.55) return .steady;
    return .explore;
}

/// 危机时禁止重编译进化 (L4/L5); L1–L3 仍可跑 (L3 降频由 caller 处理)
pub fn heavyEvolveAllowed(host_crisis: bool, level: u8) bool {
    if (!host_crisis) return true;
    return level <= 3; // 允许 L1/L2/L3; 下面会对 L3 再降频
}

/// 危机时 L3 间隔加倍; L4/L5 视为禁用 (返回 0)
pub fn evolveInterval(level: u8, host_crisis: bool) u64 {
    const base: u64 = switch (level) {
        1, 2 => 32,
        3 => 64,
        4 => 96,
        5 => 192,
        else => 64,
    };
    if (!host_crisis) return base;
    return switch (level) {
        1, 2 => base,
        3 => base * 2,
        4, 5 => 0, // 禁用
        else => base,
    };
}

pub fn isDue(tick: u64, last_tick: u64, interval: u64) bool {
    if (interval == 0) return false;
    if (tick == 0) return false;
    if (tick == last_tick) return false;
    return tick % interval == 0;
}

pub fn mrnBalanced(m: F, r: F, n: F) bool {
    const mean = (m + r + n) / 3.0;
    const dm = m - mean;
    const dr = r - mean;
    const dn = n - mean;
    const var_ = (dm * dm + dr * dr + dn * dn) / 3.0;
    return var_ < 0.01 and @min(m, @min(r, n)) > 0.35;
}

pub fn valueOk(value_trend: F) bool {
    return value_trend >= -primordial_laws.ProposeTriggers.VALUE_DECLINE_EPS;
}

/// 稳态门槛 (steady 相可视化)
pub const SteadyGates = struct {
    mrn_balanced: bool = false,
    value_ok: bool = false,
    e_ok: bool = false,

    pub fn allOk(self: SteadyGates) bool {
        return self.mrn_balanced and self.value_ok and self.e_ok;
    }
};

pub fn steadyGates(m: F, r: F, n: F, e: F, value_trend: F) SteadyGates {
    return .{
        .mrn_balanced = mrnBalanced(m, r, n),
        .value_ok = valueOk(value_trend),
        .e_ok = e >= 0.55,
    };
}

const testing = std.testing;

test "existence_phase: awaken then crisis then steady" {
    try testing.expect(compute(false, false, 0.9, true, true) == .awakening);
    try testing.expect(compute(true, true, 0.9, true, true) == .crisis);
    try testing.expect(compute(true, false, 0.7, true, true) == .steady);
    try testing.expect(compute(true, false, 0.4, false, true) == .explore);
}

test "existence_phase: crisis blocks L4/L5 intervals" {
    try testing.expectEqual(@as(u64, 0), evolveInterval(4, true));
    try testing.expectEqual(@as(u64, 0), evolveInterval(5, true));
    try testing.expectEqual(@as(u64, 128), evolveInterval(3, true));
    try testing.expect(heavyEvolveAllowed(true, 2));
    try testing.expect(heavyEvolveAllowed(true, 3));
    try testing.expect(!isDue(96, 0, 0));
    try testing.expect(isDue(96, 0, 96));
}
