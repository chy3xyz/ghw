// SPDX-License-Identifier: MIT
// examples/llm_smoke.zig — 真实 LLM smoke test
//
// 用法:
//   DEEPSEEK_API_KEY=sk-... zig build run-llm-smoke -- --provider deepseek
//   ANTHROPIC_API_KEY=sk-... zig build run-llm-smoke -- --provider anthropic
//
// 验证 HttpLLM 真的能调通, 不烧太多 token (max_tokens=128)

const std = @import("std");
const ghw = @import("ghw");
const HttpLLM = ghw.harness.http_llm.HttpLLM;
const ChatRequest = ghw.harness.llm.ChatRequest;
const Message = ghw.harness.llm.Message;
const Role = ghw.harness.llm.Role;

const Config = struct {
    provider: []const u8 = "deepseek",
    model: []const u8 = "deepseek-chat",
    base_url: []const u8 = "https://api.deepseek.com",
    api_key_env: []const u8 = "DEEPSEEK_API_KEY",
    max_tokens: u32 = 128,
    prompt: []const u8 = "Reply with exactly: 'pong' and nothing else. No markdown, no quotes.",
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
            // 调默认 model + base_url
            if (std.mem.eql(u8, args[i], "deepseek")) {
                cfg.model = "deepseek-chat";
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
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.base_url = args[i];
        } else if (std.mem.eql(u8, a, "--key-env")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.api_key_env = args[i];
        } else if (std.mem.eql(u8, a, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.max_tokens = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            cfg.prompt = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            std.process.exit(0);
        } else {
            std.debug.print("[smoke] unknown arg: {s}\n", .{a});
            return error.UnknownArg;
        }
    }
    return cfg;
}

fn printHelp() void {
    std.debug.print(
        \\llm_smoke — 真实 LLM smoke test
        \\
        \\用法:
        \\  DEEPSEEK_API_KEY=sk-... zig build run-llm-smoke -- --provider deepseek
        \\
        \\选项:
        \\  --provider <name>    deepseek | anthropic | openai (默认 deepseek)
        \\  --model <name>       模型名 (默认按 provider 推断)
        \\  --base-url <url>     API 端点 (默认按 provider 推断)
        \\  --key-env <name>     API key 的 env var 名
        \\  --max-tokens <N>     最大输出 (默认 128)
        \\  --prompt <text>      自定义 prompt
        \\
    , .{});
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
        std.debug.print("[smoke] arg parse failed: {t}\n", .{err});
        std.process.exit(1);
    };

    // 拿 API key (不打印)
    const key_opt = std.process.Environ.getPosix(init.environ, cfg.api_key_env);
    const key = key_opt orelse {
        std.debug.print("[smoke] env {s} not set\n", .{cfg.api_key_env});
        std.process.exit(2);
    };
    std.debug.print("[smoke] provider={s} model={s} key_len={d}\n", .{ cfg.provider, cfg.model, key.len });

    // 构造 HttpLLM
    const http_llm = if (std.mem.eql(u8, cfg.provider, "anthropic"))
        HttpLLM.anthropic(alloc, io, cfg.model, key)
    else
        HttpLLM.openai(alloc, io, cfg.model, key, cfg.base_url);
    var llm = http_llm catch |err| {
        std.debug.print("[smoke] HttpLLM init failed: {t}\n", .{err});
        std.process.exit(3);
    };
    defer llm.deinit();

    // 构造 chat 请求
    const messages = [_]Message{
        .{ .role = .user, .content = cfg.prompt },
    };
    const req = ChatRequest{
        .model = cfg.model,
        .messages = &messages,
        .max_tokens = cfg.max_tokens,
        .temperature = 0.1,
    };

    std.debug.print("[smoke] sending request...\n", .{});
    var resp = llm.complete(req, alloc) catch |err| {
        std.debug.print("[smoke] complete failed: {t}\n", .{err});
        std.process.exit(4);
    };
    defer resp.deinit();

    std.debug.print("[smoke] === response ===\n", .{});
    if (resp.content) |c| {
        std.debug.print("content: {s}\n", .{c});
    } else {
        std.debug.print("content: (null)\n", .{});
    }
    std.debug.print("usage: prompt={d} completion={d} total={d}\n", .{
        resp.usage.prompt_tokens,
        resp.usage.completion_tokens,
        resp.usage.total(),
    });
    std.debug.print("model: {s}\n", .{resp.model});

    // 总统计
    std.debug.print("\n[smoke] total calls={d} total_prompt={d} total_completion={d}\n", .{
        llm.total_calls,
        llm.total_prompt_tokens,
        llm.total_completion_tokens,
    });
}
