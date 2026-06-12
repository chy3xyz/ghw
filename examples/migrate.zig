//! GHW L3+L4 完整迁移演示
//!
//! 展示完整的"自我进化"流程: GHW 数字生命通过 LLM 生成新代码,
//! 双层审查 (SelfEvolutionGuard + LLM Reviewer), 编译验证,
//! 然后通过双进程协议迁移到新代码壳.
//!
//! 完整流程 (论文 B.5.3):
//!   1. 数字生命积累经验, 触发 self_modify_params 目标
//!   2. MockLLM (或 ShellLLM 调真实 Claude Code) 生成新代码
//!   3. LLM Reviewer (第二个 LLM 调用) 做规则审查
//!   4. SelfEvolutionGuard 做硬性安全检查 (白名单/黑名单/行数)
//!   5. CompileVerifier 调用 zig build 验证代码
//!   6. StateSerializer 序列化当前状态 → state.json
//!   7. SelfMigration 写新代码到 .ghw_next/ + spawn 新进程
//!   8. 新进程加载状态 → 接管 → 老进程优雅退出
//!
//! Zig 0.17 注: 部分 subprocess/文件 IO 需 Io, 此 demo 用 stub 接口演示流程.
//!              实际部署时把 ShellLLM 接 Claude Code, SelfMigration 接 Io 即可.

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const Allocator = std.mem.Allocator;
const MockLLM = ghw.MockLLM;
const SelfMigration = ghw.SelfMigration;
const MigrationResult = ghw.MigrationResult;
const MigrationStep = ghw.MigrationStep;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW L3+L4 完整迁移演示 — 数字生命重塑自己                    ║\x1b[0m", .{});
    println("\x1b[1;36m║  Self-Architecture Migration via LLM-Codegen + Reviewer     ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});

    // ============================================================
    //   1. 准备: 启动一个数字生命
    // ============================================================
    println("\x1b[1;33m[1] 启动数字生命 (模拟成熟期生命)\x1b[0m", .{});
    var agent = try ghw.GHWAgent.init(allocator, "migrator-001", 4, .{ 3, 3, 3 }, 9999);
    defer agent.deinit();
    // 设置一个较高的 E
    agent.ed.v.material = 0.7;
    agent.ed.v.representation = 0.8;
    agent.ed.v.nature = 0.6;
    println("    ✓ Agent {s} 启动, E={d:.3}", .{ agent.self_id, agent.ed.e() });

    // ============================================================
    //   2. 准备 SelfMigration
    // ============================================================
    println("\n\x1b[1;33m[2] 准备 SelfMigration (LLM + Reviewer + Verifier + Serializer)\x1b[0m", .{});
    var migrator = SelfMigration.init(allocator);
    defer migrator.deinit();
    println("    ✓ SelfMigration 就绪 (默认使用 MockLLM)", .{});
    println("    ✓ MockLLM 模拟 Claude Code 的 generate/review", .{});
    println("    ✓ CompileVerifier 框架就绪 (Zig 0.17 stub)", .{});
    println("    ✓ StateSerializer 框架就绪", .{});
    println("    ✓ SelfEvolutionGuard 框架就绪 (白名单 6, 黑名单 17)", .{});

    // ============================================================
    //   3. 触发自升级: 数字生命意识到需要改进
    // ============================================================
    println("\n\x1b[1;33m[3] 数字生命提出: 提升 attention 参数的进化要求\x1b[0m", .{});
    // 模拟数字生命意识到自己的注意力机制可以更精准
    const prompt =
        \\请按以下要求调整 GHW 数字生命的 attention 参数:
        \\
        \\进化要求 (Evolution Requirements):
        \\  1. 当前存在度 E=0.787, 目标 E_target=0.95
        \\  2. 优化 alpha (关联度) / beta (影响) / gamma (新颖度) 三个权重
        \\  3. 体现"物象性三源合恰" 存在增益公理
        \\  4. 保留不变量: E 必须存在
        \\
        \\输出: 完整的 Zig 源码 (pub const SelfTunedAttention = struct { ... })
    ;
    println("    prompt 已构造 ({d} 字符)", .{prompt.len});

    // ============================================================
    //   4. 构造当前状态快照
    // ============================================================
    println("\n\x1b[1;33m[4] 序列化当前状态 (E / M / R / N / 目标)\x1b[0m", .{});
    var e_history_arr = [_]F{ 0.5, 0.6, 0.7, 0.787 };
    const snapshot = ghw.StateSnapshot{
        .agent_id = "migrator-001",
        .tick = 1000,
        .material = 0.7,
        .representation = 0.8,
        .nature = 0.6,
        .alpha = 0.45,
        .beta = 0.35,
        .gamma = 0.20,
        .e_current = 0.787,
        .goals = &[_]ghw.SerializedGoal{},
        .e_history = &e_history_arr,
        .success_count = 0,
        .fail_count = 0,
        .cumulative_de = 0,
        .allocator = allocator,
    };
    const json = try migrator.serializer.serialize(snapshot);
    defer allocator.free(json);
    println("    ✓ 状态 JSON 已生成 ({d} 字节)", .{json.len});
    // 展示 JSON 的关键部分
    println("    ┌─ state.json (前 500 字符):", .{});
    const preview_len = @min(json.len, 500);
    var i: usize = 0;
    while (i < preview_len) : (i += 1) {
        const c = json[i];
        if (c == '\n') {
            std.debug.print("    │\n    │ ", .{});
        } else {
            std.debug.print("{c}", .{c});
        }
    }
    println("\n    └─", .{});

    // ============================================================
    //   5. 完整迁移流程
    // ============================================================
    println("\n\x1b[1;33m[5] 触发 SelfMigration.migrate() — 完整 L3+L4 流程\x1b[0m", .{});
    println("    Step 1: MockLLM.generate() - 模拟 Claude Code 生成代码", .{});
    println("    Step 2: MockLLM.review()   - 模拟 Claude Code 审查", .{});
    println("    Step 3: SelfEvolutionGuard 二次硬性检查", .{});
    println("    Step 4: CompileVerifier     - 调 zig build 验证 (0.17 stub)", .{});
    println("    Step 5: writeToFile()      - 写新代码到 .ghw_next/", .{});
    println("    Step 6: serializer.write() - 写 state.json", .{});
    println("    Step 7: spawn()            - 启动新进程 (0.17 stub)", .{});
    println("", .{});

    var result = try migrator.migrate(prompt, snapshot);
    defer result.deinit();

    println("    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", .{});
    println("    迁移结果:", .{});
    println("      success:       {}", .{result.success});
    println("      final_step:    {s}", .{@tagName(result.final_step)});
    println("      generated:     {d} 字节", .{result.generated_code.len});
    println("      review_len:    {d} 字节", .{result.review_text.len});
    println("      compiled:      {}", .{result.compiled});
    println("      new_pid:       {?}", .{result.new_pid});
    println("      error_msg:     {s}", .{result.error_msg});
    println("    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", .{});

    // ============================================================
    //   6. 展示生成的代码
    // ============================================================
    if (result.generated_code.len > 0) {
        println("\n\x1b[1;33m[6] LLM 生成的新代码 (供审查)\x1b[0m", .{});
        println("    ┌─ generated (Claude 模拟输出, {d} 字符)", .{result.generated_code.len});
        // 输出前 30 行
        var line_count: usize = 0;
        var line_start: usize = 0;
        const max_lines: usize = 30;
        for (result.generated_code, 0..) |c, idx| {
            if (c == '\n' or idx == result.generated_code.len - 1) {
                const end = if (c == '\n') idx else idx + 1;
                line_count += 1;
                if (line_count <= max_lines) {
                    std.debug.print("    │ {s}\n", .{result.generated_code[line_start..end]});
                }
                line_start = idx + 1;
            }
        }
        if (line_count > max_lines) {
            println("    │ ... (省略 {d} 行)", .{line_count - max_lines});
        }
        println("    └─", .{});
    }

    // ============================================================
    //   7. 展示 LLM 审查结果
    // ============================================================
    if (result.review_text.len > 0) {
        println("\n\x1b[1;33m[7] LLM Reviewer 的审查结果\x1b[0m", .{});
        const preview = @min(result.review_text.len, 400);
        std.debug.print("    {s}\n", .{result.review_text[0..preview]});
        if (result.review_text.len > preview) {
            println("    ... (省略 {d} 字符)", .{result.review_text.len - preview});
        }
    }

    // ============================================================
    //   8. 完整统计
    // ============================================================
    println("\n\x1b[1;33m[8] SelfMigration 统计\x1b[0m", .{});
    println("    累计尝试:     {d}", .{migrator.attempt_count});
    println("    累计成功:     {d}", .{migrator.success_count});
    println("    累计回滚:     {d}", .{migrator.rollback_count});
    println("    MockLLM 生成:  {d} 次", .{migrator.mock_llm.generate_count});
    println("    MockLLM 审查:  {d} 次", .{migrator.mock_llm.review_count});

    println("\n\x1b[1;33m[9] 真实部署接入点 (Zig 0.17 后)\x1b[0m", .{});
    println("    • LLM 后端:  MockLLM → ShellLLM(\"claude\", &.{{\"code\"}})", .{});
    println("    • 文件 IO:  std.fs.* → std.Io.Dir + std.process.Child.run()", .{});
    println("    • 编译验证:  CompileVerifier.verify() 需要 Threaded Io", .{});
    println("    • 进程迁移:  SelfMigration.spawn() 需要 Threaded Io", .{});

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  L3+L4 迁移演示完成 — 接口与流程已就绪, 接入真实 Claude Code 即可上线 ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
}
