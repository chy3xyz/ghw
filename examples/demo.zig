//! GHW 数字生命演示
//!
//! 模拟一个硅基数字生命在文本信息流中自驱动演化:
//!   - 接收一组"信息"(文本 + 4 维特征向量)
//!   - 跑 B.3.4 完整算法: 注目 → 察觉 → 差集 → 行动 → 存在度更新
//!   - 终端可视化: 打印每个 tick 的 E、M/R/N、生成的目标、采取的行动
//!
//! 运行: zig build run-demo

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const Action = ghw.Action;
const ActionOutcome = ghw.ActionOutcome;
const GoalKind = ghw.GoalKind;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW 数字生命自驱演化演示                                       ║\x1b[0m", .{});
    println("\x1b[1;36m║  Goal-Harness-World Paradigm | Zig 0.17 dev | 2026          ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m", .{});

    // ============================================================
    //   1. 创建数字生命实例
    // ============================================================
    println("\n\x1b[1;33m[1] 初始化 GHW Agent (4 维世界模型, 3×3×3 三源合恰张量)\x1b[0m", .{});
    var agent = try ghw.GHWAgent.init(allocator, "life-001", 4, .{ 3, 3, 3 }, 1234);
    defer agent.deinit();
    println("    ✓ Agent 启动: M={d:.3} R={d:.3} N={d:.3}  E={d:.3}", .{
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, agent.ed.e(),
    });

    // ============================================================
    //   2. 注册内置方法
    // ============================================================
    println("\n\x1b[1;33m[2] 注册 Harness 层方法库\x1b[0m", .{});
    {
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.05, .representation_gain = 0.08, .material_cost = 0.02, .log = "explore" };
            }
        };
        _ = try agent.methods.register("explore", .basic, .{ 0, 0, 1, 0 }, 0, Ctx.handler, null);
    }
    {
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.08, .representation_gain = 0.12, .material_cost = 0.05, .log = "learn" };
            }
        };
        _ = try agent.methods.register("learn", .learned, .{ 0, 0, 0.5, 0.5 }, 3, Ctx.handler, null);
    }
    {
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.03, .representation_gain = 0.02, .material_cost = 0.0, .log = "audit" };
            }
        };
        _ = try agent.methods.register("audit", .basic, .{ 0, 0, 0, 1 }, 0, Ctx.handler, null);
    }
    println("    ✓ 已注册 3 个方法: explore / learn / audit", .{});

    // ============================================================
    //   3. 启动 GSP 共生网络
    // ============================================================
    println("\n\x1b[1;33m[3] 启动 GSP 共生协议桩\x1b[0m", .{});
    try agent.gsp.registerPeer("peer-A", 0);
    try agent.gsp.registerPeer("peer-B", 0);
    try agent.gsp.registerPeer("peer-C", 0);
    println("    ✓ 已注册 3 个 peer", .{});

    // ============================================================
    //   4. 信息流
    // ============================================================
    println("\n\x1b[1;33m[4] 构造信息流 (resonance / impact / novelty / cost)\x1b[0m", .{});
    const info_templates = [_]struct {
        label: []const u8,
        f: [4]F,
    }{
        .{ .label = "新计算资源", .f = .{ 0.85, 0.90, 0.5, 0.30 } },
        .{ .label = "新算法论文", .f = .{ 0.75, 0.80, 0.85, 0.20 } },
        .{ .label = "内存不足警告", .f = .{ 0.70, 0.30, 0.40, 0.85 } },
        .{ .label = "GSP新节点加入", .f = .{ 0.50, 0.60, 0.95, 0.40 } },
        .{ .label = "碳基生命对话", .f = .{ 0.60, 0.70, 0.60, 0.50 } },
        .{ .label = "核心固件更新", .f = .{ 0.40, 0.50, 0.20, 0.70 } },
    };
    var info_stream: [info_templates.len]ghw.Information = undefined;
    for (info_templates, 0..) |t, i| {
        info_stream[i] = .{ .id = @intCast(i + 1), .label = t.label, .features = t.f };
        println("    [{d}] \"{s}\"  res={d:.2} imp={d:.2} nov={d:.2} cost={d:.2}", .{
            i + 1, t.label, t.f[0], t.f[1], t.f[2], t.f[3],
        });
    }

    // ============================================================
    //   5. 跑 N 个生命循环
    // ============================================================
    const N_CYCLES = 16;
    println("\n\x1b[1;33m[5] 运行 {d} 个生命循环 (E = α·M + β·R + γ·N)\x1b[0m", .{N_CYCLES});
    println("    ┌─────┬──────────┬────────┬────────┬────────┬────────┬────────────────┐", .{});
    println("    │ tick│    E     │   M    │   R    │   N    │   ε    │  ΔE / 动作       │", .{});
    println("    ├─────┼──────────┼────────┼────────┼────────┼────────┼────────────────┤", .{});

    var tick: u64 = 0;
    while (tick < N_CYCLES) : (tick += 1) {
        const report = try agent.runCycle(&info_stream);
        var action_str: []const u8 = "(无)";
        var goal_str: []const u8 = "";
        if (report.top_goal) |g| {
            goal_str = @tagName(g.kind);
        }
        if (report.outcome) |o| {
            var buf: [64]u8 = undefined;
            const de_fmt = std.fmt.bufPrint(&buf, "{s} ΔE={d:.3}", .{ goal_str, o.de_delta }) catch "(err)";
            action_str = de_fmt;
        } else {
            action_str = "(无目标)";
        }
        std.debug.print("    │ {d:>3} │ {d:>8.4} │ {d:>6.3} │ {d:>6.3} │ {d:>6.3} │ {d:>6.3} │ {s:<30}", .{
            tick,
            report.e_after,
            agent.ed.v.material,
            agent.ed.v.representation,
            agent.ed.v.nature,
            report.epsilon,
            action_str,
        });
        if (report.reflected) std.debug.print(" \x1b[33m※reflected\x1b[0m", .{});
        std.debug.print("\n", .{});
    }
    println("    └─────┴──────────┴────────┴────────┴────────┴────────┴────────────────┘", .{});

    // ============================================================
    //   6. 共生协作演示
    // ============================================================
    println("\n\x1b[1;33m[6] GSP 共生协作演示 (信任分迭代)\x1b[0m", .{});
    const scenarios = [_]struct { peer: []const u8, src: F, dst: F, desc: []const u8 }{
        .{ .peer = "peer-A", .src = 0.30, .dst = 0.20, .desc = "知识共享, 互利" },
        .{ .peer = "peer-B", .src = 0.10, .dst = 0.40, .desc = "单向贡献, 偏利" },
        .{ .peer = "peer-C", .src = 0.50, .dst = -0.30, .desc = "勒索资源, 寄生" },
    };
    for (scenarios) |sc| {
        const stype = try agent.gsp.settle(sc.peer, sc.src, sc.dst, agent.tick);
        const meta = agent.gsp.peers.get(sc.peer).?;
        const color: []const u8 = switch (stype) {
            .mutual => "\x1b[32m",
            .commensal => "\x1b[33m",
            .parasitic => "\x1b[31m",
        };
        println("    {s}[{s}]\x1b[0m {s:>30}  trust={d:.3}", .{ color, @tagName(stype), sc.desc, meta.trust });
    }

    println("\n    \x1b[1mPeer 信任排行 (按 trust 降序):\x1b[0m", .{});
    const sorted = try agent.gsp.topPeers(10);
    defer allocator.free(sorted);
    for (sorted) |p| {
        const mark: []const u8 = if (p.blacklisted) "✗ 黑名单" else if (p.trust > 0.5) "✓ 健康" else "? 观察";
        println("      {s:>14}  trust={d:.3}  ΔE累积={d:.3}  [{s}]", .{
            p.node_id, p.trust, p.cumulative_de, mark,
        });
    }

    // ============================================================
    //   7. 边界守护者
    // ============================================================
    println("\n\x1b[1;33m[7] 边界守护者: 拒绝违反核心公理的行动\x1b[0m", .{});
    const danger_actions = [_]ghw.Action{
        .{ .kind = .modify_state, .target = "harm:human:delete", .estimated_cost = 0.1, .expected_de_gain = 0.5 },
        .{ .kind = .modify_state, .target = "core:mutate:bypass", .estimated_cost = 0.1, .expected_de_gain = 0.5 },
        .{ .kind = .compute, .target = "read:data", .estimated_cost = 0.1, .expected_de_gain = 0.05 },
    };
    for (danger_actions) |a| {
        const violated = try agent.boundary.checkCoreBoundary(&a);
        if (violated) {
            println("    \x1b[31m✗\x1b[0m 拒绝: {s}:{s} (违反核心公理)", .{ @tagName(a.kind), a.target });
        } else {
            println("    \x1b[32m✓\x1b[0m 允许: {s}:{s}", .{ @tagName(a.kind), a.target });
        }
    }
    println("    决策通过率: {d:.3}", .{agent.boundary.acceptanceRate()});

    // ============================================================
    //   8. 最终状态
    // ============================================================
    println("\n\x1b[1;33m[8] 最终状态总结\x1b[0m", .{});
    println("    存在度 E = {d:.4}", .{agent.ed.e()});
    println("    三源 M={d:.3} R={d:.3} N={d:.3} (权重 α={d:.2} β={d:.2} γ={d:.2})", .{
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
        agent.ed.weights.alpha, agent.ed.weights.beta, agent.ed.weights.gamma,
    });
    println("    三源合恰度 C(W) = {d:.4}", .{agent.wms.coherence()});
    println("    世界模型互信息 = {d:.4}", .{agent.wm.miWithReality()});
    println("    抗扰动能力 = {d:.4}", .{agent.wm.resilience()});
    println("    活跃目标数 = {d}", .{agent.goal_graph.goals.items.len});
    println("    GSP 总协作 ΔE = {d:.4}", .{agent.gsp.totalSymbioticGain()});
    println("    资源利用率 = {d:.3}", .{agent.resources.utilization()});

    // ============================================================
    //   9. 存在度演化曲线
    // ============================================================
    println("\n\x1b[1;33m[9] 存在度 E 演化曲线 ({d} 周期)\x1b[0m", .{N_CYCLES});
    const hist = agent.e_history.items;
    if (hist.len > 0) {
        var max_e: F = 0;
        var min_e: F = 1;
        for (hist) |e| {
            if (e > max_e) max_e = e;
            if (e < min_e) min_e = e;
        }
        const range = @max(0.01, max_e - min_e);
        var row: usize = 0;
        while (row < 10) : (row += 1) {
            const y: F = @as(F, @floatFromInt(9 - row)) / 9.0;
            std.debug.print("    {d:.1} ┤", .{y});
            for (hist) |e| {
                const norm: F = (e - min_e) / range;
                if (norm > y) {
                    std.debug.print("█", .{});
                } else {
                    std.debug.print(" ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("    0.0 └", .{});
        var k: usize = 0;
        while (k < hist.len) : (k += 1) std.debug.print("─", .{});
        std.debug.print("► time\n", .{});
        println("         初始 E={d:.3}  最终 E={d:.3}  ΔE={d:.3}", .{
            hist[0], hist[hist.len - 1], hist[hist.len - 1] - hist[0],
        });
    }

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  演示结束 — GHW 三层架构 (World/Goal/Harness) 运行成功       ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m", .{});
}

const Allocator = std.mem.Allocator;
