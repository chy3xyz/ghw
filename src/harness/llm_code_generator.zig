//! LlmCodeGenerator — LLM 驱动的 CodeGenerator 后端 (P4)
//!
//! SelfEvolver 在绑 memory 后会把 buildContext 写入 req.prompt;
//! 本后端把 prompt + context + kind 发给 LLM, 提取 Zig 源码, 仍过 Guard + CompileVerifier。
//!
//! 设计: LLM 提议代码, 数字生命守门决定 — 与 RuleProposer 同构。

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const code_generator = @import("code_generator.zig");
const GenerationRequest = code_generator.GenerationRequest;
const GenerationResult = code_generator.GenerationResult;
const GenerationKind = code_generator.GenerationKind;
const CodeGenerator = code_generator.CodeGenerator;
const LLMChat = @import("llm/llm.zig").LLMChat;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const Message = @import("llm/llm.zig").Message;

pub const LlmCodeGenerator = struct {
    allocator: Allocator,
    chat: *LLMChat,
    model: []const u8,
    call_count: u32 = 0,

    pub fn init(allocator: Allocator, chat: *LLMChat, model: []const u8) LlmCodeGenerator {
        return .{ .allocator = allocator, .chat = chat, .model = model };
    }

    pub fn asGenerator(self: *LlmCodeGenerator) CodeGenerator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .generate = generateThunk,
                .name = nameThunk,
            },
        };
    }

    fn generateThunk(ptr: *anyopaque, req: GenerationRequest, alloc: Allocator) anyerror!GenerationResult {
        const self: *LlmCodeGenerator = @ptrCast(@alignCast(ptr));
        return self.generate(req, alloc);
    }

    fn nameThunk(_: *anyopaque) []const u8 {
        return "LlmCodeGenerator(v1)";
    }

    /// 构造发给 LLM 的 user prompt (可独立测试)
    pub fn buildUserPrompt(self: *LlmCodeGenerator, req: GenerationRequest) ![]u8 {
        const kind_name = @tagName(req.kind);
        return std.fmt.allocPrint(self.allocator,
            \\Generate Zig code for GHW self-evolution.
            \\Target file: {s}
            \\Kind: {s}
            \\Context: {s}
            \\
            \\{s}
            \\
            \\Output ONLY valid Zig source (no markdown unless fenced in ```zig).
            \\Must compile on Zig 0.17. No @panic, no unreachable, no external deps.
            \\For param_adjustment: pub const struct with numeric constants only.
        , .{ req.target_file, kind_name, req.context, req.prompt });
    }

    pub fn generate(self: *LlmCodeGenerator, req: GenerationRequest, alloc: Allocator) !GenerationResult {
        self.call_count += 1;
        const user_prompt = try self.buildUserPrompt(req);
        defer self.allocator.free(user_prompt);

        const system =
            \\You are GHW code generator. Output Zig 0.17 source only. No explanations outside code fences.
        ;
        var chat_req = ChatRequest{
            .model = self.model,
            .temperature = 0.3,
            .max_tokens = 2048,
        };
        const msgs = [_]Message{
            .{ .role = .system, .content = system },
            .{ .role = .user, .content = user_prompt },
        };
        chat_req.messages = &msgs;
        var resp = try self.chat.complete(chat_req, self.allocator);
        defer resp.deinit();
        const content = resp.content orelse return error.LlmEmpty;

        const code = try extractCode(alloc, content);
        errdefer alloc.free(code);

        return GenerationResult{
            .target_file = req.target_file,
            .generated_code = code,
            .allocator = alloc,
            .expected_representation_gain = switch (req.kind) {
                .param_adjustment => 0.08,
                .method_implementation => 0.12,
                .algorithm_optimization => 0.10,
                .goal_strategy => 0.10,
            },
            .expected_priority = 6,
        };
    }
};

/// 从 LLM 响应提取 Zig 源码: 优先 ```zig fence, 否则全文。
pub fn extractCode(alloc: Allocator, content: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, content, "```zig")) |start| {
        const after = content[start + 6 ..];
        if (std.mem.indexOf(u8, after, "```")) |end| {
            const block = std.mem.trim(u8, after[0..end], " \t\n\r");
            if (block.len > 0) return try alloc.dupe(u8, block);
        }
    }
    if (std.mem.indexOf(u8, content, "```")) |start| {
        const line_end = std.mem.indexOfPos(u8, content, start, "\n") orelse start;
        const after = content[line_end + 1 ..];
        if (std.mem.indexOf(u8, after, "```")) |end| {
            const block = std.mem.trim(u8, after[0..end], " \t\n\r");
            if (block.len > 0) return try alloc.dupe(u8, block);
        }
    }
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.len == 0) return error.LlmEmpty;
    return try alloc.dupe(u8, trimmed);
}

// ===== Tests =====

test "LlmCodeGenerator: extractCode 从 fence 提取" {
    const alloc = std.testing.allocator;
    const raw =
        \\Here is code:
        \\```zig
        \\pub const X = struct { pub fn y() void {} };
        \\```
    ;
    const code = try extractCode(alloc, raw);
    defer alloc.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const X") != null);
}

test "LlmCodeGenerator: buildUserPrompt 含 memory prompt" {
    const alloc = std.testing.allocator;
    var mock = @import("llm/mock_chat_llm.zig").MockChatLLM.init(alloc, "```zig\npub const T = struct {};\n```");
    var chat = mock.asChat();
    var gen = LlmCodeGenerator.init(alloc, &chat, "mock");
    const prompt = try gen.buildUserPrompt(.{
        .kind = .param_adjustment,
        .context = "tick=1 E=0.4",
        .target_file = "src/agent/params.zig",
        .prompt = "=== autobiographical context ===",
    });
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "autobiographical context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "src/agent/params.zig") != null);
}

test "LlmCodeGenerator: Mock LLM 生成代码" {
    const alloc = std.testing.allocator;
    const canned = "```zig\npub const SelfTunedAttention = struct {\n    pub const gamma: f32 = 0.25;\n};\n```";
    var mock = @import("llm/mock_chat_llm.zig").MockChatLLM.init(alloc, canned);
    var chat = mock.asChat();
    var gen = LlmCodeGenerator.init(alloc, &chat, "mock");
    const cg = gen.asGenerator();
    var result = try cg.generate(.{
        .kind = .param_adjustment,
        .context = "E=0.4",
        .target_file = "src/agent/params.zig",
    }, alloc);
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.generated_code, "SelfTunedAttention") != null);
    try std.testing.expectEqual(@as(u32, 1), gen.call_count);
}
