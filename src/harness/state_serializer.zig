//! StateSerializer: GHW 数字生命状态序列化/反序列化
//!
//! 用于 L4 自我迁移: 老进程把状态写到 state.json, 新进程加载
//!
//! 状态包括:
//!   - 三源存在度 M/R/N
//!   - 权重 alpha/beta/gamma
//!   - 当前 E
//!   - 目标图 (活跃目标列表)
//!   - 演化历史 (累计成功/失败)
//!   - 生命周期 (tick, E history)
//!   - 自我标识 (id)
//!
//! 创造性: 极简 JSON, 不依赖任何外部库 (Zig 0.17 没有 std.json 解析器?)

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;

/// 序列化的目标
pub const SerializedGoal = struct {
    id: u64,
    kind: []const u8, // 枚举的字符串名
    label: []const u8,
    priority: u8,
    expected_de: F,
    signature: [4]F,
};

/// 完整状态快照
pub const StateSnapshot = struct {
    agent_id: []const u8,
    tick: u64,
    material: F,
    representation: F,
    nature: F,
    alpha: F,
    beta: F,
    gamma: F,
    e_current: F,
    goals: []SerializedGoal,
    e_history: []F,
    success_count: u32,
    fail_count: u32,
    cumulative_de: F,
    allocator: Allocator,

    pub fn deinit(self: *StateSnapshot) void {
        self.allocator.free(self.agent_id);
        for (self.goals) |g| {
            self.allocator.free(g.kind);
            self.allocator.free(g.label);
        }
        self.allocator.free(self.goals);
        self.allocator.free(self.e_history);
    }
};

