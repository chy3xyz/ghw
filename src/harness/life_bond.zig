//! 人机共生配置。一份 JSON 让数字生命知道：住在这台电脑上，和谁共生，对方在意什么。
//!
//! 配置只声明关系。存在度公式不动。已有自传不覆盖。偏好写成 [with:] 信念，重复加载会替换这批信念。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Memory = @import("memory.zig").Memory;
const BeliefSource = @import("memory.zig").BeliefSource;
const HumanGSP = @import("human_symbiosis/human_gsp.zig").HumanGSP;
const state_json = @import("human_symbiosis/state_json.zig");

pub const MAX_ITEMS: usize = 8;
const PREF_BELIEFS: usize = 3;
const PREF_PREFIX = "[with:";
/// 没有 LLM 时的状态行前缀。这种自述只是运行日志，不算身份。
pub const TEMPLATE_NARRATIVE_PREFIX = "[no-LLM 模板]";
const CODE_WORDS = [_][]const u8{ "代码", "源码", "code" };

pub const LoadError = error{
    MissingHuman,
    OutOfMemory,
};

pub const LifeBond = struct {
    alloc: Allocator,
    enabled: bool = false,
    human_id: []u8 = &.{},
    display_name: []u8 = &.{},
    role: []u8 = &.{},
    narrative: []u8 = &.{},
    with_line: []u8 = &.{},
    preferences: std.ArrayList([]u8) = .empty,
    cares: std.ArrayList([]u8) = .empty,
    must_ask: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator) LifeBond {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *LifeBond) void {
        if (self.human_id.len > 0) self.alloc.free(self.human_id);
        if (self.display_name.len > 0) self.alloc.free(self.display_name);
        if (self.role.len > 0) self.alloc.free(self.role);
        if (self.narrative.len > 0) self.alloc.free(self.narrative);
        if (self.with_line.len > 0) self.alloc.free(self.with_line);
        freeList(self.alloc, &self.preferences);
        freeList(self.alloc, &self.cares);
        freeList(self.alloc, &self.must_ask);
        self.* = undefined;
    }

    /// 注册这个人，空自传才写入配置叙事，并替换 [with:] 偏好信念。
    pub fn bind(self: *const LifeBond, mem: *Memory, gsp: *HumanGSP) !BindReport {
        var report: BindReport = .{};
        if (!self.enabled or self.human_id.len == 0) return report;
        try gsp.register(self.human_id);
        report.registered = true;
        const narrative_is_log = std.mem.startsWith(u8, mem.self_narrative, TEMPLATE_NARRATIVE_PREFIX);
        if ((mem.self_narrative.len == 0 or narrative_is_log) and self.narrative.len > 0) {
            try mem.setSelfNarrative(self.narrative);
            report.narrative_set = true;
        }
        dropPrefBeliefs(mem);
        const n = @min(self.preferences.items.len, PREF_BELIEFS);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const text = try std.fmt.allocPrint(self.alloc, "{s}{s}] {s}", .{ PREF_PREFIX, self.human_id, self.preferences.items[i] });
            defer self.alloc.free(text);
            try mem.addBelief(.nature, text, 0.9, &.{});
            report.beliefs_written += 1;
        }
        return report;
    }

    /// must_ask 里提到代码时，写进源码树之前必须挂请求等人批准。
    pub fn mustAskCode(self: *const LifeBond) bool {
        if (!self.enabled) return false;
        for (self.must_ask.items) |item| {
            for (CODE_WORDS) |w| {
                if (std.mem.indexOf(u8, item, w) != null) return true;
            }
        }
        return false;
    }
};

pub const BindReport = struct {
    registered: bool = false,
    narrative_set: bool = false,
    beliefs_written: u32 = 0,
};

pub fn load(alloc: Allocator, json: []const u8) !LifeBond {
    var bond = LifeBond.init(alloc);
    errdefer bond.deinit();
    const id = state_json.extractJsonString(alloc, json, "human_id") orelse return LoadError.MissingHuman;
    bond.human_id = try unescape(alloc, id);
    alloc.free(id);
    if (bond.human_id.len == 0) return LoadError.MissingHuman;

    if (state_json.extractJsonString(alloc, json, "display_name")) |raw| {
        bond.display_name = try unescape(alloc, raw);
        alloc.free(raw);
    }
    if (bond.display_name.len == 0) bond.display_name = try alloc.dupe(u8, bond.human_id);

    if (state_json.extractJsonString(alloc, json, "role")) |raw| {
        bond.role = try unescape(alloc, raw);
        alloc.free(raw);
    }
    if (state_json.extractJsonString(alloc, json, "narrative")) |raw| {
        bond.narrative = try unescape(alloc, raw);
        alloc.free(raw);
    }
    try takeStrings(alloc, json, "preferences", &bond.preferences);
    try takeStrings(alloc, json, "cares_about", &bond.cares);
    try takeStrings(alloc, json, "must_ask", &bond.must_ask);
    bond.with_line = try makeWithLine(alloc, &bond);
    bond.enabled = true;
    return bond;
}

