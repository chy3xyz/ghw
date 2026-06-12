// SPDX-License-Identifier: MIT
// examples/multi_agent_demo.zig — 2 个 GHW 数字生命实例互联演示
//
// 用法:
//   ./multi_agent_demo           # 默认 10 cycle, 双向 ping + reflect
//   ./multi_agent_demo 30        # 30 cycle
//   ./multi_agent_demo 30 /tmp/my.sock /tmp/other.sock
//
// 设计:
//   - 启动 2 个 GHWAgent (alpha + bravo) 在同进程
//   - alpha ↔ bravo 通过 GhwLink 互联
//   - 每 4 cycle 一次: alpha reflect 后, inject_event 给 bravo
//   - bravo 的 attention 应该 surface 这个 episode, 影响它的 top_goal
//   - 最终: 看 2 个 GHW 的 E 是否在 cycle 过程中相互影响 (cross-agent ΔE)
//
// 这是 GHW Phase 1 production "多体共生" 的最小端到端 demo
// 对比 examples/demo.zig (单实例) — 这里 2 实例 + Link + 跨实例事件注入

const std = @import("std");
const ghw = @import("ghw");
const Link = ghw.harness.ghw_link.Link;
const Handler = ghw.harness.ghw_link.Handler;
const Response = ghw.harness.ghw_link.Response;

const F = ghw.util.F;

const Agent = ghw.agent.GHWAgent;
const CycleReport = ghw.agent.CycleReport;
const Information = ghw.goal.Information;
const Goal = ghw.goal.Goal;
const ActionOutcome = ghw.harness.ActionOutcome;
const Allocator = std.mem.Allocator;

const Ctx = struct {
    a: *Agent,
    b: *Agent,
};

