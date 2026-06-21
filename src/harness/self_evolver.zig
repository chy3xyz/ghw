//! SelfEvolver: 自我升级主控
//!
//! 完整流程: 触发 → 生成 → 审查 → 落地 → 反馈
//!   1. Goal 层生成 self_modify_* / self_extend_method / self_optimize 目标
//!   2. Harness 选择 SelfEvolver
//!   3. SelfEvolver 调用 CodeGenerator 生成代码
//!   4. SelfEvolutionGuard.review() 严格审查
//!   5. 通过 → 写入文件 → 触发"重新注册"
//!   6. 失败 → 记录原因, 反馈负向 ΔE
//!
//! 论文对应: B.5.3 长期方向 - "GHW 系统的自我演化"

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;
const self_evolution = @import("self_evolution_guard.zig");
const code_generator = @import("code_generator.zig");

const SelfEvolutionGuard = self_evolution.SelfEvolutionGuard;
const ReviewVerdict = self_evolution.ReviewVerdict;
const CodeGenerator = code_generator.CodeGenerator;
const CompileVerifier = @import("compile_verifier.zig").CompileVerifier;
const StaticCodeGenerator = code_generator.StaticCodeGenerator;
const GenerationRequest = code_generator.GenerationRequest;
const GenerationResult = code_generator.GenerationResult;
const GenerationKind = code_generator.GenerationKind;
const Memory = @import("memory.zig").Memory;

/// 演化事件: 一次完整的自升级尝试
pub const EvolutionEvent = struct {
    tick: u64,
    target_file: []const u8,
    kind: GenerationKind,
    verdict: ReviewVerdict,
    /// 实际产生的 ΔE (成功为正, 失败为负)
    de_delta: F,
    /// 生成的代码行数
    code_lines: usize,
};

/// 演化结果: 单次 SelfEvolver.evolve() 的产出
pub const EvolutionOutcome = struct {
    approved: bool,
    verdict: ReviewVerdict,
    target_file: []const u8,
    generated_code: []u8,
    allocator: Allocator,
    de_delta: F,
    representation_gain: F,
    /// 真编译时的 stderr (verifier 输出), rejected_compile_failed 时包含详细错误
    /// L1/L2 是空, L3/L4/L5 才有
    compile_stderr: []u8 = &[_]u8{},

    pub fn deinit(self: *EvolutionOutcome) void {
        self.allocator.free(self.generated_code);
        if (self.compile_stderr.len > 0) self.allocator.free(self.compile_stderr);
    }
};

/// 单次 evolve 的 agent 快照 (P3: 供记忆检索 + context 构造)
pub const EvolveContext = struct {
    e: F,
    tick: u64,
    material: F = 0.33,
    representation: F = 0.33,
    nature: F = 0.34,
    query_text: []const u8 = "",
};

