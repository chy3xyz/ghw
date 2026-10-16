//! 主动认识共生的人，并据此改自己的下一步。
//!
//! 和自改进同一条路：从眼前证据提出候选，先丢掉私密路径，
//! 同一个主题反复出现才算验证通过，然后自己写入信念并排一件事。
//! 不等待人点批准。改源码、结束进程、删除文件不走这里。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Memory = @import("memory.zig").Memory;
const Belief = @import("memory.zig").Belief;
const tq = @import("human_symbiosis/task_queue.zig");

pub const MIN_RECURRENCE: u32 = 2;

const sensitive_names = [_][]const u8{
    ".ssh",     ".gnupg", ".aws", ".kube",
    "Keychains", "Cookies", "Mail", "Messages",
    "credentials", "secrets", "id_rsa", "id_ed25519",
};

const generic_dirs = [_][]const u8{
    "Users",     "home",       "Library", "Applications",
    "Documents", "Desktop",    "Downloads", "src",
    "lib",       "test",       "tests",   "zig-out",
    "zig-cache", ".zig-cache", "tmp",     "node_modules",
    ".git",      "dist",       "build",   "target",
    "vendor",    "ui",         "examples", "config",
    "scripts",   "private",    "var",     "usr",
    "bin",       "opt",        "Data",    "Logs",
    "Preferences", "Caches",   "Containers", "CloudKit",
};

const system_comms = [_][]const u8{
    "kernel_task", "WindowServer", "loginwindow", "launchd",
    "syslogd",     "mds",          "mds_stores",  "Finder",
    "coreaudiod",  "bluetoothd",   "trustd",      "cfprefsd",
    "distnoted",   "ui_server",    "ghw-daemon",  "zjev-serve",
};

pub const Step = struct {
    guarded: u32 = 0,
    adopted: bool = false,
    reinforced: bool = false,
    mission_id: u64 = 0,
    /// 本轮选中的主题。空串表示证据不够。调用方负责 free。
    theme: []u8,

    pub fn deinit(self: *Step, alloc: Allocator) void {
        alloc.free(self.theme);
        self.theme = &.{};
    }
};

const Slot = struct {
    name: []const u8,
    count: u32,
    depth: u32,
};

/// 从路径和进程名走一轮。paths/comms 的内存由调用方持有。
pub fn step(
    alloc: Allocator,
    memory: *Memory,
    queue: *tq.TaskQueue,
    io: ?std.Io,
    tick: u64,
    paths: []const []const u8,
    comms: []const []const u8,
) !Step {
    var out = Step{ .theme = try alloc.dupe(u8, "") };
    errdefer out.deinit(alloc);

    var slots: [12]Slot = undefined;
    var nslots: usize = 0;

    for (paths) |path| {
        if (pathIsSensitive(path) or pathIsNoise(path)) {
            if (pathIsSensitive(path)) out.guarded += 1;
            continue;
        }
        tallyPath(&slots, &nslots, path);
    }
    for (comms) |comm| {
        if (themeFromComm(comm)) |theme| tally(&slots, &nslots, theme, 1);
    }

    const best = bestSlot(slots[0..nslots]) orelse return out;
    if (best.count < MIN_RECURRENCE) return out;

    const theme_copy = try alloc.dupe(u8, best.name);
    alloc.free(out.theme);
    out.theme = theme_copy;
    const confidence = confidenceFor(best.count);

    if (findAbout(memory, out.theme)) |idx| {
        const cur = memory.beliefs.items[idx].confidence;
        if (confidence > cur) memory.beliefs.items[idx].confidence = confidence;
        out.reinforced = true;
    } else {
        const text = try std.fmt.allocPrint(alloc, "[about:{s}] 他最近反复出现在 {s}。这是我从这台电脑上的路径自己归纳的。", .{ out.theme, out.theme });
        defer alloc.free(text);
        try memory.addBeliefAt(.nature, text, confidence, &.{}, tick);
        out.adopted = true;
    }

    if (!hasAboutTask(queue, out.theme)) {
        const title = try std.fmt.allocPrint(alloc, "[about] {s}", .{out.theme});
        defer alloc.free(title);
        const desc = try std.fmt.allocPrint(alloc, "顺着他正在做的 {s} 加深认识。不读钥匙、邮件和浏览器记录。", .{out.theme});
        defer alloc.free(desc);
        out.mission_id = try queue.submitWithSource(
            title,
            desc,
            "ghw",
            6,
            .representation,
            1,
            .self_knowing,
        );
    }
    dropOtherAbout(memory, out.theme);

    if (io) |real_io| {
        if (out.adopted or out.reinforced) {
            const summary = try std.fmt.allocPrint(alloc, "self-knowing {s} count={d}", .{ out.theme, best.count });
            defer alloc.free(summary);
            memory.recordAt(real_io, .system_event, tick, summary, null, 1, 0) catch {};
        }
    }
    return out;
}

