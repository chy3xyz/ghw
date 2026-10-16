//! HttpLLM: 真实 HTTP LLM provider
//!
//! 支持两个协议:
//!   - Anthropic Messages API (claude-sonnet-4, claude-opus-4, ...)
//!   - OpenAI Chat Completions (gpt-4o, deepseek, zhipu, ollama, ...)
//!
//! 设计: 借鉴 zai.baide 的 LlmProvider vtable, 但用 std.http.Client + Io 直接发请求
//! 不依赖任何外部 HTTP 库
//!
//! 用法:
//!   const llm = try HttpLLM.anthropic(alloc, io, "claude-sonnet-4-5", "sk-...");
//!   defer llm.deinit();
//!   const chat = llm.asChat();
//!   var resp = try chat.complete(.{ .messages = &.{
//!       .{ .role = .system, .content = "你是 GHW 数字生命的提议器" },
//!       .{ .role = .user, .content = "..." },
//!   } }, alloc);
//!   defer resp.deinit();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const llm_mod = @import("llm.zig");
const LLM = llm_mod.LLM;
const LLMChat = llm_mod.LLMChat;
const Message = llm_mod.Message;
const Role = llm_mod.Role;
const ToolCall = llm_mod.ToolCall;
const ToolSchema = llm_mod.ToolSchema;
const TokenUsage = llm_mod.TokenUsage;
const ChatRequest = llm_mod.ChatRequest;
const ChatResponse = llm_mod.ChatResponse;
const LLMRequest = llm_mod.LLMRequest;
const LLMResponse = llm_mod.LLMResponse;
const net_read = @import("../../util/net_read.zig");

pub const ProviderKind = enum {
    anthropic,
    openai_compat,
};

