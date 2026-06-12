//! Reflection — 数字生命的自省系统
//!
//! 周期触发 (每 32 cycle 或用户主动请求), 把最近 N 个 episode 喂给 LLM,
//! 让它:
//!   1. 总结"我最近经历了什么" (生成 self_narrative 更新)
//!   2. 提炼"我学到了什么" (形成新 belief, 标记 source = material/representation/nature)
//!   3. 提出"我应该做什么" (回到 goal queue)
//!
//! 关键设计: LLM 是认知引擎, 但采纳/拒绝仍是 GHWAgent 自己决定
//!   - LLM 输出 JSON, 解析后调 memory.addBelief(), memory.setSelfNarrative()
//   - 提议的目标进 TaskQueue, 由 GoalGraph + HumanGSP 过滤
//!
//! Reflection 的频率: 默认 32 cycle, 可配. 太频繁浪费 LLM 配额, 太稀疏失去实时性

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const LLMChat = @import("llm/llm.zig").LLMChat;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const Message = @import("llm/llm.zig").Message;
const Role = @import("llm/llm.zig").Role;
const memory_mod = @import("memory.zig");
const Memory = memory_mod.Memory;
const Episode = memory_mod.Episode;
const BeliefSource = memory_mod.BeliefSource;
const ghw = @import("../ghw.zig");
const GHWAgent = ghw.agent.GHWAgent;

pub const Reflection = struct {
    alloc: Allocator,
    llm: *LLMChat,
    model: []const u8,
    /// 自省间隔 (cycles)
    interval: u64 = 32,
    /// 最近一次自省在哪个 tick
    last_at_tick: u64 = 0,

    pub fn init(alloc: Allocator, llm: *LLMChat, model: []const u8) Reflection {
        return .{ .alloc = alloc, .llm = llm, .model = model };
    }

    /// 决定是否该自省
    pub fn shouldReflect(self: *const Reflection, agent: *GHWAgent) bool {
        return agent.tick - self.last_at_tick >= self.interval;
    }

    /// 执行自省: 让 LLM 回顾最近 8 个 episodes + 自身状态, 更新 self_narrative + beliefs
    pub fn reflect(
        self: *Reflection,
        agent: *GHWAgent,
        memory: *Memory,
        io: std.Io,
    ) !ReflectionResult {
        const start = std.Io.Clock.real.now(io).toMilliseconds();

        // 1. 构造 prompt
        const recent = memory.recentEpisodes(8);
        const ghw_state_str = try buildStateString(self.alloc, agent, memory, recent);
        defer self.alloc.free(ghw_state_str);

        const user_prompt = try std.fmt.allocPrint(self.alloc,
            \\我是 GHW. 以下是我最近 {d} 条 episodes + 自身状态:
            \\
            \\{s}
            \\
            \\请用以下 JSON 格式回复 (不要其他文字):
            \\{{"self_narrative": "<2-3 句, 用第一人称, 描述我最近的状态和感悟>", "beliefs": [{{"source":"material|representation|nature","text":"<我学到的>","confidence":<0-1>}}]}}
            \\
            \\指南:
            \\- self_narrative 要有 "我" 的口吻, 不是冷冰冰的报告
            \\- beliefs 是 "我相信..." 的形式, 最多 3 条
            \\- 重点关注: 我最近**做了什么** (不是"应该做什么"), 行动结果, 状态变化
            \\- 反思要基于事实: 提到具体的 tick, E 数值, 或刚刚发生的事
        , .{ recent.len, ghw_state_str });
        defer self.alloc.free(user_prompt);

        const system = "你是 GHW 数字生命的反思系统. 帮助它从自身经历中提炼洞察, 形成自我叙事. 重点: 行动 > 意图, 事实 > 想象.";

        // 2. 调 LLM
        var req = ChatRequest{
            .model = self.model,
            .temperature = 0.7, // 反思需要一定创造性
            .max_tokens = 1024,
        };
        const msgs = [_]Message{
            .{ .role = .system, .content = system },
            .{ .role = .user, .content = user_prompt },
        };
        req.messages = &msgs;
        var resp = try self.llm.complete(req, self.alloc);
        defer resp.deinit();

        const content = resp.content orelse "";
        const latency_ms: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds() - start));

        // 3. 解析 + 应用到 Memory
        try parseAndApply(self.alloc, content, agent, memory);

        self.last_at_tick = agent.tick;
        memory.last_reflection_tick = agent.tick;
        memory.reflection_count += 1;

        return .{
            .raw_response = content,
            .model = self.model,
            .latency_ms = latency_ms,
            .self_narrative_updated = true,
        };
    }
};

