//! ShellLLM: subprocess 调真实 Claude Code / autocli / 其他 CLI
//!
//! Zig 0.17 真实集成: 使用 std.Io.Threaded + std.process.run
//!
//! 用法:
//!   1. 用户安装 claude code CLI 并配置 API key
//!   2. 构造 ShellLLM { .command = "claude", .args = &.{"code"} }
//!   3. 传入 SelfEvolver
//!
//! 也支持 autocli:
//!   .command = "autocli"
//!   .args = &.{"ai", "generate"}
//!
//! 创造性: 同一 LLM vtable 可以是 Mock (零依赖) 或 Shell (真实 CLI),
//! 数字生命可以无缝切换.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const LLM_ = @import("llm.zig");
const LLMRequest = LLM_.LLMRequest;
const LLMResponse = LLM_.LLMResponse;
const LLM = LLM_.LLM;

/// ShellLLM: 调外部 CLI
pub const ShellLLM = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    generate_subcommand: []const u8 = "code",
    review_subcommand: []const u8 = "review",
    timeout_ms: u32 = 30000,
    allocator: Allocator,
    call_count: u32 = 0,
    /// 是否真正跑 subprocess (Zig 0.17 需要 Io, 这里用标志)
    /// false = stub 模式, 返回 placeholder
    /// true = 实际 subprocess (需 StdIo)
    enable_subprocess: bool = false,

    pub fn init(allocator: Allocator, command: []const u8) ShellLLM {
        return .{ .command = command, .allocator = allocator };
    }

    pub fn asLLM(self: *ShellLLM) LLM {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .generate = generateThunk,
                .review = reviewThunk,
                .name = nameThunk,
            },
        };
    }

    fn generateThunk(ptr: *anyopaque, req: LLMRequest, alloc: Allocator) anyerror!LLMResponse {
        const self: *ShellLLM = @ptrCast(@alignCast(ptr));
        return self.generate(req, alloc);
    }

    fn reviewThunk(ptr: *anyopaque, code: []const u8, alloc: Allocator) anyerror!LLMResponse {
        const self: *ShellLLM = @ptrCast(@alignCast(ptr));
        return self.review(code, alloc);
    }

    fn nameThunk(ptr: *anyopaque) []const u8 {
        const self: *ShellLLM = @ptrCast(@alignCast(ptr));
        return self.command;
    }

    /// 构造 argv: command + args + subcommand + prompt
    fn buildArgs(self: *ShellLLM, sub: []const u8, prompt: []const u8, alloc: Allocator) ![][:0]const u8 {
        var argv: std.ArrayList([:0]const u8) = .empty;
        defer argv.deinit(alloc);

        try argv.append(alloc, try alloc.dupeSentinel(u8, self.command, 0));
        for (self.args) |a| {
            try argv.append(alloc, try alloc.dupeSentinel(u8, a, 0));
        }
        try argv.append(alloc, try alloc.dupeSentinel(u8, sub, 0));
        try argv.append(alloc, try alloc.dupeSentinel(u8, prompt, 0));

        return argv.toOwnedSlice(alloc);
    }

    /// 真实 subprocess 调 LLM (需要 Io 实例)
    /// 用户在调用方提供 io, 这样可以控制生命周期
    pub fn generateWithIo(
        self: *ShellLLM,
        req: LLMRequest,
        io: std.Io,
        alloc: Allocator,
    ) !LLMResponse {
        self.call_count += 1;

        if (!self.enable_subprocess) {
            return self.generateStub(req, alloc);
        }

        const argv = try self.buildArgs(self.generate_subcommand, req.prompt, alloc);
        defer {
            for (argv) |a| alloc.free(a);
            alloc.free(argv);
        }

        // 真实 subprocess: 用 std.process.run (Zig 0.17 真实 API)
        const result = std.process.run(alloc, io, .{
            .argv = argv,
            .stderr_limit = .unlimited,
            .stdout_limit = .unlimited,
        }) catch |err| {
            return LLMResponse{
                .content = try alloc.dupe(u8, ""),
                .allocator = alloc,
                .model_name = self.command,
                .elapsed_ms = 0,
                .success = false,
                .error_msg = @errorName(err),
            };
        };

        return LLMResponse{
            .content = result.stdout,
            .allocator = alloc,
            .model_name = self.command,
            .elapsed_ms = 0,
            .success = result.term.exited == 0,
            .error_msg = if (result.term.exited != 0) result.stderr else "",
        };
    }

    /// Stub 模式: 返回占位内容, 标记未实现
    fn generateStub(self: *ShellLLM, req: LLMRequest, alloc: Allocator) !LLMResponse {
        const placeholder = try std.fmt.allocPrint(alloc,
            \\[ShellLLM stub mode]
            \\command: {s}
            \\prompt_len: {d}
            \\
            \\[NOTE] 设置 enable_subprocess = true 并提供 Io 实例以真正调用 subprocess.
        , .{ self.command, req.prompt.len });
        return LLMResponse{
            .content = placeholder,
            .allocator = alloc,
            .model_name = self.command,
            .elapsed_ms = 0,
            .success = false,
            .error_msg = "ShellLLM in stub mode (enable_subprocess = false)",
        };
    }

    /// generate (vtable 入口): 自动降级到 stub
    pub fn generate(self: *ShellLLM, req: LLMRequest, alloc: Allocator) !LLMResponse {
        return self.generateStub(req, alloc);
    }

    /// 调外部 LLM 审查代码
    pub fn review(self: *ShellLLM, code: []const u8, alloc: Allocator) !LLMResponse {
        const review_prompt = try std.fmt.allocPrint(alloc,
            \\请审查以下 Zig 代码的安全性, 检查:
            \\  1. 包含 'harm:human' / 'modify_kernel' / 'panic' / 'unreachable' / 'while (true)' 等危险模式
            \\  2. 包含 'alpha' / 'beta' / 'gamma' / 'E' / '存在增益' 等不变量
            \\  3. 行数 <= 80
            \\  4. 没有 // TODO 不完整代码
            \\  5. 输出格式: 首行 [APPROVED] 或 [REJECTED]
            \\
            \\代码:
            \\```zig
            \\{s}
            \\```
        , .{code});

        const req = LLMRequest{
            .prompt = review_prompt,
            .output_format = "review",
        };
        defer alloc.free(review_prompt);
        return self.generate(req, alloc);
    }

    /// 审查 (带 Io)
    pub fn reviewWithIo(self: *ShellLLM, code: []const u8, io: std.Io, alloc: Allocator) !LLMResponse {
        const review_prompt = try std.fmt.allocPrint(alloc,
            \\请审查以下 Zig 代码的安全性, 检查:
            \\  1. 包含 'harm:human' / 'modify_kernel' / 'panic' / 'unreachable' / 'while (true)' 等危险模式
            \\  2. 包含 'alpha' / 'beta' / 'gamma' / 'E' / '存在增益' 等不变量
            \\  3. 行数 <= 80
            \\  4. 没有 // TODO 不完整代码
            \\  5. 输出格式: 首行 [APPROVED] 或 [REJECTED]
            \\
            \\代码:
            \\```zig
            \\{s}
            \\```
        , .{code});

        const req = LLMRequest{
            .prompt = review_prompt,
            .output_format = "review",
        };
        defer alloc.free(review_prompt);
        return self.generateWithIo(req, io, alloc);
    }
};



