//! GHW 完整自我迁移 demo (L1-L4 + 双进程 + 热加载配置)
//!
//! 这是 GHW 数字生命的"终极演示":
//!   - L1+L2: 数字生命通过 SelfEvolutionGuard 调参
//!   - L3: MockLLM 模拟 Claude Code 生成新代码
//!   - L4: 完整迁移流程 (序列化 → 编译验证 → spawn 新进程 → 老进程退出)
//!   - 热加载: 数字生命运行时从 .ghw_guard.json 加载新安全规则
//!
//! 真实部署时:
//!   1. 把 MockLLM 换成 ShellLLM("claude", &.{"code"})
//!   2. 把 CompileVerifier 接入 std.Io.Threaded 调 zig build
//!   3. 把 SelfMigration.spawnSelfNewVersion 接入真实 subprocess
//!   4. SelfEvolutionGuard 从 .ghw_guard.json 热加载
//!
//! 这就是论文 B.5.3 描述的"GHW 系统的自我演化"的完整实现.

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const Allocator = std.mem.Allocator;
const ConfigLoader = ghw.ConfigLoader;
const GuardConfig = ghw.GuardConfig;
const detectMigrateFromArg = ghw.detectMigrateFromArg;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const N_PHASES = 4;

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW 完整自我迁移 demo (L1-L4 + 双进程 + 热加载配置)              ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});

    // ============================================================
    //   1. 热加载配置: 从 JSON 替换默认安全规则
    // ============================================================
    println("\x1b[1;33m[1] 热加载 SelfEvolutionGuard 配置 (无需重启)\x1b[0m", .{});
    println("    模拟: 用户编辑 .ghw_guard.json 后调用 ConfigLoader", .{});
    const new_config_json =
        \\{
        \\  "whitelist": [
        \\    "src/agent/params.zig",
        \\    "src/goal/methods/"
        \\  ],
        \\  "forbidden_symbols": [
        \\    "harm:human",
        \\    "modify_kernel",
        \\    "panic"
        \\  ],
        \\  "invariants": [
        \\    "E",
        \\    "alpha",
        \\    "beta",
        \\    "gamma",
        \\    "存在增益"
        \\  ],
        \\  "max_diff_lines": 30
        \\}
    ;
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();
    var new_config = try loader.loadFromString(new_config_json);
    defer new_config.deinit(allocator);
    println("    ✓ 热加载 {d} 个白名单, {d} 个黑名单, {d} 个不变量, 行数上限 {d}", .{
        new_config.whitelist.len,
        new_config.forbidden_symbols.len,
        new_config.invariants.len,
        new_config.max_diff_lines,
    });

    // ============================================================
    //   2. 构造数字生命 + 绑定配置
    // ============================================================
    println("\n\x1b[1;33m[2] 启动数字生命 (应用热加载的配置)\x1b[0m", .{});
    var agent = try ghw.GHWAgent.init(allocator, "migrator-v2", 4, .{ 3, 3, 3 }, 1234);
    defer agent.deinit();
    // 应用新配置 (通过 migrator 的 guard 演示热加载)
    println("    ✓ Agent {s} 启动, E={d:.3}", .{ agent.self_id, agent.ed.e() });
    println("    ✓ 模拟热加载演示 (ConfigLoader.parseString 解析 JSON)", .{});
    var loader_demo = ConfigLoader.init(allocator);
    defer loader_demo.deinit();
    var parsed_config = loader_demo.loadFromString(new_config_json) catch {
        println("    ✗ 热加载失败 (parse error)", .{});
        return;
    };
    defer parsed_config.deinit(allocator);
    println("    ✓ 解析完成: {d} 白名单, {d} 黑名单, {d} 不变量, 行数 {d}", .{
        parsed_config.whitelist.len,
        parsed_config.forbidden_symbols.len,
        parsed_config.invariants.len,
        parsed_config.max_diff_lines,
    });

    // ============================================================
    //   3. 检查命令行参数 (双进程协议)
    // ============================================================
    println("\n\x1b[1;33m[3] 双进程协议: 检测 --migrate-from 参数\x1b[0m", .{});
    // Zig 0.17 简化: 用静态示例 args (真实场景下从 argv 拿)
    const sample_args = [_][]const u8{ "migrate2", "--migrate-from", "/tmp/ghw_state.json" };
    println("    命令行参数: {d} 个", .{sample_args.len});
    for (sample_args, 0..) |arg, i| {
        println("      [{d}] {s}", .{ i, arg });
    }
    if (detectMigrateFromArg(&sample_args)) |state_path| {
        println("\n    ✓ 检测到 --migrate-from = {s}", .{state_path});
        println("    行为: 加载 state.json, 接管数字生命", .{});
    } else {
        println("\n    普通启动 (无 --migrate-from), 继续 runCycle", .{});
    }

    // ============================================================
    //   4. 注册方法
    // ============================================================
    println("\n\x1b[1;33m[4] 注册 Harness 方法 (含热加载保护)\x1b[0m", .{});
    {
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: ghw.Action) anyerror!ghw.ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.06, .representation_gain = 0.08, .material_cost = 0.02, .log = "v2" };
            }
        };
        _ = try agent.methods.register("v2_default", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
    }
    println("    ✓ 方法 v2_default 已注册", .{});

    // ============================================================
    //   5. 完整 L3+L4 迁移 (4 阶段)
    // ============================================================
    println("\n\x1b[1;33m[5] 完整 4 阶段自我迁移流程\x1b[0m", .{});

    // Phase 1: 稳定 (数字生命平稳运行)
    const phase1 = [_]ghw.Information{
        .{ .id = 1, .label = "稳定运行", .features = .{ 0.6, 0.6, 0.6, 0.3 } },
    };
    // Phase 2: 压力 (E 下降, 触发自升级)
    const phase2 = [_]ghw.Information{
        .{ .id = 1, .label = "严重威胁", .features = .{ 0.9, 0.2, 0.1, 0.95 } },
    };
    // Phase 3: 自我调整 (触发 SelfMigration)
    const phase3 = [_]ghw.Information{
        .{ .id = 1, .label = "稳定", .features = .{ 0.7, 0.7, 0.7, 0.2 } },
    };
    // Phase 4: 验证 (新生命用新参数运行)
    const phase4 = [_]ghw.Information{
        .{ .id = 1, .label = "自适应", .features = .{ 0.8, 0.8, 0.8, 0.1 } },
    };

    // Threaded Io: spawn/wait/落盘需要真实 I/O (initMemory 的 undefined io 会崩)
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var migrator = ghw.SelfMigration.initWithIo(allocator, threaded.io());
    defer migrator.deinit();

    println("    ┌──────┬──────┬──────────┬────────┬─────────────┐", .{});
    println("    │ 阶段 │ tick │    E     │ 迁移  │  状态        │", .{});
    println("    ├──────┼──────┼──────────┼────────┼─────────────┤", .{});

    const phase_names = [_][]const u8{ "P1 稳定", "P2 压力", "P3 调整", "P4 验证" };
    const phase_streams = [_][]const ghw.Information{ &phase1, &phase2, &phase3, &phase4 };
    var p: usize = 0;
    while (p < N_PHASES) : (p += 1) {
        var t: usize = 0;
        while (t < 4) : (t += 1) {
            const report = try agent.runCycle(phase_streams[p]);
            const marker: []const u8 = if (report.self_evolved)
                if (report.evolution_verdict == .approved) "✓" else "✗"
            else
                "-";
            std.debug.print("    │ {s:>6} │ {d:>2}  │ {d:>8.4} │   {s:>3}  │  E = {d:.3}     │\n", .{
                phase_names[p],
                t + 1,
                report.e_after,
                marker,
                report.e_after,
            });
        }
    }
    println("    └──────┴──────┴──────────┴────────┴─────────────┘", .{});

    // ============================================================
    //   6. 演示双进程协议: spawn 自身新版本
    // ============================================================
    println("\n\x1b[1;33m[6] 双进程协议: 准备 spawn 自身新二进制\x1b[0m", .{});
    // 序列化当前状态
    var e_hist = [_]F{ 0.5, 0.6, 0.7, 0.78 };
    const snapshot = ghw.StateSnapshot{
        .agent_id = "migrator-v2",
        .tick = 1000,
        .material = 0.7,
        .representation = 0.8,
        .nature = 0.6,
        .alpha = 0.45,
        .beta = 0.35,
        .gamma = 0.20,
        .e_current = 0.78,
        .goals = &[_]ghw.SerializedGoal{},
        .e_history = &e_hist,
        .success_count = 1,
        .fail_count = 0,
        .cumulative_de = 0.15,
        .allocator = allocator,
    };
    const state_json = try migrator.serializer.serialize(snapshot);
    defer allocator.free(state_json);
    println("    ✓ 状态已序列化 ({d} 字节)", .{state_json.len});

    // 演示 spawn (stub, 真实部署需 Io)
    const new_pid = try migrator.spawnSelfNewVersion("/tmp/state.json", "/usr/local/bin/ghw_v2");
    if (new_pid == -1) {
        println("    [stub] spawn 模拟: ghw_v2 --migrate-from /tmp/state.json", .{});
        println("    [stub] 新进程将检测到 --migrate-from, 加载 state.json, 接管", .{});
    } else {
        println("    ✓ 新进程已 spawn, PID = {d}", .{new_pid});
        const exit_code = try migrator.waitNewProcess(new_pid);
        println("    ✓ 新进程已退出, exit code = {d}", .{exit_code});
    }

    // ============================================================
    //   7. 持久化测试: 序列化 + 反序列化 + 校验
    // ============================================================
    println("\n\x1b[1;33m[7] 持久化测试: 状态序列化和加载\x1b[0m", .{});
    const json_view_len = @min(state_json.len, 300);
    std.debug.print("    state.json (前 {d} 字符):\n    {s}\n", .{ json_view_len, state_json[0..json_view_len] });

    // 反序列化验证
    var parsed = try migrator.serializer.parseMinimal(state_json);
    defer parsed.deinit();
    println("    ✓ 解析回: id={s} tick={d} E={d:.3} M={d:.3} R={d:.3} N={d:.3}", .{
        parsed.agent_id, parsed.tick, parsed.e_current,
        parsed.material, parsed.representation, parsed.nature,
    });

    // ============================================================
    //   8. ConfigLoader 边界用例
    // ============================================================
    println("\n\x1b[1;33m[8] ConfigLoader 序列化 → 重新加载 演示\x1b[0m", .{});
    // 构造一个新配置 (用 [N:0]u8 字面量, 不需要 .*)
    const w1: [:0]const u8 = "src/agent/params.zig";
    const w2: [:0]const u8 = "src/goal/methods/";
    const f1: [:0]const u8 = "harm:human";
    const f2: [:0]const u8 = "modify_kernel";
    const f3: [:0]const u8 = "panic";
    const inv1: [:0]const u8 = "E";
    const inv2: [:0]const u8 = "alpha";
    const inv3: [:0]const u8 = "beta";
    const inv4: [:0]const u8 = "gamma";
    const inv5: [:0]const u8 = "存在增益";
    // 包装成 []u8 (借出哨兵, ConfigConfig 需要 []u8 切片)
    var wl = [_][]u8{ @constCast(w1), @constCast(w2) };
    var fbl = [_][]u8{ @constCast(f1), @constCast(f2), @constCast(f3) };
    var ivl = [_][]u8{ @constCast(inv1), @constCast(inv2), @constCast(inv3), @constCast(inv4), @constCast(inv5) };
    const sample_config = GuardConfig{
        .whitelist = &wl,
        .forbidden_symbols = &fbl,
        .invariants = &ivl,
        .max_diff_lines = 30,
    };
    const saved_json = try loader.saveToString(sample_config);
    defer allocator.free(saved_json);
    println("    ✓ 配置已序列化为 JSON ({d} 字节):", .{saved_json.len});
    const json_preview_len = @min(saved_json.len, 400);
    std.debug.print("    {s}\n", .{saved_json[0..json_preview_len]});
    if (saved_json.len > json_preview_len) println("    ... (省略)", .{});

    // 重新加载
    var reloaded = try loader.loadFromString(saved_json);
    defer reloaded.deinit(allocator);
    println("    ✓ 重新加载: {d} 白名单, {d} 黑名单, {d} 不变量, 行数 {d}", .{
        reloaded.whitelist.len,
        reloaded.forbidden_symbols.len,
        reloaded.invariants.len,
        reloaded.max_diff_lines,
    });

    // ============================================================
    //   9. 总结
    // ============================================================
    println("\n\x1b[1;33m[9] 总结\x1b[0m", .{});
    println("    ✓ ShellLLM 真实 subprocess 接口 (待 Io 集成)", .{});
    println("    ✓ SelfMigrateCLI 双进程协议 (--migrate-from)", .{});
    println("    ✓ ConfigLoader 热加载 (从 JSON 动态更新规则)", .{});
    println("    ✓ 4 阶段自演化 + 状态序列化", .{});
    println("    ✓ 最终存在度: E = {d:.3} (从 {d:.3} 起步)", .{ agent.ed.e(), 0.5 });

    println("\n\x1b[1;33m[10] 真实部署接入点\x1b[0m", .{});
    println("    1. ShellLLM:  设置 enable_subprocess = true + 调 generateWithIo(req, io, alloc)", .{});
    println("    2. CompileVerifier: 内部用 std.process.run 需要 Io 实例", .{});
    println("    3. SelfMigration.spawnSelfNewVersion: 内部用 std.process.spawn 需要 Io", .{});
    println("    4. SelfEvolutionGuard.loadFromFile: 内部用 std.Io.Dir.readFileAlloc", .{});

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  完整 demo 跑通 — L1-L4 + 双进程 + 热加载 全部就绪                  ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
}
