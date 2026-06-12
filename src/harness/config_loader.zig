//! ConfigLoader: SelfEvolutionGuard 配置热加载
//!
//! 创造性: 数字生命运行时可以从外部 JSON 加载新的安全规则
//!   - 不用重新编译
//!   - 不用重启
//!   - 可以动态收紧/放宽安全策略
//!
//! 配置文件格式 (.ghw_guard.json):
//! ```json
//! {
//!   "whitelist": [
//!     "src/agent/params.zig",
//!     "src/goal/methods/"
//!   ],
//!   "forbidden_symbols": [
//!     "ExistenceDegree",
//!     "harm:human",
//!     ...
//!   ],
//!   "invariants": [
//!     "alpha", "beta", "gamma", "E", "存在增益"
//!   ],
//!   "max_diff_lines": 50
//! }
//! ```
//!
//! 工作流:
//!   1. 用户编辑 .ghw_guard.json
//!   2. SelfEvolutionGuard.loadFromFile() 重新读
//!   3. 新规则立即生效

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// 配置内容
pub const GuardConfig = struct {
    whitelist: [][]u8 = &.{},
    forbidden_symbols: [][]u8 = &.{},
    invariants: [][]u8 = &.{},
    max_diff_lines: usize = 50,

    pub fn deinit(self: *GuardConfig, allocator: Allocator) void {
        for (self.whitelist) |s| allocator.free(s);
        allocator.free(self.whitelist);
        for (self.forbidden_symbols) |s| allocator.free(s);
        allocator.free(self.forbidden_symbols);
        for (self.invariants) |s| allocator.free(s);
        allocator.free(self.invariants);
    }
};

pub const ConfigLoader = struct {
    allocator: Allocator,
    last_path: ?[]u8 = null,

    pub fn init(allocator: Allocator) ConfigLoader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConfigLoader) void {
        if (self.last_path) |p| self.allocator.free(p);
    }

    /// 极简 JSON 解析 (无依赖)
    /// 我们的格式是: {"whitelist": ["a", "b"], "forbidden_symbols": [...], ...}
    /// 简化: 用 grep 风格找 key 后的数组
    pub fn loadFromString(self: *ConfigLoader, json: []const u8) !GuardConfig {
        var config: GuardConfig = .{};
        errdefer config.deinit(self.allocator);

        // 解析 whitelist
        if (try self.parseStringArray(json, "whitelist")) |arr| {
            config.whitelist = @constCast(arr);
        }
        // 解析 forbidden_symbols
        if (try self.parseStringArray(json, "forbidden_symbols")) |arr| {
            config.forbidden_symbols = @constCast(arr);
        }
        // 解析 invariants
        if (try self.parseStringArray(json, "invariants")) |arr| {
            config.invariants = @constCast(arr);
        }
        // 解析 max_diff_lines
        if (try self.parseNumber(json, "max_diff_lines")) |n| {
            config.max_diff_lines = @intFromFloat(n);
        }

        return config;
    }

    /// 简化: 直接构造 GuardConfig (无文件 IO)
    /// 真实部署时用 std.Io.Dir
    pub fn loadDefault(_: *ConfigLoader) GuardConfig {
        return .{
            .whitelist = &[_][]const u8{},
            .forbidden_symbols = &[_][]const u8{},
            .invariants = &[_][]const u8{},
            .max_diff_lines = 50,
        };
    }

    /// 解析 JSON 中的字符串数组: "key": ["a", "b", "c"]
    fn parseStringArray(self: *ConfigLoader, json: []const u8, key: []const u8) !?[]const []u8 {
        const key_pattern = try std.fmt.allocPrint(self.allocator, "\"{s}\": [", .{key});
        defer self.allocator.free(key_pattern);
        const idx = mem.indexOf(u8, json, key_pattern) orelse return null;
        // 找到 '[' 后的开始
        const array_start = idx + key_pattern.len;
        // 找匹配的 ']' (限制在合理范围内)
        const end = mem.indexOfPos(u8, json, array_start, "]") orelse return null;
        // 限制搜索范围: 只在 array slice 内
        const array_slice = json[array_start..end];
        var items: std.ArrayList([]u8) = .empty;
        defer items.deinit(self.allocator);
        var pos: usize = 0;
        while (pos < array_slice.len) {
            // 找下一个 "
            const q1_rel = mem.indexOfScalar(u8, array_slice[pos..], '"') orelse break;
            const q1 = pos + q1_rel;
            if (q1 + 1 >= array_slice.len) break;
            const q2_rel = mem.indexOfScalar(u8, array_slice[q1 + 1 ..], '"') orelse break;
            const q2 = q1 + 1 + q2_rel;
            const item = try self.allocator.dupe(u8, array_slice[q1 + 1 .. q2]);
            try items.append(self.allocator, item);
            pos = q2 + 1;
        }
        if (items.items.len == 0) return null;
        const result = try self.allocator.alloc([]u8, items.items.len);
        @memcpy(result, items.items);
        return result;
    }

    /// 解析 JSON 中的数字: "key": 50
    fn parseNumber(self: *ConfigLoader, json: []const u8, key: []const u8) !?f64 {
        const key_pattern = try std.fmt.allocPrint(self.allocator, "\"{s}\": ", .{key});
        defer self.allocator.free(key_pattern);
        const idx = mem.indexOf(u8, json, key_pattern) orelse return null;
        var end = idx + key_pattern.len;
        while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != '\n') : (end += 1) {}
        const num_str = std.mem.trim(u8, json[idx + key_pattern.len .. end], " \t");
        return std.fmt.parseFloat(f64, num_str) catch null;
    }

    /// 序列化 GuardConfig 为 JSON (供用户编辑 / 审查)
    pub fn saveToString(self: *ConfigLoader, config: GuardConfig) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\n");
        try buf.appendSlice(self.allocator, "  \"whitelist\": [\n");
        for (config.whitelist, 0..) |item, i| {
            const sep = if (i < config.whitelist.len - 1) "," else "";
            try buf.print(self.allocator, "    \"{s}\"{s}\n", .{ item, sep });
        }
        try buf.appendSlice(self.allocator, "  ],\n");
        try buf.appendSlice(self.allocator, "  \"forbidden_symbols\": [\n");
        for (config.forbidden_symbols, 0..) |item, i| {
            const sep = if (i < config.forbidden_symbols.len - 1) "," else "";
            try buf.print(self.allocator, "    \"{s}\"{s}\n", .{ item, sep });
        }
        try buf.appendSlice(self.allocator, "  ],\n");
        try buf.appendSlice(self.allocator, "  \"invariants\": [\n");
        for (config.invariants, 0..) |item, i| {
            const sep = if (i < config.invariants.len - 1) "," else "";
            try buf.print(self.allocator, "    \"{s}\"{s}\n", .{ item, sep });
        }
        try buf.appendSlice(self.allocator, "  ],\n");
        try buf.print(self.allocator, "  \"max_diff_lines\": {d}\n", .{config.max_diff_lines});
        try buf.appendSlice(self.allocator, "}\n");

        return buf.toOwnedSlice(self.allocator);
    }
};

