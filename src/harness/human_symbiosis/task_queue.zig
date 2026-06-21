//! TaskQueue: 任务队列 + 优先级
//!
//! 数字生命"接活"的数据结构:
//!   - 人类投递任务 (title / description / required_dimension / deadline)
//!   - 数字生命取任务 (按 priority 排序)
//!   - 完成任务 → 记录 result + 等待 human feedback
//!
//! 任务维度对齐 GHW 三源合恰: material / representation / nature

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../../util/math.zig").F;

pub const Task = struct {
    id: u64,
    /// 任务标题
    title: []const u8,
    /// 任务描述 (自然语言, 可给 LLM 看)
    description: []const u8,
    /// 优先级: 1 (低) - 10 (高)
    priority: u8 = 5,
    /// 投递者 (人类 id)
    from_human: []const u8,
    /// 任务需要的维度 (对齐 GHW 三源)
    required_dimension: Dimension = .all,
    /// 期望的 ΔE (投递者的预期, 实际可能不同)
    expected_delta_e: F = 0.05,
    /// 给数字生命多少 cycle
    cycles_allocated: u32 = 4,
    /// 创建时间
    created_at: u64 = 0,
    /// 状态
    status: Status = .pending,
    /// 结果 (completed/failed 时填)
    result: ?TaskResult = null,
    /// 人类反馈 (signal 模块填)
    feedback: ?HumanFeedbackRef = null,
    /// 投递来源 (P13: UI 标记 + 审计)
    source: Source = .unknown,
    allocator: Allocator,

    pub const Dimension = enum { material, representation, nature, all };
    pub const Status = enum { pending, in_progress, completed, failed, abandoned };
    pub const Source = enum {
        unknown,
        chat_forced,
        chat_heuristic,
        llm_proposer,
        balance,
        human,
    };

    pub fn sourceLabel(s: Source) []const u8 {
        return switch (s) {
            .unknown => "—",
            .chat_forced => "@task",
            .chat_heuristic => "chat",
            .llm_proposer => "llm",
            .balance => "balance",
            .human => "human",
        };
    }

    pub const TaskResult = struct {
        output: []u8, // 任务输出 (代码/文本/...)
        actual_delta_e: F,
        cycles_used: u32,
        completed_at: u64,
    };

    /// 人类反馈 (不带 from_human, 跟 task 关联时补)
    pub const HumanFeedbackRef = struct {
        score: i8,
        comment: []const u8,
        timestamp: u64,
        delta_e: F,
    };

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.title);
        self.allocator.free(self.description);
        self.allocator.free(self.from_human);
        if (self.result) |r| {
            self.allocator.free(r.output);
        }
        if (self.feedback) |f| {
            self.allocator.free(f.comment);
        }
    }
};

