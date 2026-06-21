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
