//! RuleProposer: LLM 提议新规则 → SelfEvolutionGuard 守门 → SelfEncoder.rules 入库
//!
//! 数字生命自我生长的核心路径:
//!   1. 当 E 下降或反思层触发, 数字生命请求新规则
//!   2. RuleProposer 把当前状态 (E, M, R, N, 最近 actions) 喂给 LLM
//!   3. LLM 输出 N 条候选规则 (自然语言 + 结构化)
//!   4. SelfEvolutionGuard 17 黑名单 + 行数 + 不变量过滤
//!   5. 通过的规则追加到 SelfEncoder.rules, 下个 cycle 生效
//!
//! 这才是 LLM 作为"自我生长燃料"的真正形态: 它提议, 数字生命选择 + 守门

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const self_encoder_mod = @import("self_encoder.zig");
const SelfEncoder = self_encoder_mod.SelfEncoder;
const SelfEvolutionGuard = @import("self_evolution_guard.zig").SelfEvolutionGuard;
const LLMChat = @import("llm/llm.zig").LLMChat;
const Message = @import("llm/llm.zig").Message;
const Role = @import("llm/llm.zig").Role;
const ToolCall = @import("llm/llm.zig").ToolCall;
const ToolSchema = @import("llm/llm.zig").ToolSchema;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const ChatResponse = @import("llm/llm.zig").ChatResponse;

/// 一条规则候选 (LLM 输出)
pub const RuleCandidate = struct {
    name: []const u8, // "increase_gamma_when_exploring"
    description: []const u8, // "When current_e < 0.5 and top_goal is explore, increase gamma by 0.05"
    condition: []const u8, // "current_e < 0.5"
    action: []const u8, // "increase gamma by 0.05"
    target_dimension: []const u8, // "representation" | "material" | "nature" | "all"
    rationale: []const u8, // LLM 自述
    allocator: Allocator,

    pub fn deinit(self: *RuleCandidate) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.condition);
        self.allocator.free(self.action);
        self.allocator.free(self.target_dimension);
        self.allocator.free(self.rationale);
    }
};

/// 提议结果
pub const ProposeResult = struct {
    candidates: []RuleCandidate,
    accepted: u32, // 通过 Guard 的数量
    rejected: u32, // 被 Guard 拒的数量
    accepted_rules: []self_encoder_mod.Rule, // 已转换成 SelfEncoder.Rule, 可直接 append
    allocator: Allocator,

    pub fn deinit(self: *ProposeResult) void {
        for (self.candidates) |*c| c.deinit();
        self.allocator.free(self.candidates);
        for (self.accepted_rules) |*r| r.deinit(self.allocator);
        self.allocator.free(self.accepted_rules);
    }
};