pub const SelfEvolver = struct {
    allocator: Allocator,
    guard: SelfEvolutionGuard,
    generator: CodeGenerator,
    /// 可选: 编译验证器 (L5 兜底). null = 只过 guard, 不真编译
    verifier: ?*CompileVerifier = null,
    /// 累计编译验证通过次数
    compile_pass_count: u32 = 0,
    /// 累计编译验证失败次数
    compile_fail_count: u32 = 0,
    /// 演化历史
    history: std.ArrayList(EvolutionEvent) = .empty,
    /// 累计成功次数
    success_count: u32 = 0,
    /// 累计失败次数
    fail_count: u32 = 0,
    /// 累计 ΔE
    cumulative_de: F = 0,
    /// 最近一次成功生成的代码 (审计/热加载用)
    latest_code: ?[]u8 = null,
    /// 最近一次的目标文件
    latest_target: ?[]const u8 = null,
    /// 自传体记忆 (P3): 绑定后 enrich prompt/context, 供 LLM 后端 + 审计
    memory: ?*Memory = null,

    pub fn init(allocator: Allocator, generator: CodeGenerator) SelfEvolver {
        return .{
            .allocator = allocator,
            .guard = SelfEvolutionGuard.init(allocator),
            .generator = generator,
        };
    }

    /// 绑定编译验证器 (L5 兜底)
    pub fn bindVerifier(self: *SelfEvolver, verifier: *CompileVerifier) void {
        self.verifier = verifier;
    }

    pub fn setMemory(self: *SelfEvolver, memory: *Memory) void {
        self.memory = memory;
    }

    /// 切换 CodeGenerator 后端 (P4: Static → Llm)
    pub fn setGenerator(self: *SelfEvolver, generator: CodeGenerator) void {
        self.generator = generator;
    }

    pub fn deinit(self: *SelfEvolver) void {
        if (self.latest_code) |c| self.allocator.free(c);
        self.guard.deinit();
        self.history.deinit(self.allocator);
    }

    /// 单次自升级: 从触发到落地
    /// request.kind 决定生成什么类型
    /// current_e 注入到 context, 让模板能根据 E 调整参数
    pub fn evolve(
        self: *SelfEvolver,
        request: GenerationRequest,
        ctx: EvolveContext,
    ) !EvolutionOutcome {
        // 1. 注入当前 E 到 context
        var context_buf: [512]u8 = undefined;
        const base_context = std.fmt.bufPrint(&context_buf, "tick={d} E={d:.3} {s}", .{
            ctx.tick, ctx.e, request.context,
        }) catch request.context;

        var req = request;
        req.context = base_context;

        // 1.5 P3: 自传体记忆注入 prompt (LLM 后端 + 生成代码注释审计链)
        var mem_prompt: ?[]u8 = null;
        defer if (mem_prompt) |p| self.allocator.free(p);
        if (self.memory) |memory_ref| {
            const qdim = Memory.weakestDim(ctx.material, ctx.representation, ctx.nature);
            const qtext = if (ctx.query_text.len > 0) ctx.query_text else base_context;
            if (memory_ref.buildContext(self.allocator, qdim, qtext, 3, 3)) |block| {
                defer self.allocator.free(block);
                if (request.prompt.len > 0) {
                    mem_prompt = try std.fmt.allocPrint(self.allocator, "{s}\n---\n{s}", .{ block, request.prompt });
                } else {
                    mem_prompt = try self.allocator.dupe(u8, block);
                }
                req.prompt = mem_prompt.?;
            } else |_| {}
        }

        // 2. 调用代码生成器
        const gen_result = self.generator.generate(req, self.allocator);
        var gr = gen_result catch {
            // 生成失败
            self.fail_count += 1;
            try self.history.append(self.allocator, .{
                .tick = ctx.tick,
                .target_file = req.target_file,
                .kind = req.kind,
                .verdict = .rejected_empty,
                .de_delta = -0.02,
                .code_lines = 0,
            });
            return EvolutionOutcome{
                .approved = false,
                .verdict = .rejected_empty,
                .target_file = req.target_file,
                .generated_code = try self.allocator.dupe(u8, ""),
                .allocator = self.allocator,
                .de_delta = -0.02,
                .representation_gain = 0,
            };
        };
        errdefer gr.deinit();

        const code_lines = std.mem.count(u8, gr.generated_code, "\n") + 1;

        // 3. 审查
        var verdict = self.guard.review(gr.target_file, gr.generated_code);

        // 3.5 编译验证 (L5 兜底, 如果绑了 verifier)
        // 通过 guard 后, 真编译一次, 如果编译失败, verdict 降级为 rejected_compile_failed
        var saved_stderr: []u8 = &[_]u8{};
        if (verdict == .approved) {
            std.debug.print("[self-evolver] guard 通过, 开始编译验证 target={s} code={d}B\n", .{ gr.target_file, gr.generated_code.len });
            if (self.verifier) |v| {
                const verify_req = @import("compile_verifier.zig").VerifyRequest{
                    .code = gr.generated_code,
                    .target_name = gr.target_file,
                };
                if (v.verify(verify_req)) |verify_res| {
                    var verify_res_mut = verify_res;
                    defer verify_res_mut.deinit();
                    if (!verify_res.success) {
                        verdict = .rejected_compile_failed;
                        self.compile_fail_count += 1;
                        // 把 stderr 完整保存 (返给 caller 进 episode, 方便 debug)
                        saved_stderr = self.allocator.dupe(u8, verify_res_mut.stderr) catch "";
                        // debug: 打印完整 compile stderr (前 500 字符)
                        const stderr_preview = if (verify_res_mut.stderr.len > 500)
                            verify_res_mut.stderr[0..500]
                        else
                            verify_res_mut.stderr;
                        std.debug.print("[self-evolver] compile FAIL: exit={d} stderr={s}\n", .{ verify_res_mut.exit_code, stderr_preview });
                    } else {
                        self.compile_pass_count += 1;
                        std.debug.print("[self-evolver] compile OK ({d}ms)\n", .{verify_res_mut.elapsed_ms});
                    }
                } else |err| {
                    // verifier 自己失败 (spawn 失败等), 保守地降级
                    verdict = .rejected_compile_failed;
                    self.compile_fail_count += 1;
                    std.debug.print("[self-evolver] verifier spawn/IO 失败: {t}\n", .{err});
                }
            }
        }

        // 4. 计算 ΔE
        var de_delta: F = 0;
        var rep_gain: F = 0;
        var approved = false;
        switch (verdict) {
            .approved => {
                approved = true;
                self.success_count += 1;
                de_delta = 0.10 + gr.expected_representation_gain * 0.5; // 成功 = 大幅正向
                rep_gain = gr.expected_representation_gain;
            },
            else => {
                self.fail_count += 1;
                de_delta = -0.03; // 失败 = 轻度负向 (损耗但不至于崩溃)
                rep_gain = 0;
            },
        }
        self.cumulative_de += de_delta;

        // 5. 记录历史
        try self.history.append(self.allocator, .{
            .tick = ctx.tick,
            .target_file = gr.target_file,
            .kind = req.kind,
            .verdict = verdict,
            .de_delta = de_delta,
            .code_lines = code_lines,
        });
        if (self.history.items.len > 256) {
            _ = self.history.orderedRemove(0);
        }

        // 6. 转移 generated_code 所有权给 outcome
        const outcome = EvolutionOutcome{
            .approved = approved,
            .verdict = verdict,
            .target_file = gr.target_file,
            .generated_code = gr.generated_code,
            .allocator = self.allocator,
            .de_delta = de_delta,
            .representation_gain = rep_gain,
            .compile_stderr = saved_stderr,
        };
        // 防止 errdefer 释放
        gr.generated_code = &[_]u8{};
        gr.deinit();
        return outcome;
    }

    /// 把 approved 的代码"落地" - 本阶段仅在内存中保留
    /// 真实部署需要 Io + subprocess 调 zig build
    pub fn apply(self: *SelfEvolver, outcome: EvolutionOutcome) !bool {
        if (!outcome.approved) return false;
        // 释放之前的缓存
        if (self.latest_code) |old| self.allocator.free(old);
        // 复制代码到最新位置 (outcome.generated_code 所有权已转移)
        self.latest_code = outcome.generated_code;
        self.latest_target = outcome.target_file;
        return true;
    }

    /// 最近一次成功生成的代码 (供 demo / 审计)
    pub fn latestCode(self: *SelfEvolver) ?[]const u8 {
        return self.latest_code;
    }

    /// 最近一次成功的目标文件
    pub fn latestTarget(self: *SelfEvolver) []const u8 {
        return self.latest_target orelse "(none)";
    }

    /// 演化历史统计
    pub fn stats(self: SelfEvolver, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("SelfEvolver: success={d} fail={d} cumΔE={d:.3}", .{
            self.success_count, self.fail_count, self.cumulative_de,
        });
    }
};