/// 优先级队列: pending 任务按 priority 排序
pub const TaskQueue = struct {
    allocator: Allocator,
    tasks: std.ArrayList(*Task) = .empty,
    next_id: u64 = 1,
    /// pending 计数 (O(1) 查询)
    pending_count: u32 = 0,
    /// completed 计数
    completed_count: u32 = 0,
    /// failed 计数
    failed_count: u32 = 0,

    pub fn init(allocator: Allocator) TaskQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TaskQueue) void {
        for (self.tasks.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.tasks.deinit(self.allocator);
    }

    /// 投递一个新任务 (从人类), 返回 task id; source 默认 unknown
    pub fn submit(
        self: *TaskQueue,
        title: []const u8,
        description: []const u8,
        from_human: []const u8,
        priority: u8,
        required_dimension: Task.Dimension,
        cycles_allocated: u32,
    ) !u64 {
        return self.submitWithSource(title, description, from_human, priority, required_dimension, cycles_allocated, .unknown);
    }

    pub fn submitWithSource(
        self: *TaskQueue,
        title: []const u8,
        description: []const u8,
        from_human: []const u8,
        priority: u8,
        required_dimension: Task.Dimension,
        cycles_allocated: u32,
        source: Task.Source,
    ) !u64 {
        const t = try self.allocator.create(Task);
        errdefer self.allocator.destroy(t);
        t.* = .{
            .id = self.next_id,
            .title = try self.allocator.dupe(u8, title),
            .description = try self.allocator.dupe(u8, description),
            .from_human = try self.allocator.dupe(u8, from_human),
            .priority = priority,
            .required_dimension = required_dimension,
            .cycles_allocated = cycles_allocated,
            .expected_delta_e = 0.05,
            .created_at = 0, // 调用方填
            .status = .pending,
            .source = source,
            .allocator = self.allocator,
        };
        self.next_id += 1;
        try self.tasks.append(self.allocator, t);
        self.pending_count += 1;
        return t.id;
    }

    /// 取下一个 pending 任务 (按 priority 降序, 同 priority 按 id 升序)
    /// 取出后 status 变 in_progress
    pub fn dequeue(self: *TaskQueue) ?*Task {
        var best_idx: ?usize = null;
        var best_priority: i8 = -1;
        for (self.tasks.items, 0..) |t, i| {
            if (t.status != .pending) continue;
            const p: i8 = @intCast(t.priority);
            if (p > best_priority) {
                best_priority = p;
                best_idx = i;
            }
        }
        if (best_idx) |i| {
            const t = self.tasks.items[i];
            t.status = .in_progress;
            self.pending_count -= 1;
            return t;
        }
        return null;
    }

    /// 标记任务完成
    pub fn complete(
        self: *TaskQueue,
        task_id: u64,
        output: []const u8,
        actual_delta_e: F,
        cycles_used: u32,
    ) !void {
        const t = self.find(task_id) orelse return;
        // 释放旧 output
        if (t.result) |r| {
            self.allocator.free(r.output);
        }
        t.result = .{
            .output = try self.allocator.dupe(u8, output),
            .actual_delta_e = actual_delta_e,
            .cycles_used = cycles_used,
            .completed_at = 0,
        };
        t.status = .completed;
        self.completed_count += 1;
    }

    /// 标记任务失败
    pub fn fail(self: *TaskQueue, task_id: u64) void {
        if (self.find(task_id)) |t| {
            if (t.status == .completed) self.completed_count -= 1; // 撤回之前的完成计数
            t.status = .failed;
            self.failed_count += 1;
        }
    }

    /// 附加人类反馈
    pub fn attachFeedback(
        self: *TaskQueue,
        task_id: u64,
        score: i8,
        comment: []const u8,
        timestamp: u64,
        delta_e: F,
    ) !void {
        const t = self.find(task_id) orelse return;
        // 释放旧 comment
        if (t.feedback) |old| {
            self.allocator.free(old.comment);
        }
        t.feedback = .{
            .score = score,
            .comment = try self.allocator.dupe(u8, comment),
            .timestamp = timestamp,
            .delta_e = delta_e,
        };
    }

    /// 找任务 by id
    pub fn find(self: *TaskQueue, task_id: u64) ?*Task {
        for (self.tasks.items) |t| {
            if (t.id == task_id) return t;
        }
        return null;
    }

    /// pending 任务按维度累计 priority 权重 (P5: 供 GHWAgent.computeTaskBias 使用)
    pub const DimensionWeights = struct {
        pending_count: u32 = 0,
        material: u32 = 0,
        representation: u32 = 0,
        nature: u32 = 0,
    };

    pub fn pendingDimensionWeights(self: *const TaskQueue) DimensionWeights {
        var w: DimensionWeights = .{};
        for (self.tasks.items) |t| {
            if (t.status != .pending) continue;
            w.pending_count += 1;
            const p: u32 = t.priority;
            switch (t.required_dimension) {
                .material => w.material += p,
                .representation => w.representation += p,
                .nature => w.nature += p,
                .all => {
                    w.material += p;
                    w.representation += p;
                    w.nature += p;
                },
            }
        }
        return w;
    }

    /// 统计: 跨所有任务的人类反馈总 ΔE
    pub fn totalHumanDeltaE(self: *TaskQueue) F {
        var sum: F = 0;
        for (self.tasks.items) |t| {
            if (t.feedback) |f| sum += f.delta_e;
        }
        return sum;
    }

    /// 统计: 实际完成任务的累计 ΔE (从 Task.result.actual_delta_e)
    pub fn totalActualDeltaE(self: *const TaskQueue) F {
        var sum: F = 0;
        for (self.tasks.items) |t| {
            if (t.result) |r| sum += r.actual_delta_e;
        }
        return sum;
    }

    /// 序列化为 JSON (P7: state.json 持久化 pending/in_progress 及历史任务)
    pub fn toJson(self: *const TaskQueue, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.print(alloc, "{{\"next_id\":{d},\"pending_count\":{d},\"completed_count\":{d},\"failed_count\":{d},\"tasks\":[", .{
            self.next_id, self.pending_count, self.completed_count, self.failed_count,
        });
        for (self.tasks.items, 0..) |t, i| {
            if (i > 0) try buf.append(alloc, ',');
            try appendTaskJson(alloc, &buf, t);
        }
        try buf.appendSlice(alloc, "]}");
        return buf.toOwnedSlice(alloc);
    }

    /// 从 state.json 的 task_queue 块恢复 (P7 跨重启 pending 不丢)。
    /// 旧版无 task_queue 字段时返回 false, 不报错。
    pub fn loadFromJson(self: *TaskQueue, json: []const u8) !bool {
        const tq_pos = std.mem.indexOf(u8, json, "\"task_queue\":") orelse return false;
        const obj_start = std.mem.indexOfPos(u8, json, tq_pos, "{") orelse return false;
        const obj_end = findMatchingBrace(json, obj_start) orelse return false;
        const obj = json[obj_start .. obj_end + 1];

        self.clearAll();

        if (extractJsonNumber(obj, "next_id")) |n| {
            self.next_id = std.fmt.parseInt(u64, n, 10) catch 1;
        }

        if (std.mem.indexOf(u8, obj, "\"tasks\"")) |tasks_pos| {
            const arr_start = std.mem.indexOfPos(u8, obj, tasks_pos, "[") orelse {
                self.recomputeCounts();
                return true;
            };
            const arr_end = findMatchingBracket(obj, arr_start) orelse {
                self.recomputeCounts();
                return true;
            };
            const arr = obj[arr_start + 1 .. arr_end];
            var i: usize = 0;
            while (i < arr.len) {
                const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
                const oe = findMatchingBrace(arr, os) orelse break;
                const one = arr[os .. oe + 1];
                try loadOneTask(self, one);
                i = oe + 1;
            }
        }

        var max_id: u64 = 0;
        for (self.tasks.items) |t| max_id = @max(max_id, t.id);
        if (max_id >= self.next_id) self.next_id = max_id + 1;
        self.recomputeCounts();
        return true;
    }

    fn clearAll(self: *TaskQueue) void {
        for (self.tasks.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.tasks.clearRetainingCapacity();
        self.next_id = 1;
        self.pending_count = 0;
        self.completed_count = 0;
        self.failed_count = 0;
    }

    fn recomputeCounts(self: *TaskQueue) void {
        self.pending_count = 0;
        self.completed_count = 0;
        self.failed_count = 0;
        for (self.tasks.items) |t| {
            switch (t.status) {
                .pending => self.pending_count += 1,
                .in_progress => {},
                .completed => self.completed_count += 1,
                .failed => self.failed_count += 1,
                .abandoned => {},
            }
        }
    }
};

fn appendTaskJson(alloc: Allocator, buf: *std.ArrayList(u8), t: *const Task) !void {
    try buf.print(alloc, "{{\"id\":{d},\"title\":\"", .{t.id});
    try writeJsonString(alloc, buf, t.title);
    try buf.appendSlice(alloc, "\",\"description\":\"");
    try writeJsonString(alloc, buf, t.description);
    try buf.print(alloc, "\",\"priority\":{d},\"from_human\":\"", .{t.priority});
    try writeJsonString(alloc, buf, t.from_human);
    try buf.print(alloc, "\",\"required_dimension\":\"{s}\",\"expected_delta_e\":{d:.6},\"cycles_allocated\":{d},\"created_at\":{d},\"status\":\"{s}\",\"source\":\"{s}\",", .{
        @tagName(t.required_dimension), t.expected_delta_e, t.cycles_allocated, t.created_at, @tagName(t.status), @tagName(t.source),
    });
    try buf.appendSlice(alloc, "\"result\":");
    if (t.result) |r| {
        try buf.appendSlice(alloc, "{\"output\":\"");
        try writeJsonString(alloc, buf, r.output);
        try buf.print(alloc, "\",\"actual_delta_e\":", .{});
        try buf.print(alloc, "{d:.6}", .{r.actual_delta_e});
        try buf.print(alloc, ",\"cycles_used\":{d},\"completed_at\":{d}", .{ r.cycles_used, r.completed_at });
        try buf.append(alloc, '}');
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"feedback\":");
    if (t.feedback) |f| {
        try buf.print(alloc, "{{\"score\":{d},\"comment\":\"", .{f.score});
        try writeJsonString(alloc, buf, f.comment);
        try buf.print(alloc, "\",\"timestamp\":{d},\"delta_e\":", .{f.timestamp});
        try buf.print(alloc, "{d:.6}", .{f.delta_e});
        try buf.append(alloc, '}');
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
}

fn loadOneTask(q: *TaskQueue, one: []const u8) !void {
    const id_str = extractJsonNumber(one, "id") orelse return;
    const id = std.fmt.parseInt(u64, id_str, 10) catch return;
    const title = extractJsonString(q.allocator, one, "title") orelse return;
    errdefer q.allocator.free(title);
    const description = extractJsonString(q.allocator, one, "description") orelse {
        q.allocator.free(title);
        return;
    };
    errdefer q.allocator.free(description);
    const from_human = extractJsonString(q.allocator, one, "from_human") orelse {
        q.allocator.free(title);
        q.allocator.free(description);
        return;
    };
    errdefer q.allocator.free(from_human);

    const t = try q.allocator.create(Task);
    errdefer q.allocator.destroy(t);

    const dim_owned = extractJsonString(q.allocator, one, "required_dimension");
    const status_owned = extractJsonString(q.allocator, one, "status");
    const source_owned = extractJsonString(q.allocator, one, "source");
    defer if (dim_owned) |d| q.allocator.free(d);
    defer if (status_owned) |s| q.allocator.free(s);
    defer if (source_owned) |s| q.allocator.free(s);

    t.* = .{
        .id = id,
        .title = title,
        .description = description,
        .from_human = from_human,
        .priority = @intCast(std.fmt.parseInt(u16, extractJsonNumber(one, "priority") orelse "5", 10) catch 5),
        .required_dimension = parseDimension(if (dim_owned) |d| d else "all"),
        .expected_delta_e = std.fmt.parseFloat(F, extractJsonNumber(one, "expected_delta_e") orelse "0.05") catch 0.05,
        .cycles_allocated = @intCast(std.fmt.parseInt(u32, extractJsonNumber(one, "cycles_allocated") orelse "4", 10) catch 4),
        .created_at = std.fmt.parseInt(u64, extractJsonNumber(one, "created_at") orelse "0", 10) catch 0,
        .status = parseStatus(if (status_owned) |s| s else "pending"),
        .source = parseSource(if (source_owned) |s| s else "unknown"),
        .allocator = q.allocator,
    };

    if (std.mem.indexOf(u8, one, "\"result\":null") == null) {
        if (std.mem.indexOf(u8, one, "\"result\":")) |rp| {
            if (std.mem.indexOfPos(u8, one, rp, "{")) |obj_start| {
                if (findMatchingBrace(one, obj_start)) |obj_end| {
                    const robj = one[obj_start .. obj_end + 1];
                    if (extractJsonString(q.allocator, robj, "output")) |output| {
                        t.result = .{
                            .output = output,
                            .actual_delta_e = std.fmt.parseFloat(F, extractJsonNumber(robj, "actual_delta_e") orelse "0") catch 0,
                            .cycles_used = @intCast(std.fmt.parseInt(u32, extractJsonNumber(robj, "cycles_used") orelse "0", 10) catch 0),
                            .completed_at = std.fmt.parseInt(u64, extractJsonNumber(robj, "completed_at") orelse "0", 10) catch 0,
                        };
                    }
                }
            }
        }
    }

    if (std.mem.indexOf(u8, one, "\"feedback\":null") == null) {
        if (std.mem.indexOf(u8, one, "\"feedback\":")) |fp| {
            if (std.mem.indexOfPos(u8, one, fp, "{")) |obj_start| {
                if (findMatchingBrace(one, obj_start)) |obj_end| {
                    const fobj = one[obj_start .. obj_end + 1];
                    if (extractJsonString(q.allocator, fobj, "comment")) |comment| {
                        t.feedback = .{
                            .score = @intCast(std.fmt.parseInt(i16, extractJsonNumber(fobj, "score") orelse "0", 10) catch 0),
                            .comment = comment,
                            .timestamp = std.fmt.parseInt(u64, extractJsonNumber(fobj, "timestamp") orelse "0", 10) catch 0,
                            .delta_e = std.fmt.parseFloat(F, extractJsonNumber(fobj, "delta_e") orelse "0") catch 0,
                        };
                    }
                }
            }
        }
    }

    try q.tasks.append(q.allocator, t);
}

fn parseDimension(s: []const u8) Task.Dimension {
    return parseDimensionPublic(s);
}

pub fn parseDimensionPublic(s: []const u8) Task.Dimension {
    inline for (std.enums.values(Task.Dimension)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .all;
}

fn parseStatus(s: []const u8) Task.Status {
    inline for (std.enums.values(Task.Status)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .pending;
}

fn parseSource(s: []const u8) Task.Source {
    inline for (std.enums.values(Task.Source)) |v| {
        if (std.mem.eql(u8, s, @tagName(v))) return v;
    }
    return .unknown;
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
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

fn findMatchingBracket(json: []const u8, start: usize) ?usize {
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
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn extractJsonNumber(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    var ve = pos + quoted_key.len;
    while (ve < obj.len and (obj[ve] == ' ' or obj[ve] == '\t' or obj[ve] == '\n')) : (ve += 1) {}
    const start = ve;
    while (ve < obj.len and (std.ascii.isDigit(obj[ve]) or obj[ve] == '.' or obj[ve] == '-')) : (ve += 1) {}
    if (ve == start) return null;
    return obj[start..ve];
}

fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    var vs = pos + quoted_key.len;
    while (vs < obj.len and (obj[vs] == ' ' or obj[vs] == '\t' or obj[vs] == '\n')) : (vs += 1) {}
    if (vs >= obj.len or obj[vs] != '"') return null;
    const content_start = vs + 1;
    var ve: usize = content_start;
    while (ve < obj.len) : (ve += 1) {
        if (obj[ve] == '\\' and ve + 1 < obj.len) {
            ve += 1;
            if (obj[ve] == 'u' and ve + 4 < obj.len) ve += 4;
            continue;
        }
        if (obj[ve] == '"') break;
    }
    if (ve >= obj.len) return null;
    return alloc.dupe(u8, obj[content_start..ve]) catch null;
}

fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) try buf.print(alloc, "\\u{x:0>4}", .{c}) else try buf.append(alloc, c),
        }
    }
}

// ===== Tests =====

const testing = std.testing;

test "TaskQueue: submit + dequeue + complete + feedback" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    const id1 = try q.submit("t1", "desc1", "alice", 8, .material, 4);
    const id2 = try q.submit("t2", "desc2", "bob", 5, .representation, 2);
    try testing.expectEqual(@as(u32, 2), q.pending_count);

    // 高优先级先出
    const first = q.dequeue().?;
    try testing.expectEqual(id1, first.id);
    try testing.expectEqual(@as(u8, 8), first.priority);
    try testing.expectEqual(Task.Status.in_progress, first.status);
    try testing.expectEqual(@as(u32, 1), q.pending_count);

    // 完成
    try q.complete(id1, "output1", 0.05, 4);
    const t1 = q.find(id1).?;
    try testing.expectEqual(Task.Status.completed, t1.status);
    try testing.expectEqual(@as(u32, 1), q.completed_count);

    // 反馈
    try q.attachFeedback(id1, 4, "好活", 0, 0.24);
    const fb = t1.feedback.?;
    try testing.expectEqual(@as(i8, 4), fb.score);
    try testing.expectEqual(@as(F, 0.24), fb.delta_e);

    // 第二个还在
    const second = q.dequeue().?;
    try testing.expectEqual(id2, second.id);
    try testing.expectEqual(@as(F, 0.24), q.totalHumanDeltaE()); // 0.24 from t1's feedback
}

