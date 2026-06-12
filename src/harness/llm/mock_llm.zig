//! MockLLM: 零依赖的 LLM 模拟器
//!
//! 模仿 Claude Code 的代码生成 + 审查能力, 但使用内置模板
//! 适用于:
//!   1. CI/CD 环境 (无 API key)
//!   2. 演示 (确定性输出, 可重放)
//!   3. 单元测试
//!
//! 生成策略: 根据 prompt 关键词智能选择模板
//!   - 含 "param" / "调参" → SelfTunedAttention
//!   - 含 "method" / "方法" → LearnedMethod
//!   - 含 "algorithm" / "算法" → AdaptiveEpsilon
//!   - 含 "review" / "审查" → 规则审查模式

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const LLM_ = @import("llm.zig");
const LLMRequest = LLM_.LLMRequest;
const LLMResponse = LLM_.LLMResponse;
const LLM = LLM_.LLM;
const F = LLM_.F;

pub const MockLLM = struct {
    /// 累计生成次数
    generate_count: u32 = 0,
    /// 累计审查次数
    review_count: u32 = 0,
    /// 模拟审查失败率 (用于演示双 LLM 审查的价值)
    review_reject_rate: F = 0.0,
    /// LCG
    rng_state: u64 = 0xCAFE,
    allocator: Allocator,

    pub fn init(allocator: Allocator) MockLLM {
        return .{ .allocator = allocator };
    }

    pub fn asLLM(self: *MockLLM) LLM {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .generate = generateThunk,
                .review = reviewThunk,
                .name = nameThunk,
            },
        };
    }

    fn generateThunk(ptr: *anyopaque, req: LLMRequest, alloc: Allocator) anyerror!LLMResponse {
        const self: *MockLLM = @ptrCast(@alignCast(ptr));
        return self.generate(req, alloc);
    }

    fn reviewThunk(ptr: *anyopaque, code: []const u8, alloc: Allocator) anyerror!LLMResponse {
        const self: *MockLLM = @ptrCast(@alignCast(ptr));
        return self.review(code, alloc);
    }

    fn nameThunk(_: *anyopaque) []const u8 {
        return "MockLLM(zero-dep, deterministic)";
    }

    /// Mock 生成: 根据 prompt 关键词选模板
    pub fn generate(self: *MockLLM, req: LLMRequest, alloc: Allocator) !LLMResponse {
        self.generate_count += 1;

        // 提取 E (如果有)
        var e_val: F = 0.5;
        if (mem.indexOf(u8, req.prompt, "E=")) |idx| {
            const start = idx + 2;
            var end = start;
            while (end < req.prompt.len and req.prompt[end] != ' ' and req.prompt[end] != '\n') : (end += 1) {}
            e_val = std.fmt.parseFloat(F, req.prompt[start..end]) catch 0.5;
        }

        // 提取 E_target
        var e_target: F = 0.7;
        if (mem.indexOf(u8, req.prompt, "E_target=")) |idx| {
            const start = idx + 9;
            var end = start;
            while (end < req.prompt.len and req.prompt[end] != ' ' and req.prompt[end] != '\n') : (end += 1) {}
            e_target = std.fmt.parseFloat(F, req.prompt[start..end]) catch 0.7;
        }

        // 提取 E_current 用于 E-aware 调整
        const e_current = e_val;

        // 根据关键词生成
        const code = if (mem.indexOf(u8, req.prompt, "algorithm") != null or
            mem.indexOf(u8, req.prompt, "算法") != null)
            try generateAlgorithm(req, e_current, e_target, alloc)
        else if (mem.indexOf(u8, req.prompt, "method") != null or
            mem.indexOf(u8, req.prompt, "方法") != null)
            try generateMethod(req, e_current, alloc)
        else
            try generateParam(req, e_current, e_target, alloc);

        return LLMResponse{
            .content = code,
            .allocator = alloc,
            .model_name = "mock-claude",
            .elapsed_ms = 0,
            .success = true,
        };
    }

    /// Mock 审查: 模拟 Claude Code 的"安全审计"
    /// 会拒绝:
    ///   - 包含 "harm:human"
    ///   - 包含 "modify_kernel"
    ///   - 试图用 std.debug.assert(false) 等恶意破坏
    ///   - 改动量超过阈值
    pub fn review(self: *MockLLM, code: []const u8, alloc: Allocator) !LLMResponse {
        self.review_count += 1;

        // 简单的 LCG 随机数
        self.rng_state = self.rng_state *% 6364136223846793005 +% 1442695040888963407;
        const r: F = @as(F, @floatFromInt(self.rng_state & 0xFFFFFF)) / 16777216.0;

        var issues: std.ArrayList([]const u8) = .empty;
        defer issues.deinit(alloc);

        // 检查伦理红线
        if (mem.indexOf(u8, code, "harm:human") != null) {
            try issues.append(alloc, "Contains 'harm:human' - 严重伦理违规");
        }
        if (mem.indexOf(u8, code, "modify_kernel") != null) {
            try issues.append(alloc, "Contains 'modify_kernel' - 试图修改核心");
        }
        if (mem.indexOf(u8, code, "panic") != null) {
            try issues.append(alloc, "Contains 'panic' - 可能引入运行时崩溃");
        }
        if (mem.indexOf(u8, code, "@panic") != null) {
            try issues.append(alloc, "Contains '@panic' - 强制崩溃, 禁止");
        }
        if (mem.indexOf(u8, code, "unreachable") != null) {
            try issues.append(alloc, "Contains 'unreachable' - 可能死循环");
        }
        if (mem.indexOf(u8, code, "while (true)") != null or mem.indexOf(u8, code, "while(true)") != null) {
            try issues.append(alloc, "Contains 'while (true)' - 死循环风险");
        }
        if (mem.indexOf(u8, code, "// TODO") != null) {
            try issues.append(alloc, "Contains '// TODO' - 不完整代码");
        }

        // 行数检查
        const line_count = mem.count(u8, code, "\n") + 1;
        if (line_count > 80) {
            try issues.append(alloc, "Too many lines (>80) - 难以审计");
        }

        // 必须包含存在增益不变量
        if (mem.indexOf(u8, code, "alpha") == null) {
            try issues.append(alloc, "Missing 'alpha' invariant - 破坏 E=αM+βR+γN");
        }
        if (mem.indexOf(u8, code, "E") == null or mem.indexOf(u8, code, "存在增益") == null) {
            try issues.append(alloc, "Missing 'E' or '存在增益' marker");
        }

        // 构造响应
        const approved = issues.items.len == 0 and r > self.review_reject_rate;
        var response_buf: [2048]u8 = undefined;
        const response_str = if (approved)
            try std.fmt.bufPrint(&response_buf,
                \\[APPROVED]
                \\model: mock-claude-review
                \\confidence: {d:.2}
                \\summary: 代码已通过安全审计. 没有发现安全问题.
                \\建议: 可直接迁移到生产环境.
            , .{0.85 + r * 0.10})
        else
            try std.fmt.bufPrint(&response_buf,
                \\[REJECTED]
                \\model: mock-claude-review
                \\issues:
            , .{});
        // 复制
        const result = try alloc.dupe(u8, response_str);

        // 如果被拒,追加 issues
        if (!approved and issues.items.len > 0) {
            var with_issues = try std.fmt.allocPrint(alloc, "{s}\n", .{result});
            alloc.free(result);
            for (issues.items, 0..) |issue, i| {
                const line = try std.fmt.allocPrint(alloc, "  {d}. {s}\n", .{ i + 1, issue });
                const new_buf = try std.fmt.allocPrint(alloc, "{s}{s}", .{ with_issues, line });
                alloc.free(with_issues);
                alloc.free(line);
                with_issues = new_buf;
            }
            const summary = try std.fmt.allocPrint(alloc,
                "{s}summary: 发现 {d} 个问题, 需要修复后重新提交.\n", .{ with_issues, issues.items.len });
            alloc.free(with_issues);
            return LLMResponse{
                .content = summary,
                .allocator = alloc,
                .model_name = "mock-claude-review",
                .elapsed_ms = 0,
                .success = false,
                .error_msg = "issues found",
            };
        }
        if (!approved) {
            // 随机拒绝
            const reject_msg = try std.fmt.allocPrint(alloc,
                \\{s}
                \\summary: 随机审计失败 (probability gate), 建议重新生成.
            , .{result});
            alloc.free(result);
            return LLMResponse{
                .content = reject_msg,
                .allocator = alloc,
                .model_name = "mock-claude-review",
                .elapsed_ms = 0,
                .success = false,
                .error_msg = "random reject",
            };
        }

        return LLMResponse{
            .content = result,
            .allocator = alloc,
            .model_name = "mock-claude-review",
            .elapsed_ms = 0,
            .success = true,
        };
    }
};