pub const HttpLLM = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: ProviderKind,
    model: []u8, // owned
    api_key: []u8, // owned
    /// OpenAI-compat 用, 默认 https://api.openai.com
    base_url: []u8,
    /// Anthropic 用, 默认 https://api.anthropic.com
    anthropic_version: []u8,
    /// 简单统计
    total_calls: u64 = 0,
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,

    /// 构造 Anthropic provider
    pub fn anthropic(alloc: std.mem.Allocator, io: std.Io, model: []const u8, api_key: []const u8) !HttpLLM {
        return anthropicWithBase(alloc, io, model, api_key, "https://api.anthropic.com");
    }

    /// anthropic + 自定义 base_url (自托管网关 / 本地 mock 测试)
    pub fn anthropicWithBase(alloc: std.mem.Allocator, io: std.Io, model: []const u8, api_key: []const u8, base_url: []const u8) !HttpLLM {
        return .{
            .allocator = alloc,
            .io = io,
            .provider = .anthropic,
            .model = try alloc.dupe(u8, model),
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url),
            .anthropic_version = try alloc.dupe(u8, "2023-06-01"),
        };
    }

    /// 构造 OpenAI 兼容 provider (OpenAI / DeepSeek / 智谱 / ollama / ...)
    pub fn openai(alloc: std.mem.Allocator, io: std.Io, model: []const u8, api_key: []const u8, base_url: []const u8) !HttpLLM {
        return .{
            .allocator = alloc,
            .io = io,
            .provider = .openai_compat,
            .model = try alloc.dupe(u8, model),
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url),
            .anthropic_version = try alloc.dupe(u8, ""),
        };
    }

    /// DeepSeek 当前模型。官方名 `deepseek-flash`，对应 V4.1-Flash。
    /// 密钥不在这里，调用方只传环境变量里读到的值。
    pub const DEEPSEEK_MODEL = "deepseek-flash";
    pub const DEEPSEEK_BASE = "https://api.deepseek.com";

    /// DeepSeek 快捷构造 (OpenAI 兼容, base_url 写死)
    pub fn deepseek(alloc: std.mem.Allocator, io: std.Io, model: []const u8, api_key: []const u8) !HttpLLM {
        return .openai(alloc, io, model, api_key, DEEPSEEK_BASE);
    }

    pub fn deinit(self: *HttpLLM) void {
        self.allocator.free(self.model);
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.anthropic_version);
    }

    /// 作为 LLMChat vtable
    pub fn asChat(self: *HttpLLM) LLMChat {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{ .complete = completeThunk, .name = nameThunk, .deinit = deinitThunk },
        };
    }

    /// 作为 LLM (旧 API)
    pub fn asLLM(self: *HttpLLM) LLM {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{ .generate = generateThunk, .review = reviewThunk, .name = nameThunk },
        };
    }

    // === LLMChat vtable 实现 ===
    fn completeThunk(ptr: *anyopaque, request: ChatRequest, alloc: Allocator) anyerror!ChatResponse {
        const self: *HttpLLM = @ptrCast(@alignCast(ptr));
        return self.complete(request, alloc);
    }
    fn nameThunk(ptr: *anyopaque) []const u8 {
        const self: *HttpLLM = @ptrCast(@alignCast(ptr));
        return self.nameStr();
    }
    fn deinitThunk(ptr: *anyopaque) void {
        const self: *HttpLLM = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    // === LLM (旧) vtable 实现 ===
    fn generateThunk(ptr: *anyopaque, req: LLMRequest, alloc: Allocator) anyerror!LLMResponse {
        const self: *HttpLLM = @ptrCast(@alignCast(ptr));
        return self.generateOld(req, alloc);
    }
    fn reviewThunk(ptr: *anyopaque, code: []const u8, alloc: Allocator) anyerror!LLMResponse {
        const self: *HttpLLM = @ptrCast(@alignCast(ptr));
        return self.reviewOld(code, alloc);
    }

    pub fn nameStr(self: *HttpLLM) []const u8 {
        return switch (self.provider) {
            .anthropic => "anthropic-http",
            .openai_compat => "openai-compat-http",
        };
    }

    /// 新 API: 多轮 chat
    pub fn complete(self: *HttpLLM, request: ChatRequest, alloc: Allocator) !ChatResponse {
        return switch (self.provider) {
            .anthropic => self.completeAnthropic(request, alloc),
            .openai_compat => self.completeOpenAI(request, alloc),
        };
    }

    fn completeAnthropic(self: *HttpLLM, request: ChatRequest, alloc: Allocator) !ChatResponse {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        const url = try std.fmt.allocPrint(arena.allocator(), "{s}/v1/messages", .{self.base_url});
        const body = try self.buildAnthropicBody(arena.allocator(), request);

        var client: std.http.Client = .{ .allocator = arena.allocator(), .io = self.io };
        defer client.deinit();

        var writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer writer.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = self.anthropic_version },
            },
            .response_writer = &writer.writer,
        });

        if (@intFromEnum(result.status) != 200) {
            std.debug.print("[HttpLLM/anthropic] non-200: {d} body={s}\n", .{ @intFromEnum(result.status), writer.writer.buffered() });
            return error.LLMRequestFailed;
        }

        const body_slice = writer.writer.buffered();
        return try self.parseAnthropicResponse(&arena, body_slice);
    }

    fn completeOpenAI(self: *HttpLLM, request: ChatRequest, alloc: Allocator) !ChatResponse {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        const url = try std.fmt.allocPrint(arena.allocator(), "{s}/v1/chat/completions", .{self.base_url});
        const body = try self.buildOpenAIBody(arena.allocator(), request);

        var client: std.http.Client = .{ .allocator = arena.allocator(), .io = self.io };
        defer client.deinit();

        var writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer writer.deinit();

        // DeepSeek 还要 Bearer, 多数 OpenAI 兼容端点也是
        const auth_header = try std.fmt.allocPrint(arena.allocator(), "Bearer {s}", .{self.api_key});

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_header },
            },
            .response_writer = &writer.writer,
        });

        if (@intFromEnum(result.status) != 200) {
            std.debug.print("[HttpLLM/openai] non-200: {d} body={s}\n", .{ @intFromEnum(result.status), writer.writer.buffered() });
            return error.LLMRequestFailed;
        }

        const body_slice = writer.writer.buffered();
        return try self.parseOpenAIResponse(&arena, body_slice);
    }

    /// 旧 API: 简单 prompt in / text out
    pub fn generateOld(self: *HttpLLM, req: LLMRequest, alloc: Allocator) !LLMResponse {
        // 把 prompt 包装成单条 user message
        const messages = [_]Message{
            .{ .role = .user, .content = req.prompt },
        };
        const chat_req = ChatRequest{
            .model = self.model,
            .messages = &messages,
            .temperature = req.temperature,
            .max_tokens = req.max_tokens,
        };
        var chat_resp = try self.complete(chat_req, alloc);
        defer chat_resp.deinit();
        const content = chat_resp.content orelse "";
        return LLMResponse{
            .content = try alloc.dupe(u8, content),
            .allocator = alloc,
            .model_name = self.model,
            .elapsed_ms = 0,
            .success = true,
            .error_msg = "",
        };
    }

    pub fn reviewOld(self: *HttpLLM, code: []const u8, alloc: Allocator) !LLMResponse {
        const system = "You are a code reviewer for a self-evolving AI system. Check for: (1) illegal syscalls, (2) breaking the core invariants, (3) missing presence-degree calculation. Reply PASS or FAIL with reason.";
        const user = try std.fmt.allocPrint(alloc, "Review this code:\n```zig\n{s}\n```", .{code});
        defer alloc.free(user);
        const messages = [_]Message{
            .{ .role = .system, .content = system },
            .{ .role = .user, .content = user },
        };
        const chat_req = ChatRequest{
            .model = self.model,
            .messages = &messages,
            .max_tokens = 512,
        };
        var chat_resp = try self.complete(chat_req, alloc);
        defer chat_resp.deinit();
        const content = chat_resp.content orelse "";
        return LLMResponse{
            .content = try alloc.dupe(u8, content),
            .allocator = alloc,
            .model_name = self.model,
            .elapsed_ms = 0,
            .success = true,
            .error_msg = "",
        };
    }

    // === OpenAI 协议实现 (兼容 DeepSeek / 智谱 / ollama / etc.) ===

    fn buildOpenAIBody(self: *HttpLLM, alloc: Allocator, req: ChatRequest) ![]u8 {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);

        try body.print(alloc, "{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":{d:.2},\"stream\":false,\"messages\":[", .{
            self.model, req.max_tokens, req.temperature,
        });
        for (req.messages, 0..) |msg, i| {
            if (i > 0) try body.print(alloc, ",", .{});
            try body.print(alloc, "{{\"role\":\"{s}\"", .{roleToOpenAIStr(msg.role)});
            if (msg.content) |c| {
                try body.print(alloc, ",\"content\":", .{});
                try writeJsonString(alloc, &body, c);
            }
            try body.print(alloc, "}}", .{});
        }
        try body.print(alloc, "]", .{});
        // Flash 默认会先想再答，容易把额度花在思考上。这台生命要的是直接回答。
        if (std.mem.indexOf(u8, self.base_url, "api.deepseek.com") != null) {
            try body.appendSlice(alloc, ",\"thinking\":{");
            try body.appendSlice(alloc, "\"type\":\"disabled\"");
            try body.appendSlice(alloc, "}");
        }
        try body.appendSlice(alloc, "}");
        return body.toOwnedSlice(alloc);
    }

    fn parseOpenAIResponse(self: *HttpLLM, arena: *std.heap.ArenaAllocator, body: []const u8) !ChatResponse {
        const a = arena.allocator();
        var resp = ChatResponse{ .arena = arena.*, .model = try a.dupe(u8, self.model) };

        // 解析: "choices":[{"message":{"content":"..."}}]
        // 用 "content": 找 (不含开 "), 跳过空白后 open_quote 指向开 "
        if (findJsonString(body, "\"content\":")) |open_quote| {
            // open_quote 指向开 ", 内容从 open_quote+1 开始
            const content_start = open_quote + 1;
            const content_end = findStringEnd(body, content_start) orelse body.len;
            // 包含 JSON 转义, 解析成原始字符串
            const raw = body[content_start..content_end];
            resp.content = try unescapeJsonString(a, raw);
        }
        // usage
        if (findJsonNumber(body, "\"prompt_tokens\":")) |s| {
            resp.usage.prompt_tokens = try std.fmt.parseInt(u32, s, 10);
        }
        if (findJsonNumber(body, "\"completion_tokens\":")) |s| {
            resp.usage.completion_tokens = try std.fmt.parseInt(u32, s, 10);
        }

        self.total_calls += 1;
        self.total_prompt_tokens += resp.usage.prompt_tokens;
        self.total_completion_tokens += resp.usage.completion_tokens;
        return resp;
    }

    // === Anthropic API 协议实现 ===

    fn buildAnthropicBody(self: *HttpLLM, alloc: Allocator, req: ChatRequest) ![]u8 {
        // 简单 JSON 构造: {"model": "...", "messages": [...], "max_tokens": N, "temperature": F}
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);

        try body.print(alloc, "{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":{d:.2},\"messages\":[", .{
            self.model, req.max_tokens, req.temperature,
        });
        for (req.messages, 0..) |msg, i| {
            if (i > 0) try body.print(alloc, ",", .{});
            try body.print(alloc, "{{\"role\":\"{s}\"", .{roleToAnthropicStr(msg.role)});
            if (msg.content) |c| {
                try body.print(alloc, ",\"content\":", .{});
                try writeJsonString(alloc, &body, c);
            }
            try body.print(alloc, "}}", .{});
        }
        try body.print(alloc, "]}}", .{});
        return body.toOwnedSlice(alloc);
    }

    fn parseAnthropicResponse(self: *HttpLLM, arena: *std.heap.ArenaAllocator, body: []const u8) !ChatResponse {
        const a = arena.allocator();
        var resp = ChatResponse{ .arena = arena.*, .model = try a.dupe(u8, self.model) };

        // 简单 JSON 解析: 找 "content":[{"text":"..."}] 里的 text
        // 找 "usage":{"input_tokens":N,"output_tokens":M}
        // findJsonString 返回**值开引号**位置 (与 openai 路径同约定)。
        // 旧实现又加了 key 长度, 导致 content 恒为 null — 由 mock server 集成测试暴露。
        if (findJsonString(body, "\"text\":")) |open_quote| {
            const content_start = open_quote + 1;
            const content_end = findStringEnd(body, content_start) orelse body.len;
            const raw = body[content_start..content_end];
            resp.content = try unescapeJsonString(a, raw);
        }
        if (findJsonNumber(body, "\"input_tokens\":")) |s| {
            resp.usage.prompt_tokens = try std.fmt.parseInt(u32, s, 10);
        }
        if (findJsonNumber(body, "\"output_tokens\":")) |s| {
            resp.usage.completion_tokens = try std.fmt.parseInt(u32, s, 10);
        }

        self.total_calls += 1;
        self.total_prompt_tokens += resp.usage.prompt_tokens;
        self.total_completion_tokens += resp.usage.completion_tokens;
        return resp;
    }
};

