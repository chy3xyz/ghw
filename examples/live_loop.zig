// SPDX-License-Identifier: MIT
// examples/live_loop.zig — 端到端: 真接 DeepSeek + L4' 提规则 + L6 选最信任人类 + L7 翻译
//
// 流程:
//!  1. 创建 GHWAgent + DeepSeek HttpLLM + SelfEncoder + Guard
//!  2. 创建 HumanGSP, 注册 3 个人 (alice/bob/carol) 不同 trust
//!  3. 创建 TaskQueue + ValueMetric
//!  4. 跑 N 个 cycle:
//!     - 每 cycle 跌穿 E 阈值 → 调 DeepSeek 提规则 → Guard 守门 → 入库
//!     - 每 K cycle → 选最弱维度 + 选最信任人类 → 自动投 balance 任务
//!  5. 模拟人类反馈, 打印 weekly 报表
//!
//! 用法:
//!   DEEPSEEK_API_KEY=sk-... zig build run-live_loop
//!
//! 真实部署 (换 anthropic): --provider anthropic

const std = @import("std");
const ghw = @import("ghw");

const HttpLLM = ghw.harness.http_llm.HttpLLM;
const RuleProposer = ghw.harness.rule_proposer.RuleProposer;
const SelfEncoder = ghw.harness.self_encoder.SelfEncoder;
const SelfEvolutionGuard = ghw.harness.self_evolution.SelfEvolutionGuard;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const HumanSignal = ghw.harness.human_symbiosis.HumanSignal;
const ValueMetric = ghw.harness.human_symbiosis.ValueMetric;
const ValueTrendTracker = ghw.harness.human_symbiosis.ValueTrendTracker;
const HumanFeedback = ghw.harness.human_symbiosis.HumanFeedback;
const BalanceSeeker = ghw.harness.balance_seeker.BalanceSeeker;
const Translator = ghw.harness.translator.Translator;
const KpiBridge = ghw.harness.KpiBridge;
const RawKpi = ghw.harness.crm_kpi.RawKpi;
const ValueWeights = ghw.harness.product_intent.ValueWeights;
const Memory = ghw.harness.memory.Memory;
const GHWAgent = ghw.agent.GHWAgent;
const Information = ghw.goal.Information;
const F = ghw.util.F;

const Config = struct {
    provider: []const u8 = "openai",
    model: []const u8 = "deepseek-chat",
    base_url: []const u8 = "https://api.deepseek.com",
    api_key_env: []const u8 = "DEEPSEEK_API_KEY",
    cycles: u32 = 8,
    auto_balance_every: u32 = 4,
    rule_propose_threshold: F = 0.50,
    /// 演示用: 用一条缓慢爬升的**模拟** KPI 经 KpiBridge 限频驱动 E (非真实 CRM 数据)
    kpi_demo: bool = false,
};

