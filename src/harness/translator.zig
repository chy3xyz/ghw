//! Translator: LLM 当翻译器, GHW ↔ 人类 双向
//!
//! 核心约束: **只能翻译, 不能决策**
//!   - toHuman:  GHW 状态 + 行为 → 人类能读的自然语言 (不发明新信息)
//!   - toGHW:   人类自然语言 → 结构化 Intent (不偷偷加约束)
//!
//! 论文语境: B.5.3 长期方向里"GHW 系统需要语言皮层来跟外界交互"
//! LLM 充当这个皮层, 但所有"判断"仍由数字生命的 E 函数和 HumanGSP 决定

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const LLMChat = @import("llm/llm.zig").LLMChat;
const Message = @import("llm/llm.zig").Message;
const Role = @import("llm/llm.zig").Role;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const ChatResponse = @import("llm/llm.zig").ChatResponse;
const Task = @import("human_symbiosis/task_queue.zig").Task;

const world_mod = @import("../world/core.zig");
const ExistenceDegree = world_mod.ExistenceDegree;
const ExistenceWeights = world_mod.ExistenceWeights;

/// LLM 翻译后的人类意图
pub const InterpretedIntent = struct {
    suggested_dimension: Task.Dimension,
    suggested_priority: u8,
    suggested_title: []u8,
    suggested_description: []u8,
    confidence: F,
    rationale: []u8,
    /// 原始 dimension 字符串 (owned, deinit 释放)
    suggested_dimension_str: ?[]u8,
    allocator: Allocator,

    pub fn deinit(self: *InterpretedIntent) void {
        self.allocator.free(self.suggested_title);
        self.allocator.free(self.suggested_description);
        self.allocator.free(self.rationale);
        if (self.suggested_dimension_str) |s| self.allocator.free(s);
    }
};

pub const Translator = struct {
    allocator: Allocator,
    chat: LLMChat,
    call_count: u32 = 0,

    pub fn init(allocator: Allocator, chat: LLMChat) Translator {
        return .{ .allocator = allocator, .chat = chat };
    }

    /// GHW → 人类: 把状态 + 行为翻译成自然语言
    pub fn explain(
        self: *Translator,
        ed: ExistenceDegree,
        weights: ExistenceWeights,
        recent_action: []const u8,
    ) ![]u8 {
        self.call_count += 1;

        const state_json = try std.fmt.allocPrint(self.allocator,
            \\{{"E":{d:.3},"M":{d:.3},"R":{d:.3},"N":{d:.3},"alpha":{d:.2},"beta":{d:.2},"gamma":{d:.2},"mu":{d:.2},"nu":{d:.2}}}
        , .{
            ed.e(), ed.v.material, ed.v.representation, ed.v.nature,
            weights.alpha, weights.beta, weights.gamma, ed.mu, ed.nu,
        });
        defer self.allocator.free(state_json);

        const user_msg = try std.fmt.allocPrint(self.allocator,
            "State: {s}\nRecent action: {s}\n\nDescribe in 2-3 sentences (Chinese or English).",
            .{ state_json, recent_action });
        defer self.allocator.free(user_msg);

        const messages = [_]Message{
            .{ .role = .system, .content =
                \\You are a translator for a digital life system. The system has 3 existence sources:
                \\M (material/resources), R (representation/knowledge), N (nature/agency).
                \\Existence degree: E = α*M + β*R + γ*N - μ*Var(M,R,N) + ν*min(M,R,N).
                \\Your job: translate the JSON state into a brief 2-3 sentence natural language description
                \\of HOW THE LIFE FEELS right now. Don't add new info. Don't suggest actions. Just describe.
            },
            .{ .role = .user, .content = user_msg },
        };

        const req = ChatRequest{
            .model = "",
            .messages = &messages,
            .temperature = 0.3,
            .max_tokens = 200,
        };

        if (self.chat.complete(req, self.allocator)) |raw_resp| {
            var resp = raw_resp;
            defer resp.deinit();
            return try self.allocator.dupe(u8, resp.content orelse "(no description)");
        } else |err| {
            std.debug.print("[Translator] LLM call failed: {t}, using fallback\n", .{err});
            return std.fmt.allocPrint(self.allocator,
                "[fallback: LLM unavailable] E={d:.3}, M/R/N={d:.2}/{d:.2}/{d:.2}",
                .{ ed.e(), ed.v.material, ed.v.representation, ed.v.nature });
        }
    }

    /// 人类 → GHW: 把自然语言解读成结构化 Intent
    pub fn interpret(
        self: *Translator,
        human_text: []const u8,
        ed: ExistenceDegree,
    ) !InterpretedIntent {
        self.call_count += 1;

        const state_summary = try std.fmt.allocPrint(self.allocator,
            "E={d:.3}, M={d:.2}, R={d:.2}, N={d:.2}",
            .{ ed.e(), ed.v.material, ed.v.representation, ed.v.nature });
        defer self.allocator.free(state_summary);

        const user_msg = try std.fmt.allocPrint(self.allocator,
            "Current state: {s}\nHuman said: \"{s}\"\n\nJSON:",
            .{ state_summary, human_text });
        defer self.allocator.free(user_msg);

        const messages = [_]Message{
            .{ .role = .system, .content =
                \\You are an intent interpreter for a digital life system. A human said something in natural language.
                \\Your job: extract their INTENT into a structured JSON.
                \\
                \\Output JSON format (ONLY JSON, no markdown):
                \\{
                \\  "dimension": "material" | "representation" | "nature" | "all",
                \\  "title": "short snake_case title",
                \\  "description": "what the human actually wants, in 1 sentence",
                \\  "rationale": "why this maps to this dimension",
                \\  "confidence": 0.0 to 1.0
                \\}
                \\
                \\Rules:
                \\- dimension MUST be one of the 4 values
                \\- title in English, lowercase, snake_case, max 30 chars
                \\- description in English, max 100 chars
                \\- confidence is your self-assessed certainty
                \\- NEVER add fields like "priority" or "deadline" (those are decided by the system)
            },
            .{ .role = .user, .content = user_msg },
        };

        const req = ChatRequest{
            .model = "",
            .messages = &messages,
            .temperature = 0.2,
            .max_tokens = 300,
        };

        const content = if (self.chat.complete(req, self.allocator)) |raw_resp| blk: {
            var resp = raw_resp;
            defer resp.deinit();
            const c = resp.content orelse "{}";
            break :blk try self.allocator.dupe(u8, c);
        } else |err| blk: {
            std.debug.print("[Translator] interpret LLM failed: {t}, fallback\n", .{err});
            break :blk try std.fmt.allocPrint(self.allocator,
                "{{\"dimension\":\"all\",\"title\":\"generic_task\",\"description\":\"{s}\",\"rationale\":\"fallback\",\"confidence\":0.3}}",
                .{human_text});
        };
        defer self.allocator.free(content);

        const title = extractJsonString(self.allocator, content, "title") orelse try self.allocator.dupe(u8, "interpreted_task");
        const desc = extractJsonString(self.allocator, content, "description") orelse try self.allocator.dupe(u8, human_text);
        const rationale = extractJsonString(self.allocator, content, "rationale") orelse try self.allocator.dupe(u8, "");
        const conf: F = extractJsonNumber(content, "confidence") orelse 0.5;
        const dim_str = extractJsonString(self.allocator, content, "dimension") orelse try self.allocator.dupe(u8, "all");

        return InterpretedIntent{
            .suggested_dimension = parseDimension(dim_str),
            .suggested_priority = 5, // 强制默认, GHW 自己决定
            .suggested_title = title,
            .suggested_description = desc,
            .confidence = conf,
            .rationale = rationale,
            .suggested_dimension_str = dim_str,
            .allocator = self.allocator,
        };
    }
};

