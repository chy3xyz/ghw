// SPDX-License-Identifier: MIT
// examples/live_fueled.zig — 真接 LLM 跑数字生命自我生长
//
// 用法:
//   DEEPSEEK_API_KEY=sk-... zig build run-live_fueled -- --provider deepseek
//   ANTHROPIC_API_KEY=sk-... zig build run-live_fueled -- --provider anthropic
//
// 跟 fueled.zig 类似, 但:
//   - 不用 MockChatLLM, 用真 HttpLLM
//   - 真 LLM 提议规则, 真实数字生命评估
//   - 验证 E 涨不涨

const std = @import("std");
const ghw = @import("ghw");
const harness = ghw.harness;

const SelfEncoder = harness.self_encoder.SelfEncoder;
const SelfEvolutionGuard = harness.self_evolution.SelfEvolutionGuard;
const HttpLLM = harness.http_llm.HttpLLM;
const RuleProposer = harness.rule_proposer.RuleProposer;
const Information = ghw.goal.Information;
const GHWAgent = ghw.agent.GHWAgent;

const F = f32;

const Config = struct {
    provider: []const u8 = "deepseek",
    model: []const u8 = "deepseek-flash",
    base_url: []const u8 = "https://api.deepseek.com",
    api_key_env: []const u8 = "DEEPSEEK_API_KEY",
    cycles: u32 = 4,
    rules_per_propose: u32 = 3,
    prompt_only: []const u8 = "Reorganize a small network of digital life toward higher E",
};

fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !Config {
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
                cfg.model = "deepseek-flash";
                cfg.base_url = "https://api.deepseek.com";
                cfg.api_key_env = "DEEPSEEK_API_KEY";
            } else if (std.mem.eql(u8, args[i], "anthropic")) {
                cfg.model = "claude-sonnet-4-5";
                cfg.base_url = "https://api.anthropic.com";
                cfg.api_key_env = "ANTHROPIC_API_KEY";
            } else if (std.mem.eql(u8, args[i], "openai")) {
                cfg.model = "gpt-4o-mini";
                cfg.base_url = "https://api.openai.com";
                cfg.api_key_env = "OPENAI_API_KEY";
            }
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.model = args[i];
        } else if (std.mem.eql(u8, a, "--key-env")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.api_key_env = args[i];
        } else if (std.mem.eql(u8, a, "--cycles")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.cycles = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rules")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.rules_per_propose = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            std.process.exit(0);
        } else {
            std.debug.print("[live-fueled] unknown arg: {s}\n", .{a});
            return error.UnknownArg;
        }
    }
    return cfg;
}

