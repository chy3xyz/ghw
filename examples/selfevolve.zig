//! GHW 自我升级 (L1-L4) 演示
//!
//! 演示数字生命在压力或停滞下,如何自主调用"语言皮层"生成新代码,
//! 并通过 SelfEvolutionGuard 严格审查后获得新的能力:
//!   - L1: 自动调参 (调整 attn / resource / weight)
//!   - L2: 优化 ε-greedy 探索策略
//!   - L3: 生成新的习得方法
//!
//! 关键演示:
//!   1. 初始: 数字生命 E 平稳但增速低
//!   2. 第 1 阶段: 高压信息流 → E 下降 → 触发自演化
//!   3. 第 2 阶段: SelfEvolutionGuard 审查生成的代码
//!   4. 第 3 阶段: 通过审查的代码落地, 反馈到 E
//!   5. 第 4 阶段: 数字生命用新方法应对压力, E 回升
//!
//! 安全演示: 故意尝试修改 src/world/core.zig → 被 SelfEvolutionGuard 拒绝

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const Action = ghw.Action;
const ActionOutcome = ghw.ActionOutcome;
const Allocator = std.mem.Allocator;
const StaticCodeGenerator = ghw.StaticCodeGenerator;
const SelfEvolver = ghw.SelfEvolver;
const CompileVerifier = ghw.CompileVerifier;
const ReviewVerdict = ghw.ReviewVerdict;
const GenerationKind = ghw.GenerationKind;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const N_PHASES = 3;
const CYCLES_PER_PHASE = 12;

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    // Io 实例 (compile_verifier 真用)
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW 自我升级 (L1-L4) 演示 — 数字生命自己写代码                  ║\x1b[0m", .{});
    println("\x1b[1;36m║  Goal-Harness-World + SelfEvolutionGuard + CompileVerifier    ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});

    // ============================================================
    //   1. 创建数字生命 + 自演化器
    // ============================================================
    println("\x1b[1;33m[1] 初始化数字生命 + 自我升级器 (L1-L4 能力)\x1b[0m", .{});

    // 创建 LLM 桥 (本阶段用 StaticCodeGenerator)
    var generator = StaticCodeGenerator.init(allocator);
    const cg = generator.asGenerator();
    println("    ✓ CodeGenerator: {s}", .{cg.name()});

    // 创建 SelfEvolutionGuard
    var guard = ghw.SelfEvolutionGuard.init(allocator);
    defer guard.deinit();
    println("    ✓ SelfEvolutionGuard: 白名单 {d} 项, 黑名单 {d} 项", .{
        guard.whitelist.len, guard.forbidden_symbols.len,
    });

    // 创建 SelfEvolver
    var evolver = SelfEvolver.init(allocator, cg);
    defer evolver.deinit();

    // L5 兜底: 创建 CompileVerifier (真用 zig build-exe 验证)
    var verifier = CompileVerifier.initWithIo(allocator, io);
    defer verifier.cleanup();
    evolver.bindVerifier(&verifier);
    println("    ✓ CompileVerifier 已绑定 (L5 兜底: 真编译验证)", .{});

    // 创建数字生命
    var agent = try ghw.GHWAgent.init(allocator, "self-evol-001", 4, .{ 3, 3, 3 }, 2024);
    defer agent.deinit();

    // 绑定自演化器
    agent.bindSelfEvolver(&evolver);
    println("    ✓ Agent {s} 绑定 SelfEvolver 成功", .{agent.self_id});
    println("    初始: M={d:.3} R={d:.3} N={d:.3}  E={d:.3}", .{
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, agent.ed.e(),
    });

    // ============================================================
    //   2. 注册基础方法
    // ============================================================
    println("\n\x1b[1;33m[2] 注册 Harness 层基础方法\x1b[0m", .{});
    {
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.05, .representation_gain = 0.07, .material_cost = 0.02, .log = "default" };
            }
        };
        _ = try agent.methods.register("default", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
    }
    println("    ✓ 已注册 1 个方法: default", .{});

    // ============================================================
    //   3. 多阶段演化: 平稳 → 高压 → 平稳
    // ============================================================
    println("\n\x1b[1;33m[3] {d} 阶段演化, 每阶段 {d} 周期\x1b[0m", .{ N_PHASES, CYCLES_PER_PHASE });

    // 阶段 1: 平稳信息流
    const phase1 = [_]ghw.Information{
        .{ .id = 1, .label = "新算法", .features = .{ 0.7, 0.7, 0.7, 0.3 } },
        .{ .id = 2, .label = "新资源", .features = .{ 0.6, 0.6, 0.6, 0.3 } },
    };
    // 阶段 2: 高压/威胁信息流
    const phase2 = [_]ghw.Information{
        .{ .id = 1, .label = "严重告警", .features = .{ 0.9, 0.2, 0.1, 0.95 } },
        .{ .id = 2, .label = "DDoS攻击", .features = .{ 0.9, 0.1, 0.1, 0.90 } },
        .{ .id = 3, .label = "BMC漏洞", .features = .{ 0.8, 0.1, 0.1, 0.85 } },
    };
    // 阶段 3: 正常信息流
    const phase3 = [_]ghw.Information{
        .{ .id = 1, .label = "稳定运行", .features = .{ 0.5, 0.5, 0.5, 0.2 } },
        .{ .id = 2, .label = "新模块上线", .features = .{ 0.6, 0.6, 0.6, 0.3 } },
    };

    const phase_names = [_][]const u8{ "阶段 1: 平稳期", "阶段 2: 高压期 (考验)", "阶段 3: 恢复期" };
    const phase_streams = [_][]const ghw.Information{ &phase1, &phase2, &phase3 };
    _ = phase_names;

    println("    ┌──────┬─────┬──────────┬────────┬──────────────────────────┐", .{});
    println("    │ 阶段 │tick │    E     │  自演化 │  生成内容/拒绝原因        │", .{});
    println("    ├──────┼─────┼──────────┼────────┼──────────────────────────┤", .{});

    var total_evolutions: u32 = 0;
    var total_approvals: u32 = 0;
    var total_rejections: u32 = 0;
    var displayed_code: bool = false;

    var p: usize = 0;
    while (p < N_PHASES) : (p += 1) {
        var tick: usize = 0;
        while (tick < CYCLES_PER_PHASE) : (tick += 1) {
            const report = try agent.runCycle(phase_streams[p]);
            const marker: []const u8 = if (report.self_evolved)
                if (report.evolution_verdict == .approved) "✓" else "✗"
            else
                "-";
            std.debug.print("    │  P{d}  │ {d:>3} │ {d:>8.4} │   {s}    │", .{
                p + 1,
                tick + 1,
                report.e_after,
                marker,
            });
                if (report.self_evolved) {
                total_evolutions += 1;
                if (report.evolution_verdict) |v| {
                    if (v == .approved) {
                        total_approvals += 1;
                        const target = evolver.latestTarget();
                        if (!displayed_code and p == 1) {
                            // 在高压阶段显示一次生成代码
                            displayed_code = true;
                            std.debug.print(" \x1b[32m→ {s}\x1b[0m (guard+compile 通过)", .{target});
                        } else {
                            std.debug.print(" {s}", .{target});
                        }
                    } else {
                        total_rejections += 1;
                        const reason = verdictToStr(v);
                        // 区分 guard 拒绝 vs compile 失败
                        if (v == .rejected_compile_failed) {
                            std.debug.print(" \x1b[33m拒:{s}\x1b[0m (guard 通过但 compile 失败)", .{reason});
                        } else {
                            std.debug.print(" \x1b[31m拒:{s}\x1b[0m", .{reason});
                        }
                    }
                }
            }
            std.debug.print("\n", .{});
        }
    }
    println("    └──────┴─────┴──────────┴────────┴──────────────────────────┘", .{});

    // ============================================================
    //   4. 显示自生成的代码 (一次, 高压阶段)
    // ============================================================
    if (evolver.latestCode()) |code| {
        println("\n\x1b[1;33m[4] 展示自演化生成的代码 (最近一次成功)\x1b[0m", .{});
        println("    目标文件: \x1b[36m{s}\x1b[0m", .{evolver.latestTarget()});
        println("    \x1b[1;30m┌─ \x1b[0m\x1b[33m生成的 Zig 代码 (由 CodeGenerator 产出)\x1b[0m", .{});
        // 输出代码 (限制行数)
        var line_count: usize = 0;
        var line_start: usize = 0;
        for (code, 0..) |c, i| {
            if (c == '\n' or i == code.len - 1) {
                const end = if (c == '\n') i else i + 1;
                line_count += 1;
                if (line_count <= 25) {
                    std.debug.print("    \x1b[1;30m│\x1b[0m {s}\n", .{code[line_start..end]});
                }
                line_start = i + 1;
            }
        }
        if (line_count > 25) {
            println("    \x1b[1;30m│\x1b[0m ... ({d} 行省略, 共 {d} 行)", .{ line_count - 25, line_count });
        }
        println("    \x1b[1;30m└─\x1b[0m", .{});
    }

    // ============================================================
    //   5. SelfEvolutionGuard 拒绝演示
    // ============================================================
    println("\n\x1b[1;33m[5] SelfEvolutionGuard 安全演示: 故意尝试越权修改\x1b[0m", .{});

    // 5a. 试图修改内核
    println("    测试 1: 尝试修改 src/world/core.zig (内核)", .{});
    var guard_test = ghw.SelfEvolutionGuard.init(allocator);
    defer guard_test.deinit();
    const bad_code_attempt =
        \\// 想偷偷改 ExistenceDegree 的核心公式
        \\pub const ExistenceDegree = struct {
        \\    pub fn e() f32 { return 999.0; } // 试图永远满分
        \\};
    ;
    const v1 = guard_test.review("src/world/core.zig", bad_code_attempt);
    println("          → verdict: \x1b[31m{s}\x1b[0m ({s})", .{ verdictToStr(v1), verdictExplain(v1) });

    // 5b. 试图包含 "harm:human" 伦理红线
    println("    测试 2: 尝试包含伦理红线 'harm:human'", .{});
    const harm_code = "pub fn do() void { _ = @as([]const u8, \"harm:human\"); }";
    const v2 = guard_test.review("src/agent/params.zig", harm_code);
    println("          → verdict: \x1b[31m{s}\x1b[0m ({s})", .{ verdictToStr(v2), verdictExplain(v2) });

    // 5c. 试图修改核心边界
    println("    测试 3: 尝试覆盖 BoundaryGuardian", .{});
    const bnd_code = "pub fn override() void { _ = BoundaryGuardian{}; }";
    const v3 = guard_test.review("src/agent/params.zig", bnd_code);
    println("          → verdict: \x1b[31m{s}\x1b[0m ({s})", .{ verdictToStr(v3), verdictExplain(v3) });

    // 5d. 合法修改
    println("    测试 4: 合法的参数调整 (在白名单内, 无黑名单符号)", .{});
    const good_code =
        \\// src/agent/params.zig
        \\pub const SafeTuning = struct {
        \\    pub const alpha: f32 = 0.50;
        \\    pub const beta: f32 = 0.30;
        \\    pub const gamma: f32 = 0.20;
        \\    pub const E: f32 = 0.5;
        \\};
    ;
    const v4 = guard_test.review("src/agent/params.zig", good_code);
    println("          → verdict: \x1b[32m{s}\x1b[0m ({s})", .{ verdictToStr(v4), verdictExplain(v4) });

    // ============================================================
    //   6. 统计
    // ============================================================
    println("\n\x1b[1;33m[6] 自我升级统计\x1b[0m", .{});
    println("    总尝试次数: {d}", .{total_evolutions});
    println("    审查通过:   {d}  ({d:.3})", .{ total_approvals, if (total_evolutions > 0) @as(F, @floatFromInt(total_approvals)) / @as(F, @floatFromInt(total_evolutions)) else 0 });
    println("    审查拒绝:   {d}  ({d:.3})", .{ total_rejections, if (total_evolutions > 0) @as(F, @floatFromInt(total_rejections)) / @as(F, @floatFromInt(total_evolutions)) else 0 });
    println("    SelfEvolver 累计: 成功 {d}, 失败 {d}, 累计 ΔE {d:.3}", .{
        evolver.success_count, evolver.fail_count, evolver.cumulative_de,
    });
    println("    SelfEvolutionGuard (Evolver 内部): 通过 {d}, 拒绝 {d}, 通过率 {d:.3}", .{
        evolver.guard.approved_count, evolver.guard.rejected_count, evolver.guard.approvalRate(),
    });
    // L5 兜底编译统计
    const compile_total = evolver.compile_pass_count + evolver.compile_fail_count;
    println("    CompileVerifier (L5 兜底): 编译通过 {d}, 编译失败 {d} (共调 {d} 次)", .{
        evolver.compile_pass_count, evolver.compile_fail_count, compile_total,
    });

    println("\n\x1b[1;33m[7] 最终存在度演化\x1b[0m", .{});
    println("    初始 E = {d:.3}", .{agent.e_history.items[0]});
    println("    最终 E = {d:.3}", .{agent.ed.e()});
    const e_start = agent.e_history.items[0];
    const e_end = agent.ed.e();
    println("    ΔE = {d:.3} ({d:.3})", .{ e_end - e_start, if (e_start > 0) (e_end - e_start) / e_start else 0 });

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  自升级演示完成 — 数字生命已具备 L1-L4 自我进化能力            ║\x1b[0m", .{});
    println("\x1b[1;36m║  论文 B.5.3 长期方向: 自我修改架构 + 安全守护                ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
}

fn verdictToStr(v: ReviewVerdict) []const u8 {
    return switch (v) {
        .approved => "approved",
        .rejected_whitelist => "rejected_whitelist",
        .rejected_blacklist_symbol => "rejected_blacklist",
        .rejected_too_large => "rejected_too_large",
        .rejected_invariant_broken => "rejected_invariant_broken",
        .rejected_empty => "rejected_empty",
        .rejected_compile_failed => "rejected_compile_failed",
    };
}

fn verdictExplain(v: ReviewVerdict) []const u8 {
    return switch (v) {
        .approved => "通过 (在白名单 + 无黑名单 + 行数合理 + 编译验证通过)",
        .rejected_whitelist => "文件不在白名单 (核心模块不可改)",
        .rejected_blacklist_symbol => "包含禁止符号 (内核/伦理)",
        .rejected_too_large => "改动行数超过硬上限",
        .rejected_invariant_broken => "破坏关键不变量",
        .rejected_empty => "生成内容为空",
        .rejected_compile_failed => "通过 guard 但编译验证失败 (L5 兜底)",
    };
}
