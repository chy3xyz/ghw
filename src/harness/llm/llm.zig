//! LLM 抽象接口: 数字生命的"语言皮层"
//!
//! 真正的 LLM 桥接: subprocess 调 claude code / autocli / ollama 等
//! 本阶段提供:
//!   - MockLLM: 内置 (用于零依赖 demo, 模拟 Claude 的代码生成能力)
//!   - ShellLLM: subprocess 调外部 CLI (用户配置 API key 后即可用)
//!   - HttpLLM: 直接 HTTP POST 到 Anthropic / OpenAI-compat (zai.baide 风格 vtable)
//!   - vtable: 用户可插入自己的 LLM 后端
//!
//! 两套 API:
//!   - LLM (旧): 简单的 text-in / text-out, 适用于 MockLLM / ShellLLM
//!   - LLMChat (新): 多轮消息 + 工具调用 + token 跟踪, 适用于 HttpLLM
//!
//! 论文对应: B.5.3 长期方向 - "GHW 系统的自我演化"
//!
//! 架构哲学: LLM 是数字生命的"搜索加速器",不是"决策者"。
//! - LLM 提议: 文本→特征, 代码变体, 规则候选, 反事实
//! - 数字生命决定: ΔE 评估, SelfEvolutionGuard 守门, SelfEncoder 编译

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// F32 类型别名 (本地定义, 避免跨目录导入问题)
pub const F = f32;

// ===== 旧 API (简单 text-in/text-out) =====

/// LLM 调用请求
pub const LLMRequest = struct {
    /// 完整 prompt (GHW 自演化的"进化要求"会序列化到这里)
    prompt: []const u8,
    /// 期望的输出格式提示 ("zig_code", "review", "free")
    output_format: []const u8 = "zig_code",
    /// 上下文 (供多轮对话)
    context: []const u8 = "",
    /// 最大输出 token (给真实 LLM 用, Mock 忽略)
    max_tokens: u32 = 4096,
    /// 温度 (Mock 忽略)
    temperature: F = 0.2,
};

/// LLM 响应
pub const LLMResponse = struct {
    content: []u8,
    allocator: Allocator,
    /// 真实 LLM 才有这个 (Mock 为空)
    model_name: []const u8 = "mock",
    /// 用时 (ms, 0 表示未测量)
    elapsed_ms: u64 = 0,
    /// 是否成功
    success: bool = true,
    /// 失败原因
    error_msg: []const u8 = "",

    pub fn deinit(self: *LLMResponse) void {
        self.allocator.free(self.content);
    }
};

/// 简易计时器 (Zig 0.17 没有 std.time.milliTimestamp, 用 ns 计数代替)
pub fn nowMs() u64 {
    // 简单占位 — 真实部署可以用 std.posix.clock_gettime
    return 0;
}

/// LLM 后端 vtable (旧, 简单 API)
pub const LLM = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 生成代码 (L3)
        generate: *const fn (ptr: *anyopaque, req: LLMRequest, alloc: Allocator) anyerror!LLMResponse,
        /// 审查代码 (L4 规则审计)
        review: *const fn (ptr: *anyopaque, code: []const u8, alloc: Allocator) anyerror!LLMResponse,
        /// 后端名称
        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn generate(self: LLM, req: LLMRequest, alloc: Allocator) !LLMResponse {
        return self.vtable.generate(self.ptr, req, alloc);
    }
    pub fn review(self: LLM, code: []const u8, alloc: Allocator) !LLMResponse {
        return self.vtable.review(self.ptr, code, alloc);
    }
    pub fn name(self: LLM) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

// ===== 新 API (多轮消息 + 工具调用) =====
// 借鉴 zai.baide/src/agentkit/llm_provider.zig 的设计

/// 消息角色
pub const Role = enum { system, user, assistant, tool };

/// 多轮消息
pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

/// LLM 发起的工具调用 (function calling)
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON 字符串
};

/// 工具 schema (供 LLM 选择)
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema 描述参数
    parameters_schema: []const u8,
};

/// Token 用量
pub const TokenUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,

    pub fn total(self: TokenUsage) u32 {
        return self.prompt_tokens + self.completion_tokens;
    }
};

/// 新 API 请求
pub const ChatRequest = struct {
    model: []const u8 = "",
    messages: []const Message = &.{},
    tools: ?[]const ToolSchema = null,
    temperature: F = 0.2,
    max_tokens: u32 = 4096,
};

/// 新 API 响应 (内部用 arena, deinit 释放所有字段)
pub const ChatResponse = struct {
    content: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,
    usage: TokenUsage = .{},
    model: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ChatResponse) void {
        self.arena.deinit();
    }
};

/// 流式回调
pub const StreamCallback = struct {
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, content: []const u8, done: bool) void,
};

/// LLM Chat vtable (新 API, 多轮 + 工具)
/// 借鉴 zai.baide/src/agentkit/llm_provider.zig
pub const LLMChat = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        complete: *const fn (ptr: *anyopaque, request: ChatRequest, alloc: Allocator) anyerror!ChatResponse,
        /// 后端名称
        name: *const fn (ptr: *anyopaque) []const u8,
        /// 释放内部资源 (可选)
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn complete(self: LLMChat, request: ChatRequest, alloc: Allocator) !ChatResponse {
        return self.vtable.complete(self.ptr, request, alloc);
    }
    pub fn getName(self: LLMChat) []const u8 {
        return self.vtable.name(self.ptr);
    }
    pub fn deinit(self: LLMChat) void {
        if (self.vtable.deinit) |d| d(self.ptr);
    }
};