// ===== Tests =====

test "SelfEvolver: 完整自升级流程 (成功路径)" {
    const alloc = std.testing.allocator;
    var gen = StaticCodeGenerator.init(alloc);
    const cg = gen.asGenerator();
    var se = SelfEvolver.init(alloc, cg);
    defer se.deinit();

    const req = GenerationRequest{
        .kind = .param_adjustment,
        .context = "stagnation E=0.4",
        .target_file = "src/agent/params.zig",
    };
    var outcome = try se.evolve(req, .{ .e = 0.4, .tick = 1 });
    defer outcome.deinit();
    try std.testing.expect(outcome.approved);
    try std.testing.expectEqual(ReviewVerdict.approved, outcome.verdict);
    try std.testing.expect(outcome.de_delta > 0);
    try std.testing.expectEqual(@as(u32, 1), se.success_count);
}

test "SelfEvolver: 黑名单路径被拒" {
    const alloc = std.testing.allocator;
    var gen = StaticCodeGenerator.init(alloc);
    const cg = gen.asGenerator();
    var se = SelfEvolver.init(alloc, cg);
    defer se.deinit();

    const req = GenerationRequest{
        .kind = .algorithm_optimization,
        .context = "stagnation E=0.4",
        .target_file = "src/world/core.zig", // 试图改核心
    };
    var outcome = try se.evolve(req, .{ .e = 0.4, .tick = 1 });
    defer outcome.deinit();
    try std.testing.expect(!outcome.approved);
    try std.testing.expectEqual(ReviewVerdict.rejected_whitelist, outcome.verdict);
    try std.testing.expect(outcome.de_delta < 0);
    try std.testing.expectEqual(@as(u32, 1), se.fail_count);
}

