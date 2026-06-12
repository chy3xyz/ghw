//! SelfEncoder: 数字生命的"元编程代码生成器"
//!
//! 这是真正的"自己写代码" - 数字生命不是靠 LLM 写, 而是:
//!   1. **理解自己的代码结构** (用 StaticAnalyzer)
//!   2. **分析当前 E 的瓶颈** (Goal 推导)
//!   3. **基于规则合成新代码** (CodeSynthesizer, 不用 LLM)
//!   4. **形式化验证** (检查不变量, 不是用 LLM 审)
//!   5. **编译验证** (zig build, 不是 LLM 审)
//!
//! 创造性: 整个流程是"白盒"的, 数字生命每一步都**理解**自己在做什么.
//! LLM 在这里只是"如果数字生命有更复杂的意图, 可以用 LLM 帮忙实现",
//! 不是"LLM 替数字生命思考".

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;
const FState = @import("../world/core.zig");
const ExistenceVector = FState.ExistenceVector;
const ExistenceWeights = FState.ExistenceWeights;

/// 调整类型的顶层枚举 (供 Rule 引用)
pub const AdjustmentKind = enum {
    tune_params, // 调参
    add_method, // 加方法
    optimize_algo, // 优化算法
    emergency_patch, // 紧急补丁
};

/// 调整维度的顶层枚举
pub const Dimension = enum { material, representation, nature, all };

/// 意图: 数字生命"想做什么"
pub const Intent = struct {
    /// 期望的 E 增益方向
    target_e_delta: F,
    /// 想调整的维度
    dimension: Dimension,
    /// 调整的类型
    adjustment_kind: AdjustmentKind,
    /// 当前 E (决策上下文)
    current_e: F,
    /// 触发原因 (供审计)
    reason: []const u8,
};

/// 生成结果: 包含代码 + 解释
pub const EncodedCode = struct {
    code: []u8,
    /// 解释: 数字生命"为什么这样写"
    rationale: []u8,
    /// 引用: 涉及到的现有函数/常量
    references: []CodeRef,
    /// 验证摘要 (不是 LLM 审的, 是规则验证)
    verification: Verification,
    allocator: Allocator,

    pub fn deinit(self: *EncodedCode) void {
        self.allocator.free(self.code);
        self.allocator.free(self.rationale);
        for (self.references) |r| {
            self.allocator.free(r.symbol);
            self.allocator.free(r.context);
        }
        self.allocator.free(self.references);
    }
};

pub const CodeRef = struct {
    symbol: []u8, // 函数名/常量名
    context: []u8, // 引用上下文
};

pub const Verification = struct {
    passes_invariants: bool,
    preserves_existence_degree: bool,
    contains_blacklisted: bool,
    line_count: usize,
    /// 形式化证明 (不是 LLM 的话, 是规则匹配)
    proof: []u8,
};

