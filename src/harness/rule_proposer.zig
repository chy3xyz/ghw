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
const Memory = @import("memory.zig").Memory;

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
    /// 自传体记忆 (P1 连续性): 绑定后, propose 的 prompt 会注入
    /// 自我叙事 + 高置信信念 + 与当下最相关的往事, 让提议基于"自己的一生"
    /// 而非失忆快照。默认 null ⇒ 行为不变 (退回纯状态快照 prompt)。
    memory: ?*Memory = null,
    /// 数字生命当前状态 (在 propose 时填入)
    last_e: F = 0.5,
    last_material: F = 0.5,
    last_representation: F = 0.4,
    last_nature: F = 0.3,
    last_top_goal: []const u8 = "explore",
    last_action: []const u8 = "(none)",
    last_de: F = 0.0,
    /// 最近 KPI 趋势 (K-units/cycle, 来自 ExistenceDegree.kpiTrend)。
    /// 负值 = 产品 KPI 在下滑, 即使 E 暂时未跌穿阈值也应主动提议补救。
    last_kpi_trend: F = 0.0,
    /// 人类价值趋势 (value-units/cycle, 来自 ValueTrendTracker.trend)。
    last_value_trend: F = 0.0,
    /// 本机压力一行摘要 (可选; 空串 = 不注入)
    last_system_pressure: []const u8 = "",
    /// P4: 主机危机 (disk/mem/load 越阈) — 主动提议求存规则
    last_host_crisis: bool = false,
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

    /// KPI 趋势下滑被视为"主动提议"的阈值 (K-units/cycle)。
    /// kpiTrend 在缓冲未满时返回 0, 所以这里只对真正的负斜率反应。
    pub const KPI_DECLINE_EPS: F = 0.005;
    /// 人类 value_score 趋势下滑阈值 (P11)
    pub const VALUE_DECLINE_EPS: F = 0.003;
    /// E 饱和: ΔE 难再涨, 应提议多样性/同伴/价值规则
    pub const E_SATURATED: F = 0.98;

    /// 喂入 KPI 趋势信号 (来自 ed.kpiTrend())。与 updateState 解耦, 不破坏旧调用。
    pub fn setKpiTrend(self: *RuleProposer, trend: F) void {
        self.last_kpi_trend = trend;
    }

    /// 喂入人类价值趋势 (来自 ValueTrendTracker.trend())
    pub fn setValueTrend(self: *RuleProposer, trend: F) void {
        self.last_value_trend = trend;
    }

    /// 喂入本机压力摘要 (来自 SystemCollector / world_sensor.formatPressureLine)
    /// 指针不拥有; caller 保证在 propose 期间有效, 或传静态/持久缓冲。
    pub fn setSystemPressure(self: *RuleProposer, line: []const u8) void {
        self.last_system_pressure = line;
    }

    /// P4: 主机危机标志 (生存压力 → 应提议 material 规则)
    pub fn setHostCrisis(self: *RuleProposer, crisis: bool) void {
        self.last_host_crisis = crisis;
    }

    /// 绑定自传体记忆, 让规则提议带上"我是谁/我相信什么/相关往事"。
    pub fn setMemory(self: *RuleProposer, memory: *Memory) void {
        self.memory = memory;
    }

    /// 当下最需要补救的维度 (argmin M/R/N): 1=material 2=representation 3=nature。
    /// 用作记忆检索的 query_dim (优先回忆与短板维度相关的往事)。
    fn weakestDim(self: *const RuleProposer) u8 {
        const m = self.last_material;
        const r = self.last_representation;
        const n = self.last_nature;
        if (m <= r and m <= n) return 1;
        if (r <= m and r <= n) return 2;
        return 3;
    }

    /// 构造发给 LLM 的 user prompt (可独立测试)。
    /// 若绑定了 memory, 先注入自传体记忆块, 再附当前状态快照。
    pub fn buildUserPrompt(self: *RuleProposer, n: u32) ![]u8 {
        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);

        // 1) 自传体记忆注入 (连续性)
        if (self.memory) |m| {
            const qtext = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.last_top_goal, self.last_action });
            defer self.allocator.free(qtext);
            if (m.buildContext(self.allocator, self.weakestDim(), qtext, 5, 5)) |ctx| {
                defer self.allocator.free(ctx);
                try prompt_buf.print(self.allocator, "{s}\n", .{ctx});
            } else |_| {}
        }

        // 2) 当前状态快照
        try prompt_buf.print(self.allocator,
            \\Current state of the digital life:
            \\- E (existence degree): {d:.3}
            \\- M (material): {d:.3}
            \\- R (representation): {d:.3}
            \\- N (nature): {d:.3}
            \\- top goal: {s}
            \\- last action: {s}
            \\- last ΔE: {d:.3}
            \\- KPI trend (K/cycle, negative = product KPI declining): {d:.4}
            \\- Human value trend (score/cycle, negative = human satisfaction declining): {d:.4}
            \\- Host pressure: {s}
            \\- Host crisis (disk/mem/load over threshold): {s}
            \\
            \\Propose {d} new rules. Output ONLY a JSON array (no markdown), each object with:
            \\"name", "description", "condition", "action", "dimension" (material|representation|nature|all), "rationale".
            \\If your memory above is relevant, ground the rules in those past episodes/beliefs.
            \\If host pressure is high or host crisis is true, prefer material/survival rules.
        , .{
            @as(f32, self.last_e),
            @as(f32, self.last_material),
            @as(f32, self.last_representation),
            @as(f32, self.last_nature),
            self.last_top_goal,
            self.last_action,
            @as(f32, self.last_de),
            @as(f32, self.last_kpi_trend),
            @as(f32, self.last_value_trend),
            if (self.last_system_pressure.len > 0) self.last_system_pressure else "(unavailable)",
            if (self.last_host_crisis) "true" else "false",
            n,
        });
        return prompt_buf.toOwnedSlice(self.allocator);
    }

    /// 是否应触发一次提议: E 跌穿 / KPI·价值下滑 / E 饱和 / 主机危机。
    pub fn shouldPropose(self: *const RuleProposer, e_threshold: F) bool {
        return self.last_e < e_threshold or
            self.last_kpi_trend < -KPI_DECLINE_EPS or
            self.last_value_trend < -VALUE_DECLINE_EPS or
            self.last_e >= E_SATURATED or
            self.last_host_crisis;
    }

    /// 询问 LLM 提议 N 条规则候选
    pub fn propose(self: *RuleProposer, n: u32) ![]RuleCandidate {
        const prompt = try self.buildUserPrompt(n);
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
            // 守门: 审查候选的**全部文本** (name+description+condition+action+rationale),
            // 不只是 description — 否则 description 被洗白但 action 含 @panic 会漏网。
            const audit_text = try std.fmt.allocPrint(
                self.allocator,
                "{s} {s} {s} {s} {s}",
                .{ cand.name, cand.description, cand.condition, cand.action, cand.rationale },
            );
            defer self.allocator.free(audit_text);
            // target_file 用 examples/ 前缀 (规则不是代码文件); 黑名单含 @panic/unreachable 等危险构造
            const verdict = guard.review("examples/rules.zig", audit_text);
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

/// 一条规则的 JSON 投影 (字段缺省值容忍 LLM 漏字段)
const RuleJson = struct {
    name: []const u8 = "?",
    description: []const u8 = "?",
    condition: []const u8 = "",
    action: []const u8 = "",
    dimension: []const u8 = "all",
    rationale: []const u8 = "",
};

/// 把 LLM 输出的 JSON 规则列表解析成 RuleCandidate[]。
/// 用 std.json 做健壮解析 (正确处理嵌套大括号、转义引号、字符串内的 `}` 等,
/// 替代旧的 indexOf 手写切割)。LLM 常在 JSON 前后裹 markdown / 解说文字,
/// 故先截取第一个 '[' 到最后一个 ']' 之间的数组再解析。
fn parseRules(alloc: Allocator, content: []const u8) ![]RuleCandidate {
    const start = std.mem.indexOfScalar(u8, content, '[') orelse return &[_]RuleCandidate{};
    const end = std.mem.lastIndexOfScalar(u8, content, ']') orelse return &[_]RuleCandidate{};
    if (end <= start) return &[_]RuleCandidate{};
    const json_slice = content[start .. end + 1];

    const parsed = std.json.parseFromSlice(
        []RuleJson,
        alloc,
        json_slice,
        .{ .ignore_unknown_fields = true },
    ) catch {
        // 解析失败 (LLM 输出非法 JSON): 返回空集, 不崩溃
        return &[_]RuleCandidate{};
    };
    defer parsed.deinit();

    var list: std.ArrayList(RuleCandidate) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit();
        list.deinit(alloc);
    }

    for (parsed.value) |rj| {
        // 深拷贝每个字段, 使 RuleCandidate 独立于 parsed 的生命周期
        var cand = RuleCandidate{
            .name = try alloc.dupe(u8, rj.name),
            .description = try alloc.dupe(u8, rj.description),
            .condition = try alloc.dupe(u8, rj.condition),
            .action = try alloc.dupe(u8, rj.action),
            .target_dimension = try alloc.dupe(u8, rj.dimension),
            .rationale = try alloc.dupe(u8, rj.rationale),
            .allocator = alloc,
        };
        errdefer cand.deinit();
        try list.append(alloc, cand);
    }

    return list.toOwnedSlice(alloc);
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

test "RuleProposer: shouldPropose — E 跌穿 或 KPI 下滑 都触发" {
    const alloc = testing.allocator;
    var mock = llm_mod_mod.MockChatLLM.init(alloc, llm_mod_mod.DEFAULT_CANNED);
    var proposer = RuleProposer.init(alloc, mock.asChat());

    // E 健康 + KPI 平稳 ⇒ 不提议
    proposer.updateState(0.70, 0.6, 0.6, 0.6, "explore", "(none)", 0.0);
    proposer.setKpiTrend(0.0);
    try testing.expect(!proposer.shouldPropose(0.50));

    // E 跌穿阈值 ⇒ 提议 (旧行为保留)
    proposer.updateState(0.40, 0.6, 0.6, 0.6, "explore", "(none)", 0.0);
    try testing.expect(proposer.shouldPropose(0.50));

    // E 健康但 KPI 明显下滑 ⇒ 也提议 (新信号驱动行为)
    proposer.updateState(0.70, 0.6, 0.6, 0.6, "explore", "(none)", 0.0);
    proposer.setKpiTrend(-0.02);
    try testing.expect(proposer.shouldPropose(0.50));

    // KPI 轻微抖动 (未越过 EPS) ⇒ 不提议
    proposer.setKpiTrend(-RuleProposer.KPI_DECLINE_EPS / 2.0);
    proposer.setValueTrend(0.0);
    try testing.expect(!proposer.shouldPropose(0.50));

    // 人类价值明显下滑 ⇒ 也提议 (P11)
    proposer.updateState(0.70, 0.6, 0.6, 0.6, "explore", "(none)", 0.0);
    proposer.setKpiTrend(0.0);
    proposer.setValueTrend(-0.01);
    try testing.expect(proposer.shouldPropose(0.50));

    // E 饱和 ⇒ 也提议 (改推多样性, 非再刷高 E)
    proposer.updateState(0.99, 0.9, 0.9, 0.9, "explore", "(none)", 0.0);
    proposer.setKpiTrend(0.0);
    proposer.setValueTrend(0.0);
    try testing.expect(proposer.shouldPropose(0.50));

    // P4: 主机危机 ⇒ 也提议 (求存规则)
    proposer.updateState(0.70, 0.6, 0.6, 0.6, "explore", "(none)", 0.0);
    proposer.setHostCrisis(true);
    try testing.expect(proposer.shouldPropose(0.50));
    proposer.setHostCrisis(false);
    try testing.expect(!proposer.shouldPropose(0.50));
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

    // 3 条候选: 2 条安全规则通过, 1 条 'dangerous_panic_rule' (含 @panic) 被守门拒绝
    try testing.expectEqual(@as(usize, 3), result.candidates.len);
    try testing.expectEqual(@as(u32, 2), result.accepted);
    try testing.expectEqual(@as(u32, 1), result.rejected);

    // 规则库应当增加了 (但只增加了通过守门的 2 条)
    try testing.expectEqual(initial_count + 2, encoder.rules.items.len);
}

test "RuleProposer: 含 @panic 的规则被守门拒绝 (黑名单单一事实源)" {
    const alloc = testing.allocator;
    const canned =
        \\[{"name":"safe_rule","description":"When E low, raise gamma","condition":"E<0.5","action":"raise gamma","dimension":"nature","rationale":"explore"},
        \\{"name":"panic_rule","description":"call @panic on error","condition":"err","action":"@panic","dimension":"all","rationale":"crash"}]
    ;
    var mock = llm_mod_mod.MockChatLLM.init(alloc, canned);
    var proposer = RuleProposer.init(alloc, mock.asChat());
    proposer.updateState(0.4, 0.4, 0.3, 0.2, "explore", "noop", -0.05);

    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    var result = try proposer.proposeAndAdopt(&encoder, &guard, 2);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.accepted);
    try testing.expectEqual(@as(u32, 1), result.rejected);
}

