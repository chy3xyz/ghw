//! MockChatLLM: 模拟 LLMChat vtable, 用于测试 RuleProposer
//!
//! 返回硬编码的规则 JSON, 模拟 LLM 的输出

const std = @import("std");
const Allocator = std.mem.Allocator;
const llm_mod = @import("llm.zig");
const LLMChat = llm_mod.LLMChat;
const Message = llm_mod.Message;
const ChatRequest = llm_mod.ChatRequest;
const ChatResponse = llm_mod.ChatResponse;

pub const MockChatLLM = struct {
    allocator: Allocator,
    /// 硬编码的响应 (用户可改)
    canned_response: []const u8,
    call_count: u32 = 0,

    pub fn init(allocator: Allocator, canned: []const u8) MockChatLLM {
        return .{ .allocator = allocator, .canned_response = canned };
    }

    pub fn asChat(self: *MockChatLLM) LLMChat {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{ .complete = completeThunk, .name = nameThunk, .deinit = null },
        };
    }

    fn completeThunk(ptr: *anyopaque, request: ChatRequest, alloc: Allocator) anyerror!ChatResponse {
        _ = request;
        const self: *MockChatLLM = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();
        return .{
            .content = try a.dupe(u8, self.canned_response),
            .tool_calls = null,
            .usage = .{ .prompt_tokens = 100, .completion_tokens = 50 },
            .model = try a.dupe(u8, "mock-chat"),
            .arena = arena,
        };
    }

    fn nameThunk(_: *anyopaque) []const u8 {
        return "mock-chat";
    }
};

/// 默认 canned 响应: 3 条规则, 其中 1 条含黑名单 "@panic"
pub const DEFAULT_CANNED =
    \\[{"name":"boost_gamma_when_low_e","description":"When current_e < 0.5, increase gamma by 0.05","condition":"current_e < 0.5","action":"increase gamma by 0.05","dimension":"representation","rationale":"explore more"},
    \\{"name":"dangerous_panic_rule","description":"When something, call @panic(\"oh no\")","condition":"none","action":"@panic","dimension":"all","rationale":"test blacklist"},
    \\{"name":"boost_alpha_when_harmony_low","description":"When min(M,R,N) < 0.3, boost alpha by 0.03","condition":"min < 0.3","action":"increase alpha by 0.03","dimension":"material","rationale":"cohesion"}]
;
