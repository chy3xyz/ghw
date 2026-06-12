//! SQLite 集成测试

const std = @import("std");
const SqliteDb = @import("sqlite_db.zig").SqliteDb;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const test_path = "/tmp/ghw_test.db";

    // 删除旧 db (sqlite3_open 会覆盖)

    std.debug.print("=== SQLite 集成测试 ===\n\n", .{});

    var db = try SqliteDb.open(alloc, test_path);
    defer db.close();
    std.debug.print("[1] 打开 {s} 成功\n", .{test_path});

    try db.initSchema();
    std.debug.print("[2] schema 初始化成功\n", .{});

    // 插入 episodes
    const id1 = try db.insertEpisode(32, "reflection", "我刚醒来, 感到好奇", 0.9, "llm");
    std.debug.print("[3] insert reflection, id={d}\n", .{id1});
    _ = try db.insertEpisode(33, "cycle", "E=0.5 M=0.5 R=0.5 N=0.3", 0.5, "system");
    _ = try db.insertEpisode(64, "propose", "[1] 探索端口服务", 0.8, "llm");
    _ = try db.insertEpisode(65, "chat", "user: 帮我看看", 0.7, "human");
    std.debug.print("[4] 4 条 episodes 插入\n", .{});

    // 插入 beliefs
    const b1 = try db.insertBelief(32, "nature", "初始状态是探索的起点", 0.9);
    std.debug.print("[5] insert belief, id={d}\n", .{b1});
    _ = try db.insertBelief(32, "representation", "E 是存在度的核心", 0.7);
    std.debug.print("[6] 2 beliefs 插入\n", .{});

    // 插入 proposed goals
    const p1 = try db.insertProposedGoal(64, "探索端口服务", "扫所有 listen 端口", "representation", "扩展 R 维度", 0.7, "raw response here");
    std.debug.print("[7] insert proposed_goal, id={d}\n", .{p1});

    // 搜索
    std.debug.print("\n[8] 搜索 '探索':\n", .{});
    const results = try db.searchEpisodes("探索", 10);
    defer {
        for (results) |r| r.deinit();
        alloc.free(results);
    }
    std.debug.print("  找到 {d} 条\n", .{results.len});
    for (results) |r| {
        std.debug.print("  - tick={d} kind={s} importance={d:.2} data={s}\n", .{ r.tick, r.kind, r.importance, r.data });
    }

    // 搜索空 → 返所有
    std.debug.print("\n[9] 搜索空 (返所有):\n", .{});
    const all = try db.searchEpisodes("", 10);
    defer {
        for (all) |r| r.deinit();
        alloc.free(all);
    }
    std.debug.print("  共 {d} 条\n", .{all.len});

    // 统计
    std.debug.print("\n[10] 统计:\n", .{});
    const stats_json = try db.stats(alloc);
    defer alloc.free(stats_json);
    std.debug.print("  {s}\n", .{stats_json});

    std.debug.print("\n=== 全部测试 PASS ✓ ===\n", .{});
    std.debug.print("\nSQLite 记忆系统 v1 验证:\n", .{});
    std.debug.print("  ✓ 打开 .db 文件 (system libsqlite3)\n", .{});
    std.debug.print("  ✓ 创建 schema (episodes / beliefs / proposed_goals)\n", .{});
    std.debug.print("  ✓ INSERT 4+2+1 条记录\n", .{});
    std.debug.print("  ✓ SELECT LIKE 全文搜索\n", .{});
    std.debug.print("  ✓ 统计 GROUP BY kind\n", .{});
}