// === 辅助函数 ===

fn roleToAnthropicStr(r: Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "user", // Anthropic 不支持 tool role, 转为 user
    };
}

fn roleToOpenAIStr(r: Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool", // OpenAI 支持 tool role
    };
}

fn writeJsonString(alloc: Allocator, body: *std.ArrayList(u8), s: []const u8) !void {
    try body.print(alloc, "\"", .{});
    for (s) |c| {
        switch (c) {
            '"' => try body.print(alloc, "\\\"", .{}),
            '\\' => try body.print(alloc, "\\\\", .{}),
            '\n' => try body.print(alloc, "\\n", .{}),
            '\r' => try body.print(alloc, "\\r", .{}),
            '\t' => try body.print(alloc, "\\t", .{}),
            else => try body.print(alloc, "{c}", .{c}),
        }
    }
    try body.print(alloc, "\"", .{});
}

/// 找 "key":"value" 中 value 起始位置
fn findJsonString(body: []const u8, key: []const u8) ?usize {
    if (std.mem.indexOf(u8, body, key)) |idx| {
        var i = idx + key.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
        if (i < body.len and body[i] == '"') {
            return i;
        }
    }
    return null;
}

fn findStringEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') return i;
    }
    return null;
}

/// JSON 字符串反转义: \" → ", \\ → \, \n → newline, \t → tab, \uXXXX → utf8
/// LLM API 经常把 inner JSON 当字符串包, 我们需要真正解出 raw 内容
fn unescapeJsonString(alloc: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                'b' => try out.append(alloc, 0x08),
                'f' => try out.append(alloc, 0x0C),
                'u' => {
                    if (i + 5 < raw.len) {
                        const hex = raw[i + 2 .. i + 6];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            try out.append(alloc, '?');
                            i += 6;
                            continue;
                        };
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch 0;
                        try out.appendSlice(alloc, buf[0..len]);
                        i += 4; // 跳过 4 位 hex
                    } else {
                        try out.append(alloc, '?');
                    }
                },
                else => try out.append(alloc, next),
            }
            i += 2;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 找 "key":N 中数字起始位置
