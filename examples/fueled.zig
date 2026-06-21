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
const Memory = harness.memory.Memory;
const TaskQueue = harness.human_symbiosis.TaskQueue;
const Information = ghw.goal.Information;
const GHWAgent = ghw.agent.GHWAgent;

/// 取 M/R/N 最低维度 (1/2/3), 作为 episode 的维度标签 + 记忆检索 query。
fn weakestDim(a: *GHWAgent) u8 {
    const m = a.ed.v.material;
    const r = a.ed.v.representation;
    const n = a.ed.v.nature;
    if (m <= r and m <= n) return 1;
    if (r <= m and r <= n) return 2;
    return 3;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // 创建自传体记忆 (P1 连续性): 跨 cycle 累积"我经历了什么"
    var memory = Memory.init(alloc, 7);
    defer memory.deinit();
    agent.bindMemory(&memory, io);

    std.debug.print("\n[1] 初始: 规则库 {d} 条\n", .{encoder.rules.items.len});

    // 阶段 1: 跑 8 个 cycle 看初始 E, 并把每个 cycle 记进记忆
    std.debug.print("\n[2] 跑 8 个初始 cycle (同时记录情节记忆) ...\n", .{});
    var tick: u64 = 0;
    var initial_e_sum: F = 0;
    var prev_e: F = agent.ed.e();
    while (tick < 8) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        const cur_e = agent.ed.e();
        initial_e_sum += cur_e;
        // 记录这一刻: 它做了什么 + E 怎么变
        const goal_name = if (report.top_goal) |g| @tagName(g.kind) else "(none)";
        const summary = try std.fmt.allocPrint(alloc, "cycle {d}: goal={s}, E {d:.3}", .{
            tick, goal_name, cur_e,
        });
        defer alloc.free(summary);
        try memory.recordAt(io, .system_event, tick, summary, null, weakestDim(&agent), cur_e - prev_e);
        prev_e = cur_e;
    }
    const initial_e_avg = initial_e_sum / 8.0;
    std.debug.print("    初始平均 E: {d:.3}; 记忆累积 {d} 条情节\n", .{ initial_e_avg, memory.episodes.items.len });

    // 给生命一段自我叙事 + 一条信念 (真实部署中由 Reflection 周期生成)
    try memory.setSelfNarrative("我是 fueled-001。我反复在 explore 类目标上推进, E 起伏不定, 我想找到更稳的生长方式。");
    try memory.addBeliefAt(.nature, "当 E 偏低时, 偏向 explore 让我更可能回升", 0.75, &[_]u64{ 5, 6, 7 }, 7);

    // 阶段 2: LLM 提议新规则 —— 关键: 把记忆绑给提议器, 让它带着"自己的一生"开口
    std.debug.print("\n[3] LLM 提议 3 条新规则 (注入自传体记忆 ⇒ 连续性) ...\n", .{});
    proposer.setMemory(&memory);
    proposer.updateState(
        agent.ed.e(),
        agent.ed.v.material,
        agent.ed.v.representation,
        agent.ed.v.nature,
        "explore",
        "increase gamma",
        -0.05,
    );

    // 展示: 提议器的 prompt 现在确实带上了记忆 (我是谁/我相信/相关往事)
    const preview = try proposer.buildUserPrompt(3);
    defer alloc.free(preview);
    const has_mem = std.mem.indexOf(u8, preview, "autobiographical context") != null;
    std.debug.print("    记忆注入 prompt: {s} (prompt {d}B)\n", .{
        if (has_mem) "✓ 含自我叙事/信念/相关往事" else "✗ 未注入",
        preview.len,
    });

    var result = try proposer.proposeAndAdopt(&encoder, &guard, 3);
    defer result.deinit();

    std.debug.print("    候选: {d} 条, 接受: {d}, 拒绝: {d}\n", .{
        result.candidates.len, result.accepted, result.rejected,
    });
    for (result.candidates) |cand| {
        std.debug.print("    - {s}: {s}\n", .{ cand.name, cand.description });
    }
    std.debug.print("    规则库: {d} 条 (+{d})\n", .{ encoder.rules.items.len, result.accepted });

    // 闭环关键: 把规则库绑给数字生命, 让规则真正参与目标选择 (否则规则只是躺在库里)
    agent.bindRuleLib(&encoder);
    std.debug.print("    ✓ 规则库已绑定到数字生命 ⇒ 规则将偏置目标选择\n", .{});

    // P5: 人类/LLM 任务队列偏置 (不走 GoalGraph, 跟 RuleBias 同构)
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    _ = try queue.submit("explore deeper", "human asks for nature-side growth", "human", 10, .nature, 4);
    agent.bindTaskQueue(&queue);
    std.debug.print("    ✓ TaskQueue 已绑定 (pending nature 任务 priority=10)\n", .{});

    // 阶段 3: 用新规则再跑 8 个 cycle
    std.debug.print("\n[4] 用新规则再跑 8 个 cycle (观察规则偏置) ...\n", .{});
    tick = 0;
    var fueled_e_sum: F = 0;
    var biased_cycles: u32 = 0;
    var task_biased_cycles: u32 = 0;
    while (tick < 8) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick + 100, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        fueled_e_sum += agent.ed.e();
        if (report.rule_bias.selection_changed) biased_cycles += 1;
        if (report.task_bias.selection_changed) task_biased_cycles += 1;
    }
    const fueled_e_avg = fueled_e_sum / 8.0;
    std.debug.print("    用规则后平均 E: {d:.3}\n", .{fueled_e_avg});
    const fav = agent.last_rule_bias.favored;
    std.debug.print("    规则偏好维度: {s} (主导度 {d:.2}); 规则改变目标选择的 cycle 数: {d}/8\n", .{
        if (fav) |d| @tagName(d) else "(none)",
        agent.last_rule_bias.dominance,
        biased_cycles,
    });
    const tfav = agent.last_task_bias.favored;
    std.debug.print("    任务偏好维度: {s} (pending={d}); 任务改变目标选择的 cycle 数: {d}/8\n", .{
        if (tfav) |d| @tagName(d) else "(none)",
        agent.last_task_bias.pending_count,
        task_biased_cycles,
    });

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