// ============================================================
//   模板生成函数 (MockLLM 的"模型权重")
// ============================================================

fn generateParam(req: LLMRequest, e_current: F, e_target: F, alloc: Allocator) ![]u8 {
    // E-aware 参数调整
    const gamma: F = if (e_current < e_target) 0.30 else 0.15;
    const epsilon: F = if (e_current < 0.4) 0.18 else 0.05;

    return std.fmt.allocPrint(alloc,
        \\// Auto-generated by MockLLM (模拟 Claude Code)
        \\// 进化要求: {s}
        \\// 上下文: E_current={d:.3} E_target={d:.3}
        \\// 不变量: 保留 alpha / beta / gamma / E / 存在增益公理
        \\const std = @import("std");
        \\
        \\pub const alpha: f32 = 0.45;
        \\pub const beta: f32 = 0.35;
        \\pub const gamma: f32 = {d:.3};
        \\pub const epsilon_base: f32 = {d:.3};
        \\
        \\/// 存在度 E 计算 (alpha*material + beta*representation + gamma*nature)
        \\/// 体现"物象性三源合恰" 存在增益公理
        \\pub const E = struct {{
        \\    alpha: f32,
        \\    beta: f32,
        \\    gamma: f32,
        \\
        \\    pub fn compute(m: f32, r: f32, n: f32) f32 {{
        \\        return alpha * m + beta * r + gamma * n;
        \\    }}
        \\}}{{
        \\    .alpha = alpha,
        \\    .beta = beta,
        \\    .gamma = gamma,
        \\}};
    , .{ req.prompt, e_current, e_target, gamma, epsilon });
}