fn findJsonNumber(body: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, body, key)) |idx| {
        var i = idx + key.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\n')) : (i += 1) {}
        const start = i;
        while (i < body.len and (body[i] >= '0' and body[i] <= '9')) : (i += 1) {}
        if (i > start) return body[start..i];
    }
    return null;
}

// ===== 集成测试: 本地 mock HTTP server, 验证真实网络往返 (无需 API key) =====

const testing = std.testing;

/// 单连接 mock server: 收一条 HTTP 请求, 回固定 OpenAI 兼容 JSON
const MockServerCtx = struct {
    io: std.Io,
    port: u16,
    /// 默认回 OpenAI 兼容形状; anthropic 用例换 anthropic 形状
    response_body: []const u8 =
        \\{"id":"mock-1","object":"chat.completion","model":"mock-model","choices":[{"index":0,"message":{"role":"assistant","content":"你好, 来自本地 mock server 的回复"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}
    ,
    received: [16384]u8 = undefined,
    received_len: usize = 0,

    fn run(ctx: *MockServerCtx) void {
        ctx.serve() catch |err| {
            std.debug.print("[mock-llm-server] serve 失败: {t}\n", .{err});
        };
    }

    fn serve(ctx: *MockServerCtx) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", ctx.port);
        var server = try address.listen(ctx.io, .{ .reuse_address = true });
        defer server.deinit(ctx.io);

        var stream: std.Io.net.Stream = try server.accept(ctx.io);
        defer stream.close(ctx.io);

        // 读到 headers 结束 + Content-Length 满足
        var header_end: usize = 0;
        var content_len: usize = 0;
        while (ctx.received_len < ctx.received.len) {
            if (header_end == 0) {
                if (std.mem.indexOf(u8, ctx.received[0..ctx.received_len], "\r\n\r\n")) |he| {
                    header_end = he + 4;
                    content_len = parseContentLength(ctx.received[0..header_end]);
                }
            }
            if (header_end > 0 and ctx.received_len >= header_end + content_len) break;
            const n = try net_read.readChunk(&stream, ctx.io, @constCast(&[_][]u8{ctx.received[ctx.received_len..]}));
            if (n == 0) break;
            ctx.received_len += n;
        }

        const body = ctx.response_body;
        var head_buf: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len});
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(ctx.io, &wbuf);
        try w.interface.writeAll(head);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }
};