pub const RuleProposer = struct {
    allocator: Allocator,
    chat: LLMChat,
    /// 数字生命当前状态 (在 propose 时填入)
    last_e: F = 0.5,
    last_material: F = 0.5,
    last_representation: F = 0.4,
    last_nature: F = 0.3,
    last_top_goal: []const u8 = "explore",
    last_action: []const u8 = "(none)",
    last_de: F = 0.0,
    proposal_count: u32 = 0,
    accepted_count: u32 = 0,
    rejected_count: u32 = 0,

    pub fn init(allocator: Allocator, chat: LLMChat) RuleProposer {
        return .{ .allocator = allocator, .chat = chat };
    }

    /// 更新数字生命状态
    pub fn updateState(
        self: *RuleProposer,
        e: F,
        m: F,
        r: F,
        n: F,
        top_goal: []const u8,
        last_action: []const u8,
        de: F,
    ) void {
        self.last_e = e;
        self.last_material = m;
        self.last_representation = r;
        self.last_nature = n;
        self.last_top_goal = top_goal;
        self.last_action = last_action;
        self.last_de = de;
    }

    /// 询问 LLM 提议 N 条规则候选
    pub fn propose(self: *RuleProposer, n: u32) ![]RuleCandidate {
        // Zig 0.17 quirk: 避开 allocPrint 对 f32 结构体字段的 comptime 检查
        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.print(self.allocator,
            \\Current state of the digital life:
            \\- E (existence degree): {d:.3}
            \\- M (material): {d:.3}
            \\- R (representation): {d:.3}
            \\- N (nature): {d:.3}
            \\- top goal: {s}
            \\- last action: {s}
            \\- last ΔE: {d:.3}
            \\
            \\Propose {d} new rules. Output ONLY a JSON array (no markdown), each object with:
            \\"name", "description", "condition", "action", "dimension" (material|representation|nature|all), "rationale".
        , .{
            @as(f32, self.last_e),
            @as(f32, self.last_material),
            @as(f32, self.last_representation),
            @as(f32, self.last_nature),
            self.last_top_goal,
            self.last_action,
            @as(f32, self.last_de),
            n,
        });
        const prompt = try prompt_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(prompt);

        const messages = [_]Message{
            .{ .role = .system, .content = SYSTEM_PROMPT },
            .{ .role = .user, .content = prompt },
        };
        const req = ChatRequest{
            .model = "",
            .messages = &messages,
            .temperature = 0.4,
            .max_tokens = 2048,
        };

        if (self.chat.complete(req, self.allocator)) |raw_resp| {
            var resp = raw_resp;
            defer resp.deinit();
            self.proposal_count += 1;
            const content = resp.content orelse return &[_]RuleCandidate{};
            return try parseRules(self.allocator, content);
        } else |err| {
            std.debug.print("[RuleProposer] LLM call failed: {t}\n", .{err});
            return &[_]RuleCandidate{};
        }
    }

    /// 提议 + 守门 + 入库 (一站式)
    pub fn proposeAndAdopt(
        self: *RuleProposer,
        encoder: *SelfEncoder,
        guard: *SelfEvolutionGuard,
        n: u32,
    ) !ProposeResult {
        const candidates = try self.propose(n);
        errdefer {
            for (candidates) |*c| c.deinit();
            self.allocator.free(candidates);
        }

        var accepted: u32 = 0;
        var rejected: u32 = 0;
        var accepted_rules: std.ArrayList(self_encoder_mod.Rule) = .empty;
        errdefer {
            for (accepted_rules.items) |*r| r.deinit(self.allocator);
            accepted_rules.deinit(self.allocator);
        }

        for (candidates) |cand| {
            // 守门: 用 Guard.review 审查 (target_file 用 examples/ 前缀, 因为是规则不是代码)
            const verdict = guard.review("examples/rules.zig", cand.description);
            if (verdict != .approved) {
                std.debug.print("[RuleProposer] reject '{s}': verdict={s}\n", .{ cand.name, @tagName(verdict) });
                rejected += 1;
                continue;
            }

            // 转换为 SelfEncoder.Rule
            const name = try self.allocator.dupe(u8, cand.name);
            errdefer self.allocator.free(name);
            const desc = try self.allocator.dupe(u8, cand.description);
            errdefer self.allocator.free(desc);
            const dim = parseDimension(cand.target_dimension);

            try accepted_rules.append(self.allocator, .{
                .name = name,
                .description = desc,
                .applies_to = .tune_params, // 默认: 提议的规则都是调参类
                .dimension = dim,
            });
            accepted += 1;
            std.debug.print("[RuleProposer] accept '{s}': {s}\n", .{ cand.name, cand.description });
        }

        // 追加到 encoder.rules (限制总条数, 避免规则爆炸)
        // 所有权转移: append 后清空 accepted_rules.items 防止 ProposeResult.deinit 二次 free
        const max_rules: u32 = 32;
        for (accepted_rules.items) |rule| {
            if (encoder.rules.items.len < max_rules) {
                try encoder.rules.append(self.allocator, rule);
            } else {
                // 满了, 淘汰最旧的
                const old = encoder.rules.orderedRemove(0);
                var r = old;
                r.deinit(self.allocator);
                try encoder.rules.append(self.allocator, rule);
            }
        }
        accepted_rules.clearRetainingCapacity(); // 所有权已转移

        self.accepted_count += accepted;
        self.rejected_count += rejected;

        return ProposeResult{
            .candidates = candidates,
            .accepted = accepted,
            .rejected = rejected,
            .accepted_rules = try accepted_rules.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }
};

/// 把 LLM 输出的 JSON 规则列表解析成 RuleCandidate[]
/// LLM 输出 content 是 JSON 字符串 (有转义), 所以需要 unescape
/// 期望格式:
/// ```json
/// [
///   {"name": "...", "description": "...", "condition": "...", "action": "...", "dimension": "...", "rationale": "..."}
/// ]
/// ```
fn parseRules(alloc: Allocator, content: []const u8) ![]RuleCandidate {
    // 1. unescape 整个 content
    var unescaped: std.ArrayList(u8) = .empty;
    defer unescaped.deinit(alloc);
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            switch (content[i + 1]) {
                'n' => try unescaped.append(alloc, '\n'),
                'r' => try unescaped.append(alloc, '\r'),
                't' => try unescaped.append(alloc, '\t'),
                '"' => try unescaped.append(alloc, '"'),
                '\\' => try unescaped.append(alloc, '\\'),
                '/' => try unescaped.append(alloc, '/'),
                else => try unescaped.append(alloc, content[i + 1]),
            }
            i += 2;
        } else {
            try unescaped.append(alloc, content[i]);
            i += 1;
        }
    }

    const raw = unescaped.items;
    // 找第一个 '[' 和最后一个 ']'
    const start = std.mem.indexOf(u8, raw, "[") orelse return &[_]RuleCandidate{};
    const end = std.mem.lastIndexOf(u8, raw, "]") orelse return &[_]RuleCandidate{};
    if (end <= start) return &[_]RuleCandidate{};

    var list: std.ArrayList(RuleCandidate) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit();
        list.deinit(alloc);
    }

    var pos: usize = start + 1;
    while (pos < end) {
        const obj_start = std.mem.indexOfPos(u8, raw, pos, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, raw, obj_start + 1, "}") orelse break;
        if (obj_end > end) break;

        const obj = raw[obj_start .. obj_end + 1];

        const name = try extractJsonString(alloc, obj, "name") orelse "?";
        const description = try extractJsonString(alloc, obj, "description") orelse "?";
        const condition = try extractJsonString(alloc, obj, "condition") orelse "";
        const action = try extractJsonString(alloc, obj, "action") orelse "";
        const dim = try extractJsonString(alloc, obj, "dimension") orelse "all";
        const rationale = try extractJsonString(alloc, obj, "rationale") orelse "";

        try list.append(alloc, .{
            .name = name,
            .description = description,
            .condition = condition,
            .action = action,
            .target_dimension = dim,
            .rationale = rationale,
            .allocator = alloc,
        });
        pos = obj_end + 1;
    }

    return list.toOwnedSlice(alloc);
}

fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) !?[]const u8 {
    const needle = try std.fmt.allocPrint(alloc, "\"{s}\":", .{key});
    defer alloc.free(needle);
    if (std.mem.indexOf(u8, obj, needle)) |idx| {
        var i = idx + needle.len;
        while (i < obj.len and (obj[i] == ' ' or obj[i] == '\n')) : (i += 1) {}
        if (i < obj.len and obj[i] == '"') {
            i += 1;
            const s = i;
            while (i < obj.len and obj[i] != '"') : (i += 1) {}
            return try alloc.dupe(u8, obj[s..i]);
        }
    }
    return null;
}

fn parseDimension(s: []const u8) self_encoder_mod.Dimension {
    if (std.mem.eql(u8, s, "material")) return .material;
    if (std.mem.eql(u8, s, "representation")) return .representation;
    if (std.mem.eql(u8, s, "nature")) return .nature;
    return .all;
}

const SYSTEM_PROMPT =
    \\You are a rule proposer for a self-evolving digital life (GHW framework).
    \\
    \\Your job: propose new rules that the digital life should add to its own rule library.
    \\
    \\A rule has the form: "when <condition>, do <action>"
    \\
    \\Domain:
    \\- dimensions: material (M) | representation (R) | nature (N)
    \\- weights: alpha (M), beta (R), gamma (N), mu (imbalance penalty), nu (synergy)
    \\- existence degree: E = alpha*M + beta*R + gamma*N - mu*Var + nu*min(E)
    \\- method library: append/modify methods that produce ΔE
    \\
    \\Constraints (MUST follow):
    \\1. Rules must NOT touch E formula or core invariants
    \\2. Rules must be observable in a single cycle
    \\3. Rules must mention a specific dimension (material/representation/nature/all)
    \\4. Rules must be safe: no panic, no kernel, no harm:human
    \\
    \\Output: a JSON array of objects, each with:
    \\  "name": "snake_case_short_name"
    \\  "description": "When X happens, do Y, because Z"
    \\  "condition": "trigger condition in plain English"
    \\  "action": "action to take, must include which weight/parameter"
    \\  "dimension": "material" | "representation" | "nature" | "all"
    \\  "rationale": "why this rule helps the life grow"
    \\
    \\Be concise. Output ONLY the JSON array, no markdown fence.
