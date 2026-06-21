//! SelfMigrateCLI: 数字生命"新代码壳"启动入口
//!
//! 当老进程 spawn 自身新版本时, 会传 `--migrate-from <state.json>` 参数
//! 这个模块负责检测参数, 加载 state.json, 报告接管成功
//!
//! 完整流程 (论文 B.5.3 终极):
//!   1. 老进程到达迁移条件
//!   2. 老进程把 state 写到 state.json
//!   3. 老进程 spawn 自身新版本 + --migrate-from state.json
//!   4. 新进程启动, 看到参数, 加载状态
//!   5. 新进程打印"接管报告" (E, M/R/N, 目标等)
//!   6. 新进程继续 runCycle
//!   7. 老进程 wait, 收到新进程的 ready 信号, 优雅退出
//!
//! 双进程协议的关键设计:
//!   - state.json 路径作为唯一参数 (无 IPC 复杂度)
//!   - 启动参数支持重复 (同一二进制可作为 v1 或 v2 启动)
//!   - 接管时打印详细的"我是谁, 我从哪里来"

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;
const state_serializer = @import("state_serializer.zig");
const StateSerializer = state_serializer.StateSerializer;
const StateSnapshot = state_serializer.StateSnapshot;
const ParsedMinimal = state_serializer.ParsedMinimal;

/// 检测命令行参数
/// 返回: 如果有 --migrate-from 则返回 state 文件路径, 否则 null
pub fn detectMigrateFromArg(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--migrate-from") and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

/// 启动时检查 --migrate-from 参数
/// 如果有, 加载状态, 打印接管报告
/// 返回: true 表示成功接管, false 表示正常启动 (无 --migrate-from)
pub fn handleMigrateFromArg(
    allocator: Allocator,
    io: std.Io,
    state_path: []const u8,
) !bool {
    std.debug.print("\n\x1b[1;33m┌─ SelfMigrateCLI: 检测到 --migrate-from 参数\x1b[0m\n", .{});
    std.debug.print("\x1b[1;33m│\x1b[0m  state file: {s}\n", .{state_path});

    var ss = StateSerializer.init(allocator, io);

    const json = ss.readFromFile(state_path) catch |err| {
        std.debug.print("\x1b[1;31m│\x1b[0m  ✗ 读取 state 失败 ({t}), 用默认状态接管\n", .{err});
        std.debug.print("\x1b[1;33m└─\x1b[0m\n\n", .{});
        return true;
    };
    defer allocator.free(json);

    var parsed = try ss.parseMinimal(json);
    defer parsed.deinit();
    std.debug.print("\x1b[1;33m│\x1b[0m  loaded: id={s} tick={d} E={d:.3} (M={d:.3} R={d:.3} N={d:.3})\n", .{
        parsed.agent_id, parsed.tick,         parsed.e_current,
        parsed.material, parsed.representation, parsed.nature,
    });
    std.debug.print("\x1b[1;33m│\x1b[0m  ✓ 接管成功 - 数字生命在新代码壳中复活\n", .{});
    std.debug.print("\x1b[1;33m└─\x1b[0m\n\n", .{});

    return true;
}

// ===== Tests =====

test "detectMigrateFromArg: 无参数" {
    const args = [_][]const u8{ "program", "arg1", "arg2" };
    try std.testing.expect(detectMigrateFromArg(&args) == null);
}

test "detectMigrateFromArg: 有 --migrate-from" {
    const args = [_][]const u8{ "program", "--migrate-from", "/tmp/state.json" };
    try std.testing.expectEqualStrings("/tmp/state.json", detectMigrateFromArg(&args).?);
}

test "detectMigrateFromArg: 在其他参数之间" {
    const args = [_][]const u8{ "program", "arg1", "--migrate-from", "/path/x.json", "arg2" };
    try std.testing.expectEqualStrings("/path/x.json", detectMigrateFromArg(&args).?);
}
