//! host_shortfall — 宿主信号 → 存在短板报告 (AWAKENING_LIFECYCLE P0)
//!
//! 把 disk/mem/load、外网真空、社会真空映射到 M/R/N 权重,
//! 供 TaskBias 旁路提示、RuleProposer、UI provenance 共用。
//! LLM 不决定; 只产出可审计报告。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const primordial_laws = @import("primordial_laws.zig");
const survival_learn = @import("survival_learn.zig");

pub const Report = struct {
    host_crisis: bool = false,
    material: F = 0,
    representation: F = 0,
    nature: F = 0,
    /// argmax 维: 1=M 2=R 3=N; 0=无显著短板
    favored_dim: u8 = 0,
    disk_hot: bool = false,
    mem_hot: bool = false,
    load_hot: bool = false,
    world_starve: bool = false,
    social_starve: bool = false,
    e_saturated: bool = false,
    /// P2 mobile
    battery_low: bool = false,
    thermal_hot: bool = false,
    bg_restricted: bool = false,

    pub fn hasSignal(self: Report) bool {
        return self.host_crisis or self.world_starve or self.social_starve or self.e_saturated or
            self.battery_low or self.thermal_hot;
    }
};

pub fn assess(
    snap: ?SystemSnapshot,
    e: F,
    world_fetch_count: u32,
    live_peers: u32,
    value_trend: F,
) Report {
    return assessWithProfile(snap, e, world_fetch_count, live_peers, value_trend, null);
}

pub fn assessWithProfile(
    snap: ?SystemSnapshot,
    e: F,
    world_fetch_count: u32,
    live_peers: u32,
    value_trend: F,
    profile: ?@import("host_profile.zig").Profile,
) Report {
    var out: Report = .{};
    if (snap) |s| {
        out.host_crisis = survival_learn.isCrisisSnap(s);
        out.disk_hot = s.disk_used_pct >= primordial_laws.HostCrisis.DISK_PCT_EPS;
        out.mem_hot = s.mem_pct >= primordial_laws.HostCrisis.MEM_PCT_EPS;
        // L07: 负载按每核归一 (load ≥ n_cpus = 全核饱和)
        out.load_hot = s.load_1m >= primordial_laws.HostCrisis.LOAD_EPS_PER_CORE * @as(F, @floatFromInt(@max(s.n_cpus, 1)));
        if (out.disk_hot) out.material += 0.45;
        if (out.mem_hot) out.material += 0.35;
        if (out.load_hot) out.material += 0.30;
    }
    if (profile) |p| {
        out.battery_low = if (p.battery_pct) |b| b <= primordial_laws.HostCrisis.BATTERY_LOW_PCT else false;
        out.thermal_hot = p.thermal_hot;
        out.bg_restricted = p.bg_restricted;
        out.material += p.materialBoost();
        if (p.mobileCrisis()) out.host_crisis = true;
    }
    // 外网长期真空 → R
    if (world_fetch_count == 0) {
        out.world_starve = true;
        out.representation += 0.40;
    }
    // 无同伴 + 价值下滑 → N
    if (live_peers == 0) {
        out.social_starve = true;
        out.nature += 0.25;
    }
    if (value_trend < -primordial_laws.ProposeTriggers.VALUE_DECLINE_EPS) {
        out.social_starve = true;
        out.nature += 0.35;
    }
    if (e >= primordial_laws.ProposeTriggers.E_SATURATED) {
        out.e_saturated = true;
        out.nature += 0.15;
    }

    out.material = @min(1.0, out.material);
    out.representation = @min(1.0, out.representation);
    out.nature = @min(1.0, out.nature);

    if (out.material >= out.representation and out.material >= out.nature and out.material > 0.05) {
        out.favored_dim = 1;
    } else if (out.representation >= out.nature and out.representation > 0.05) {
        out.favored_dim = 2;
    } else if (out.nature > 0.05) {
        out.favored_dim = 3;
    }
    return out;
}

pub fn appendJson(alloc: Allocator, body: *std.ArrayList(u8), r: Report) !void {
    try body.print(alloc,
        \\{{"host_crisis":{s},"material":{d:.3},"representation":{d:.3},"nature":{d:.3},"favored_dim":{d},"disk_hot":{s},"mem_hot":{s},"load_hot":{s},"world_starve":{s},"social_starve":{s},"e_saturated":{s},"battery_low":{s},"thermal_hot":{s},"bg_restricted":{s}}}
    , .{
        if (r.host_crisis) "true" else "false",
        r.material,
        r.representation,
        r.nature,
        r.favored_dim,
        if (r.disk_hot) "true" else "false",
        if (r.mem_hot) "true" else "false",
        if (r.load_hot) "true" else "false",
        if (r.world_starve) "true" else "false",
        if (r.social_starve) "true" else "false",
        if (r.e_saturated) "true" else "false",
        if (r.battery_low) "true" else "false",
        if (r.thermal_hot) "true" else "false",
        if (r.bg_restricted) "true" else "false",
    });
}