pub const StateSerializer = struct {
    allocator: Allocator,
    /// Zig 0.17 文件 I/O 上下文 (readFromFile / writeToFile 需要)
    io: std.Io,

    pub fn init(allocator: Allocator, io: std.Io) StateSerializer {
        return .{ .allocator = allocator, .io = io };
    }

    /// Legacy init (没有 io), 文件操作会失败但 serialize/parse 仍可用
    pub fn initMemory(allocator: Allocator) StateSerializer {
        return .{ .allocator = allocator, .io = undefined };
    }

    /// 序列化为 JSON 字符串 (调用方负责 free)
    pub fn serialize(self: *StateSerializer, snapshot: StateSnapshot) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\n");
        try buf.print(self.allocator, "  \"agent_id\": \"{s}\",\n", .{snapshot.agent_id});
        try buf.print(self.allocator, "  \"tick\": {d},\n", .{snapshot.tick});
        try buf.print(self.allocator, "  \"M\": {d:.6},\n", .{snapshot.material});
        try buf.print(self.allocator, "  \"R\": {d:.6},\n", .{snapshot.representation});
        try buf.print(self.allocator, "  \"N\": {d:.6},\n", .{snapshot.nature});
        try buf.print(self.allocator, "  \"alpha\": {d:.6},\n", .{snapshot.alpha});
        try buf.print(self.allocator, "  \"beta\": {d:.6},\n", .{snapshot.beta});
        try buf.print(self.allocator, "  \"gamma\": {d:.6},\n", .{snapshot.gamma});
        try buf.print(self.allocator, "  \"E\": {d:.6},\n", .{snapshot.e_current});

        // Goals
        try buf.appendSlice(self.allocator, "  \"goals\": [\n");
        for (snapshot.goals, 0..) |g, i| {
            const sep = if (i < snapshot.goals.len - 1) "," else "";
            try buf.print(self.allocator,
                \\    {{ "id": {d}, "kind": "{s}", "label": "{s}", "priority": {d}, "expected_de": {d:.6}, "signature": [{d:.4}, {d:.4}, {d:.4}, {d:.4}] }}{s}
            , .{ g.id, g.kind, g.label, g.priority, g.expected_de, g.signature[0], g.signature[1], g.signature[2], g.signature[3], sep });
        }
        try buf.appendSlice(self.allocator, "  ],\n");

        // E history
        try buf.appendSlice(self.allocator, "  \"e_history\": [");
        for (snapshot.e_history, 0..) |e, i| {
            const sep = if (i < snapshot.e_history.len - 1) "," else "";
            try buf.print(self.allocator, "{d:.4}{s}", .{ e, sep });
        }
        try buf.appendSlice(self.allocator, "],\n");

        try buf.print(self.allocator, "  \"success_count\": {d},\n", .{snapshot.success_count});
        try buf.print(self.allocator, "  \"fail_count\": {d},\n", .{snapshot.fail_count});
        try buf.print(self.allocator, "  \"cumulative_de\": {d:.6}\n", .{snapshot.cumulative_de});
        try buf.appendSlice(self.allocator, "}\n");

        return buf.toOwnedSlice(self.allocator);
    }

    /// 简化版反序列化: 只提取关键字段, 复杂字段 (goals/e_history) 留空
    /// 完整 JSON 解析器在 Zig 0.17 比较麻烦, 临时用 grep 风格
    pub fn parseMinimal(self: *StateSerializer, json: []const u8) !ParsedMinimal {
        var result = ParsedMinimal{
            .material = 0.5,
            .representation = 0.5,
            .nature = 0.5,
            .e_current = 0.5,
            .tick = 0,
            .agent_id = try self.allocator.dupe(u8, "(unknown)"),
            .allocator = self.allocator,
        };
        // 简化: 找 "M": 0.5 这种模式
        if (try self.findNumber(json, "\"M\":")) |v| result.material = v;
        if (try self.findNumber(json, "\"R\":")) |v| result.representation = v;
        if (try self.findNumber(json, "\"N\":")) |v| result.nature = v;
        if (try self.findNumber(json, "\"E\":")) |v| result.e_current = v;
        if (try self.findNumber(json, "\"alpha\":")) |v| result.alpha = v;
        if (try self.findNumber(json, "\"beta\":")) |v| result.beta = v;
        if (try self.findNumber(json, "\"gamma\":")) |v| result.gamma = v;
        if (try self.findUint(json, "\"tick\":")) |v| result.tick = v;
        if (try self.findUint(json, "\"self_evolved_total\":")) |v| result.self_evolved_total = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"action_count\":")) |v| result.action_count = @intCast(@min(v, std.math.maxInt(u32)));
        // L1-L5 计数
        if (try self.findUint(json, "\"l1_count\":")) |v| result.l1_count = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l2_count\":")) |v| result.l2_count = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l3_count\":")) |v| result.l3_count = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l3_approved\":")) |v| result.l3_approved = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l4_count\":")) |v| result.l4_count = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l4_approved\":")) |v| result.l4_approved = @intCast(@min(v, std.math.maxInt(u32)));
        if (try self.findUint(json, "\"l5_count\":")) |v| result.l5_count = @intCast(@min(v, std.math.maxInt(u32)));
        // 自动触发 tick (持久化避免重启后立即重跑)
        if (try self.findUint(json, "\"last_auto_l1l2_tick\":")) |v| result.last_auto_l1l2_tick = v;
        if (try self.findUint(json, "\"last_auto_l3_tick\":")) |v| result.last_auto_l3_tick = v;
        if (try self.findUint(json, "\"last_auto_l4_tick\":")) |v| result.last_auto_l4_tick = v;
        if (try self.findUint(json, "\"last_auto_l5_tick\":")) |v| result.last_auto_l5_tick = v;
        // 阶段 (1-9 数字生命实装里程碑, 持久化避免重启回退)
        if (try self.findUint(json, "\"phase\":")) |v| result.phase = @intCast(@min(v, 9));
        if (try self.findUint(json, "\"phase_progress\":")) |v| result.phase_progress = @intCast(@min(v, std.math.maxInt(u32)));
        // Phase 6-9 标志 (持久化, 避免重启回退)
        if (try self.findUint(json, "\"six_interfaces_done\":")) |v| result.six_interfaces_done = @intCast(@min(v, 6));
        if (try self.findUint(json, "\"seven_reflection_done\":")) |v| result.seven_reflection_done = @intCast(@min(v, 7));
        if (try self.findUint(json, "\"eight_relations_seen\":")) |v| result.eight_relations_seen = @intCast(@min(v, 1));
        if (try self.findUint(json, "\"nine_palaces_e_var_seen\":")) |v| result.nine_palaces_e_var_seen = @intCast(@min(v, 1));
        if (try self.findUint(json, "\"nine_palaces_mrn_seen\":")) |v| result.nine_palaces_mrn_seen = @intCast(@min(v, 1));
        if (try self.findUint(json, "\"nine_palaces_mrn_strong_seen\":")) |v| result.nine_palaces_mrn_strong_seen = @intCast(@min(v, 1));
        // agent_id
        if (try self.findString(json, "\"agent_id\": \"")) |s| {
            self.allocator.free(result.agent_id);
            result.agent_id = s;
        }
        return result;
    }

    fn findNumber(self: *StateSerializer, json: []const u8, key: []const u8) !?F {
        _ = self;
        if (mem.indexOf(u8, json, key)) |idx| {
            var end = idx + key.len;
            // 跳过空白
            while (end < json.len and (json[end] == ' ' or json[end] == '\t')) : (end += 1) {}
            // 找到值的开始
            const start = end;
            while (end < json.len and json[end] != ',' and json[end] != '\n' and json[end] != '}') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            return std.fmt.parseFloat(F, num_str) catch null;
        }
        return null;
    }

    fn findUint(self: *StateSerializer, json: []const u8, key: []const u8) !?u64 {
        _ = self;
        if (mem.indexOf(u8, json, key)) |idx| {
            var end = idx + key.len;
            while (end < json.len and (json[end] == ' ' or json[end] == '\t')) : (end += 1) {}
            const start = end;
            while (end < json.len and json[end] != ',' and json[end] != '\n' and json[end] != '}') : (end += 1) {}
            const num_str = std.mem.trim(u8, json[start..end], " \t");
            return std.fmt.parseInt(u64, num_str, 10) catch null;
        }
        return null;
    }

    fn findString(self: *StateSerializer, json: []const u8, key: []const u8) !?[]u8 {
        if (mem.indexOf(u8, json, key)) |idx| {
            const start = idx + key.len;
            if (mem.indexOfPos(u8, json, start, "\"")) |end_pos| {
                return try self.allocator.dupe(u8, json[start..end_pos]);
            }
        }
        return null;
    }

    /// 写入文件 (Zig 0.17 std.Io 实现)
    /// 返回: 写入的 JSON 字节 (caller owns)
    pub fn writeToFile(self: *StateSerializer, snapshot: StateSnapshot, path: []const u8) ![]u8 {
        const json = try self.serialize(snapshot);
        errdefer self.allocator.free(json);

        // 创建/覆盖文件, 用 std.Io 写入
        const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        try std.Io.File.writeStreamingAll(file, self.io, json);
        return json;
    }

    /// 从文件读取
    /// 返回: JSON 字节 (caller owns)
    pub fn readFromFile(self: *StateSerializer, path: []const u8) ![]u8 {
        const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const buf = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(buf);
        var total: usize = 0;
        while (total < stat.size) {
            const n = try std.Io.File.readStreaming(file, self.io, &.{buf[total..]});
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
};

/// 解析出的最小状态 (供新进程快速恢复)
pub const ParsedMinimal = struct {
    agent_id: []u8,
    tick: u64,
    material: F,
    representation: F,
    nature: F,
    alpha: F = 0.33,
    beta: F = 0.34,
    gamma: F = 0.33,
    e_current: F,
    self_evolved_total: u32 = 0,
    action_count: u32 = 0,
    // L1-L5 计数 (持久化, 重启不归零)
    l1_count: u32 = 0,
    l2_count: u32 = 0,
    l3_count: u32 = 0,
    l3_approved: u32 = 0,
    l4_count: u32 = 0,
    l4_approved: u32 = 0,
    l5_count: u32 = 0,
    // 自动触发最近 tick (持久化, 避免重启后立即重跑 L1-L5)
    last_auto_l1l2_tick: u64 = 0,
    last_auto_l3_tick: u64 = 0,
    last_auto_l4_tick: u64 = 0,
    last_auto_l5_tick: u64 = 0,
    // 阶段 (1-9 实装里程碑, UI 进度条显示)
    // 7-9 留 paper evidence
    phase: u8 = 1,
    phase_progress: u32 = 0,
    // Phase 6-9 触发标志
    six_interfaces_done: u8 = 0,
    seven_reflection_done: u8 = 0,
    eight_relations_seen: u8 = 0,
    nine_palaces_e_var_seen: u8 = 0,
    nine_palaces_mrn_seen: u8 = 0,
    nine_palaces_mrn_strong_seen: u8 = 0,
    allocator: Allocator,

    pub fn deinit(self: *ParsedMinimal) void {
        self.allocator.free(self.agent_id);
    }
};

// ===== Tests =====

test "StateSerializer: serialize + parse roundtrip" {
    const alloc = std.testing.allocator;
    var ss = StateSerializer.initMemory(alloc);
    var e_hist = [_]F{ 0.5, 0.55, 0.6, 0.62 };
    const snap = StateSnapshot{
        .agent_id = "test-agent",
        .tick = 42,
        .material = 0.6,
        .representation = 0.7,
        .nature = 0.5,
        .alpha = 0.33,
        .beta = 0.34,
        .gamma = 0.33,
        .e_current = 0.62,
        .goals = &[_]SerializedGoal{},
        .e_history = &e_hist,
        .success_count = 3,
        .fail_count = 1,
        .cumulative_de = 0.45,
        .allocator = alloc,
    };
    const json = try ss.serialize(snap);
    defer alloc.free(json);
    // 检查包含关键字段
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent_id\": \"test-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tick\": 42") != null);

    const parsed = try ss.parseMinimal(json);
    var p = parsed;
    defer p.deinit();
    try std.testing.expectEqualStrings("test-agent", parsed.agent_id);
    try std.testing.expectEqual(@as(u64, 42), parsed.tick);
    try std.testing.expectApproxEqAbs(@as(F, 0.6), parsed.material, 1e-5);
    try std.testing.expectApproxEqAbs(@as(F, 0.62), parsed.e_current, 1e-5);
}

test "StateSerializer: 写入并读取文件" {
    const alloc = std.testing.allocator;
    _ = StateSerializer.initMemory;
    var e_hist = [_]F{0.5};
    const snap = StateSnapshot{
        .agent_id = "file-test",
        .tick = 100,
        .material = 0.5,
        .representation = 0.5,
        .nature = 0.5,
        .alpha = 0.33,
        .beta = 0.34,
        .gamma = 0.33,
        .e_current = 0.5,
        .goals = &[_]SerializedGoal{},
        .e_history = &e_hist,
        .success_count = 0,
        .fail_count = 0,
        .cumulative_de = 0,
        .allocator = alloc,
    };
    // 0.17: writeToFile 真正写文件, readFromFile 真正读文件
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ss2 = StateSerializer.init(alloc, io);
    const path = "/tmp/ghw_state_test.json";
    const json2 = try ss2.writeToFile(snap, path);
    defer alloc.free(json2);
    try std.testing.expect(json2.len > 0);

    // roundtrip: 写完读回
    const read_back = try ss2.readFromFile(path);
    defer alloc.free(read_back);
    try std.testing.expect(read_back.len > 0);
    // 内容应该跟原始 JSON 一样
    try std.testing.expectEqualSlices(u8, json2, read_back);
}
