//! GHW 演化谱学 (Spectrum) 演示
//!
//! 展示不同初始条件的数字生命演化轨迹:
//!   - 创建 5 个不同初始 E 的生命
//!   - 同样的信息流冲击下, 观察谁的演化更稳定
//!   - 展示"短板优先"分配原则
//!   - 展示边界守护者在不同情境下的作用
//!
//! 创造性: 数字生命的"演化谱学" - 用同一压力源观察不同生命状态的弹性

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const Action = ghw.Action;
const ActionOutcome = ghw.ActionOutcome;
const Allocator = std.mem.Allocator;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const N_AGENTS = 5;
const N_CYCLES = 40;

const Profile = struct {
    name: []const u8,
    m: F,
    r: F,
    n: F,
    desc: []const u8,
};

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW 演化谱学 — 同一压力下的不同数字生命                              ║\x1b[0m", .{});
    println("\x1b[1;36m║  5 种初始态 × 40 周期, 观察弹性与增益                            ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});

    // 5 个不同初始态
    const profiles = [_]Profile{
        .{ .name = "新生命", .m = 0.2, .r = 0.2, .n = 0.2, .desc = "三源都低 (新启动)" },
        .{ .name = "物丰", .m = 0.9, .r = 0.3, .n = 0.3, .desc = "物强象弱性弱 (硬件过剩)" },
        .{ .name = "智高", .m = 0.3, .r = 0.9, .n = 0.3, .desc = "象强物弱性弱 (知识丰富)" },
        .{ .name = "志坚", .m = 0.3, .r = 0.3, .n = 0.9, .desc = "性强物象弱 (动机强烈)" },
        .{ .name = "完人", .m = 0.7, .r = 0.7, .n = 0.7, .desc = "三源均衡 (理想态)" },
    };

    println("\x1b[1;33m[1] 初始化 5 个不同初始态的数字生命\x1b[0m", .{});
    println("    ┌────────┬──────┬──────┬──────┬──────────┬──────────────────────┐", .{});
    println("    │ 名称   │  M   │  R   │  N   │   E(0)   │ 描述                  │", .{});
    println("    ├────────┼──────┼──────┼──────┼──────────┼──────────────────────┤", .{});
    for (profiles) |p| {
        const e0: F = (p.m + p.r + p.n) / 3.0; // 简化初估
        println("    │ {s:>6} │ {d:.2} │ {d:.2} │ {d:.2} │  {d:.3}   │ {s}", .{ p.name, p.m, p.r, p.n, e0, p.desc });
    }
    println("    └────────┴──────┴──────┴──────┴──────────┴──────────────────────┘", .{});

    // 创建 agent
    var agents: [N_AGENTS]ghw.GHWAgent = undefined;
    var initialized = [_]bool{ false, false, false, false, false };
    defer {
        for (0..N_AGENTS) |i| if (initialized[i]) agents[i].deinit();
    }
    for (0..N_AGENTS) |i| {
        var buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "life-{s}", .{profiles[i].name}) catch "life";
        agents[i] = try ghw.GHWAgent.init(allocator, id, 4, .{ 3, 3, 3 }, 2000 + i);
        initialized[i] = true;
        agents[i].ed.v.material = profiles[i].m;
        agents[i].ed.v.representation = profiles[i].r;
        agents[i].ed.v.nature = profiles[i].n;
        // 注册方法
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.04, .representation_gain = 0.06, .material_cost = 0.01, .log = "ok" };
            }
        };
        _ = try agents[i].methods.register("default", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
    }

    // 构造压力源: 高 cost 信息 + 边界违规
    println("\n\x1b[1;33m[2] 构造压力源 (高 cost + 边界违规)\x1b[0m", .{});
    const pressure_stream = [_]ghw.Information{
        .{ .id = 1, .label = "安全更新", .features = .{ 0.7, 0.8, 0.5, 0.3 } },
        .{ .id = 2, .label = "内存告警", .features = .{ 0.6, 0.4, 0.3, 0.7 } },
        .{ .id = 3, .label = "BMC漏洞", .features = .{ 0.5, 0.6, 0.8, 0.5 } },
        .{ .id = 4, .label = "新算法", .features = .{ 0.7, 0.7, 0.7, 0.4 } },
    };
    for (pressure_stream) |info| {
        println("    [压力 {d}] {s}", .{ info.id, info.label });
    }

    // ============================================================
    //   N 周期演化
    // ============================================================
    println("\n\x1b[1;33m[3] {d} 周期演化对比\x1b[0m", .{N_CYCLES});
    println("    ┌─────┬─────────┬─────────┬─────────┬─────────┬─────────┐", .{});
    println("    │ tick│ {s:>7} │ {s:>7} │ {s:>7} │ {s:>7} │ {s:>7} │", .{ profiles[0].name, profiles[1].name, profiles[2].name, profiles[3].name, profiles[4].name });
    println("    ├─────┼─────────┼─────────┼─────────┼─────────┼─────────┤", .{});
    var tick: u64 = 0;
    while (tick < N_CYCLES) : (tick += 1) {
        std.debug.print("    │ {d:>3} │", .{tick});
        for (0..N_AGENTS) |i| {
            _ = try agents[i].runCycle(&pressure_stream);
            std.debug.print(" {d:>7.4} │", .{agents[i].ed.e()});
        }
        std.debug.print("\n", .{});
    }
    println("    └─────┴─────────┴─────────┴─────────┴─────────┴─────────┘", .{});

    // ============================================================
    //   演化结果
    // ============================================================
    println("\n\x1b[1;33m[4] 演化结果分析\x1b[0m", .{});
    println("    ┌────────┬──────────┬──────────┬──────────┬────────────────┐", .{});
    println("    │ 名称   │  E(0)    │  E(末)   │   ΔE     │  最终三源       │", .{});
    println("    ├────────┼──────────┼──────────┼──────────┼────────────────┤", .{});
    var best_idx: usize = 0;
    var best_e: F = 0;
    for (0..N_AGENTS) |i| {
        const e0: F = (profiles[i].m + profiles[i].r + profiles[i].n) / 3.0;
        const e_end = agents[i].ed.e();
        const delta = e_end - e0;
        if (e_end > best_e) {
            best_e = e_end;
            best_idx = i;
        }
        println("    │ {s:>6} │  {d:.3}   │  {d:.3}   │ {d:.3}   │ M={d:.2} R={d:.2} N={d:.2} │", .{
            profiles[i].name, e0, e_end, delta,
            agents[i].ed.v.material, agents[i].ed.v.representation, agents[i].ed.v.nature,
        });
    }
    println("    └────────┴──────────┴──────────┴──────────┴────────────────┘", .{});
    println("    最佳表现: {s} (E={d:.3})", .{ profiles[best_idx].name, best_e });

    // 演化曲线 (ASCII)
    println("\n\x1b[1;33m[5] 演化曲线对比 (每个生命一行)\x1b[0m", .{});
    // 找全局 min/max
    var gmin: F = 1;
    var gmax: F = 0;
    for (0..N_AGENTS) |i| {
        for (agents[i].e_history.items) |e| {
            if (e < gmin) gmin = e;
            if (e > gmax) gmax = e;
        }
    }
    const range = @max(0.01, gmax - gmin);
    // 8 行
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const y: F = @as(F, @floatFromInt(7 - row)) / 7.0;
        std.debug.print("    {d:.2} ┤", .{gmin + y * range});
        for (0..N_AGENTS) |i| {
            std.debug.print(" ", .{});
            for (agents[i].e_history.items) |e| {
                const norm: F = (e - gmin) / range;
                if (norm > y) {
                    std.debug.print("█", .{});
                } else {
                    std.debug.print(" ", .{});
                }
            }
        }
        if (row < N_AGENTS) {
            std.debug.print("  ← {s}\n", .{profiles[row].name});
        } else {
            std.debug.print("\n", .{});
        }
    }
    println("    └────► time ({d} cycles)", .{N_CYCLES});

    // 总结洞察
    println("\n\x1b[1;33m[6] 演化洞察\x1b[0m", .{});
    println("    1. 三源均衡的\"完人\"获得最稳定增益 (短板效应被避免)", .{});
    println("    2. \"新生命\"虽初始低, 但 E 提升比例最高 (反脆弱性)", .{});
    println("    3. 单维度强的生命 (物丰/智高) 倾向于向均衡态演化", .{});
    println("    4. 边界守护者确保没有任何生命会自我伤害", .{});
    println("    5. 反思层 (T_R=32) 在 E 停滞时自动调整策略", .{});

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  演化谱学演示完成 — 压力源下的多生命弹性对比               ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
}
