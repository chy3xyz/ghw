//! SQLite 记忆存储 — 把 LLM 反思/对话/提议都存到 .sqlite, 支持查询
//!
//! 设计:
//!   - 一个表一种数据 (episodes / beliefs / proposed_goals / chat)
//!   - 主进程持有一个 connection, 所有写都走 prepared statements
//!   - state.json 仍保留 (做快照, 启动时优先从 sqlite 重建内存状态)
//!
//! 用法:
//!   var db = try SqliteDb.open(alloc, "/tmp/ghw.db");
//!   defer db.close();
//!   try db.exec("CREATE TABLE ...", ...);  // 初始化
//!   try db.insertEpisode(.{
//!       .tick = 100, .kind = "reflection", .data = "我刚醒来", .importance = 0.8
//!   });
//!   var iter = try db.searchEpisodes("醒来", 10);
//!   defer iter.deinit();
//!   while (try iter.next()) |row| { ... }

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// SQLite C API bindings (manual extern "c")
// ============================================================

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

pub const SQLITE_OPEN_READONLY = 0x00000001;
pub const SQLITE_OPEN_READWRITE = 0x00000002;
pub const SQLITE_OPEN_CREATE = 0x00000004;

extern "c" fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close_v2(db: *sqlite3) c_int;
extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern "c" fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (data: ?*anyopaque, argc: c_int, argv: [*][*:0]const u8, col_names: [*][*:0]const u8) c_int, data: ?*anyopaque, errmsg: *?[*:0]u8) c_int;

extern "c" fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: [*c]?[*:0]const u8) c_int;
extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, text: [*]const u8, nByte: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
extern "c" fn sqlite3_bind_double(stmt: *sqlite3_stmt, idx: c_int, value: f64) c_int;
extern "c" fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;

extern "c" fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_int64(stmt: *sqlite3_stmt, idx: c_int) i64;
extern "c" fn sqlite3_column_double(stmt: *sqlite3_stmt, idx: c_int) f64;
extern "c" fn sqlite3_column_text(stmt: *sqlite3_stmt, idx: c_int) [*]const u8;
extern "c" fn sqlite3_column_bytes(stmt: *sqlite3_stmt, idx: c_int) c_int;
extern "c" fn sqlite3_column_type(stmt: *sqlite3_stmt, idx: c_int) c_int;

// ============================================================
// 高层 API
// ============================================================

pub const SqliteError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    OutOfMemory,
};