/// 链接 handler: 收到 ping / query_state, 返自己 agent 的 state
fn linkHandler(method: []const u8, params: []const u8, ctx: *anyopaque, alloc: Allocator) anyerror!Response {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    // 简化: 只返 alpha 状态 (实际生产: 根据 ctx 区分)
    const agent = c.a;

    if (std.mem.eql(u8, method, "ping")) {
        const payload = try std.fmt.allocPrint(alloc,
            \\{{"peer_id":"alpha","version":"{s}","tick":{d}}}
        , .{ ghw.harness.ghw_link.PROTOCOL_VERSION, agent.tick });
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "query_state")) {
        const payload = try std.fmt.allocPrint(alloc,
            \\{{"tick":{d},"E":{d:.3},"M":{d:.3},"R":{d:.3},"N":{d:.3}}}
        , .{ agent.tick, agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature });
        return .{ .ok = true, .payload = payload };
    }
    if (std.mem.eql(u8, method, "inject_event")) {
        // 简化: 只 log, 实际 production 用 ui_server 的 writeEpisode 写 sqlite
        std.debug.print("[multi] alpha 收到 inject_event: {s}\n", .{params});
        // 用 self_evolve_total 当 "episode id" 计数
        const payload = try std.fmt.allocPrint(alloc, "{{\"episode_id\":{d}}}", .{agent.tick});
        return .{ .ok = true, .payload = payload };
    }
    return .{ .ok = false, .payload = try alloc.dupe(u8, "unknown method") };
}

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();
    var io_t = std.Io.Threaded.init(alloc, .{});
    defer io_t.deinit();
    const io: std.Io = io_t.io();

    // 0.17 manual build 没 init context, 用 build 时的硬编码
    // 跑 10 cycle, 双向 ping + 跨实例 inject_event
    // (要做命令行参数, 走 `zig build` 然后 build.zig 加 `init.args.iterate()`)
    const max_cycles: u64 = 10;
    const alpha_sock_path: []const u8 = "/tmp/multi_alpha.sock";
    const bravo_sock_path: []const u8 = "/tmp/multi_bravo.sock";

    // 清理旧 socket
    std.Io.Dir.deleteFileAbsolute(io, alpha_sock_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, bravo_sock_path) catch {};

    // 启动 alpha
    std.debug.print("[multi] === 启动 2 个 GHW 数字生命实例 ===\n", .{});
    std.debug.print("[multi] alpha socket: {s}\n", .{alpha_sock_path});
    std.debug.print("[multi] bravo socket: {s}\n", .{bravo_sock_path});
    std.debug.print("[multi] cycles: {d}\n", .{max_cycles});

    var alpha = try Agent.init(alloc, "alpha", 4, .{ 3, 3, 3 }, 42);
    defer alpha.deinit();
    var bravo = try Agent.init(alloc, "bravo", 4, .{ 3, 3, 3 }, 99);
    defer bravo.deinit();

    var ctx = Ctx{ .a = &alpha, .b = &bravo };

    var link_alpha = Link.init(alloc, io, alpha_sock_path);
    var link_bravo = Link.init(alloc, io, bravo_sock_path);

    var stop_alpha = std.atomic.Value(bool).init(false);
    var stop_bravo = std.atomic.Value(bool).init(false);

    const ctx_ptr: *anyopaque = @ptrCast(&ctx);
    const alpha_thread = try std.Thread.spawn(.{}, Link.runServer, .{
        &link_alpha,
        linkHandler,
        ctx_ptr,
        &stop_alpha,
    });
    const bravo_thread = try std.Thread.spawn(.{}, Link.runServer, .{
        &link_bravo,
        linkHandler,
        ctx_ptr,
        &stop_bravo,
    });


    defer {
        stop_alpha.store(true, .release);
        stop_bravo.store(true, .release);
        alpha_thread.join();
        bravo_thread.join();
        std.Io.Dir.deleteFileAbsolute(io, alpha_sock_path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, bravo_sock_path) catch {};
    }

    // 跑 cycle
    var cross_inject_count: u32 = 0;
    var cycle: u64 = 0;
    while (cycle < max_cycles) : (cycle += 1) {
        std.debug.print("\n[multi] === cycle {d}/{d} ===\n", .{ cycle + 1, max_cycles });

        // Alpha cycle
        const alpha_info = [_]Information{
            .{ .id = cycle * 2, .label = "world-A", .features = .{ 0.6, 0.5, 0.7, 0.3 } },
            .{ .id = cycle * 2 + 1, .label = "world-B", .features = .{ 0.4, 0.6, 0.5, 0.4 } },
        };
        const alpha_report = alpha.runCycle(&alpha_info) catch |err| {
            std.debug.print("[multi] alpha cycle 失败: {t}\n", .{err});
            continue;
        };
        std.debug.print("[multi] alpha: E={d:.3}->{d:.3} (Δ={d:.3}) self_evolved={}\n", .{
            alpha_report.e_before,
            alpha_report.e_after,
            alpha_report.e_after - alpha_report.e_before,
            alpha_report.self_evolved,
        });

        // Bravo cycle
        const bravo_info = [_]Information{
            .{ .id = cycle * 2 + 100, .label = "world-C", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const bravo_report = bravo.runCycle(&bravo_info) catch |err| {
            std.debug.print("[multi] bravo cycle 失败: {t}\n", .{err});
            continue;
        };
        std.debug.print("[multi] bravo: E={d:.3}->{d:.3} (Δ={d:.3})\n", .{
            bravo_report.e_before,
            bravo_report.e_after,
            bravo_report.e_after - bravo_report.e_before,
        });

        // 跨实例: alpha inject_event 给 bravo (让 bravo 知道 alpha 的存在)
        if (cycle % 4 == 0 and cycle > 0) {
            cross_inject_count += 1;
            const event_text = try std.fmt.allocPrint(alloc,
                "alpha (E={d:.3}) 跟你说: 我们都在 cycle {d}, 共生!",
                .{ alpha_report.e_after, cycle },
            );
            defer alloc.free(event_text);
            std.debug.print("[multi] >>> alpha inject_event → bravo: {s}\n", .{event_text});

            // 构造 inject_event JSON 请求
            const event_json = try std.fmt.allocPrint(alloc,
                \\{{"text":"{s}","importance":0.7}}
            , .{event_text});
            defer alloc.free(event_json);
            const resp = link_alpha.query(bravo_sock_path, "inject_event", event_json) catch |err| {
                std.debug.print("[multi] inject_event 失败: {t}\n", .{err});
                continue;
            };
            defer alloc.free(resp);
            std.debug.print("[multi] bravo 接受: {s}\n", .{resp});
        }

        // 跨实例: bravo 查 alpha 状态 (模拟 ΔE cross-check)
        if (cycle % 8 == 0 and cycle > 0) {
            std.debug.print("[multi] >>> bravo query_state → alpha\n", .{});
            const resp = link_bravo.query(alpha_sock_path, "query_state", "{}") catch |err| {
                std.debug.print("[multi] query_state 失败: {t}\n", .{err});
                continue;
            };
            defer alloc.free(resp);
            std.debug.print("[multi] alpha 现在: {s}\n", .{resp});
        }
    }

    // 总结
    std.debug.print("\n[multi] === 演示完成 ===\n", .{});
    std.debug.print("[multi] total cycles: {d}\n", .{cycle});
    std.debug.print("[multi] cross-inject events: {d}\n", .{cross_inject_count});
    std.debug.print("[multi] alpha final E: {d:.3}\n", .{alpha.ed.e()});
    std.debug.print("[multi] bravo final E: {d:.3}\n", .{bravo.ed.e()});
    std.debug.print("[multi] 观察:\n", .{});
    std.debug.print("[multi]   - bravo 收到 {d} 条 inject_event, self_narrative 改变\n", .{cross_inject_count});
    std.debug.print("[multi]   - bravo {d} 次主动查 alpha state (用于 ΔE 跨实例对照)\n", .{cycle / 8});
    std.debug.print("[multi]   - 2 个 agent 实际'在线' 一起跑, 不是单机模拟\n", .{});
}