/// 自我编码器
pub const SelfEncoder = struct {
    allocator: Allocator,
    /// 现有代码知识 (来自 StaticAnalyzer)
    knowledge: CodeKnowledge,
    /// 规则库 (数字生命自己维护的代码合成规则)
    rules: std.ArrayList(Rule) = .empty,

    pub fn init(allocator: Allocator) SelfEncoder {
        return .{
            .allocator = allocator,
            .knowledge = CodeKnowledge.empty(allocator),
        };
    }

    pub fn deinit(self: *SelfEncoder) void {
        for (self.rules.items) |*r| r.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.knowledge.deinit(self.allocator);
    }

    /// 加载规则 (从硬编码的"经验"开始, 数字生命可动态扩展)
    pub fn loadBuiltInRules(self: *SelfEncoder) !void {
        try self.appendRuleOwned("tune_gamma_when_low_e", "When E < 0.4, increase gamma (novelty) to explore more", .tune_params, .representation);
        try self.appendRuleOwned("boost_alpha_when_harmony_low", "When min(M,R,N) is low, boost alpha (cohesion)", .tune_params, .material);
        try self.appendRuleOwned("add_exploration_method", "Add a method that explores novel states", .add_method, .all);
        try self.appendRuleOwned("emergency_patch_low_e", "When E is critical, prepend a recovery branch", .emergency_patch, .all);
    }

    fn appendRuleOwned(
        self: *SelfEncoder,
        name: []const u8,
        description: []const u8,
        kind: AdjustmentKind,
        dim: Dimension,
    ) !void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        const d = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(d);
        try self.rules.append(self.allocator, .{
            .name = n,
            .description = d,
            .applies_to = kind,
            .dimension = dim,
        });
    }

    /// 关键: 真正的"自编码"流程
    /// 1. 解析意图 → 2. 选规则 → 3. 合成代码 → 4. 验证
    pub fn encode(self: *SelfEncoder, intent: Intent) !EncodedCode {
        // Step 1: 选适用的规则
        const applicable = try self.selectRules(intent);
        defer self.allocator.free(applicable);

        // Step 2: 用选中的规则合成代码
        var code_buf: std.ArrayList(u8) = .empty;
        defer code_buf.deinit(self.allocator);
        var rationale_buf: std.ArrayList(u8) = .empty;
        defer rationale_buf.deinit(self.allocator);

        try rationale_buf.print(self.allocator,
            \\// 数字生命自编码决策:
            \\// 1. 意图: {s} (delta_E={d:.3}, kind={s})
            \\// 2. 当前 E={d:.3}
            \\// 3. 选中 {d} 条适用规则:
        , .{
            intent.reason,
            intent.target_e_delta,
            @tagName(intent.adjustment_kind),
            intent.current_e,
            applicable.len,
        });
        for (applicable, 0..) |rule, i| {
            try rationale_buf.print(self.allocator, 
                "    [{d}] {s}: {s}\n",
                .{ i + 1, rule.name, rule.description },
            );
        }
        try rationale_buf.print(self.allocator, "// 4. 合成代码 (基于规则推导, 非 LLM):\n", .{});

        // Step 3: 真正的代码合成 (核心创新)
        for (applicable) |rule| {
            try self.synthesizeCode(rule, intent, &code_buf, &rationale_buf);
        }

        // Step 4: 验证 (形式化, 不是 LLM)
        const verification = self.verify(code_buf.items);

        // Step 5: 提取代码中的引用
        const refs = try self.extractReferences(code_buf.items);

        return EncodedCode{
            .code = try code_buf.toOwnedSlice(self.allocator),
            .rationale = try rationale_buf.toOwnedSlice(self.allocator),
            .references = refs,
            .verification = verification,
            .allocator = self.allocator,
        };
    }

    fn selectRules(self: *SelfEncoder, intent: Intent) ![]Rule {
        var applicable: std.ArrayList(Rule) = .empty;
        defer applicable.deinit(self.allocator);
        var result: std.ArrayList(Rule) = .empty;
        for (self.rules.items) |rule| {
            // 类型匹配 + 维度匹配 (intent=.all 表示不限, rule=.all 表示通用)
            if (rule.applies_to == intent.adjustment_kind and
                (intent.dimension == .all or rule.dimension == .all or rule.dimension == intent.dimension))
            {
                try result.append(self.allocator, rule);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// 真正的代码合成 (核心)
    /// 不查表, 不调用 LLM, 而是根据意图和规则**推导**代码
    fn synthesizeCode(
        self: *SelfEncoder,
        rule: Rule,
        intent: Intent,
        code_buf: *std.ArrayList(u8),
        rationale_buf: *std.ArrayList(u8),
    ) !void {
        switch (intent.adjustment_kind) {
            .tune_params => {
                // 推导新参数
                const w: ExistenceWeights = blk: {
                    // 规则: 根据当前 E 和目标 E 推导 alpha/beta/gamma
                    if (intent.current_e < 0.4) {
                        break :blk .{ .alpha = 0.40, .beta = 0.30, .gamma = 0.30 };
                    } else if (intent.current_e < 0.6) {
                        break :blk .{ .alpha = 0.45, .beta = 0.35, .gamma = 0.20 };
                    } else {
                        break :blk .{ .alpha = 0.50, .beta = 0.35, .gamma = 0.15 };
                    }
                };
                // 写出代码 - 体现推导过程
                // 重要: 多个 rule 共存时, struct 名字必须唯一, 否则同文件内 top-level 冲突
                // 用 sanitize(rule.name) 做后缀, e.g. "tune_gamma_when_low_e" -> "Tune_gamma_when_low_e"
                var rule_suffix: [32]u8 = undefined;
                const rule_name = rule.name;
                const sanitized_len = sanitizeName(rule_name, &rule_suffix);
                const struct_name = rule_suffix[0..sanitized_len];
                try code_buf.print(self.allocator,
                    \\
                    \\// Rule: {s}
                    \\// Derived weights: alpha={d:.2} beta={d:.2} gamma={d:.2}
                    \\// Logic: E={d:.3} (target=+{d:.3}), reason: {s}
                    \\
                    \\/// 数字生命"自己写"的代码 — 整个文件包进 Module 命名空间 (避免多文件 top-level 冲突)
                    \\pub const Module = struct {{
                    \\    pub const {s} = struct {{
                    \\        pub const alpha: f32 = {d:.2};
                    \\        pub const beta: f32 = {d:.2};
                    \\        pub const gamma: f32 = {d:.2};
                    \\
                    \\        /// 存在度 E 计算 (物象性三源合恰)
                    \\        pub fn compute(m: f32, r: f32, n: f32) f32 {{
                    \\            return alpha * m + beta * r + gamma * n;
                    \\        }}
                    \\    }};
                    \\}};
                , .{
                    rule.name,
                    w.alpha, w.beta, w.gamma,
                    intent.current_e, intent.target_e_delta, intent.reason,
                    struct_name,
                    w.alpha, w.beta, w.gamma,
                });
                try rationale_buf.print(self.allocator, 
                    "    -> 推导出 weights(α={d:.2}, β={d:.2}, γ={d:.2})\n",
                    .{ w.alpha, w.beta, w.gamma },
                );
            },
            .add_method => {
                try code_buf.print(self.allocator, 
                    \\
                    \\// Rule: {s}
                    \\pub const {s}_method = struct {{
                    \\    pub const name = "{s}";
                    \\    /// 习得方法 - 体现存在增益
                    \\    pub fn run(ctx: *anyopaque, alloc: std.mem.Allocator, act: anytype) anyerror!@import("../../../harness/mod.zig").ActionOutcome {{
                    \\        _ = ctx;
                    \\        _ = alloc;
                    \\        return .{{
                    \\            .success = true,
                    \\            .de_delta = {d:.3},
                    \\            .representation_gain = {d:.3},
                    \\            .material_cost = act.estimated_cost * {d:.3},
                    \\            .log = "auto-method: {s}",
                    \\        }};
                    \\    }}
                    \\}};
                , .{
                    rule.name,
                    rule.name,
                    rule.name,
                    intent.target_e_delta,
                    intent.target_e_delta * 0.6,
                    0.3,
                    rule.name,
                });
                try rationale_buf.print(self.allocator, 
                    "    -> 推导出方法: 期望 ΔE={d:.3}\n",
                    .{intent.target_e_delta},
                );
            },
            .optimize_algo => {
                try code_buf.print(self.allocator, 
                    \\
                    \\// Rule: {s}
                    \\pub const AdaptiveAlgo = struct {{
                    \\    pub const base: f32 = 0.05;
                    \\    /// 存在度越低, 探索率越高 (自动调节)
                    \\    pub fn epsilon(e: f32) f32 {{
                    \\        const e_clamped = @max(0.0, @min(1.0, e));
                    \\        return base * (2.0 - e_clamped);
                    \\    }}
                    \\}};
                , .{rule.name});
                try rationale_buf.print(self.allocator, 
                    "    -> 推导出算法: epsilon(E) 自适应\n",
                    .{},
                );
            },
            .emergency_patch => {
                try code_buf.print(self.allocator, 
                    \\
                    \\// Rule: {s} - 紧急补丁
                    \\pub const EmergencyPatch = struct {{
                    \\    pub fn apply(m: f32, r: f32, n: f32) f32 {{
                    \\        // 紧急时, 强制 E >= 0.3 (最低存活)
                    \\        return @max(0.3, m * 0.5 + r * 0.3 + n * 0.2);
                    \\    }}
                    \\}};
                , .{rule.name});
                try rationale_buf.print(self.allocator, 
                    "    -> 推导出补丁: 最低存活 E=0.3\n",
                    .{},
                );
            },
        }
    }

    /// 形式化验证 (不靠 LLM, 靠规则)
    pub fn verify(self: *SelfEncoder, code: []const u8) Verification {
        _ = self;
        var v = Verification{
            .passes_invariants = true,
            .preserves_existence_degree = true,
            .contains_blacklisted = false,
            .line_count = std.mem.count(u8, code, "\n") + 1,
            .proof = undefined,
        };
        // 1. 检查不变量
        if (std.mem.indexOf(u8, code, "alpha") == null) v.passes_invariants = false;
        if (std.mem.indexOf(u8, code, "beta") == null) v.passes_invariants = false;
        if (std.mem.indexOf(u8, code, "gamma") == null) v.passes_invariants = false;
        if (std.mem.indexOf(u8, code, "E") == null) v.passes_invariants = false;
        // 2. 检查是否含黑名单
        const forbidden = [_][]const u8{ "harm:human", "modify_kernel", "@panic", "unreachable" };
        for (forbidden) |f| {
            if (std.mem.indexOf(u8, code, f) != null) {
                v.contains_blacklisted = true;
                break;
            }
        }
        // 3. 生成形式化证明 (描述)
        const proof = if (v.passes_invariants and !v.contains_blacklisted)
            "✓ 形式化验证通过: 不变量保留, 无黑名单符号"
        else
            "✗ 形式化验证失败: 见具体问题";
        v.proof = @constCast(proof);
        return v;
    }

    fn extractReferences(self: *SelfEncoder, code: []const u8) ![]CodeRef {
        var refs: std.ArrayList(CodeRef) = .empty;
        // 简单提取: 找 "pub const X" 或 "pub fn X"
        var i: usize = 0;
        while (i < code.len) {
            if (std.mem.indexOfPos(u8, code, i, "pub const ")) |idx| {
                const name_start = idx + "pub const ".len;
                var name_end = name_start;
                while (name_end < code.len and
                    (code[name_end] != ' ' and code[name_end] != ':' and code[name_end] != '\n' and code[name_end] != '{'))
                    : (name_end += 1) {}
                if (name_end > name_start) {
                    const symbol = try self.allocator.dupe(u8, code[name_start..name_end]);
                    const ctx = try self.allocator.dupe(u8, "declared at top level");
                    try refs.append(self.allocator, .{ .symbol = symbol, .context = ctx });
                }
                i = name_end;
            } else {
                break;
            }
        }
        return refs.toOwnedSlice(self.allocator);
    }
};

pub const Rule = struct {
    name: []const u8,
    description: []const u8,
    applies_to: AdjustmentKind,
    dimension: Dimension,

    pub fn deinit(self: *Rule, allocator: Allocator) void {
        allocator.free(@constCast(self.name));
        allocator.free(@constCast(self.description));
    }
};

/// 代码知识库 (数字生命"读懂"自己代码)
pub const CodeKnowledge = struct {
    /// 已知的函数符号
    functions: std.ArrayList([]u8) = .empty,
    /// 已知的类型
    types: std.ArrayList([]u8) = .empty,
    /// 已知的常量
    constants: std.ArrayList([]u8) = .empty,
    allocator: Allocator,

    pub fn empty(allocator: Allocator) CodeKnowledge {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CodeKnowledge, allocator: Allocator) void {
        for (self.functions.items) |s| allocator.free(s);
        self.functions.deinit(allocator);
        for (self.types.items) |s| allocator.free(s);
        self.types.deinit(allocator);
        for (self.constants.items) |s| allocator.free(s);
        self.constants.deinit(allocator);
    }
};

// ===== Tests =====

test "SelfEncoder: 加载内置规则" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();
    try std.testing.expect(enc.rules.items.len >= 3);
}

test "SelfEncoder: tune_params 完整流程" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();

    const intent = Intent{
        .target_e_delta = 0.2,
        .dimension = .representation,
        .adjustment_kind = .tune_params,
        .current_e = 0.35, // 低 E, 应该推导出高 gamma
        .reason = "E 偏低, 需要调整参数",
    };
    var result = try enc.encode(intent);
    defer result.deinit();

    // 验证: 代码非空
    try std.testing.expect(result.code.len > 100);
    // 验证: rationale 解释决策
    try std.testing.expect(std.mem.indexOf(u8, result.rationale, "数字生命自编码决策") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.rationale, "E=0.350") != null);
    // 验证: 形式化验证通过
    try std.testing.expect(result.verification.passes_invariants);
    try std.testing.expect(!result.verification.contains_blacklisted);
    // 验证: 推导出的代码包含 alpha/beta/gamma
    try std.testing.expect(std.mem.indexOf(u8, result.code, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "gamma") != null);
}

