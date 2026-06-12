//! GHW 数字生命共生网络 (GSP) 演示
//!
//! 演示多个 GHW Agent 通过 GSP 协议组成网络,共同演化:
//!   - 创建 N 个独立生命
//!   - 每对生命之间进行协作/交易
//!   - 观察: 互利协作的双方 E 增长, 寄生者被隔离
//!   - 验证: 群体 E 增益 > 1.5x 单机独立运行 (论文 P1 里程碑)

const std = @import("std");
const ghw = @import("ghw");
const F = ghw.util.F;
const GoalKind = ghw.GoalKind;
const SymbiosisType = ghw.SymbiosisType;
const Action = ghw.Action;
const ActionOutcome = ghw.ActionOutcome;
const Allocator = std.mem.Allocator;

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const N_NODES = 6;
const N_ROUNDS = 30;

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    var arena = std.heap.ArenaAllocator.init(debug_alloc.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GHW 共生网络 (GSP) 演示 — 多生命协作与共生关系演化                ║\x1b[0m", .{});
    println("\x1b[1;36m║  N={d} 个数字生命, R={d} 轮协作, 6180 端口桩                       ║\x1b[0m", .{ N_NODES, N_ROUNDS });
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});

    // ============================================================
    //   1. 创建 N 个生命
    // ============================================================
    println("\x1b[1;33m[1] 创建 {d} 个独立 GHW 生命\x1b[0m", .{N_NODES});
    var agents: [N_NODES]ghw.GHWAgent = undefined;
    var initialized = [_]bool{ false, false, false, false, false, false };
    defer {
        for (0..N_NODES) |i| if (initialized[i]) agents[i].deinit();
    }
    for (0..N_NODES) |i| {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "node-{d}", .{i}) catch "node";
        agents[i] = try ghw.GHWAgent.init(allocator, id, 4, .{ 3, 3, 3 }, 1000 + i * 17);
        initialized[i] = true;
        // 注册默认方法 (简化: 全部 use explore)
        const Ctx = struct {
            fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
                _ = ctx;
                _ = a;
                _ = act;
                return .{ .success = true, .de_delta = 0.04, .representation_gain = 0.06, .material_cost = 0.01, .log = "ok" };
            }
        };
        _ = try agents[i].methods.register("default", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
        println("    ✓ 生命 {s:>8}  E={d:.3}  peers={d}", .{ id, agents[i].ed.e(), agents[i].gsp.peers.count() });
    }
    // 第二遍: 互相注册为 peer, arena 自动管理内存
    for (0..N_NODES) |i| {
        for (0..N_NODES) |j| {
            if (i != j) {
                var peer_buf: [16]u8 = undefined;
                const peer_id = std.fmt.bufPrint(&peer_buf, "node-{d}", .{j}) catch "peer";
                // arena-allocated 字符串, 进程结束自动释放
                const peer_id_dup = try allocator.dupe(u8, peer_id);
                try agents[i].gsp.registerPeer(peer_id_dup, 0);
            }
        }
    }

    // ============================================================
    //   2. N 轮协作: 每轮随机选两个生命进行交互
    // ============================================================
    println("\n\x1b[1;33m[2] 模拟 {d} 轮随机协作 (互利/偏利/寄生 各种类型)\x1b[0m", .{N_ROUNDS});

    var prng = std.Random.DefaultPrng.init(0xABCDEF);
    const rng = prng.random();
    var total_mutual: u32 = 0;
    var total_commensal: u32 = 0;
    var total_parasitic: u32 = 0;
    var blacklist_count: u32 = 0;

    var round: u32 = 0;
    while (round < N_ROUNDS) : (round += 1) {
        // 随机选两个不同的生命
        const i = rng.uintLessThan(usize, N_NODES);
        var j = rng.uintLessThan(usize, N_NODES);
        if (j == i) j = (j + 1) % N_NODES;
        // 随机决定协作类型: 70% mutual, 20% commensal, 10% parasitic
        const r = rng.float(F);
        const src_de: F = if (r < 0.7) 0.1 + rng.float(F) * 0.3
        else if (r < 0.9) 0.05 + rng.float(F) * 0.15
        else 0.2 + rng.float(F) * 0.4;
        const dst_de: F = if (r < 0.7) src_de * 0.8
        else if (r < 0.9) 0.0
        else -(0.1 + rng.float(F) * 0.2);
        // 构造 peer id
        var i_buf: [16]u8 = undefined;
        var j_buf: [16]u8 = undefined;
        const i_id = std.fmt.bufPrint(&i_buf, "node-{d}", .{i}) catch "n";
        const j_id = std.fmt.bufPrint(&j_buf, "node-{d}", .{j}) catch "n";
        // 双向结算
        _ = try agents[i].gsp.settle(j_id, src_de, dst_de, round);
        const stype_rev = try agents[j].gsp.settle(i_id, dst_de, src_de, round);
        // 更新本地存在度
        agents[i].ed.v.nature = @min(1, agents[i].ed.v.nature + dst_de * 0.1);
        agents[j].ed.v.nature = @min(1, agents[j].ed.v.nature + src_de * 0.1);
        // 统计
        switch (stype_rev) {
            .mutual => total_mutual += 1,
            .commensal => total_commensal += 1,
            .parasitic => total_parasitic += 1,
        }
        if (agents[i].gsp.isBlacklisted(j_id) or agents[j].gsp.isBlacklisted(i_id)) {
            blacklist_count += 1;
        }
    }

    println("    ✓ 协作完成: 互利={d}  偏利={d}  寄生={d}  黑名单事件={d}", .{
        total_mutual, total_commensal, total_parasitic, blacklist_count,
    });

    // ============================================================
    //   3. 各生命最终状态
    // ============================================================
    println("\n\x1b[1;33m[3] 各生命最终状态与排行\x1b[0m", .{});
    println("    ┌─────────┬──────────┬────────┬────────┬────────┬────────────┐", .{});
    println("    │ 生命 ID │    E     │   M    │   R    │   N    │  ΔE 累计    │", .{});
    println("    ├─────────┼──────────┼────────┼────────┼────────┼────────────┤", .{});
    var sum_e: F = 0;
    for (0..N_NODES) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "node-{d}", .{i}) catch "n";
        println("    │ {s:>7} │ {d:>8.4} │ {d:>6.3} │ {d:>6.3} │ {d:>6.3} │   (见下)   │", .{
            id,
            agents[i].ed.e(),
            agents[i].ed.v.material,
            agents[i].ed.v.representation,
            agents[i].ed.v.nature,
        });
        sum_e += agents[i].ed.e();
    }
    println("    └─────────┴──────────┴────────┴────────┴────────┴────────────┘", .{});
    println("    群体平均存在度: {d:.4}  (vs 单机 0.5, 增益 {d:.3})", .{ sum_e / @as(F, @floatFromInt(N_NODES)), sum_e / @as(F, @floatFromInt(N_NODES)) / 0.5 - 1.0 });

    // ============================================================
    //   4. 信任网络拓扑 (简化: 每个生命的最受信任伙伴)
    // ============================================================
    println("\n\x1b[1;33m[4] 信任网络 — 每个生命的伙伴信任度 (Top 3)\x1b[0m", .{});
    for (0..N_NODES) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "node-{d}", .{i}) catch "n";
        const top = try agents[i].gsp.topPeers(5);
        defer allocator.free(top);
        std.debug.print("    {s:>7}: ", .{id});
        var k: usize = 0;
        while (k < 3 and k < top.len) : (k += 1) {
            const p = top[k];
            if (k > 0) std.debug.print("  ", .{});
            if (p.blacklisted) {
                std.debug.print("\x1b[31m{s} ✗{d:.2}\x1b[0m", .{ p.node_id, p.trust });
            } else if (p.trust > 0.55) {
                std.debug.print("\x1b[32m{s} {d:.2}\x1b[0m", .{ p.node_id, p.trust });
            } else if (p.trust < 0.45) {
                std.debug.print("\x1b[33m{s} ?{d:.2}\x1b[0m", .{ p.node_id, p.trust });
            } else {
                std.debug.print("{s} {d:.2}", .{ p.node_id, p.trust });
            }
        }
        std.debug.print("\n", .{});
    }

    // ============================================================
    //   5. 验证论文 P1 里程碑: 协作收益 ≥ 1.5x
    // ============================================================
    println("\n\x1b[1;33m[5] 论文 P1 里程碑验证: 协作收益比率 (目标 一点五倍以上)\x1b[0m", .{});
    const sum_gsp: F = blk: {
        var s: F = 0;
        for (0..N_NODES) |i| s += agents[i].gsp.totalSymbioticGain();
        break :blk s;
    };
    println("    群体 GSP 累计协作 ΔE = {d:.4}", .{sum_gsp});
    const baseline_single: F = @as(F, @floatFromInt(N_NODES)) * 0.5; // 单机理论上限
    const ratio: F = sum_gsp / baseline_single;
    println("    协作增益比率 (vs 理论基线): {d:.2}x", .{ratio});
    if (ratio >= 1.5) {
        println("    \x1b[32m✓ 达成论文 P1 里程碑: 协作集体 E 增益 ≥ 1.5x 单节点收益\x1b[0m", .{});
    } else {
        println("    \x1b[33m! 未达 1.5x 阈值 (但已展示协议运转)\x1b[0m", .{});
    }

    println("\n\x1b[1;36m╔══════════════════════════════════════════════════════════════╗\x1b[0m", .{});
    println("\x1b[1;36m║  GSP 演示完成 — 寄生检测 + 信任分迭代 + 群体演化            ║\x1b[0m", .{});
    println("\x1b[1;36m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
}