test "TaskQueue: priority order 严格降序" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    _ = try q.submit("low", "d", "a", 1, .all, 1);
    _ = try q.submit("high", "d", "a", 10, .all, 1);
    _ = try q.submit("mid", "d", "a", 5, .all, 1);

    const t1 = q.dequeue().?;
    try testing.expectEqualStrings("high", t1.title);
    const t2 = q.dequeue().?;
    try testing.expectEqualStrings("mid", t2.title);
    const t3 = q.dequeue().?;
    try testing.expectEqualStrings("low", t3.title);
}

test "TaskQueue: pendingDimensionWeights 按 priority 加权" {
    const alloc = std.testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    _ = try q.submit("mat", "m", "alice", 8, .material, 4);
    _ = try q.submit("nat", "n", "bob", 10, .nature, 4);
    _ = try q.submit("rep", "r", "carol", 5, .representation, 4);
    if (q.find(3)) |t| t.status = .completed;

    const w = q.pendingDimensionWeights();
    try std.testing.expectEqual(@as(u32, 2), w.pending_count);
    try std.testing.expectEqual(@as(u32, 8), w.material);
    try std.testing.expectEqual(@as(u32, 10), w.nature);
    try std.testing.expectEqual(@as(u32, 0), w.representation);
}

test "TaskQueue: fail 后 completed_count 减 1" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    _ = try q.submit("t1", "d", "a", 5, .all, 1);
    const t = q.dequeue().?;
    try q.complete(t.id, "out", 0.1, 1);
    try testing.expectEqual(@as(u32, 1), q.completed_count);
    q.fail(t.id);
    try testing.expectEqual(@as(u32, 0), q.completed_count);
    try testing.expectEqual(@as(u32, 1), q.failed_count);
}