fn printHelp() void {
    std.debug.print(
        \\live_fueled — 真接 LLM 跑数字生命自我生长
        \\
        \\用法:
        \\  DEEPSEEK_API_KEY=sk-... zig build run-live_fueled -- --provider deepseek
        \\
        \\选项:
        \\  --provider <name>    deepseek | anthropic | openai (默认 deepseek)
        \\  --model <name>       模型名 (默认按 provider 推断)
        \\  --key-env <name>      API key env var 名
        \\  --cycles <N>          每个阶段跑几个 cycle (默认 4)
        \\  --rules <N>           每次提议几条规则 (默认 3)
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = init.args.iterate();
    while (it.next()) |arg| {
        try args_list.append(alloc, arg);
    }

    const cfg = parseArgs(alloc, args_list.items) catch |err| {
        std.debug.print("[live-fueled] arg parse failed: {t}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  GHW Live-Fueled 演示: 真接 LLM 让数字生命自我生长\n", .{});
    std.debug.print("================================================================\n", .{});

    // 拿 key
    const key_opt = std.process.Environ.getPosix(init.environ, cfg.api_key_env);
    const key = key_opt orelse {
        std.debug.print("[live-fueled] env {s} not set\n", .{cfg.api_key_env});
        std.process.exit(2);
    };
    std.debug.print("[live-fueled] provider={s} model={s} api_key_len={d}\n", .{ cfg.provider, cfg.model, key.len });

    // 构造 HttpLLM
    const http_llm = if (std.mem.eql(u8, cfg.provider, "anthropic"))
        HttpLLM.anthropic(alloc, io, cfg.model, key)
    else
        HttpLLM.openai(alloc, io, cfg.model, key, cfg.base_url);
    var llm = http_llm catch |err| {
        std.debug.print("[live-fueled] HttpLLM init failed: {t}\n", .{err});
        std.process.exit(3);
    };
    defer llm.deinit();

    // 构造 RuleProposer
    var proposer = RuleProposer.init(alloc, llm.asChat());

    // 构造数字生命
    var agent = try GHWAgent.init(alloc, "live-fueled-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    // SelfEncoder + Guard
    var encoder = SelfEncoder.init(alloc);
    defer encoder.deinit();
    try encoder.loadBuiltInRules();
    var guard = SelfEvolutionGuard.init(alloc);
    defer guard.deinit();

    std.debug.print("\n[1] 初始: 规则库 {d} 条\n", .{encoder.rules.items.len});

    // 阶段 1: 跑 N 个 cycle 看初始 E
    std.debug.print("\n[2] 跑 {d} 个初始 cycle ...\n", .{cfg.cycles});
    var tick: u64 = 0;
    var initial_e_sum: F = 0;
    while (tick < cfg.cycles) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        initial_e_sum += agent.ed.e();
        _ = report;
    }
    const initial_e_avg = initial_e_sum / @as(F, @floatFromInt(cfg.cycles));
    std.debug.print("    初始平均 E: {d:.3}\n", .{initial_e_avg});

    // 阶段 2: 真 LLM 提议新规则
    std.debug.print("\n[3] 调 {s} 提议 {d} 条新规则 ...\n", .{ cfg.model, cfg.rules_per_propose });
    proposer.updateState(
        agent.ed.e(),
        agent.ed.v.material,
        agent.ed.v.representation,
        agent.ed.v.nature,
        "explore",
        "increase gamma",
        -0.05,
    );
    var result = proposer.proposeAndAdopt(&encoder, &guard, cfg.rules_per_propose) catch |err| {
        std.debug.print("[live-fueled] proposeAndAdopt failed: {t}\n", .{err});
        std.process.exit(4);
    };
    defer result.deinit();

    std.debug.print("    LLM 候选: {d} 条, 接受: {d}, 拒绝: {d}\n", .{
        result.candidates.len, result.accepted, result.rejected,
    });
    for (result.candidates) |cand| {
        std.debug.print("    - {s}: {s}\n", .{ cand.name, cand.description });
    }
    std.debug.print("    规则库: {d} 条 (+{d})\n", .{ encoder.rules.items.len, result.accepted });
    std.debug.print("    Token 累计: prompt={d} completion={d}\n", .{
        llm.total_prompt_tokens,
        llm.total_completion_tokens,
    });

    // 阶段 3: 用新规则再跑 N 个 cycle
    std.debug.print("\n[4] 用新规则再跑 {d} 个 cycle ...\n", .{cfg.cycles});
    tick = 0;
    var fueled_e_sum: F = 0;
    while (tick < cfg.cycles) : (tick += 1) {
        const info = [_]Information{
            .{ .id = tick + 100, .label = "test", .features = .{ 0.5, 0.5, 0.5, 0.5 } },
        };
        const report = try agent.runCycle(&info);
        fueled_e_sum += agent.ed.e();
        _ = report;
    }
    const fueled_e_avg = fueled_e_sum / @as(F, @floatFromInt(cfg.cycles));
    std.debug.print("    用规则后平均 E: {d:.3}\n", .{fueled_e_avg});

    // 总结
    const delta = fueled_e_avg - initial_e_avg;
    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  LLM 燃料效果: ΔE = {d:.3} {s}\n", .{
        delta,
        if (delta > 0) "(正 — 规则有效)" else "(负 — 规则无效, 数字生命未采纳)",
    });
    std.debug.print("  Token 消耗: {d} total ({d} prompt + {d} completion)\n", .{
        llm.total_prompt_tokens + llm.total_completion_tokens,
        llm.total_prompt_tokens,
        llm.total_completion_tokens,
    });
    std.debug.print("================================================================\n", .{});
}