fn makeWithLine(alloc: Allocator, bond: *const LifeBond) ![]u8 {
    const role = if (bond.role.len > 0) bond.role else "这台电脑上的数字生命";
    if (bond.preferences.items.len > 0) {
        return std.fmt.allocPrint(alloc, "我是{s}。我和 {s} 共生。他要我：{s}。", .{
            role,
            bond.display_name,
            bond.preferences.items[0],
        });
    }
    return std.fmt.allocPrint(alloc, "我是{s}。我和 {s} 共生。", .{ role, bond.display_name });
}

fn freeList(alloc: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

fn dropPrefBeliefs(mem: *Memory) void {
    var i: usize = 0;
    while (i < mem.beliefs.items.len) {
        if (std.mem.startsWith(u8, mem.beliefs.items[i].text, PREF_PREFIX)) {
            const old = mem.beliefs.orderedRemove(i);
            mem.alloc.free(old.text);
            mem.alloc.free(old.evidence_ticks);
        } else {
            i += 1;
        }
    }
}

fn takeStrings(alloc: Allocator, json: []const u8, key: []const u8, out: *std.ArrayList([]u8)) !void {
    var needle: [96]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return;
    const pos = std.mem.indexOf(u8, json, quoted) orelse return;
    const open = std.mem.indexOfPos(u8, json, pos + quoted.len, "[") orelse return;
    const close = state_json.findMatchingBracket(json, open) orelse return;
    const body = json[open + 1 .. close];
    var i: usize = 0;
    while (i < body.len and out.items.len < MAX_ITEMS) {
        if (body[i] != '"') {
            i += 1;
            continue;
        }
        const parsed = try readString(alloc, body, i + 1);
        try out.append(alloc, parsed.text);
        i = parsed.next;
    }
}

const ReadString = struct { text: []u8, next: usize };

fn readString(alloc: Allocator, s: []const u8, start: usize) !ReadString {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(alloc);
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            try raw.append(alloc, s[i]);
            i += 1;
            try raw.append(alloc, s[i]);
            continue;
        }
        if (s[i] == '"') {
            const text = try unescape(alloc, raw.items);
            raw.deinit(alloc);
            return .{ .text = text, .next = i + 1 };
        }
        try raw.append(alloc, s[i]);
    }
    const text = try unescape(alloc, raw.items);
    raw.deinit(alloc);
    return .{ .text = text, .next = s.len };
}

fn unescape(alloc: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            const c: u8 = switch (raw[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => raw[i],
            };
            try out.append(alloc, c);
        } else {
            try out.append(alloc, raw[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

const sample =
    \\{"human_id":"n0x","display_name":"n0x","role":"这台 Mac 上的数字生命助手","narrative":"我住在这台电脑上。","preferences":["用中文说话","不杀进程"],"cares_about":["这台电脑能一直跑"],"must_ask":["删除文件"]}
;

test "life bond: config names the human and the first preference" {
    const alloc = testing.allocator;
    var bond = try load(alloc, sample);
    defer bond.deinit();
    try testing.expect(bond.enabled);
    try testing.expectEqualStrings("n0x", bond.human_id);
    try testing.expectEqual(@as(usize, 2), bond.preferences.items.len);
    try testing.expectEqual(@as(usize, 1), bond.must_ask.items.len);
    try testing.expect(std.mem.indexOf(u8, bond.with_line, "共生") != null);
    try testing.expect(std.mem.indexOf(u8, bond.with_line, "用中文说话") != null);
}

test "life bond: bind keeps an existing narrative and replaces preference beliefs" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("我已经记得以前的事");
    try mem.addBelief(BeliefSource.nature, "[with:n0x] 旧偏好", 0.5, &.{});
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var bond = try load(alloc, sample);
    defer bond.deinit();
    const once = try bond.bind(&mem, &gsp);
    try testing.expect(once.registered);
    try testing.expect(!once.narrative_set);
    try testing.expectEqualStrings("我已经记得以前的事", mem.self_narrative);
    const twice = try bond.bind(&mem, &gsp);
    try testing.expectEqual(twice.beliefs_written, once.beliefs_written);
    var pref_n: usize = 0;
    for (mem.beliefs.items) |b| {
        if (std.mem.startsWith(u8, b.text, "[with:")) pref_n += 1;
    }
    try testing.expectEqual(@as(usize, 2), pref_n);
    try testing.expect(gsp.peers.get("n0x") != null);
}

test "life bond: a status-log narrative is replaced by the configured self" {
    const alloc = testing.allocator;
    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative(TEMPLATE_NARRATIVE_PREFIX ++ " 我跑到了 tick=8792");
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    var bond = try load(alloc, sample);
    defer bond.deinit();
    const r = try bond.bind(&mem, &gsp);
    try testing.expect(r.narrative_set);
    try testing.expectEqualStrings("我住在这台电脑上。", mem.self_narrative);
}

test "life bond: must_ask about code turns on the ask-first gate" {
    const alloc = testing.allocator;
    var bond = try load(alloc, sample);
    defer bond.deinit();
    try testing.expect(!bond.mustAskCode());
    var with_code = try load(alloc,
        \\{"human_id":"n0x","must_ask":["删除文件","改他的代码"]}
    );
    defer with_code.deinit();
    try testing.expect(with_code.mustAskCode());
}