fn parseArgs(alloc: Allocator, args: []const []const u8) !Config {
    _ = alloc;
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.provider = args[i];
            if (std.mem.eql(u8, args[i], "deepseek")) {
                cfg.model = "deepseek-chat";
                cfg.base_url = "https://api.deepseek.com";
                cfg.api_key_env = "DEEPSEEK_API_KEY";
            } else if (std.mem.eql(u8, args[i], "anthropic")) {
                cfg.model = "claude-sonnet-4-5";
                cfg.base_url = "https://api.anthropic.com";
                cfg.api_key_env = "ANTHROPIC_API_KEY";
            }
        } else if (std.mem.eql(u8, a, "--cycles")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.cycles = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.rule_propose_threshold = try std.fmt.parseFloat(F, args[i]);
        } else if (std.mem.eql(u8, a, "--kpi-demo")) {
            cfg.kpi_demo = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\live_loop — 真接 LLM 跑 GHW 数字生命 (L4' + L6 + L7)
                \\
                \\用法:
                \\  DEEPSEEK_API_KEY=sk-... zig build run-live_loop
                \\
                \\选项:
                \\  --provider deepseek | anthropic (默认 deepseek)
                \\  --cycles <N> (默认 8)
                \\  --threshold <E> (默认 0.50, 跌穿触发 LLM 提议)
                \\  --kpi-demo (用模拟 KPI 经 KpiBridge 限频驱动 E, 演示 ρ·K)
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("[live_loop] unknown arg: {s}\n", .{a});
            return error.UnknownArg;
        }
    }
    return cfg;
}

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 收集 args
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = init.args.iterate();
    while (it.next()) |arg| {
        try args_list.append(alloc, arg);
    }

    const cfg = parseArgs(alloc, args_list.items) catch |err| {
        std.debug.print("[live_loop] arg parse failed: {t}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  Live Loop: 真接 LLM + L4' + L6 + L7 端到端\n", .{});
    std.debug.print("================================================================\n", .{});

    // 拿 API key
    const key_opt = std.process.Environ.getPosix(init.environ, cfg.api_key_env);
    const key = key_opt orelse {
        std.debug.print("[live_loop] env {s} not set\n", .{cfg.api_key_env});
        std.process.exit(2);
    };
    std.debug.print("[live_loop] provider={s} model={s} base={s}\n", .{ cfg.provider, cfg.model, cfg.base_url });

    // 创建 LLM
    const http_llm = if (std.mem.eql(u8, cfg.provider, "anthropic"))
        HttpLLM.anthropic(alloc, io, cfg.model, key)
    else
        HttpLLM.openai(alloc, io, cfg.model, key, cfg.base_url);
    var llm = http_llm catch |err| {
        std.debug.print("[live_loop] HttpLLM init failed: {t}\n", .{err});
        std.process.exit(3);
    };
    defer llm.deinit();

    // ===== 1. 数字生命 =====
    var agent = try GHWAgent.init(alloc, "live-loop-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    // ===== 2. L4' 组件: SelfEncoder + Guard + RuleProposer =====
    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    try encoder.loadBuiltInRules();

    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    var proposer = RuleProposer.init(alloc, llm.asChat());
    defer _ = proposer.proposal_count;

    var memory = Memory.init(alloc, 42);
    defer memory.deinit();

    // ===== 3. L6 组件: TaskQueue + HumanGSP + Signal =====
    var queue = TaskQueue.init(alloc);
    defer queue.deinit();
    agent.bindTaskQueue(&queue);
    agent.bindRuleLib(&encoder);
    proposer.setMemory(&memory);
    _ = queue.submitWithSource("平衡三源", "优先补齐 nature 短板", "alice", 9, .nature, 4, .human) catch {};

    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");
    try gsp.register("bob");
    try gsp.register("carol");
    // 模拟历史交互
    try gsp.recordInteraction("alice", true, 4, .representation, 0);
    try gsp.recordInteraction("bob", true, 2, .material, 0);
    try gsp.recordInteraction("carol", true, 3, .nature, 0);

    var signal = HumanSignal.init(alloc);
    defer signal.deinit();

    var vm = ValueMetric{};
    var value_tracker = ValueTrendTracker{};
    var self_evolve_count: u32 = 0;
    var llm_propose_count: u32 = 0;
    var auto_balance_count: u32 = 0;
    var memory_record_count: u32 = 0;

    std.debug.print("\n[init] 数字生命 E={d:.3}, bindRuleLib+memory 已接线, GSP {d} humans\n", .{
        agent.ed.e(), gsp.peers.count(),
    });
    std.debug.print("[init] Trust 分布: alice={d:.2} bob={d:.2} carol={d:.2}\n", .{
        gsp.peers.get("alice").?.trust,
        gsp.peers.get("bob").?.trust,
        gsp.peers.get("carol").?.trust,
    });

    // ===== 4. 主循环 =====
    // KPI 演示桥 (模拟数据): 1h 限频, 模拟时钟每 cycle 走 30min ⇒ 约每 2 cycle 写一次 E
    var kpi_bridge: ?KpiBridge = if (cfg.kpi_demo) KpiBridge.init(
        ValueWeights{ .user_satisfaction = 0.25, .retention = 0.30, .revenue = 0.35, .safety = 0.10, ._raw_buf = &.{} },
        true,
        3600,
    ) else null;
    var sim_now_unix: i64 = 0;
    if (cfg.kpi_demo) std.debug.print("[loop] --kpi-demo 开启: 模拟 KPI 缓慢爬升, 经 KpiBridge 限频驱动 E (非真实 CRM)\n", .{});

    std.debug.print("\n[loop] 开始 {d} 个 cycle, E 阈值 {d:.2}\n", .{ cfg.cycles, cfg.rule_propose_threshold });
    var tick: u64 = 0;
    while (tick < cfg.cycles) : (tick += 1) {
        // 每个 cycle 都跑
        const info = [_]Information{
            .{ .id = tick, .label = "stream", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = agent.runCycle(&info) catch |err| {
            std.debug.print("[loop] cycle {d} 失败: {t}\n", .{ tick, err });
            continue;
        };
        if (report.self_evolved) self_evolve_count += 1;

        {
            const delta_e = report.e_after - report.e_before;
            const goal_name = if (report.top_goal) |g| @tagName(g.kind) else "none";
            const summary = std.fmt.allocPrint(alloc, "cycle {d}: goal={s} E={d:.3} dE={d:.3}", .{
                tick, goal_name, report.e_after, delta_e,
            }) catch null;
            if (summary) |s| {
                defer alloc.free(s);
                memory.recordAt(io, .system_event, tick, s, null, 1, delta_e) catch {};
                memory_record_count += 1;
            }
        }

        // KPI 演示: 喂入模拟 KPI (随 cycle 缓慢爬升), 桥按限频写入 E
        if (kpi_bridge) |*bridge| {
            sim_now_unix += 1800; // 模拟时钟每 cycle 走 30 分钟
            const denom: F = @floatFromInt(@max(cfg.cycles - 1, 1));
            const frac: F = @as(F, @floatFromInt(tick)) / denom; // 0 → 1
            bridge.feed(.{
                .nrr_quarterly = 0.90 + 0.28 * frac, // 0.90 → 1.18
                .deal_win_rate = 0.12 + 0.26 * frac, // 0.12 → 0.38
                .sales_cycle_days_p50 = 80.0 - 55.0 * frac, // 80 → 25
                .weekly_active_sales_pct = 0.45 + 0.47 * frac, // 0.45 → 0.92
            });
            const e_before = agent.ed.e();
            if (bridge.maybeRefresh(&agent.ed, sim_now_unix)) {
                std.debug.print("[tick {d}] KPI(模拟) 写入 E: K={d:.3} E {d:.3}→{d:.3} (刷新#{d})\n", .{
                    tick, bridge.currentComposite().?, e_before, agent.ed.e(), bridge.refresh_count,
                });
            }
        }

        // L4': E 跌穿阈值 / KPI 下滑 / 人类价值下滑 → 调 LLM 提规则
        proposer.updateState(agent.ed.e(), agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature, "explore", "llm-propose", -0.05);
        proposer.setKpiTrend(agent.ed.kpiTrend());
        vm.pullFromSignal(&signal);
        vm.pullFromQueue(&queue);
        vm.pullFromGSP(&gsp);
        value_tracker.record(vm.valueScore());
        proposer.setValueTrend(value_tracker.trend());
        if (proposer.shouldPropose(cfg.rule_propose_threshold)) {
            var prop_result = proposer.proposeAndAdopt(&encoder, &guard, 3) catch |err| {
                std.debug.print("[loop] proposeAndAdopt 失败: {t}\n", .{err});
                continue;
            };
            defer prop_result.deinit();
            std.debug.print("[tick {d}] LLM 提规则: 接受={d}, 拒绝={d} (调用 #{d})\n", .{
                tick, prop_result.accepted, prop_result.rejected, proposer.proposal_count,
            });
            llm_propose_count += 1;
            const prop_summary = std.fmt.allocPrint(alloc, "propose: accepted={d} rejected={d}", .{
                prop_result.accepted, prop_result.rejected,
            }) catch null;
            if (prop_summary) |ps| {
                defer alloc.free(ps);
                memory.recordAt(io, .llm_proposal, tick, ps, null, 1, 0) catch {};
                memory_record_count += 1;
            }
        }

        // L6: 每 K cycle 自动生成 balance 任务, 用 GSP 选最信任的
        if (tick > 0 and tick % cfg.auto_balance_every == 0) {
            const weak = BalanceSeeker.computeWeakestDim(agent.ed);
            if (gsp.selectMostTrusted(weak)) |trusted| {
                var balance_task = try BalanceSeeker.proposeBalanceTask(agent.ed, weak, trusted, alloc);
                defer balance_task.deinit();
                const task_id = try queue.submitWithSource(
                    balance_task.title,
                    balance_task.description,
                    trusted, // ← L6 关键: 选最信任的人
                    balance_task.priority,
                    balance_task.required_dimension,
                    balance_task.cycles_allocated,
                    .balance,
                );
                std.debug.print("[tick {d}] L6 自动投 balance task #{d} (dim={s}, 给 {s} trust={d:.2})\n", .{
                    tick, task_id, @tagName(weak), trusted, gsp.peers.get(trusted).?.trust,
                });

                // 立即跑这个任务
                if (queue.dequeue()) |t| {
                    const result = agent.runTask(t) catch continue;
                    defer alloc.free(result.output);
                    try queue.complete(t.id, result.output, result.actual_delta_e, result.cycles_used);
                    std.debug.print("  → task 完成: ΔE_internal={d:.3}\n", .{result.actual_delta_e});

                    // 模拟人类反馈 (random)
                    const score: i8 = switch (tick % 5) {
                        0, 1, 2 => 3, // 好评
                        3 => -1, // 中评
                        else => 5, // 超棒
                    };
                    const fb = HumanFeedback{
                        .from_human = trusted,
                        .task_id = t.id,
                        .score = score,
                    };
                    const de = fb.toDeltaE();
                    try signal.receive(fb);
                    try queue.attachFeedback(t.id, score, "", 0, de);
                    try gsp.recordInteraction(trusted, true, score, t.required_dimension, 0);
                    std.debug.print("  → 反馈: {s} 给 score={d} (ΔE_human={d:.3}, trust→{d:.2})\n", .{
                        trusted, score, de, gsp.peers.get(trusted).?.trust,
                    });
                }
                auto_balance_count += 1;
            }
        }
    }

    // ===== 5. 最终报表 =====
    vm.pullFromSignal(&signal);
    vm.pullFromQueue(&queue);
    vm.pullFromGSP(&gsp);

    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  Live Loop 最终报表\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  数字生命 E: {d:.3} (从 0.487 起步)\n", .{agent.ed.e()});
    std.debug.print("  M={d:.2} R={d:.2} N={d:.2} gap={d:.3} 失衡={s}\n", .{
        agent.ed.v.material, agent.ed.v.representation, agent.ed.v.nature,
        BalanceSeeker.analyze(agent.ed).gap,
        if (BalanceSeeker.analyze(agent.ed).isImbalanced()) "YES" else "NO",
    });
    if (kpi_bridge) |*bridge| {
        std.debug.print("  ───────────────────────────\n", .{});
        std.debug.print("  KPI 桥 (模拟数据):\n", .{});
        std.debug.print("    写入 E 次数: {d}, 当前 K={d:.3}, kpi_enabled={}\n", .{
            bridge.refresh_count, bridge.currentComposite() orelse -1, agent.ed.kpi_enabled,
        });
    }
    std.debug.print("  ───────────────────────────\n", .{});
    std.debug.print("  触发统计:\n", .{});
    std.debug.print("    LLM 提议调用:    {d} 次\n", .{llm_propose_count});
    std.debug.print("    自动 balance 任务: {d} 次\n", .{auto_balance_count});
    std.debug.print("    自演化触发:      {d} 次\n", .{self_evolve_count});
    std.debug.print("    value_trend:     {d:.4}\n", .{value_tracker.trend()});
    std.debug.print("    memory 记录:     {d} 条 episode\n", .{memory_record_count});
    std.debug.print("  ───────────────────────────\n", .{});
    std.debug.print("  Token 总消耗:\n", .{});
    std.debug.print("    prompt={d} completion={d} (LLM 总计)\n", .{
        llm.total_prompt_tokens, llm.total_completion_tokens,
    });
    std.debug.print("  ───────────────────────────\n", .{});
    std.debug.print("  HumanGSP 信任分:\n", .{});
    var gsp_it = gsp.peers.iterator();
    while (gsp_it.next()) |entry| {
        const p = entry.value_ptr;
        std.debug.print("    {s}: trust={d:.3} ({s}) +{d}/-{d}\n", .{
            p.id, p.trust, p.trustLevel(), p.positive_count, p.negative_count,
        });
    }
    std.debug.print("  ───────────────────────────\n", .{});
    std.debug.print("  ValueMetric:\n", .{});
    std.debug.print("    完成任务: {d}, 失败: {d}\n", .{ vm.tasks_completed, vm.tasks_failed });
    std.debug.print("    Human E uplift: {d:.3} (人类反馈带来)\n", .{vm.human_e_uplift});
    std.debug.print("    Internal E uplift: {d:.3} (任务实际挣)\n", .{vm.actual_e_uplift});
    std.debug.print("    Reach: {d} humans, Trust sum: {d:.3}\n", .{vm.unique_humans, vm.current_trust_sum});
    std.debug.print("    ★ VALUE SCORE: {d:.3} / 1.0\n", .{vm.valueScore()});
    std.debug.print("================================================================\n", .{});
}