// ===== Tests =====

test "ConfigLoader: 解析简单 JSON" {
    const alloc = std.testing.allocator;
    var loader = ConfigLoader.init(alloc);
    defer loader.deinit();
    const json =
        \\{
        \\  "whitelist": ["a.zig", "b/"],
        \\  "forbidden_symbols": ["harm", "core"],
        \\  "invariants": ["E", "存在增益"],
        \\  "max_diff_lines": 100
        \\}
    ;
    var config = try loader.loadFromString(json);
    defer config.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), config.whitelist.len);
    try std.testing.expectEqualStrings("a.zig", config.whitelist[0]);
    try std.testing.expectEqualStrings("b/", config.whitelist[1]);
    try std.testing.expectEqual(@as(usize, 2), config.forbidden_symbols.len);
    try std.testing.expectEqual(@as(usize, 2), config.invariants.len);
    try std.testing.expectEqual(@as(usize, 100), config.max_diff_lines);
}

test "ConfigLoader: 部分字段缺失" {
    const alloc = std.testing.allocator;
    var loader = ConfigLoader.init(alloc);
    defer loader.deinit();
    const json = "{\"whitelist\": [\"x\"]}";
    var config = try loader.loadFromString(json);
    defer config.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), config.whitelist.len);
    try std.testing.expectEqual(@as(usize, 0), config.forbidden_symbols.len);
    try std.testing.expectEqual(@as(usize, 50), config.max_diff_lines);
}

test "ConfigLoader: 序列化 → 反序列化 roundtrip" {
    const alloc = std.testing.allocator;
    var loader = ConfigLoader.init(alloc);
    defer loader.deinit();
    var w1: [9]u8 = "src/x.zig".*;
    var w2: [6]u8 = "src/y/".*;
    var f1: [10]u8 = "harm:human".*;
    var inv1: [1]u8 = "E".*;
    var inv2: [5]u8 = "alpha".*;
    var wl = [_][]u8{ &w1, &w2 };
    var fbl = [_][]u8{&f1};
    var ivl = [_][]u8{ &inv1, &inv2 };
    const config = GuardConfig{
        .whitelist = &wl,
        .forbidden_symbols = &fbl,
        .invariants = &ivl,
        .max_diff_lines = 80,
    };
    const json = try loader.saveToString(config);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "src/x.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "harm:human") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "80") != null);

    // 解析回来
    var config2 = try loader.loadFromString(json);
    defer config2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), config2.whitelist.len);
    try std.testing.expectEqual(@as(usize, 80), config2.max_diff_lines);
}