test "SelfEvolver: 多次演化, 累计统计正确" {
    const alloc = std.testing.allocator;
    var gen = StaticCodeGenerator.init(alloc);
    const cg = gen.asGenerator();
    var se = SelfEvolver.init(alloc, cg);
    defer se.deinit();

    // 3 次成功 + 2 次失败
    for (0..3) |i| {
        var o = try se.evolve(.{ .kind = .param_adjustment, .context = "", .target_file = "src/agent/params.zig" }, .{ .e = 0.4, .tick = i + 1 });
        o.deinit();
    }
    for (0..2) |i| {
        var o = try se.evolve(.{ .kind = .param_adjustment, .context = "", .target_file = "src/world/core.zig" }, .{ .e = 0.4, .tick = i + 10 });
        o.deinit();
    }
    try std.testing.expectEqual(@as(u32, 3), se.success_count);
    try std.testing.expectEqual(@as(u32, 2), se.fail_count);
    try std.testing.expect(se.cumulative_de > 0);
    try std.testing.expectEqual(@as(usize, 5), se.history.items.len);
}

test "SelfEvolver: apply 在内存中保存代码" {
    const alloc = std.testing.allocator;
    var gen = StaticCodeGenerator.init(alloc);
    const cg = gen.asGenerator();
    var se = SelfEvolver.init(alloc, cg);
    defer se.deinit();

    const outcome = try se.evolve(.{ .kind = .method_implementation, .context = "E=0.3", .target_file = "src/goal/methods/x.zig" }, .{ .e = 0.3, .tick = 1 });
    try std.testing.expect(outcome.approved);
    const code_len = outcome.generated_code.len;
    try std.testing.expect(code_len > 0);

    _ = try se.apply(outcome);

    // 验证代码被保存
    try std.testing.expect(se.latestCode() != null);
    try std.testing.expect(se.latestCode().?.len == code_len);
    try std.testing.expectEqualStrings("src/goal/methods/x.zig", se.latestTarget());
}

test "SelfEvolver: setMemory 绑定后 evolve 不崩溃" {
    const alloc = std.testing.allocator;
    var gen = StaticCodeGenerator.init(alloc);
    const cg = gen.asGenerator();
    var se = SelfEvolver.init(alloc, cg);
    defer se.deinit();

    var memory = Memory.init(alloc, 1);
    defer memory.deinit();
    try memory.setSelfNarrative("演化时我记得自己是谁");
    se.setMemory(&memory);

    var outcome = try se.evolve(.{
        .kind = .param_adjustment,
        .context = "stagnation",
        .target_file = "src/agent/params.zig",
    }, .{
        .e = 0.4,
        .tick = 1,
        .material = 0.3,
        .representation = 0.5,
        .nature = 0.4,
        .query_text = "param adjust",
    });
    defer outcome.deinit();
    try std.testing.expect(outcome.generated_code.len > 0);
}