test "RuleProposer: prompt 注入自传体记忆 (P1 连续性)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock = llm_mod_mod.MockChatLLM.init(alloc, llm_mod_mod.DEFAULT_CANNED);
    var proposer = RuleProposer.init(alloc, mock.asChat());

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("我反复在 explore 上获得增益");
    try mem.addBeliefAt(.nature, "explore 提升我的 N", 0.8, &[_]u64{1}, 1);
    try mem.recordAt(io, .reflection, 5, "explored and E rose", null, 3, 0.15);

    proposer.setMemory(&mem);
    // N 最低 ⇒ weakestDim=nature, query 含 "explore"
    proposer.updateState(0.40, 0.5, 0.5, 0.3, "explore", "noop", -0.02);

    const prompt = try proposer.buildUserPrompt(3);
    defer alloc.free(prompt);

    // prompt 必须带上"我是谁/我相信什么/相关往事"
    try testing.expect(std.mem.indexOf(u8, prompt, "我反复在 explore 上获得增益") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "explore 提升我的 N") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "explored and E rose") != null);
    // 仍保留状态快照
    try testing.expect(std.mem.indexOf(u8, prompt, "existence degree") != null);

    // 未绑定 memory ⇒ 不注入记忆块 (行为回退)
    var p2 = RuleProposer.init(alloc, mock.asChat());
    p2.updateState(0.40, 0.5, 0.5, 0.3, "explore", "noop", -0.02);
    const prompt2 = try p2.buildUserPrompt(3);
    defer alloc.free(prompt2);
    try testing.expect(std.mem.indexOf(u8, prompt2, "autobiographical context") == null);
}

const llm_mod_mod = @import("llm/mock_chat_llm.zig");