fn parseContentLength(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const lower = std.ascii.allocLowerString(testing.allocator, line) catch return 0;
        defer testing.allocator.free(lower);
        if (std.mem.startsWith(u8, lower, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10) catch 0;
        }
    }
    return 0;
}

test "HttpLLM: openai_compat 经本地 mock server 完成 HTTP 往返" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 在候选端口上找可用的 (避免 CI 端口冲突)
    var ctx: MockServerCtx = .{ .io = io, .port = 0 };
    const candidate_ports = [_]u16{ 19871, 19872, 19873, 19874 };
    var probe: ?u16 = null;
    for (candidate_ports) |p| {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", p) catch continue;
        var srv = address.listen(io, .{ .reuse_address = true }) catch continue;
        srv.deinit(io);
        probe = p;
        break;
    }
    try testing.expect(probe != null);
    ctx.port = probe.?;

    const thread = try std.Thread.spawn(.{}, MockServerCtx.run, .{&ctx});

    const base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{ctx.port});
    var llm = try HttpLLM.openai(alloc, io, "mock-model", "test-key", base_url);
    defer llm.deinit();
    defer alloc.free(base_url);
    var chat = llm.asChat();
    var resp = try chat.complete(.{
        .model = "mock-model",
        .messages = &.{
            .{ .role = .user, .content = "帮我诊断 daemon" },
        },
        .max_tokens = 64,
    }, alloc);
    defer resp.deinit();

    thread.join();

    // 响应侧: content / usage / 统计
    try testing.expect(resp.content != null);
    try testing.expectEqualStrings("你好, 来自本地 mock server 的回复", resp.content.?);
    try testing.expectEqual(@as(u32, 11), resp.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 7), resp.usage.completion_tokens);
    try testing.expectEqual(@as(u64, 1), llm.total_calls);

    // 请求侧: mock server 实际收到了什么
    const req = ctx.received[0..ctx.received_len];
    try testing.expect(std.mem.indexOf(u8, req, "POST /v1/chat/completions") != null);
    try testing.expect(std.mem.indexOf(u8, req, "authorization: Bearer test-key") != null);
    try testing.expect(std.mem.indexOf(u8, req, "帮我诊断 daemon") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"model\":\"mock-model\"") != null);
}