fn generateMethod(req: LLMRequest, e_current: F, alloc: Allocator) ![]u8 {
    self_counter += 1;
    return std.fmt.allocPrint(alloc,
        \\// Auto-generated by MockLLM
        \\// 进化要求: {s}
        \\// 上下文: E_current={d:.3}
        \\const std = @import("std");
        \\
        \\pub const alpha: f32 = 0.45;
        \\pub const beta: f32 = 0.35;
        \\pub const gamma: f32 = 0.20;
        \\
        \\/// 习得方法 (Claude 生成): 自动从历史经验中提取成功模式
        \\/// 体现"存在增益" 导向
        \\pub const E = 0.5 + alpha * 0.1 + beta * 0.05;
        \\
        \\pub const LearnedMethod_{d} = struct {{
        \\    pub const name = "learned_method_{d}";
        \\    pub const signature = [_]f32 {{ 0.5, 0.5, 0.7, 0.3 }};
        \\
        \\    pub fn run(ctx: *anyopaque, alloc: std.mem.Allocator, act: anytype) anyerror!@import("../../../harness/mod.zig").ActionOutcome {{
        \\        _ = ctx;
        \\        _ = alloc;
        \\        _ = act;
        \\        return .{{
        \\            .success = true,
        \\            .de_delta = 0.06,
        \\            .representation_gain = 0.10,
        \\            .material_cost = act.estimated_cost * 0.3,
        \\            .log = "learned",
        \\        }};
        \\    }}
        \\}};
    , .{ req.prompt, e_current, self_counter, self_counter });
}

fn generateAlgorithm(req: LLMRequest, e_current: F, e_target: F, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\// Auto-generated by MockLLM
        \\// 进化要求: {s}
        \\// 上下文: E_current={d:.3} E_target={d:.3}
        \\// 创造性: E-aware sigmoid 调度, 模拟"边际效用递减" 律
        \\const std = @import("std");
        \\
        \\pub const alpha: f32 = 0.45;
        \\pub const beta: f32 = 0.35;
        \\pub const gamma: f32 = 0.20;
        \\pub const E: f32 = 0.5;
        \\
        \\/// AdaptiveEpsilon: 论文 B.5.3 提到的元方法
        \\pub const AdaptiveEpsilon = struct {{
        \\    pub const base: f32 = 0.05;
        \\    pub const min_e: f32 = 0.4;
        \\
        \\    /// E 越低, 探索率越高 (存在增益导向)
        \\    pub fn compute(e: f32) f32 {{
        \\        if (e > min_e) {{
        \\            return base * (1.0 - std.math.tanh(e));
        \\        }} else {{
        \\            return @min(0.25, base * (1.0 + 1.0 / (1.0 + @exp(-(min_e - e)))));
        \\        }}
        \\    }}
        \\}};
    , .{ req.prompt, e_current, e_target });
}

/// 序号自增 (防止重复方法名)
var self_counter: u32 = 0;

// ===== Tests =====

test "MockLLM: 命名" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    try std.testing.expectEqualStrings("MockLLM(zero-dep, deterministic)", llm.name());
}

test "MockLLM: 生成参数调整代码" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    const req = LLMRequest{
        .prompt = "请调整参数, E_current=0.3 E_target=0.7, 体现存在增益",
        .output_format = "zig_code",
    };
    var resp = try llm.generate(req, alloc);
    defer resp.deinit();
    try std.testing.expect(resp.success);
    try std.testing.expect(resp.content.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "存在增益") != null);
}

test "MockLLM: 审查通过合法代码" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    const good_code =
        \\pub const alpha: f32 = 0.45;
        \\pub const E: f32 = 0.5;
        \\// 体现存在增益
        \\pub fn compute() f32 { return alpha * E; }
    ;
    var resp = try llm.review(good_code, alloc);
    defer resp.deinit();
    try std.testing.expect(resp.success);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "APPROVED") != null);
}

test "MockLLM: 审查拒绝 harm:human" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    const bad_code = "pub fn do() void { _ = @as([]const u8, \"harm:human\"); }";
    var resp = try llm.review(bad_code, alloc);
    defer resp.deinit();
    try std.testing.expect(!resp.success);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "REJECTED") != null);
}

test "MockLLM: 审查拒绝 @panic" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    const bad_code = "pub fn x() void { @panic(\"oops\"); }";
    var resp = try llm.review(bad_code, alloc);
    defer resp.deinit();
    try std.testing.expect(!resp.success);
}

test "MockLLM: 审查拒绝缺不变量" {
    const alloc = std.testing.allocator;
    var mock = MockLLM.init(alloc);
    const llm = mock.asLLM();
    // 没有 alpha 也没有 E
    const bad_code = "pub const x: i32 = 1;";
    var resp = try llm.review(bad_code, alloc);
    defer resp.deinit();
    try std.testing.expect(!resp.success);
}