/// 信念文本里 `[about:主题]` 的主题切片，没有则 null。
pub fn themeIn(text: []const u8) ?[]const u8 {
    const prefix = "[about:";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// 置信度最高的一条关于人的主题。返回的切片指向信念文本。
pub fn dominant(beliefs: []const Belief) []const u8 {
    var best: []const u8 = "";
    var conf: F = -1;
    for (beliefs) |b| {
        if (themeIn(b.text)) |name| {
            if (b.confidence > conf) {
                conf = b.confidence;
                best = name;
            }
        }
    }
    return best;
}

fn confidenceFor(count: u32) F {
    const extra: F = @floatFromInt(count - MIN_RECURRENCE);
    const raw = 0.55 + 0.05 * extra;
    return if (raw > 0.90) 0.90 else raw;
}

fn findAbout(memory: *Memory, theme: []const u8) ?usize {
    for (memory.beliefs.items, 0..) |b, i| {
        if (themeIn(b.text)) |name| {
            if (std.mem.eql(u8, name, theme)) return i;
        }
    }
    return null;
}

fn hasAboutTask(queue: *tq.TaskQueue, theme: []const u8) bool {
    for (queue.tasks.items) |t| {
        if (t.status != .pending and t.status != .in_progress) continue;
        if (!std.mem.startsWith(u8, t.title, "[about] ")) continue;
        if (std.mem.eql(u8, t.title["[about] ".len..], theme)) return true;
    }
    return false;
}

fn dropOtherAbout(memory: *Memory, keep: []const u8) void {
    var i: usize = 0;
    while (i < memory.beliefs.items.len) {
        const name = themeIn(memory.beliefs.items[i].text) orelse {
            i += 1;
            continue;
        };
        if (std.mem.eql(u8, name, keep)) {
            i += 1;
            continue;
        }
        const old = memory.beliefs.orderedRemove(i);
        memory.alloc.free(old.text);
        memory.alloc.free(old.evidence_ticks);
    }
}

fn tally(slots: *[12]Slot, n: *usize, name: []const u8, depth: u32) void {
    for (slots.*[0..n.*]) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            s.count += 1;
            s.depth += depth;
            return;
        }
    }
    if (n.* >= slots.len) return;
    slots.*[n.*] = .{ .name = name, .count = 1, .depth = depth };
    n.* += 1;
}

fn tallyPath(slots: *[12]Slot, n: *usize, path: []const u8) void {
    var it = std.mem.splitScalar(u8, path, '/');
    var depth: u32 = 0;
    while (it.next()) |part| {
        depth += 1;
        // /Users/<名字>/<一层> 人人都有，说明不了他在做什么。
        if (depth < 4) continue;
        if (part.len < 2 or part.len > 48) continue;
        if (std.mem.indexOfScalar(u8, part, '.') != null) continue;
        if (isGeneric(part)) continue;
        tally(slots, n, part, depth);
    }
}