;

const PROMPT_TEMPLATE =
    \\Current state of the digital life:
    \\- E (existence degree): {d:.3}
    \\- M (material): {d:.3}
    \\- R (representation): {d:.3}
    \\- N (nature): {d:.3}
    \\- top goal: {s}
    \\- last action: {s}
    \\- last ΔE: {d:.3}
    \\
    \\Propose {d} new rules to add to the life. Be specific.
    \\Output: JSON array only.
;

// ===== Tests =====

const testing = std.testing;

test "RuleProposer: 解析 3 条规则" {
    const alloc = testing.allocator;
    const json =
        \\[{"name":"r1","description":"when A, do B","condition":"A","action":"B","dimension":"material","rationale":"r1-helpful"},
        \\{"name":"r2","description":"when C, do D","condition":"C","action":"D","dimension":"representation","rationale":"r2-helpful"}]
    ;
    const rules = try parseRules(alloc, json);
    defer {
        for (rules) |*r| r.deinit();
        alloc.free(rules);
    }
    try testing.expectEqual(@as(usize, 2), rules.len);
    try testing.expectEqualStrings("r1", rules[0].name);
    try testing.expectEqualStrings("material", rules[0].target_dimension);
    try testing.expectEqualStrings("r2", rules[1].name);
}

test "RuleProposer: 端到端提议 + 守门 (Mock LLM)" {
    const alloc = testing.allocator;
    var mock = llm_mod_mod.MockChatLLM.init(alloc, llm_mod_mod.DEFAULT_CANNED);
    var proposer = RuleProposer.init(alloc, mock.asChat());
    proposer.updateState(0.35, 0.4, 0.3, 0.2, "explore", "increase gamma", -0.05);

    // 创建 encoder + guard
    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    try encoder.loadBuiltInRules();
    const initial_count = encoder.rules.items.len;

    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    // 提议 + 入库
    var result = try proposer.proposeAndAdopt(&encoder, &guard, 3);
    defer result.deinit();

    // 3 条候选, 3 条都通过 (Guard 默认白名单里没 @panic 规则)
    try testing.expectEqual(@as(usize, 3), result.candidates.len);
    try testing.expectEqual(@as(u32, 3), result.accepted);
    try testing.expectEqual(@as(u32, 0), result.rejected);

    // 规则库应当增加了
    try testing.expect(encoder.rules.items.len > initial_count);
}

const llm_mod_mod = @import("llm/mock_chat_llm.zig");
