//! GHW L4 端到端"真"自迁移演示 (双进程交接)
//!
//! 与 migrate.zig (只演示流程, 不真 spawn) 不同, 本例真正跑通整条链:
//!   老进程(v1) ── 序列化状态(原子落盘) → spawn 自身(v2) → wait 回收 ──▶ 退休
//!   新进程(v2) ── 真读 state.json → 接管(复活) → 继续 runCycle ──▶ 退出
//!
//! 同一个二进制既能当 v1 也能当 v2: 靠 `--migrate-from <state.json>` 参数区分。
//! 这正是论文 B.5.3 的双进程协议 —— state.json 是唯一交接媒介, 无 IPC 复杂度。
//!
//! 关于"编新二进制":
//!   生产部署里, v1 会先 `zig build` 出一份**新源码编译的**二进制, 再把它的路径
//!   作为 self_binary_path 传给 spawnSelfNewVersion。本例为可复现, 直接用 args[0]
//!   (即当前二进制) 充当"新版本" —— spawn / wait / 状态交接的代码路径完全一致,
//!   只是省去重编译那一步。把 args[0] 换成新产物路径即为完整生产形态。
//!
//! 运行:
//!   zig build self_migrate_e2e
//!   # 或: ./zig-out/bin/self_migrate_e2e

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const SelfMigration = ghw.SelfMigration;
const StateSerializer = ghw.StateSerializer;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const STATE_PATH = "/tmp/ghw_e2e_state.json";

pub fn main(init: std.process.Init.Minimal) !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 收集 argv (0.17: init.args.iterate(); items[0] = 本二进制路径)
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = init.args.iterate();
    while (it.next()) |arg| try args_list.append(alloc, arg);
    const args = args_list.items;

    // 看到 --migrate-from ⇒ 我是被老进程拉起的"新代码壳"(v2)
    if (ghw.detectMigrateFromArg(args)) |state_path| {
        try runAsNewVersion(alloc, io, state_path);
        return;
    }

    // 否则 ⇒ 我是老进程(v1), 跑完整 e2e
    try runAsOldVersion(alloc, io, args);
}

// ============================================================
//   老进程 (v1): 序列化 → spawn 自身 → wait → 退休
// ============================================================
fn runAsOldVersion(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW L4 端到端真自迁移 — 老进程 (v1)                      ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════╝\x1b[0m", .{});

    // 1) 启动一个"成熟期"数字生命
    var agent = try ghw.GHWAgent.init(alloc, "e2e-migrator", 4, .{ 3, 3, 3 }, 7777);
    defer agent.deinit();
    agent.ed.v.material = 0.72;
    agent.ed.v.representation = 0.81;
    agent.ed.v.nature = 0.64;
    println("\n[v1] 数字生命启动: id={s} E={d:.3} (M={d:.2} R={d:.2} N={d:.2})", .{
        agent.self_id, agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
    });

    // 2) 序列化当前状态并**原子落盘** (SelfMigration.serializer 真写文件)
    var migrator = SelfMigration.initWithIo(alloc, io);
    defer migrator.deinit();

    var e_hist = [_]F{ 0.5, 0.6, 0.7, agent.ed.e() };
    const snapshot = ghw.StateSnapshot{
        .agent_id = agent.self_id,
        .tick = 1000,
        .material = agent.ed.v.material,
        .representation = agent.ed.v.representation,
        .nature = agent.ed.v.nature,
        .alpha = 0.45,
        .beta = 0.35,
        .gamma = 0.20,
        .e_current = agent.ed.e(),
        .goals = &[_]ghw.SerializedGoal{},
        .e_history = &e_hist,
        .success_count = 7,
        .fail_count = 1,
        .cumulative_de = 0.6,
        .allocator = alloc,
    };
    const json = try migrator.serializer.writeToFile(snapshot, STATE_PATH);
    defer alloc.free(json);
    println("[v1] 状态已原子落盘 → {s} ({d} 字节, tmp+rename)", .{ STATE_PATH, json.len });

    // 3) spawn 自身新版本 (args[0] = 本二进制路径)
    //    生产里此处换成 `zig build` 产出的新二进制路径。
    const self_exe = args[0];
    println("[v1] spawn 新版本: {s} --migrate-from {s}", .{ self_exe, STATE_PATH });
    const pid = try migrator.spawnSelfNewVersion(STATE_PATH, self_exe);
    if (pid <= 0) {
        println("\x1b[1;31m[v1] spawn 失败 (pid={d}) — 中止迁移, 老进程继续存活\x1b[0m", .{pid});
        return;
    }
    println("[v1] 新进程已拉起, pid={d}; 等待其接管...", .{pid});

    // 4) wait 回收新进程退出码 (真 wait, 防僵尸)
    const exit_code = try migrator.waitNewProcess(pid);
    println("\n[v1] 新进程退出, code={d}", .{exit_code});
    if (exit_code == 0) {
        println("\x1b[1;32m[v1] ✓ 交接成功 — 数字生命已在新代码壳中复活, 老进程优雅退休。\x1b[0m", .{});
    } else {
        println("\x1b[1;31m[v1] ✗ 新进程异常退出 (code={d}) — 老进程保留, 等待回滚/重试。\x1b[0m", .{exit_code});
    }
}

// ============================================================
//   新进程 (v2): 真读 state.json → 接管 → 继续 runCycle
// ============================================================
fn runAsNewVersion(alloc: std.mem.Allocator, io: std.Io, state_path: []const u8) !void {
    // 官方接管入口: 真读盘 + 打印"我是谁, 我从哪来"
    _ = try ghw.handleMigrateFromArg(alloc, io, state_path);

    // 用落盘状态重建数字生命并继续生存
    var ss = StateSerializer.init(alloc, io);
    const json = ss.readFromFile(state_path) catch |err| {
        println("[v2] 读 state 失败 ({t}), 以默认状态冷启动", .{err});
        return;
    };
    defer alloc.free(json);
    var parsed = try ss.parseMinimal(json);
    defer parsed.deinit();

    var agent = try ghw.GHWAgent.init(alloc, "e2e-migrator", 4, .{ 3, 3, 3 }, 7777);
    defer agent.deinit();
    // 恢复 M/R/N → 存在度连续 (生命没有"断片")
    agent.ed.v.material = parsed.material;
    agent.ed.v.representation = parsed.representation;
    agent.ed.v.nature = parsed.nature;
    println("[v2] 重建数字生命: 恢复 E={d:.3} (从 tick={d} 接续)", .{ agent.ed.e(), parsed.tick });

    // 继续跑几个周期, 证明"新壳"里生命照常运转
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try agent.runCycle(&[_]ghw.Information{});
        println("[v2] runCycle #{d}: E={d:.4}", .{ i + 1, agent.ed.e() });
    }
    println("\x1b[1;32m[v2] ✓ 生命在新代码壳中持续运转, 即将向老进程交回控制权 (exit 0)。\x1b[0m", .{});
    // 正常 return ⇒ exit code 0 ⇒ 老进程收到"接管成功"信号
}