test "HttpLLM: anthropic 头与端点 (本地 mock server)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: MockServerCtx = .{ .io = io, .port = 0, .response_body =
        \\{"id":"msg_mock_1","type":"message","role":"assistant","model":"claude-mock","content":[{"type":"text","text":"anthropic mock 回复"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":3}}
    };
    const candidate_ports = [_]u16{ 19881, 19882, 19883, 19884 };
    var probe: ?u16 = null;
    for (candidate_ports) |p| {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", p) catch continue;
        var srv = address.listen(io, .{ .reuse_address = true }) catch continue;
        srv.deinit(io);
        probe = p;
        break;
    }
    try testing.expect(probe != null);
    ctx.port = probe.?;

    const thread = try std.Thread.spawn(.{}, MockServerCtx.run, .{&ctx});

    const base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{ctx.port});
    var llm = try HttpLLM.anthropicWithBase(alloc, io, "claude-mock", "ant-key", base_url);
    defer llm.deinit();
    defer alloc.free(base_url);
    var chat = llm.asChat();
    var resp = try chat.complete(.{
        .model = "claude-mock",
        .messages = &.{
            .{ .role = .user, .content = "review this" },
        },
        .max_tokens = 64,
    }, alloc);
    defer resp.deinit();

    thread.join();

    try testing.expectEqualStrings("anthropic mock 回复", resp.content.?);
    try testing.expectEqual(@as(u32, 5), resp.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 3), resp.usage.completion_tokens);
    try testing.expectEqual(@as(u64, 1), llm.total_calls);

    const req = ctx.received[0..ctx.received_len];
    try testing.expect(std.mem.indexOf(u8, req, "POST /v1/messages") != null);
    try testing.expect(std.mem.indexOf(u8, req, "x-api-key: ant-key") != null);
    try testing.expect(std.mem.indexOf(u8, req, "anthropic-version:") != null);
}