fn extractBool(hay: []const u8, key: []const u8) bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return false;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return false;
    var i = pos + needle.len;
    while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
    return i + 4 <= hay.len and std.mem.eql(u8, hay[i .. i + 4], "true");
}

fn extractFloat(hay: []const u8, key: []const u8) F {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return 0;
    var i = pos + needle.len;
    while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < hay.len and (hay[i] == '.' or hay[i] == '-' or (hay[i] >= '0' and hay[i] <= '9'))) : (i += 1) {}
    if (i == start) return 0;
    return std.fmt.parseFloat(F, hay[start..i]) catch 0;
}

fn extractU8(hay: []const u8, key: []const u8) u8 {
    return @intFromFloat(@min(255, extractFloat(hay, key)));
}

/// 从 JSON 对象 (或含 report 嵌套) 解析 Report; 失败返回 null
pub fn parseJson(hay: []const u8) ?Report {
    // 优先嵌套 "report":{...}
    const body = blk: {
        if (std.mem.indexOf(u8, hay, "\"report\":")) |rp| {
            const os = std.mem.indexOfPos(u8, hay, rp, "{") orelse break :blk hay;
            const oe = findBrace(hay, os) orelse break :blk hay;
            break :blk hay[os .. oe + 1];
        }
        break :blk hay;
    };
    if (std.mem.indexOf(u8, body, "\"host_crisis\":") == null and
        std.mem.indexOf(u8, body, "\"favored_dim\":") == null)
    {
        return null;
    }
    return .{
        .host_crisis = extractBool(body, "host_crisis"),
        .material = extractFloat(body, "material"),
        .representation = extractFloat(body, "representation"),
        .nature = extractFloat(body, "nature"),
        .favored_dim = extractU8(body, "favored_dim"),
        .disk_hot = extractBool(body, "disk_hot"),
        .mem_hot = extractBool(body, "mem_hot"),
        .load_hot = extractBool(body, "load_hot"),
        .world_starve = extractBool(body, "world_starve"),
        .social_starve = extractBool(body, "social_starve"),
        .e_saturated = extractBool(body, "e_saturated"),
        .battery_low = extractBool(body, "battery_low"),
        .thermal_hot = extractBool(body, "thermal_hot"),
        .bg_restricted = extractBool(body, "bg_restricted"),
    };
}

fn findBrace(json: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        if (in_string) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 1;
                continue;
            }
            if (json[i] == '"') in_string = false;
            continue;
        }
        switch (json[i]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

pub fn dimName(favored: u8) []const u8 {
    return switch (favored) {
        1 => "material",
        2 => "representation",
        3 => "nature",
        else => "none",
    };
}

const testing = std.testing;

fn sampleSnap(disk: F, mem: F, load: F) SystemSnapshot {
    return .{
        .cpu_user_pct = 10,
        .cpu_sys_pct = 5,
        .cpu_idle_pct = 85,
        .mem_used_gb = 8,
        .mem_total_gb = 16,
        .mem_pct = mem,
        .disk_used_pct = disk,
        .load_1m = load,
        .proc_count = 200,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
}

test "host_shortfall: disk crisis favors material" {
    const r = assess(sampleSnap(95, 40, 1), 0.5, 3, 1, 0);
    try testing.expect(r.host_crisis);
    try testing.expect(r.disk_hot);
    try testing.expectEqual(@as(u8, 1), r.favored_dim);
}

test "host_shortfall: world starve favors representation" {
    const r = assess(sampleSnap(40, 30, 1), 0.6, 0, 2, 0);
    try testing.expect(r.world_starve);
    try testing.expectEqual(@as(u8, 2), r.favored_dim);
}

test "host_shortfall: social starve favors nature" {
    const r = assess(sampleSnap(40, 30, 1), 0.6, 5, 0, -0.01);
    try testing.expect(r.social_starve);
    try testing.expectEqual(@as(u8, 3), r.favored_dim);
}

test "host_shortfall: mobile battery raises material crisis" {
    var profile = @import("host_profile.zig").Profile{};
    profile.pushMobile(8.0, false, false, 1);
    const r = assessWithProfile(sampleSnap(40, 30, 1), 0.6, 5, 2, 0, profile);
    try testing.expect(r.host_crisis);
    try testing.expect(r.battery_low);
    try testing.expectEqual(@as(u8, 1), r.favored_dim);
}

test "host_shortfall: parseJson roundtrip fields" {
    const alloc = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    const r0: Report = .{ .host_crisis = true, .favored_dim = 1, .material = 0.45, .disk_hot = true };
    try appendJson(alloc, &body, r0);
    const r1 = parseJson(body.items).?;
    try testing.expect(r1.host_crisis);
    try testing.expect(r1.disk_hot);
    try testing.expectEqual(@as(u8, 1), r1.favored_dim);
}