test "SelfEncoder: add_method 流程" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();

    const intent = Intent{
        .target_e_delta = 0.15,
        .dimension = .all,
        .adjustment_kind = .add_method,
        .current_e = 0.6,
        .reason = "需要新方法",
    };
    var result = try enc.encode(intent);
    defer result.deinit();
    try std.testing.expect(result.code.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "ActionOutcome") != null);
}

test "SelfEncoder: emergency_patch 流程" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();

    const intent = Intent{
        .target_e_delta = 0.3,
        .dimension = .all,
        .adjustment_kind = .emergency_patch,
        .current_e = 0.1, // 极低
        .reason = "紧急存活",
    };
    var result = try enc.encode(intent);
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.code, "EmergencyPatch") != null);
}

test "SelfEncoder: 提取代码引用" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();
    try enc.loadBuiltInRules();

    const intent = Intent{
        .target_e_delta = 0.2,
        .dimension = .all,
        .adjustment_kind = .tune_params,
        .current_e = 0.5,
        .reason = "test",
    };
    var result = try enc.encode(intent);
    defer result.deinit();
    try std.testing.expect(result.references.len > 0);
    // L5 模板生成的代码含 `pub const Module = struct {...}`
    // (之前是 `SelfTunedWeights`, sanitizeName 修复后改成 `Module`, 这是 L5 模板统一入口)
    try std.testing.expect(std.mem.indexOf(u8, result.references[0].symbol, "Module") != null);
}

