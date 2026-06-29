//! state_json — human_symbiosis 块的最小 JSON 读写 (P7/P10 state.json)

const std = @import("std");
pub const Allocator = std.mem.Allocator;

pub fn findMatchingBrace(json: []const u8, start: usize) ?usize {
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

pub fn findMatchingBracket(json: []const u8, start: usize) ?usize {
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

pub fn extractJsonNumber(obj: []const u8, key: []const u8) ?[]const u8 {
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

pub fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
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

pub fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
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

/// 从顶层 state.json 提取 `"field_name":{...}` 对象切片 (含花括号)
pub fn extractObjectBlock(json: []const u8, field_name: []const u8) ?[]const u8 {
    var needle: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&needle, "\"{s}\":", .{field_name}) catch return null;
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const obj_start = std.mem.indexOfPos(u8, json, pos, "{") orelse return null;
    const obj_end = findMatchingBrace(json, obj_start) orelse return null;
    return json[obj_start .. obj_end + 1];
}

// ===== Tests =====

test "state_json: findMatchingBrace 基本匹配" {
    const json = "{\"a\":{\"b\":1}}";
    const end = findMatchingBrace(json, 0);
    try std.testing.expectEqual(@as(?usize, json.len - 1), end);
}

test "state_json: findMatchingBrace 嵌套 + 字符串跳过" {
    const json = "{\"inner\":{\"x\":\"}\"},\"y\":1}";
    const end = findMatchingBrace(json, 0);
    try std.testing.expectEqual(@as(?usize, json.len - 1), end);
}

test "state_json: findMatchingBrace 不完整返回 null" {
    const json = "{\"a\":{";
    const end = findMatchingBrace(json, 0);
    try std.testing.expect(end == null);
}

test "state_json: findMatchingBracket" {
    const json = "[\"a\",[\"b\",\"c\"],\"d\"]";
    const end = findMatchingBracket(json, 0);
    try std.testing.expectEqual(@as(?usize, json.len - 1), end);
}

test "state_json: extractJsonNumber" {
    const obj = "{\"score\":3.14,\"count\":42}";
    const score = extractJsonNumber(obj, "score");
    try std.testing.expect(score != null);
    try std.testing.expectEqualStrings("3.14", score.?);

    const count = extractJsonNumber(obj, "count");
    try std.testing.expect(count != null);
    try std.testing.expectEqualStrings("42", count.?);

    try std.testing.expect(extractJsonNumber(obj, "missing") == null);
}

test "state_json: extractJsonString" {
    const alloc = std.testing.allocator;
    const obj = "{\"name\":\"hello\",\"empty\":\"\"}";

    const name = extractJsonString(alloc, obj, "name");
    defer if (name) |n| alloc.free(n);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("hello", name.?);

    const empty = extractJsonString(alloc, obj, "empty");
    defer if (empty) |e| alloc.free(e);
    try std.testing.expect(empty != null);
    try std.testing.expectEqualStrings("", empty.?);

    try std.testing.expect(extractJsonString(alloc, obj, "missing") == null);
}

test "state_json: extractJsonString 转义字符" {
    const alloc = std.testing.allocator;
    const obj = "{\"msg\":\"line1\\nline2\\ttab\\\"quote\"}";
    const msg = extractJsonString(alloc, obj, "msg");
    defer if (msg) |m| alloc.free(m);
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\\"quote", msg.?);
}

test "state_json: writeJsonString" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try writeJsonString(alloc, &buf, "hello\"world\nline2");
    const result = try buf.toOwnedSlice(alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello\\\"world\\nline2", result);
}

test "state_json: extractObjectBlock" {
    const json =
        \\{"version":1,"data":{"key":"val","nested":{"a":1}},"end":true}
    ;
    const block = extractObjectBlock(json, "data");
    try std.testing.expect(block != null);
    try std.testing.expect(block.?[0] == '{');
    try std.testing.expect(block.?[block.?.len - 1] == '}');

    try std.testing.expect(extractObjectBlock(json, "missing") == null);
}

test "state_json: extractObjectBlock 对象内有嵌套花括号" {
    const json = "{\"cfg\":{\"rules\":[{\"a\":1},{\"b\":2}],\"enabled\":true}}";
    const block = extractObjectBlock(json, "cfg");
    try std.testing.expect(block != null);
    // 应匹配到最外层 'cfg' 的整个对象
    try std.testing.expectEqualStrings("{\"rules\":[{\"a\":1},{\"b\":2}],\"enabled\":true}", block.?);
}