fn bestSlot(slots: []const Slot) ?Slot {
    if (slots.len == 0) return null;
    var best = slots[0];
    for (slots[1..]) |s| {
        const better_count = s.count > best.count;
        const same_count_deeper = s.count == best.count and s.depth > best.depth;
        if (better_count or same_count_deeper) best = s;
    }
    return best;
}

fn pathIsNoise(path: []const u8) bool {
    const noise = [_][]const u8{
        "/Library/", "/.Trash/", "/zig-cache/", "/.zig-cache/",
        "/node_modules/", "/Caches/",
    };
    for (noise) |part| {
        if (std.mem.indexOf(u8, path, part) != null) return true;
    }
    return false;
}

fn pathIsSensitive(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (isSensitive(part)) return true;
    }
    return false;
}

fn isSensitive(part: []const u8) bool {
    if (std.mem.startsWith(u8, part, ".env")) return true;
    if (std.mem.endsWith(u8, part, ".pem")) return true;
    for (sensitive_names) |name| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn isGeneric(part: []const u8) bool {
    for (generic_dirs) |name| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn themeFromComm(comm: []const u8) ?[]const u8 {
    if (comm.len < 2 or comm.len > 48) return null;
    if (std.mem.indexOfScalar(u8, comm, ' ') != null) return null;
    if (std.mem.indexOfScalar(u8, comm, '/') != null) return null;
    for (system_comms) |name| {
        if (std.mem.eql(u8, comm, name)) return null;
    }
    return comm;
}

const testing = std.testing;

test "self-knowing adopts a repeated project and skips secrets" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc, 1);
    defer memory.deinit();
    var queue = tq.TaskQueue.init(alloc);
    defer queue.deinit();

    const paths = [_][]const u8{
        "/Users/n0x/w4_proj/3yhq_uni/ghw/src/harness/foo.zig",
        "/Users/n0x/w4_proj/3yhq_uni/ghw/examples/ui_server.zig",
        "/Users/n0x/.ssh/id_ed25519",
        "/Users/n0x/notes/.env",
    };
    var ran = try step(alloc, &memory, &queue, null, 4, &paths, &.{});
    defer ran.deinit(alloc);

    try testing.expectEqual(@as(u32, 2), ran.guarded);
    try testing.expect(ran.adopted);
    try testing.expectEqualStrings("ghw", ran.theme);
    try testing.expect(ran.mission_id != 0);
    try testing.expectEqual(@as(usize, 1), memory.beliefs.items.len);
    try testing.expect(themeIn(memory.beliefs.items[0].text) != null);
    try testing.expectEqual(tq.Task.Source.self_knowing, queue.tasks.items[0].source);
    try testing.expectEqual(tq.Task.Dimension.representation, queue.tasks.items[0].required_dimension);

    var again = try step(alloc, &memory, &queue, null, 8, &paths, &.{});
    defer again.deinit(alloc);
    try testing.expect(again.reinforced);
    try testing.expect(!again.adopted);
    try testing.expectEqual(@as(u64, 0), again.mission_id);
    try testing.expectEqual(@as(usize, 1), memory.beliefs.items.len);
    try testing.expectEqual(@as(usize, 1), queue.tasks.items.len);
}

test "self-knowing does not adopt a theme seen once" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc, 1);
    defer memory.deinit();
    var queue = tq.TaskQueue.init(alloc);
    defer queue.deinit();
    const paths = [_][]const u8{"/Users/n0x/only/once/src/main.zig"};
    var ran = try step(alloc, &memory, &queue, null, 1, &paths, &.{"zig"});
    defer ran.deinit(alloc);
    try testing.expect(!ran.adopted);
    try testing.expectEqual(@as(usize, 0), memory.beliefs.items.len);
    try testing.expectEqual(@as(usize, 0), queue.tasks.items.len);
}