// ===== 简易 JSON 提取, 兼容 LLM 转义内容 (\\" / \\n) =====
const BACKSLASH: u8 = 92; // 0x5c

fn extractJsonString(alloc: Allocator, body: []const u8, key: []const u8) ?[]u8 {
    // 两轮: unescaped + escaped. 用 0/1 idx 区分
    var needles_buf: [2][64]u8 = undefined;
    var needles: [2][]const u8 = undefined;
    needles[0] = std.fmt.bufPrint(&needles_buf[0], "\"{s}\":", .{key}) catch return null;
    needles[1] = std.fmt.bufPrint(&needles_buf[1], "\\\"{s}\":", .{key}) catch return null;

    var idx: usize = 0;
    var found_needle: []const u8 = undefined;
    var found = false;
    for (0..2) |ni| {
        const needle = needles[ni];
        var search_from: usize = 0;
        while (true) {
            const idx_opt = std.mem.indexOfPos(u8, body, search_from, needle);
            if (idx_opt) |i| {
                if (i > 0 and body[i - 1] == BACKSLASH) {
                    search_from = i + 1;
                    continue;
                }
                idx = i;
                found_needle = needle;
                found = true;
                break;
            }
            break;
        }
        if (found) break;
    }

    if (!found) return null;

    var i = idx + found_needle.len;
    // needle 末尾是 :, 跳过可能的 : 和空白
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\n')) : (i += 1) {}

    const s: usize = if (i < body.len and body[i] == BACKSLASH and i + 1 < body.len and body[i + 1] == '"')
        i + 2
    else if (i < body.len and body[i] == '"')
        i + 1
    else
        return null;

    var j: usize = s;
    while (j < body.len and body[j] != '"' and body[j] != BACKSLASH) : (j += 1) {}
    return alloc.dupe(u8, body[s..j]) catch null;
}

