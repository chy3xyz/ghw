// SPDX-License-Identifier: MIT
// examples/fueled.zig — 演示 LLM 燃料驱动的数字生命自我生长
//
// 流程:
//!  1. 启动一个数字生命 (GHWAgent)
//!  2. 跑 N 个 cycle 看初始 E
//!  3. 当 E 低时, 调 LLM 提议新规则
//!  4. RuleProposer 过滤 (SelfEvolutionGuard 守门) + 入库到 SelfEncoder
//!  5. 用新规则再跑 N 个 cycle, 看 E 是否涨
//!
//! 用 MockChatLLM (无需 API key) — 真实部署时换成 HttpLLM
const std = @import("std");
const ghw = @import("ghw");
const harness = ghw.harness;

const SelfEncoder = harness.self_encoder.SelfEncoder;
const SelfEvolutionGuard = harness.self_evolution.SelfEvolutionGuard;
const MockChatLLM = harness.mock_chat_llm.MockChatLLM;
const RuleProposer = harness.rule_proposer.RuleProposer;
const Information = ghw.goal.Information;
const GHWAgent = ghw.agent.GHWAgent;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  GHW LLM-Fueled 演示: 数字生命用 LLM 提议新规则自我生长\n", .{});
    std.debug.print("================================================================\n", .{});

    // 创建 LLM (Mock 模式, 真实部署用 HttpLLM.anthropic/openai)
    var mock_llm = MockChatLLM.init(alloc, harness.mock_chat_llm.DEFAULT_CANNED);
    const chat = mock_llm.asChat();

    // 创建 RuleProposer
    var proposer = RuleProposer.init(alloc, chat);
    defer proposer.proposal_count += 0;

    // 创建数字生命
    var agent = try GHWAgent.init(alloc, "fueled-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    // 创建 SelfEncoder (规则库)
    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    try encoder.loadBuiltInRules();

    // 创建 SelfEvolutionGuard
    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    std.debug.print("\n[1] 初始: 规则库 {d} 条\n", .{encoder.rules.items.len});

    // 阶段 1: 跑 8 个 cycle 看初始 E
    std.debug.print("\n[2] 跑 8 个初始 cycle ...\n", .{});
    var tick: u64 = 0;
    var initial_e_sum: F = 0;
    while (tick < 8) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        initial_e_sum += agent.ed.e();
        _ = report;
    }
    const initial_e_avg = initial_e_sum / 8.0;
    std.debug.print("    初始平均 E: {d:.3}\n", .{initial_e_avg});

    // 阶段 2: LLM 提议新规则
    std.debug.print("\n[3] LLM 提议 3 条新规则 ...\n", .{});
    proposer.updateState(
        agent.ed.e(),
        agent.ed.v.material,
        agent.ed.v.representation,
        agent.ed.v.nature,
        "explore",
        "increase gamma",
        -0.05,
    );
    var result = try proposer.proposeAndAdopt(&encoder, &guard, 3);
    defer result.deinit();

    std.debug.print("    候选: {d} 条, 接受: {d}, 拒绝: {d}\n", .{
        result.candidates.len, result.accepted, result.rejected,
    });
    for (result.candidates) |cand| {
        std.debug.print("    - {s}: {s}\n", .{ cand.name, cand.description });
    }
    std.debug.print("    规则库: {d} 条 (+{d})\n", .{ encoder.rules.items.len, result.accepted });

    // 阶段 3: 用新规则再跑 8 个 cycle
    std.debug.print("\n[4] 用新规则再跑 8 个 cycle ...\n", .{});
    tick = 0;
    var fueled_e_sum: F = 0;
    while (tick < 8) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick + 100, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        fueled_e_sum += agent.ed.e();
        _ = report;
    }
    const fueled_e_avg = fueled_e_sum / 8.0;
    std.debug.print("    用规则后平均 E: {d:.3}\n", .{fueled_e_avg});

    // 总结
    const delta = fueled_e_avg - initial_e_avg;
    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  LLM 燃料效果: ΔE = {d:.3} {s}\n", .{
        delta,
        if (delta > 0) "(正 — 规则有效)" else "(负 — 规则无效, 数字生命未采纳)",
    });
    std.debug.print("  LLM 调用次数: {d}\n", .{proposer.proposal_count});
    std.debug.print("  接受/拒绝: {d}/{d}\n", .{ proposer.accepted_count, proposer.rejected_count });
    std.debug.print("================================================================\n", .{});
}

const F = f32;