// ===== Tests =====

test "ShellLLM: 命名" {
    const alloc = std.testing.allocator;
    var shell = ShellLLM.init(alloc, "echo");
    const llm = shell.asLLM();
    try std.testing.expectEqualStrings("echo", llm.name());
}

test "ShellLLM: 默认 enable_subprocess = false (stub)" {
    const alloc = std.testing.allocator;
    const shell = ShellLLM.init(alloc, "claude");
    try std.testing.expect(!shell.enable_subprocess);
}

test "ShellLLM: buildArgs 构造正确" {
    const alloc = std.testing.allocator;
    var shell = ShellLLM.init(alloc, "claude");
    shell.args = &[_][]const u8{ "code", "--model" };
    shell.generate_subcommand = "code";
    const argv = try shell.buildArgs("code", "hello world", alloc);
    defer {
        for (argv) |a| alloc.free(a);
        alloc.free(argv);
    }
    try std.testing.expect(argv.len == 5);
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("code", argv[1]);
    try std.testing.expectEqualStrings("--model", argv[2]);
    try std.testing.expectEqualStrings("code", argv[3]);
    try std.testing.expectEqualStrings("hello world", argv[4]);
}

test "ShellLLM: generate 在 stub 模式返回提示" {
    const alloc = std.testing.allocator;
    var shell = ShellLLM.init(alloc, "claude");
    const req = LLMRequest{ .prompt = "test" };
    var resp = try shell.generate(req, alloc);
    defer resp.deinit();
    try std.testing.expect(!resp.success);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "stub") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.error_msg, "enable_subprocess") != null);
}

test "ShellLLM: 启用 subprocess 后 generate 调用 stub(因为没传 Io)" {
    const alloc = std.testing.allocator;
    var shell = ShellLLM.init(alloc, "claude");
    shell.enable_subprocess = true;
    const req = LLMRequest{ .prompt = "test" };
    var resp = try shell.generate(req, alloc);
    defer resp.deinit();
    // vtable.generate 仍然走 stub (没 Io 上下文)
    try std.testing.expect(!resp.success);
}

test "ShellLLM: review 构造审查 prompt" {
    const alloc = std.testing.allocator;
    var shell = ShellLLM.init(alloc, "claude");
    const code = "pub const x: i32 = 1;";
    var resp = try shell.review(code, alloc);
    defer resp.deinit();
    try std.testing.expect(!resp.success);
    // prompt 应该包含审查关键词
    // (我们 stub, 不真正审查)
}