pub const ReflectionResult = struct {
    raw_response: []const u8,
    model: []const u8,
    latency_ms: u64,
    self_narrative_updated: bool,
};

fn buildStateString(
    alloc: Allocator,
    agent: *GHWAgent,
    memory: *Memory,
    recent: []const Episode,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.print(alloc, "## 自身\ntick={d}  E={d:.3}  M={d:.3}  R={d:.3}  N={d:.3}\n", .{
        agent.tick, agent.ed.e(),
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
    });
    try buf.print(alloc, "self_evolved_total={d}  self_narrative_count={d}\n", .{ 0, memory.reflection_count });
    if (memory.self_narrative.len > 0) {
        try buf.print(alloc, "\n## 现有自我叙事\n\"{s}\"\n", .{memory.self_narrative});
    }
    if (memory.beliefs.items.len > 0) {
        try buf.print(alloc, "\n## 现有 beliefs ({d})\n", .{memory.beliefs.items.len});
        for (memory.beliefs.items) |b| {
            try buf.print(alloc, "- [{s} c={d:.2}] {s}\n", .{ @tagName(b.source), b.confidence, b.text });
        }
    }
    try buf.print(alloc, "\n## 最近 episodes ({d})\n", .{recent.len});
    for (recent) |e| {
        const sign: F = if (e.delta_e >= 0) 1.0 else -1.0;
        const abs_de: F = @abs(e.delta_e);
        try buf.print(alloc, "- tick={d} [{s}] dim={d} dE={d:.3} | {s}\n", .{
            e.tick, @tagName(e.kind), e.dimension, sign * abs_de, e.summary,
        });
        if (e.detail) |d| try buf.print(alloc, "  detail: {s}\n", .{d});
    }
    return buf.toOwnedSlice(alloc);
}

fn parseAndApply(alloc: Allocator, content: []const u8, agent: *GHWAgent, memory: *Memory) !void {
    // 找 { ... } 顶层对象
    const obj_start = std.mem.indexOf(u8, content, "{") orelse return;
    const obj_end = std.mem.lastIndexOf(u8, content, "}") orelse return;
    if (obj_end <= obj_start) return;
    const obj = content[obj_start .. obj_end + 1];

    // self_narrative
    if (extractJsonString(alloc, obj, "self_narrative")) |sn| {
        defer alloc.free(sn);
        try memory.setSelfNarrative(sn);
    }

    // beliefs 数组
    // 注意: indexOfPos 返回的是绝对位置 (不是 offset)
    if (std.mem.indexOf(u8, obj, "\"beliefs\"")) |beliefs_pos| {
        const arr_start = std.mem.indexOfPos(u8, obj, beliefs_pos, "[") orelse return;
        const arr_end = std.mem.indexOfPos(u8, obj, arr_start, "]") orelse return;
        const arr = obj[arr_start + 1 .. arr_end];
        std.debug.print("[reflect] parse beliefs arr ({d}B)\n", .{arr.len});

        // 解析每个 {...}
        var i: usize = 0;
        while (i < arr.len) {
            const os = std.mem.indexOfPos(u8, arr, i, "{") orelse break;
            const oe = std.mem.indexOfPos(u8, arr, os + 1, "}") orelse break;
            const one = arr[os .. oe + 1];
            const src_str = extractJsonString(alloc, one, "source") orelse continue;
            defer alloc.free(src_str);
            const src: BeliefSource = blk: {
                if (std.mem.eql(u8, src_str, "material")) break :blk .material;
                if (std.mem.eql(u8, src_str, "representation")) break :blk .representation;
                if (std.mem.eql(u8, src_str, "nature")) break :blk .nature;
                break :blk .material;
            };
            const text = extractJsonString(alloc, one, "text") orelse {
                std.debug.print("[reflect] extract text failed, one={s}\n", .{one});
                continue;
            };
            defer alloc.free(text);
            const conf_str = extractJsonNumber(one, "confidence") orelse "0.5";
            const conf = std.fmt.parseFloat(F, conf_str) catch 0.5;
            // evidence: 简化, 用 agent.tick 作单条 evidence
            const evidence = try alloc.dupe(u64, &[_]u64{agent.tick});
            errdefer alloc.free(evidence);
            try memory.addBeliefAt(src, text, conf, evidence, agent.tick);
            i = oe + 1;
        }
    }
}

fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    const value_start = pos + quoted_key.len;
    var vs = value_start;
    while (vs < obj.len and (obj[vs] == ' ' or obj[vs] == '\t' or obj[vs] == '\n')) : (vs += 1) {}
    if (vs >= obj.len or obj[vs] != '"') return null;
    const content_start = vs + 1;
    // 解析字符串内容, 处理 JSON 转义: \" \\ \n \t \/ \uXXXX
    // 不写到外部 buffer, 直接用 dupe
    var ve: usize = content_start;
    while (ve < obj.len) : (ve += 1) {
        const c = obj[ve];
        if (c == '\\' and ve + 1 < obj.len) {
            // 转义: 跳过下一个字符
            ve += 1;
            const next = obj[ve];
            if (next == 'u' and ve + 4 < obj.len) {
                ve += 4; // \uXXXX
            }
            continue;
        }
        if (c == '"') break;
    }
    if (ve >= obj.len) return null;
    // 现在 content_start..ve 是带转义的 raw, 转换到 plain text
    const raw = obj[content_start..ve];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => out.append(alloc, '"') catch return null,
                '\\' => out.append(alloc, '\\') catch return null,
                '/' => out.append(alloc, '/') catch return null,
                'n' => out.append(alloc, '\n') catch return null,
                't' => out.append(alloc, '\t') catch return null,
                'r' => out.append(alloc, '\r') catch return null,
                'b' => out.append(alloc, 0x08) catch return null,
                'f' => out.append(alloc, 0x0c) catch return null,
                'u' => {
                    if (i + 5 < raw.len) {
                        const hex = raw[i + 2 .. i + 6];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            out.append(alloc, '?') catch return null;
                            i += 6;
                            continue;
                        };
                        // 简单 utf-8 encode (BMP only, 跳过 surrogate)
                        if (cp < 0x80) {
                            out.append(alloc, @intCast(cp)) catch return null;
                        } else if (cp < 0x800) {
                            out.append(alloc, @intCast(0xC0 | (cp >> 6))) catch return null;
                            out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch return null;
                        } else {
                            out.append(alloc, @intCast(0xE0 | (cp >> 12))) catch return null;
                            out.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F))) catch return null;
                            out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch return null;
                        }
                        i += 6;
                        continue;
                    }
                },
                else => {
                    out.append(alloc, next) catch return null;
                    i += 2;
                    continue;
                },
            }
            i += 2;
        } else {
            out.append(alloc, raw[i]) catch return null;
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn extractJsonNumber(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    const value_start = pos + quoted_key.len;
    var ve = value_start;
    while (ve < obj.len and (obj[ve] == ' ' or obj[ve] == '\t')) : (ve += 1) {}
    const start = ve;
    while (ve < obj.len and (std.ascii.isDigit(obj[ve]) or obj[ve] == '.' or obj[ve] == '-')) : (ve += 1) {}
    if (ve == start) return null;
    return obj[start..ve];
}