test "TaskQueue: toJson/loadFromJson roundtrip" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    const id1 = try q.submit("mat task", "fix material", "alice", 8, .material, 4);
    const id2 = try q.submit("nat task", "explore nature", "bob", 8, .nature, 2);
    const first = q.dequeue().?;
    try testing.expectEqual(id1, first.id); // 同 priority 时先投递先出
    try q.complete(id1, "done output", 0.12, 3);
    try q.attachFeedback(id1, 5, "excellent", 100, 0.3);

    const json = try q.toJson(alloc);
    defer alloc.free(json);
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"task_queue\":{s}}}", .{json});
    defer alloc.free(wrapped);

    var q2 = TaskQueue.init(alloc);
    defer q2.deinit();
    try testing.expect(try q2.loadFromJson(wrapped));
    try testing.expectEqual(@as(u32, 1), q2.pending_count);
    try testing.expectEqual(@as(u32, 1), q2.completed_count);
    try testing.expectEqual(id2, q2.dequeue().?.id);
    const restored = q2.find(id1).?;
    try testing.expectEqual(Task.Status.completed, restored.status);
    try testing.expectEqual(Task.Source.unknown, restored.source);
    try testing.expectEqualStrings("done output", restored.result.?.output);
    try testing.expectEqual(@as(i8, 5), restored.feedback.?.score);
    try testing.expect(q2.next_id > id2);
}

test "TaskQueue: source roundtrip" {
    const alloc = testing.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();
    _ = try q.submitWithSource("forced", "d", "human", 8, .nature, 4, .chat_forced);
    _ = try q.submitWithSource("balance", "d", "alice", 9, .material, 4, .balance);

    const json = try q.toJson(alloc);
    defer alloc.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"source\":\"chat_forced\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source\":\"balance\"") != null);

    var q2 = TaskQueue.init(alloc);
    defer q2.deinit();
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"task_queue\":{s}}}", .{json});
    defer alloc.free(wrapped);
    try testing.expect(try q2.loadFromJson(wrapped));
    for (q2.tasks.items) |t| {
        if (std.mem.eql(u8, t.title, "forced")) try testing.expectEqual(Task.Source.chat_forced, t.source);
        if (std.mem.eql(u8, t.title, "balance")) try testing.expectEqual(Task.Source.balance, t.source);
    }
}