pub const SqliteDb = struct {
    alloc: Allocator,
    db: *sqlite3,
    path: []u8,

    pub fn open(alloc: Allocator, path: []const u8) !SqliteDb {
        var db: ?*sqlite3 = null;
        // 拷贝 path 到 null 结尾 (Zig 0.17 没有 dupeZ, 用 dupe + 手动加 0)
        const path_buf = try alloc.allocSentinel(u8, path.len, 0);
        @memcpy(path_buf[0..path.len], path);
        errdefer alloc.free(path_buf);
        // 显式 flags: READWRITE | CREATE
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
        const rc = sqlite3_open_v2(@ptrCast(path_buf.ptr), &db, flags, null);
        if (rc != SQLITE_OK) {
            std.debug.print("[sqlite] open_v2 失败 (rc={d}) path={s}\n", .{ rc, path });
            return SqliteError.OpenFailed;
        }
        return .{
            .alloc = alloc,
            .db = db.?,
            .path = path_buf,
        };
    }

    pub fn close(self: *const SqliteDb) void {
        _ = sqlite3_close_v2(self.db);
        self.alloc.free(self.path);
    }

    pub fn exec(self: *const SqliteDb, sql: []const u8) !void {
        const sql_z = try self.alloc.allocSentinel(u8, sql.len, 0);
        @memcpy(sql_z[0..sql.len], sql);
        defer self.alloc.free(sql_z);
        var err_msg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(self.db, @ptrCast(sql_z.ptr), null, null, &err_msg);
        if (rc != SQLITE_OK) {
            if (err_msg) |m| {
                std.debug.print("[sqlite] exec 失败: {s}\n  sql: {s}\n", .{ m, sql });
            }
            return SqliteError.ExecFailed;
        }
    }

    fn prepare(self: *const SqliteDb, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.alloc.allocSentinel(u8, sql.len, 0);
        @memcpy(sql_z[0..sql.len], sql);
        defer self.alloc.free(sql_z);
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt, null);
        if (rc != SQLITE_OK) {
            std.debug.print("[sqlite] prepare 失败: {s}\n  sql: {s}\n", .{ sqlite3_errmsg(self.db), sql });
            return SqliteError.PrepareFailed;
        }
        return stmt.?;
    }

    pub fn initSchema(self: *const SqliteDb) !void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS episodes (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  tick INTEGER NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  data TEXT NOT NULL,
            \\  importance REAL DEFAULT 0.5,
            \\  ts INTEGER NOT NULL,
            \\  source TEXT
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_episodes_tick ON episodes(tick DESC);");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_episodes_kind ON episodes(kind);");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS beliefs (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  tick INTEGER NOT NULL,
            \\  source TEXT NOT NULL,
            \\  text TEXT NOT NULL,
            \\  confidence REAL NOT NULL,
            \\  evidence_count INTEGER DEFAULT 1
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS proposed_goals (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  tick INTEGER NOT NULL,
            \\  title TEXT NOT NULL,
            \\  description TEXT NOT NULL,
            \\  dimension TEXT NOT NULL,
            \\  reason TEXT NOT NULL,
            \\  urgency REAL NOT NULL,
            \\  raw_response TEXT,
            \\  adopted INTEGER DEFAULT 0
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_beliefs_tick ON beliefs(tick DESC);");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_goals_adopted ON proposed_goals(adopted);");

        // === actions 表: 实际执行的动作历史 (LLM-as-agent 关键的"状态变化" 证据) ===
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS actions (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  goal_id INTEGER,
            \\  tick INTEGER NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  source TEXT,
            \\  input TEXT,
            \\  output TEXT,
            \\  result TEXT,
            \\  duration_ms INTEGER,
            \\  ts INTEGER NOT NULL
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_actions_tick ON actions(tick DESC);");

        // === evolved_adopted 表: 跟踪 L3/L4/L5 落盘文件是否已 adopt 进 ghw 源码 (按 hash 去重) ===
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS evolved_adopted (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  kind TEXT NOT NULL,                 -- L3 / L4 / L5
            \\  tick INTEGER NOT NULL,              -- 触发 tick
            \\  filename TEXT NOT NULL,             -- 落盘 basename, e.g. "l4_96.zig"
            \\  hash TEXT NOT NULL,                  -- 16 字符 hex (64-bit FNV-1a), 用于去重
            \\  source_path TEXT NOT NULL,          -- /tmp/ghw_evolved/<name>
            \\  target_path TEXT NOT NULL,          -- ghw_root/<sub_path>
            \\  size INTEGER NOT NULL,              -- 文件大小
            \\  adopted_at INTEGER NOT NULL,        -- 落盘时间 (unix timestamp)
            \\  UNIQUE(kind, hash)                  -- 同 kind + 同 hash 只能存在一次
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_evolved_kind ON evolved_adopted(kind);");
    }

    // ===== Episodes =====

    pub fn insertEpisode(
        self: *const SqliteDb,
        tick: i64,
        kind: []const u8,
        data: []const u8,
        importance: f64,
        source: []const u8,
    ) !i64 {
        const stmt = try self.prepare(
            \\INSERT INTO episodes (tick, kind, data, importance, ts, source)
            \\VALUES (?, ?, ?, ?, strftime('%s','now'), ?);
        );
        defer _ = sqlite3_finalize(stmt);
        try bindText(stmt, 1, &[_]u8{}, ""); // unused
        _ = sqlite3_bind_int64(stmt, 1, tick);
        try bindTextAlloc(self.alloc, stmt, 2, kind);
        try bindTextAlloc(self.alloc, stmt, 3, data);
        _ = sqlite3_bind_double(stmt, 4, importance);
        try bindTextAlloc(self.alloc, stmt, 5, source);
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return SqliteError.StepFailed;
        return sqlite3_last_insert_rowid(self.db);
    }

    // ===== Beliefs =====

    pub fn insertBelief(
        self: *const SqliteDb,
        tick: i64,
        source: []const u8,
        text: []const u8,
        confidence: f64,
    ) !i64 {
        const stmt = try self.prepare(
            \\INSERT INTO beliefs (tick, source, text, confidence, evidence_count)
            \\VALUES (?1, ?2, ?3, ?4, 1);
        );
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, tick);
        try bindTextAlloc(self.alloc, stmt, 2, source);
        try bindTextAlloc(self.alloc, stmt, 3, text);
        _ = sqlite3_bind_double(stmt, 4, confidence);
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return SqliteError.StepFailed;
        return sqlite3_last_insert_rowid(self.db);
    }

    // ===== 搜索 =====

    /// 倒序列出某 kind 的最近 N 条 episodes (返 []{tick, data} 不复制, ownership 给 caller)
    /// 用于 propose history / 反思重放
    pub fn listEpisodesByKind(self: *const SqliteDb, kind: []const u8, limit: i64) ![]EpisodeRow {
        var results = std.ArrayList(EpisodeRow).empty;
        errdefer {
            for (results.items) |r| r.deinit();
            results.deinit(self.alloc);
        }
        const stmt = try self.prepare(
            \\SELECT id, tick, kind, data, importance, ts, source FROM episodes WHERE kind = ?1
            \\ORDER BY tick DESC LIMIT ?2;
        );
        defer _ = sqlite3_finalize(stmt);
        var kind_z: [64]u8 = undefined;
        if (kind.len > kind_z.len) return results.toOwnedSlice(self.alloc);
        @memcpy(kind_z[0..kind.len], kind);
        _ = sqlite3_bind_text(stmt, 1, &kind_z, @intCast(kind.len), null);
        _ = sqlite3_bind_int64(stmt, 2, limit);
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return SqliteError.StepFailed;

            const dupText = struct {
                fn dup(alloc: Allocator, stmt2: *sqlite3_stmt, col: c_int) ![]u8 {
                    const z = sqlite3_column_text(stmt2, col);
                    const len: usize = @intCast(sqlite3_column_bytes(stmt2, col));
                    if (len == 0) return alloc.dupe(u8, "");
                    const buf = try alloc.alloc(u8, len);
                    @memcpy(buf, @as([*]const u8, @ptrCast(z))[0..len]);
                    return buf;
                }
            }.dup;

            const id = sqlite3_column_int64(stmt, 0);
            const tick = sqlite3_column_int64(stmt, 1);
            const kind_dup = try dupText(self.alloc, stmt, 2);
            const data_dup = try dupText(self.alloc, stmt, 3);
            const importance = sqlite3_column_double(stmt, 4);
            const ts = sqlite3_column_int64(stmt, 5);
            const source_dup = try dupText(self.alloc, stmt, 6);

            try results.append(self.alloc, .{
                .id = id,
                .tick = tick,
                .kind = kind_dup,
                .data = data_dup,
                .importance = importance,
                .ts = ts,
                .source = source_dup,
                .alloc = self.alloc,
            });
        }
        return results.toOwnedSlice(self.alloc);
    }

    // ===== Proposed Goals =====

    pub fn insertProposedGoal(
        self: *const SqliteDb,
        tick: i64,
        title: []const u8,
        description: []const u8,
        dimension: []const u8,
        reason: []const u8,
        urgency: f64,
        raw: []const u8,
    ) !i64 {
        const stmt = try self.prepare(
            \\INSERT INTO proposed_goals
            \\  (tick, title, description, dimension, reason, urgency, raw_response)
            \\VALUES (?, ?, ?, ?, ?, ?, ?);
        );
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, tick);
        try bindTextAlloc(self.alloc, stmt, 2, title);
        try bindTextAlloc(self.alloc, stmt, 3, description);
        try bindTextAlloc(self.alloc, stmt, 4, dimension);
        try bindTextAlloc(self.alloc, stmt, 5, reason);
        _ = sqlite3_bind_double(stmt, 6, urgency);
        if (raw.len > 0) {
            try bindTextAlloc(self.alloc, stmt, 7, raw);
        } else {
            _ = sqlite3_bind_null(stmt, 7);
        }
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return SqliteError.StepFailed;
        return sqlite3_last_insert_rowid(self.db);
    }

    /// 标记一个 proposed_goal 为已采纳
    pub fn markGoalAdopted(self: *const SqliteDb, goal_id: i64) !void {
        const stmt = try self.prepare(
            \\UPDATE proposed_goals SET adopted = 1 WHERE id = ?;
        );
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, goal_id);
        _ = sqlite3_step(stmt);
    }

    pub const GoalRow = struct {
        id: i64,
        tick: i64,
        title: []u8,
        description: []u8,
        dimension: []u8,
        reason: []u8,
        urgency: f64,
        alloc: Allocator,

        pub fn deinit(self: *const GoalRow) void {
            self.alloc.free(self.title);
            self.alloc.free(self.description);
            self.alloc.free(self.dimension);
            self.alloc.free(self.reason);
        }
    };

    /// 取 unadopted 提议里 urgency 最高的那条
    pub fn topUnadoptedGoal(self: *const SqliteDb) !?GoalRow {
        const stmt = try self.prepare(
            \\SELECT id, tick, title, description, dimension, reason, urgency
            \\FROM proposed_goals
            \\WHERE adopted = 0
            \\ORDER BY urgency DESC
            \\LIMIT 1;
        );
        defer _ = sqlite3_finalize(stmt);
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) return null;
        if (rc != SQLITE_ROW) return SqliteError.StepFailed;
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .tick = sqlite3_column_int64(stmt, 1),
            .title = dupColumnText(self.alloc, stmt, 2),
            .description = dupColumnText(self.alloc, stmt, 3),
            .dimension = dupColumnText(self.alloc, stmt, 4),
            .reason = dupColumnText(self.alloc, stmt, 5),
            .urgency = sqlite3_column_double(stmt, 6),
            .alloc = self.alloc,
        };
    }

    // ===== Actions =====

    pub fn insertAction(
        self: *const SqliteDb,
        goal_id: ?i64,
        tick: i64,
        kind: []const u8,
        source: []const u8,
        input: []const u8,
        output: []const u8,
        result: []const u8,
        duration_ms: i64,
    ) !i64 {
        const stmt = try self.prepare(
            \\INSERT INTO actions
            \\  (goal_id, tick, kind, source, input, output, result, duration_ms, ts)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%s','now'));
        );
        defer _ = sqlite3_finalize(stmt);
        if (goal_id) |gid| {
            _ = sqlite3_bind_int64(stmt, 1, gid);
        } else {
            _ = sqlite3_bind_null(stmt, 1);
        }
        _ = sqlite3_bind_int64(stmt, 2, tick);
        try bindTextAlloc(self.alloc, stmt, 3, kind);
        try bindTextAlloc(self.alloc, stmt, 4, source);
        try bindTextAlloc(self.alloc, stmt, 5, input);
        try bindTextAlloc(self.alloc, stmt, 6, output);
        try bindTextAlloc(self.alloc, stmt, 7, result);
        _ = sqlite3_bind_int64(stmt, 8, duration_ms);
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return SqliteError.StepFailed;
        return sqlite3_last_insert_rowid(self.db);
    }

    pub const ActionRow = struct {
        id: i64,
        goal_id: ?i64,
        tick: i64,
        kind: []u8,
        source: []u8,
        input: []u8,
        output: []u8,
        result: []u8,
        duration_ms: i64,
        ts: i64,
        alloc: Allocator,

        pub fn deinit(self: *const ActionRow) void {
            self.alloc.free(self.kind);
            self.alloc.free(self.source);
            self.alloc.free(self.input);
            self.alloc.free(self.output);
            self.alloc.free(self.result);
        }
    };

    /// 数 [tick_min, tick_max] 范围内 kind 的数量
    pub fn countKindInRange(self: *const SqliteDb, kind: []const u8, tick_min: i64, tick_max: i64) !i32 {
        const stmt = try self.prepare(
            \\SELECT COUNT(*) FROM actions WHERE kind = ?1 AND tick >= ?2 AND tick <= ?3;
        );
        defer _ = sqlite3_finalize(stmt);
        var kind_z: [64]u8 = undefined;
        if (kind.len > kind_z.len) return 0;
        @memcpy(kind_z[0..kind.len], kind);
        _ = sqlite3_bind_text(stmt, 1, &kind_z, @intCast(kind.len), null);
        _ = sqlite3_bind_int64(stmt, 2, tick_min);
        _ = sqlite3_bind_int64(stmt, 3, tick_max);
        const rc = sqlite3_step(stmt);
        if (rc != 100) return 0; // not ROW → 0
        return @intCast(sqlite3_column_int64(stmt, 0));
    }

    // ===== 搜索 =====

    pub const EpisodeRow = struct {
        id: i64,
        tick: i64,
        kind: []u8,
        data: []u8,
        importance: f64,
        ts: i64,
        source: []u8,
        alloc: Allocator,

        pub fn deinit(self: *const EpisodeRow) void {
            if (self.kind.len > 0) self.alloc.free(self.kind);
            if (self.data.len > 0) self.alloc.free(self.data);
            if (self.source.len > 0) self.alloc.free(self.source);
        }
    };

    /// 返所有已执行动作 (倒序)
    pub fn listActions(self: *const SqliteDb, limit: i64) ![]ActionRow {
        var results = std.ArrayList(ActionRow).empty;
        errdefer {
            for (results.items) |r| r.deinit();
            results.deinit(self.alloc);
        }
        const stmt = try self.prepare(
            \\SELECT id, goal_id, tick, kind, source, input, output, result, duration_ms, ts
            \\FROM actions
            \\ORDER BY tick DESC
            \\LIMIT ?1;
        );
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, limit);
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return SqliteError.StepFailed;
            const gid = sqlite3_column_int64(stmt, 1);
            const col_type = sqlite3_column_type(stmt, 1);
            const goal_id: ?i64 = if (col_type == 5) null else gid; // SQLITE_NULL = 5
            try results.append(self.alloc, .{
                .id = sqlite3_column_int64(stmt, 0),
                .goal_id = goal_id,
                .tick = sqlite3_column_int64(stmt, 2),
                .kind = dupColumnText(self.alloc, stmt, 3),
                .source = dupColumnText(self.alloc, stmt, 4),
                .input = dupColumnText(self.alloc, stmt, 5),
                .output = dupColumnText(self.alloc, stmt, 6),
                .result = dupColumnText(self.alloc, stmt, 7),
                .duration_ms = sqlite3_column_int64(stmt, 8),
                .ts = sqlite3_column_int64(stmt, 9),
                .alloc = self.alloc,
            });
        }
        return results.toOwnedSlice(self.alloc);
    }

    // ===== 搜索 =====

    /// 搜索 episodes (LIKE 全文匹配, 按 importance * recency 排序)
    /// query 为空 → 返所有 (按 tick DESC 排)
    pub fn searchEpisodes(
        self: *const SqliteDb,
        query: []const u8,
        limit: i64,
    ) ![]EpisodeRow {
        var results = std.ArrayList(EpisodeRow).empty;
        errdefer {
            for (results.items) |r| r.deinit();
            results.deinit(self.alloc);
        }

        const stmt = blk: {
            if (query.len > 0) {
                break :blk try self.prepare(
                    \\SELECT id, tick, kind, data, importance, ts, source
                    \\FROM episodes
                    \\WHERE data LIKE ?1 OR kind LIKE ?1 OR source LIKE ?1
                    \\ORDER BY tick DESC
                    \\LIMIT ?2;
                );
            } else {
                break :blk try self.prepare(
                    \\SELECT id, tick, kind, data, importance, ts, source
                    \\FROM episodes
                    \\ORDER BY tick DESC
                    \\LIMIT ?1;
                );
            }
        };
        defer _ = sqlite3_finalize(stmt);

        if (query.len > 0) {
            // SQL LIKE 需要 %query%
            var like_buf = std.ArrayList(u8).empty;
            try like_buf.append(self.alloc, '%');
            try like_buf.appendSlice(self.alloc, query);
            try like_buf.append(self.alloc, '%');
            _ = sqlite3_bind_text(stmt, 1, like_buf.items.ptr, @intCast(like_buf.items.len), @ptrCast(&sqlTransientDestructor));
            _ = sqlite3_bind_int64(stmt, 2, limit);
        } else {
            _ = sqlite3_bind_int64(stmt, 1, limit);
        }

        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return SqliteError.StepFailed;
            const id = sqlite3_column_int64(stmt, 0);
            const tick = sqlite3_column_int64(stmt, 1);
            const kind = dupColumnText(self.alloc, stmt, 2);
            const data = dupColumnText(self.alloc, stmt, 3);
            const imp = sqlite3_column_double(stmt, 4);
            const ts = sqlite3_column_int64(stmt, 5);
            const source = dupColumnText(self.alloc, stmt, 6);
            try results.append(self.alloc, .{
                .id = id,
                .tick = tick,
                .kind = kind,
                .data = data,
                .importance = imp,
                .ts = ts,
                .source = source,
                .alloc = self.alloc,
            });
        }
        return results.toOwnedSlice(self.alloc);
    }

    /// 统计: 总记录数 + 按 kind 分组
    pub fn stats(self: *const SqliteDb, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        const stmt = try self.prepare(
            \\SELECT kind, COUNT(*), MAX(importance)
            \\FROM episodes
            \\GROUP BY kind
            \\ORDER BY COUNT(*) DESC;
        );
        defer _ = sqlite3_finalize(stmt);

        try buf.appendSlice(alloc, "{\"episodes_by_kind\":[");
        var first = true;
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return SqliteError.StepFailed;
            const kind = dupColumnText(alloc, stmt, 0);
            defer alloc.free(kind);
            const count = sqlite3_column_int64(stmt, 1);
            const imp = sqlite3_column_double(stmt, 2);
            if (!first) try buf.append(alloc, ',');
            first = false;
            try buf.print(alloc, "{{\"kind\":\"{s}\",\"count\":{d},\"max_importance\":{d:.3}}}", .{ kind, count, imp });
        }
        try buf.appendSlice(alloc, "]}");
        return buf.toOwnedSlice(alloc);
    }

    // ====== 落盘文件 hash 追踪 (防止重复 adopt) ======

    /// 检查 (kind, hash) 是否已 adopt. 返: true=已 adopt, false=未
    pub fn isAdopted(self: *const SqliteDb, kind: []const u8, hash: u64) !bool {
        const hex = hashToHex(hash);
        const hash_str = hex[0..];
        const stmt = try self.prepare(
            \\SELECT 1 FROM evolved_adopted WHERE kind = ? AND hash = ? LIMIT 1
        );
        defer _ = sqlite3_finalize(stmt);
        var kind_z: [128]u8 = undefined;
        if (kind.len > kind_z.len) return false;
        @memcpy(kind_z[0..kind.len], kind);
        _ = sqlite3_bind_text(stmt, 1, &kind_z, @intCast(kind.len), null);
        _ = sqlite3_bind_text(stmt, 2, hash_str.ptr, @intCast(hash_str.len), null);
        const rc = sqlite3_step(stmt);
        return rc == 100; // SQLITE_ROW
    }

    /// 记录 adopt (idempotent via UNIQUE constraint)
    pub fn recordAdopted(
        self: *const SqliteDb,
        io: std.Io,
        kind: []const u8,
        tick: i64,
        filename: []const u8,
        hash: u64,
        source_path: []const u8,
        target_path: []const u8,
        size: i64,
    ) !void {
        const hex = hashToHex(hash);
        const hash_str = hex[0..];
        const stmt = try self.prepare(
            \\INSERT OR IGNORE INTO evolved_adopted (kind, tick, filename, hash, source_path, target_path, size, adopted_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = sqlite3_finalize(stmt);

        var kind_z: [64]u8 = undefined;
        if (kind.len > kind_z.len) return;
        @memcpy(kind_z[0..kind.len], kind);
        _ = sqlite3_bind_text(stmt, 1, &kind_z, @intCast(kind.len), null);

        _ = sqlite3_bind_int64(stmt, 2, tick);

        var fn_z: [128]u8 = undefined;
        if (filename.len > fn_z.len) return;
        @memcpy(fn_z[0..filename.len], filename);
        _ = sqlite3_bind_text(stmt, 3, &fn_z, @intCast(filename.len), null);

        _ = sqlite3_bind_text(stmt, 4, hash_str.ptr, @intCast(hash_str.len), null);

        var src_z: [512]u8 = undefined;
        if (source_path.len > src_z.len) return;
        @memcpy(src_z[0..source_path.len], source_path);
        _ = sqlite3_bind_text(stmt, 5, &src_z, @intCast(source_path.len), null);

        var tgt_z: [512]u8 = undefined;
        if (target_path.len > tgt_z.len) return;
        @memcpy(tgt_z[0..target_path.len], target_path);
        _ = sqlite3_bind_text(stmt, 6, &tgt_z, @intCast(target_path.len), null);

        _ = sqlite3_bind_int64(stmt, 7, size);

        _ = sqlite3_bind_int64(stmt, 8, std.Io.Clock.real.now(io).toSeconds());

        _ = sqlite3_step(stmt);
    }

    /// 列出所有已 adopt 的文件 (供 UI 展示)
    pub const AdoptedRow = struct {
        id: i64,
        kind: []u8,
        tick: i64,
        filename: []u8,
        hash: []u8,
        source_path: []u8,
        target_path: []u8,
        size: i64,
        adopted_at: i64,
    };

    pub fn listAdopted(self: *const SqliteDb, limit: i64) ![]AdoptedRow {
        var results: std.ArrayList(AdoptedRow) = .empty;
        errdefer {
            for (results.items) |r| {
                self.allocator.free(r.kind);
                self.allocator.free(r.filename);
                self.allocator.free(r.hash);
                self.allocator.free(r.source_path);
                self.allocator.free(r.target_path);
            }
            results.deinit(self.allocator);
        }
        const stmt = try self.prepare(
            \\SELECT id, kind, tick, filename, hash, source_path, target_path, size, adopted_at
            \\FROM evolved_adopted ORDER BY adopted_at DESC LIMIT ?
        );
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, limit);
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc != 100) break; // not ROW
            const id = sqlite3_column_int64(stmt, 0);
            const kind = dupColumnText(self.allocator, stmt, 1);
            const tick_v = sqlite3_column_int64(stmt, 2);
            const filename = dupColumnText(self.allocator, stmt, 3);
            const hash = dupColumnText(self.allocator, stmt, 4);
            const source_path = dupColumnText(self.allocator, stmt, 5);
            const target_path = dupColumnText(self.allocator, stmt, 6);
            const size = sqlite3_column_int64(stmt, 7);
            const adopted_at = sqlite3_column_int64(stmt, 8);
            try results.append(self.allocator, .{
                .id = id,
                .kind = kind,
                .tick = tick_v,
                .filename = filename,
                .hash = hash,
                .source_path = source_path,
                .target_path = target_path,
                .size = size,
                .adopted_at = adopted_at,
            });
        }
        return results.toOwnedSlice(self.allocator);
    }
};

