//! host_profile — 统一宿主抽象 (desktop | mobile) (AWAKENING P2)
//!
//! Sense 阶段用同一 Profile 描述电脑/手机生存环境。
//! 桌面由 SystemCollector 填充; 手机经 pushMobile 注入 (SDK/宿主 App)。
//! LLM 不决定危机; 只产出可审计信号供 host_shortfall 消费。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const SystemSnapshot = @import("system_collector.zig").SystemSnapshot;
const primordial_laws = @import("primordial_laws.zig");

pub const Kind = enum {
    desktop,
    mobile,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .desktop => "desktop",
            .mobile => "mobile",
        };
    }

    pub fn parse(s: []const u8) Kind {
        if (std.mem.eql(u8, s, "mobile")) return .mobile;
        return .desktop;
    }
};

pub const Profile = struct {
    kind: Kind = .desktop,
    /// 手机电量 0..100; null = 未知/不适用
    battery_pct: ?F = null,
    thermal_hot: bool = false,
    /// 后台受限 (iOS 杀后台 / Doze)
    bg_restricted: bool = false,
    /// 镜像桌面压力 (from SystemSnapshot)
    mem_pct: F = 0,
    disk_used_pct: F = 0,
    load_1m: F = 0,
    /// 最近一次更新 unix 秒
    updated_at_unix: i64 = 0,

    pub fn fromDesktop(snap: SystemSnapshot, now_unix: i64) Profile {
        return .{
            .kind = .desktop,
            .battery_pct = null,
            .thermal_hot = false,
            .bg_restricted = false,
            .mem_pct = snap.mem_pct,
            .disk_used_pct = snap.disk_used_pct,
            .load_1m = snap.load_1m,
            .updated_at_unix = now_unix,
        };
    }

    /// 宿主 App / SDK 推送手机信号 (不采样设备 API)
    pub fn pushMobile(self: *Profile, battery_pct: ?F, thermal_hot: bool, bg_restricted: bool, now_unix: i64) void {
        self.kind = .mobile;
        self.battery_pct = battery_pct;
        self.thermal_hot = thermal_hot;
        self.bg_restricted = bg_restricted;
        self.updated_at_unix = now_unix;
    }

    /// 手机侧是否构成 material 危机
    pub fn mobileCrisis(self: Profile) bool {
        if (self.kind != .mobile) return false;
        if (self.thermal_hot) return true;
        if (self.battery_pct) |b| {
            if (b <= primordial_laws.HostCrisis.BATTERY_LOW_PCT) return true;
        }
        return false;
    }

    /// 叠加到短板 material 的增量 [0,1]
    pub fn materialBoost(self: Profile) F {
        var boost: F = 0;
        if (self.kind != .mobile) return 0;
        if (self.battery_pct) |b| {
            if (b <= primordial_laws.HostCrisis.BATTERY_LOW_PCT) {
                boost += 0.50;
            } else if (b <= 30.0) {
                boost += 0.25;
            }
        }
        if (self.thermal_hot) boost += 0.35;
        if (self.bg_restricted) boost += 0.20;
        return @min(1.0, boost);
    }

    pub fn toJson(self: Profile, alloc: Allocator) ![]u8 {
        if (self.battery_pct) |b| {
            return std.fmt.allocPrint(alloc,
                \\{{"kind":"{s}","battery_pct":{d:.1},"thermal_hot":{s},"bg_restricted":{s},"mem_pct":{d:.1},"disk_used_pct":{d:.1},"load_1m":{d:.2},"updated_at_unix":{d}}}
            , .{
                self.kind.label(),
                b,
                if (self.thermal_hot) "true" else "false",
                if (self.bg_restricted) "true" else "false",
                self.mem_pct,
                self.disk_used_pct,
                self.load_1m,
                self.updated_at_unix,
            });
        }
        return std.fmt.allocPrint(alloc,
            \\{{"kind":"{s}","battery_pct":null,"thermal_hot":{s},"bg_restricted":{s},"mem_pct":{d:.1},"disk_used_pct":{d:.1},"load_1m":{d:.2},"updated_at_unix":{d}}}
        , .{
            self.kind.label(),
            if (self.thermal_hot) "true" else "false",
            if (self.bg_restricted) "true" else "false",
            self.mem_pct,
            self.disk_used_pct,
            self.load_1m,
            self.updated_at_unix,
        });
    }

    pub fn appendJson(self: Profile, alloc: Allocator, body: *std.ArrayList(u8)) !void {
        const j = try self.toJson(alloc);
        defer alloc.free(j);
        try body.appendSlice(alloc, j);
    }
};

const testing = std.testing;

test "host_profile: desktop from snap" {
    const snap: SystemSnapshot = .{
        .cpu_user_pct = 10,
        .cpu_sys_pct = 5,
        .cpu_idle_pct = 85,
        .mem_used_gb = 8,
        .mem_total_gb = 16,
        .mem_pct = 50,
        .disk_used_pct = 40,
        .load_1m = 1.2,
        .proc_count = 100,
        .net_in_mbps = 0,
        .net_out_mbps = 0,
        .disk_read_mbps = 0,
        .disk_write_mbps = 0,
        .hour = 12,
        .weekday = 1,
        .timestamp = 0,
    };
    const p = Profile.fromDesktop(snap, 100);
    try testing.expect(p.kind == .desktop);
    try testing.expectApproxEqAbs(@as(F, 50), p.mem_pct, 0.01);
    try testing.expect(!p.mobileCrisis());
    try testing.expectApproxEqAbs(@as(F, 0), p.materialBoost(), 0.001);
}

test "host_profile: mobile low battery is crisis" {
    var p: Profile = .{};
    p.pushMobile(10.0, false, false, 200);
    try testing.expect(p.kind == .mobile);
    try testing.expect(p.mobileCrisis());
    try testing.expect(p.materialBoost() >= 0.45);
}

test "host_profile: toJson contains kind" {
    const alloc = testing.allocator;
    var p: Profile = .{};
    p.pushMobile(50.0, true, true, 1);
    const j = try p.toJson(alloc);
    defer alloc.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"kind\":\"mobile\"") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"thermal_hot\":true") != null);
}
