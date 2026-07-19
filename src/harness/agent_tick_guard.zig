//! agent.tick 持久化 sanity check — 防止 Unix 时间戳或异常大值污染 state.json。

const std = @import("std");

/// 正常长跑 agent.tick 不应超过此值 (约 31.7 年 @ 1 tick/s)。
pub const DEFAULT_MAX_AGENT_TICK: u64 = 1_000_000_000;

pub const SanitizeResult = struct {
    tick: u64,
    reset: bool,
    reason: []const u8,
};

/// 校验从 snapshot/WAL 读出的 agent.tick。
/// `now_unix`: 当前 wall-clock 秒 (用于识别误写的 Unix 时间戳)。
pub fn sanitizeAgentTick(stored: u64, now_unix: u64, max_tick: u64) SanitizeResult {
    if (stored == 0) return .{ .tick = 0, .reset = false, .reason = "ok" };
    if (now_unix > 0 and stored > now_unix) {
        return .{ .tick = 0, .reset = true, .reason = "tick_gt_unix_now" };
    }
    // 1e9..now 且落在 2001-2038 典型 Unix 秒区间 → 历史误写 (先于 max 检查)
    if (stored >= 1_000_000_000 and now_unix > 0 and stored <= now_unix and stored >= 978_307_200) {
        return .{ .tick = 0, .reset = true, .reason = "looks_like_unix_timestamp" };
    }
    if (stored > max_tick) {
        return .{ .tick = 0, .reset = true, .reason = "exceeds_max_agent_tick" };
    }
    return .{ .tick = stored, .reset = false, .reason = "ok" };
}

const testing = std.testing;

test "sanitizeAgentTick: rejects billion-scale unix-like tick" {
    const now: u64 = 1_786_000_000; // ~2026
    const r = sanitizeAgentTick(1_477_035_291, now, DEFAULT_MAX_AGENT_TICK);
    try testing.expect(r.reset);
    try testing.expectEqual(@as(u64, 0), r.tick);
    try testing.expectEqualStrings("looks_like_unix_timestamp", r.reason);
}

test "sanitizeAgentTick: keeps normal small tick" {
    const r = sanitizeAgentTick(42_000, 1_786_000_000, DEFAULT_MAX_AGENT_TICK);
    try testing.expect(!r.reset);
    try testing.expectEqual(@as(u64, 42_000), r.tick);
}

test "sanitizeAgentTick: rejects above max after unix check" {
    const r = sanitizeAgentTick(200_000, 1_786_000_000, 100_000);
    try testing.expect(r.reset);
    try testing.expectEqualStrings("exceeds_max_agent_tick", r.reason);
}