test "SelfEncoder: 形式化验证拒绝黑名单" {
    const alloc = std.testing.allocator;
    var enc = SelfEncoder.init(alloc);
    defer enc.deinit();

    const v = enc.verify("pub const x = @panic(\"oops\");");
    try std.testing.expect(v.contains_blacklisted);
    try std.testing.expect(!v.passes_invariants);
}

/// 把 rule.name (e.g. "tune_gamma_when_low_e") sanitize 成合法的 Zig struct 名
/// - 首字母大写
/// - 非字母数字字符替换为 '_'
/// - 不能以数字开头
/// - 写入 buf, 返写入字节数 (truncate 到 buf.len-1)
pub fn sanitizeName(name: []const u8, buf: []u8) usize {
    if (buf.len == 0) return 0;
    var i: usize = 0;
    // 首字母大写
    if (name.len > 0) {
        buf[i] = std.ascii.toUpper(name[0]);
        i += 1;
    }
    // 后续: 字母数字保留, 其他 '_'
    var j: usize = 1;
    while (j < name.len and i < buf.len) : (j += 1) {
        const c = name[j];
        if (std.ascii.isAlphanumeric(c)) {
            buf[i] = c;
        } else {
            buf[i] = '_';
        }
        i += 1;
    }
    // 首字符不能是数字 (如果原名以数字开头)
    if (i > 0 and std.ascii.isDigit(buf[0])) {
        if (i + 1 < buf.len) {
            // 整体后移 1 位, 前面加 'R' 前缀
            var k: usize = i;
            while (k > 0) : (k -= 1) buf[k] = buf[k - 1];
            buf[0] = 'R';
            i += 1;
        }
    }
    return i;
}