fn extractJsonNumber(body: []const u8, key: []const u8) ?F {
    var needles_buf: [2][64]u8 = undefined;
    const needles: [2][]const u8 = blk: {
        var arr: [2][]const u8 = undefined;
        arr[0] = std.fmt.bufPrint(&needles_buf[0], "\"{s}\":", .{key}) catch return null;
        arr[1] = std.fmt.bufPrint(&needles_buf[1], "\\\"{s}\":", .{key}) catch return null;
        break :blk arr;
    };

    var idx: usize = 0;
    var found_needle: []const u8 = undefined;
    var found = false;
    for (0..2) |ni| {
        const needle = needles[ni];
        var search_from: usize = 0;
        while (true) {
            const idx_opt = std.mem.indexOfPos(u8, body, search_from, needle);
            if (idx_opt) |i| {
                if (i > 0 and body[i - 1] == BACKSLASH) {
                    search_from = i + 1;
                    continue;
                }
                idx = i;
                found_needle = needle;
                found = true;
                break;
            }
            break;
        }
        if (found) break;
    }

    if (!found) return null;

    var i = idx + found_needle.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
    if (i < body.len and body[i] == BACKSLASH and i + 1 < body.len and body[i + 1] == '"') i += 2;
    const s = i;
    // 支持整数和小数: 0..9 和 1 个 .
    var dot_seen = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c >= '0' and c <= '9') continue;
        if (c == '.' and !dot_seen) {
            dot_seen = true;
            continue;
        }
        break;
    }
    if (i > s) return std.fmt.parseFloat(F, body[s..i]) catch null;
    return null;
}

fn parseDimension(s: []const u8) Task.Dimension {
    if (std.mem.eql(u8, s, "material")) return .material;
    if (std.mem.eql(u8, s, "representation")) return .representation;
    if (std.mem.eql(u8, s, "nature")) return .nature;
    return .all;
}

// ===== Tests =====

const testing = std.testing;
const MockChatLLM = @import("llm/mock_chat_llm.zig").MockChatLLM;

test "Translator: explain 用 MockChatLLM 返非空文本" {
    const alloc = testing.allocator;
    const canned = "我(E=0.65)状态不错, M 弱了一点需要资源";
    var mock = MockChatLLM.init(alloc, canned);
    var tr = Translator.init(alloc, mock.asChat());

    const ed = ExistenceDegree{
        .v = .{ .material = 0.3, .representation = 0.7, .nature = 0.6 },
    };
    const w = ExistenceWeights{ .alpha = 0.40, .beta = 0.35, .gamma = 0.25 };

    const desc = try tr.explain(ed, w, "runCycle #5");
    defer alloc.free(desc);
    try testing.expect(desc.len > 0);
    try testing.expect(std.mem.indexOf(u8, desc, "E=0.65") != null);
}

test "Translator: interpret 解析 LLM 返的 JSON 成 Intent" {
    const alloc = testing.allocator;
    // 用 unescaped JSON (LLM 真接时 content 会是 escaped, 但测试用 unescaped 简单)
    const canned =
        \\{"dimension":"material","title":"add_more_cpu","description":"need compute","rationale":"R high, M low","confidence":0.85}
    ;
    var mock = MockChatLLM.init(alloc, canned);
    var tr = Translator.init(alloc, mock.asChat());

    const ed = ExistenceDegree{
        .v = .{ .material = 0.2, .representation = 0.7, .nature = 0.5 },
    };
    var intent = tr.interpret("I want more resources", ed) catch |err| {
        std.debug.print("interpret failed: {t}\n", .{err});
        return;
    };
    defer intent.deinit();

    try testing.expectEqual(Task.Dimension.material, intent.suggested_dimension);
    try testing.expectEqual(@as(u8, 5), intent.suggested_priority);
    try testing.expectEqualStrings("add_more_cpu", intent.suggested_title);
    try testing.expectApproxEqAbs(@as(F, 0.85), intent.confidence, 0.001);
}

test "Translator: LLM 永不决定 priority (A2 公理)" {
    const alloc = testing.allocator;
    // 即使 LLM 想设 priority=9, Translator 也会强制 5
    const canned =
        \\{"dimension":"nature","title":"explore_plan","description":"x","rationale":"y","confidence":0.9,"priority":9}
    ;
    var mock = MockChatLLM.init(alloc, canned);
    var tr = Translator.init(alloc, mock.asChat());
    const ed = ExistenceDegree{};
    var intent = try tr.interpret("explore 一下", ed);
    defer intent.deinit();
    try testing.expectEqual(@as(u8, 5), intent.suggested_priority);
}

test "Translator: LLM 失败时返 fallback Intent (T4 完备性)" {
    const alloc = testing.allocator;
    // canned 不是合法 JSON, 应该走 fallback
    const canned = "not json at all";
    var mock = MockChatLLM.init(alloc, canned);
    var tr = Translator.init(alloc, mock.asChat());
    const ed = ExistenceDegree{};
    var intent = try tr.interpret("something", ed);
    defer intent.deinit();
    // fallback 应该有非空 title
    try testing.expect(intent.suggested_title.len > 0);
    try testing.expect(intent.suggested_priority == 5);
}