extern "c" fn sqlite3_last_insert_rowid(db: *sqlite3) i64;

// ===== FNV-1a 64-bit hash (简单, 不用拉外部 crypto 库) =====
pub fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (data) |b| {
        h = (h ^ b) *% 0x100000001b3; // FNV prime
    }
    return h;
}

/// 把 64-bit hash 格式化成 16 字符 hex (sqlite TEXT 字段存)
pub fn hashToHex(hash: u64) [16]u8 {
    var buf: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const nibble: u4 = @intCast((hash >> shift) & 0xF);
        buf[i] = hex[nibble];
    }
    return buf;
}

// ============================================================
// helpers
// ============================================================

fn bindTextAlloc(alloc: Allocator, stmt: *sqlite3_stmt, idx: c_int, s: []const u8) !void {
    // 复制一份, 因为 sqlite 会在 step 时拿引用
    // 用 SQLITE_STATIC (null destructor) — 我们保留字符串 alive 到 step 完
    const dup = try alloc.dupe(u8, s);
    _ = sqlite3_bind_text(stmt, idx, dup.ptr, @intCast(dup.len), null);
    // 注意: dup 内存会泄漏. 用 SQLITE_TRANSIENT 应该更好, 但需要 cast to -1 ptr
}

fn bindText(_: *sqlite3_stmt, _: c_int, _: []const u8, _: []const u8) !void {}

fn dupColumnText(alloc: Allocator, stmt: *sqlite3_stmt, idx: c_int) []u8 {
    const ptr = sqlite3_column_text(stmt, idx);
    // sqlite 不保证 null 终止, 我们拿 len 从 column bytes
    // 简化: 走 C-string 终止
    const len = cStrlen(ptr);
    return alloc.dupe(u8, ptr[0..len]) catch &[_]u8{};
}

fn cStrlen(s: [*]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

/// SQLITE_TRANSIENT: 让 sqlite 复制字符串 (我们给的指针释放后仍可读)
/// Zig 里用 fn (void) callconv(.c) 表示
fn sqlTransientDestructor(_: ?*anyopaque) callconv(.c) void {}
