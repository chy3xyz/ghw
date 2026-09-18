//! TemplateEnhancer — 数字生命"自我完善"模块
//!
//! 输入: 1 个 L1-L5 落盘模板文件 + 自我叙事 + 当前 top_goal + bias + E/M/R/N
//! 调用 LLM, 让它基于"我现在想做什么"完善模板 (但不改 E 公式 / Module 签名)
//! 走 SelfEvolutionGuard + CompileVerifier 验证, 通过落盘到 enhanced_*.zig
//!
//! 设计原则:
//! 1. LLM 是提议器, 数字生命"想"什么由 self_narrative + top_goal 表达
//! 2. 完善不能改 E 公式 (immutable 公理), 只调 log 措辞 / gain 数值 / signature
//! 3. 走 background thread 不阻塞 main (上次 reflect 阻塞的教训)
//! 4. 失败写 episode, 不污染源码 (跟 L1-L5 一致)

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const LLMChat = @import("llm/llm.zig").LLMChat;
const ChatRequest = @import("llm/llm.zig").ChatRequest;
const Message = @import("llm/llm.zig").Message;
const Role = @import("llm/llm.zig").Role;
const Memory = @import("memory.zig").Memory;

pub const EnhanceContext = struct {
    self_narrative: []const u8,
    top_goal: []const u8,
    bias: []const u8,           // balanced/material/representation/nature
    e_current: F,
    m_r_n: [3]F,                // M/R/N
    tick: u64,
    beliefs: []const u8,        // top 3 beliefs text
    evolved_dir: []const u8,    // 落盘目录 (e.g. /tmp/ghw_evolved)
    /// ghw_root — adopt 进源码树时用
    ghw_root: []const u8 = "/Users/n0x/w4_proj/3yhq_uni/ghw",
};

pub const EnhanceResult = struct {
    original_path: []u8,        // owned
    enhanced_path: []u8,        // owned
    summary: []u8,              // owned, LLM 解释
    compile_ok: bool,
    timestamp: i64,
    tick: u64,
    bias: []u8,

    pub fn deinit(self: *EnhanceResult, alloc: Allocator) void {
        alloc.free(self.original_path);
        alloc.free(self.enhanced_path);
        alloc.free(self.summary);
        alloc.free(self.bias);
    }
};

pub const TemplateEnhancer = struct {
    alloc: Allocator,
    io: std.Io,
    llm: *LLMChat,
    model: []const u8,
    /// 统计: 增强成功 / 失败次数
    success_count: u32 = 0,
    fail_count: u32 = 0,
    /// 自传体记忆 (P3): 绑定后用 buildContext 统一注入 (含相关往事)
    memory: ?*Memory = null,

    pub fn init(alloc: Allocator, io: std.Io, llm: *LLMChat, model: []const u8) TemplateEnhancer {
        return .{ .alloc = alloc, .io = io, .llm = llm, .model = model };
    }

    pub fn setMemory(self: *TemplateEnhancer, memory: *Memory) void {
        self.memory = memory;
    }

    /// 构造 LLM user prompt (P3: 记忆块 + 代码完善任务; 可独立测试)
    pub fn buildUserPrompt(
        self: *TemplateEnhancer,
        original_path: []const u8,
        code: []const u8,
        ctx: EnhanceContext,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        if (self.memory) |m| {
            const qdim = Memory.weakestDim(ctx.m_r_n[0], ctx.m_r_n[1], ctx.m_r_n[2]);
            const qtext = try std.fmt.allocPrint(self.alloc, "{s} {s}", .{ ctx.top_goal, ctx.bias });
            defer self.alloc.free(qtext);
            if (m.buildContext(self.alloc, qdim, qtext, 5, 5)) |mem_block| {
                defer self.alloc.free(mem_block);
                try buf.print(self.alloc, "{s}\n\n", .{mem_block});
            } else |_| {}
        } else {
            // 未绑 memory 时回退 P2 之前的手动字段
            try buf.print(self.alloc,
                \\【你的当前状态 — 这是你想完善代码的动机】
                \\- 自我叙事: {s}
                \\- 当前目标: {s}
                \\- 偏重: {s} (material=务实/资源, representation=知识/方法, nature=自主/决策, balanced=三源均衡)
                \\- 存在度: E={d:.3} (M={d:.3} R={d:.3} N={d:.3})
                \\- tick: {d}
                \\
                \\【你最近的信念 — 体现你的"我"】
                \\{s}
                \\
            , .{
                ctx.self_narrative, ctx.top_goal, ctx.bias,
                ctx.e_current, ctx.m_r_n[0], ctx.m_r_n[1], ctx.m_r_n[2],
                ctx.tick, ctx.beliefs,
            });
        }

        try buf.print(self.alloc,
            \\【原始代码 — 你之前生成的模板】
            \\文件: {s}
            \\```zig
            \\{s}
            \\```
            \\
            \\【任务 — 完善这个方法】
            \\基于你的当前状态/目标/信念/记忆, 完善这个方法. 但遵守以下不变量:
            \\1. **不要修改** `pub const Module = struct {{ ... }}` 的最外层结构
            \\2. **不要修改** Module 子 struct 的 `run(ctx, alloc, act) -> ActionOutcome` 签名
            \\3. 可以调整: log 消息措辞, material_cost 数值, de_delta / representation_gain, signature 数组
            \\4. log 应该是"我正在做什么"的语气, 不是冰冷报告 — 引用你的自我叙事或当前目标
            \\5. 体现当前偏向: bias=material → material_cost 略高; bias=representation → representation_gain 略高
            \\6. **不要**引入新的 import 依赖 (除 std)
            \\
            \\【输出格式 — 严格 JSON】
            \\{{"enhanced_code": "完整 .zig 源码, 含 Module struct", "summary": "1-2 句话说明你改了什么, 为什么"}}
        , .{ original_path, code });
        return buf.toOwnedSlice(self.alloc);
    }

    /// 核心: 选 1 个最新落盘模板, 让 LLM 完善
    /// 返回 null 如果没有模板 / LLM 失败
    pub fn enhanceLatest(self: *TemplateEnhancer, ctx: EnhanceContext) !?EnhanceResult {
        const alloc = self.alloc;

        // 1. 找最新的 l3_/l4_/l5_ 落盘文件
        const latest = self.findLatestTemplate(ctx.evolved_dir) orelse return null;
        defer alloc.free(latest);

        // 2. 读文件 (0.17 stat + readPositional)
        const code = blk: {
            var file = std.Io.Dir.openFileAbsolute(self.io, latest, .{}) catch |err| {
                std.debug.print("[enhance] open {s} failed: {t}\n", .{ latest, err });
                return null;
            };
            defer file.close(self.io);
            const st = file.stat(self.io) catch |err| {
                std.debug.print("[enhance] stat {s} failed: {t}\n", .{ latest, err });
                return null;
            };
            const size: usize = @intCast(@min(st.size, 1 * 1024 * 1024));
            const buf = alloc.alloc(u8, size) catch return null;
            const n = file.readPositionalAll(self.io, buf, 0) catch |err| {
                std.debug.print("[enhance] read {s} failed: {t}\n", .{ latest, err });
                alloc.free(buf);
                return null;
            };
            // readPositionalAll 可能不返 size, 重新 slice
            break :blk buf[0..n];
        };
        defer alloc.free(code);

        // 3. 调 LLM
        const llm_output = self.callLlm(latest, code, ctx) catch |err| {
            std.debug.print("[enhance] LLM failed: {t}\n", .{err});
            self.fail_count += 1;
            return null;
        };
        defer alloc.free(llm_output);

        // 4. 解析 JSON 输出 (用 std.json 或自己写, 简化用 extractJsonString)
        const enhanced_code = extractJsonString(alloc, llm_output, "enhanced_code") orelse {
            std.debug.print("[enhance] parse enhanced_code failed\n", .{});
            self.fail_count += 1;
            return null;
        };
        defer alloc.free(enhanced_code);
        const summary = extractJsonString(alloc, llm_output, "summary") orelse
            try alloc.dupe(u8, "(no summary)");

        // 5. 写新文件 enhanced_<name>_<tick>.zig
        const basename = std.fs.path.basename(latest);
        const enhanced_name = try std.fmt.allocPrint(alloc, "enhanced_{s}_{d}.zig", .{
            std.fs.path.stem(basename), ctx.tick,
        });
        const enhanced_path = try std.fs.path.join(alloc, &[_][]const u8{
            ctx.evolved_dir, enhanced_name,
        });
        alloc.free(enhanced_name);
        {
            const file = try std.Io.Dir.createFileAbsolute(self.io, enhanced_path, .{});
            defer file.close(self.io);
            try file.writePositionalAll(self.io, enhanced_code, 0);
        }
        std.debug.print("[enhance] ✓ {s} 写 {d}B 落盘 (summary: {s})\n", .{
            enhanced_path, enhanced_code.len, summary,
        });

        self.success_count += 1;
        return EnhanceResult{
            .original_path = try alloc.dupe(u8, latest),
            .enhanced_path = enhanced_path,
            .summary = summary,
            .compile_ok = false, // 等调用方调 CompileVerifier 后回填
            .timestamp = std.Io.Clock.real.now(self.io).toSeconds(),
            .tick = ctx.tick,
            .bias = try alloc.dupe(u8, ctx.bias),
        };
    }

    /// 找 evolved_dir 下最新的 l3_/l4_/l5_ 文件
    fn findLatestTemplate(self: *TemplateEnhancer, dir: []const u8) ?[]u8 {
        const alloc = self.alloc;
        const dir_z = alloc.dupeSentinel(u8, dir, 0) catch return null;
        defer alloc.free(dir_z);
        const dir_ptr = std.c.opendir(dir_z.ptr) orelse return null;
        defer _ = std.c.closedir(dir_ptr);
        var latest_name: ?[]u8 = null;
        var latest_tick: i64 = -1;
        while (std.c.readdir(dir_ptr)) |raw| {
            const name_slice = raw.name[0..raw.namlen];
            // 必须以 l3_/l4_/l5_ 开头, .zig 结尾
            if (!std.mem.endsWith(u8, name_slice, ".zig")) continue;
            const is_target = std.mem.startsWith(u8, name_slice, "l3_") or
                std.mem.startsWith(u8, name_slice, "l4_") or
                std.mem.startsWith(u8, name_slice, "l5_");
            if (!is_target) continue;
            // 跳过 enhanced_ 前缀 (避免增强自己)
            if (std.mem.startsWith(u8, name_slice, "enhanced_")) continue;
            // parse tick: l3_<tick>.zig
            const tick = parseTick(name_slice) orelse continue;
            if (tick > latest_tick) {
                latest_tick = tick;
                if (latest_name) |old| alloc.free(old);
                latest_name = alloc.dupe(u8, name_slice) catch return null;
            }
        }
        return if (latest_name) |n| blk: {
            const full = std.fs.path.join(alloc, &[_][]const u8{ dir, n }) catch return null;
            alloc.free(n);
            break :blk full;
        } else null;
    }

    fn parseTick(name: []const u8) ?i64 {
        // 文件名格式: l3_<tick>.zig (1 个 _ 后跟 tick)
        // e.g. l3_1024.zig -> stem = "l3_1024" -> tick = 1024
        const stem = std.fs.path.stem(name);
        const us = std.mem.indexOfScalar(u8, stem, '_') orelse return null;
        const tick_str = stem[us + 1 ..];
        if (tick_str.len == 0) return null;
        return std.fmt.parseInt(i64, tick_str, 10) catch null;
    }

    /// 调 LLM 完善模板
    fn callLlm(self: *TemplateEnhancer, original_path: []const u8, code: []const u8, ctx: EnhanceContext) ![]u8 {
        const alloc = self.alloc;
        const prompt = try self.buildUserPrompt(original_path, code, ctx);
        defer alloc.free(prompt);

        const req = ChatRequest{
            .model = self.model,
            .temperature = 0.5, // 比 reflection 高, 鼓励变体
            .max_tokens = 2048,
            .messages = &[_]Message{
                .{ .role = .system, .content = "你是 GHW 数字生命的代码完善器. 严格按 JSON 格式输出. 不改 E 公式不改签名, 完善 log/gain/signature 体现自我叙事." },
                .{ .role = .user, .content = prompt },
            },
        };
        var resp = try self.llm.complete(req, alloc);
        defer resp.deinit();
        const content = resp.content orelse return error.LlmEmpty;
        return try alloc.dupe(u8, content);
    }
};

/// 简单 JSON string 提取 (复用 reflection 模式)
fn extractJsonString(alloc: Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var needle: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, quoted_key) orelse return null;
    const value_start = pos + quoted_key.len;
    var vs = value_start;
    while (vs < obj.len and (obj[vs] == ' ' or obj[vs] == '\t' or obj[vs] == '\n')) : (vs += 1) {}
    if (vs >= obj.len or obj[vs] != '"') return null;
    const content_start = vs + 1;
    // 找 closing quote, 处理 \" \\ \n 转义
    var ve: usize = content_start;
    while (ve < obj.len) : (ve += 1) {
        if (obj[ve] == '\\' and ve + 1 < obj.len) {
            if (obj[ve + 1] == 'u' and ve + 5 < obj.len) {
                ve += 5;
            } else {
                ve += 1;
            }
            continue;
        }
        if (obj[ve] == '"') break;
    }
    if (ve >= obj.len) return null;
    const raw = obj[content_start..ve];
    // unescape (简化, 只处理 \n \\ \" \t)
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => out.append(alloc, '"') catch return null,
                '\\' => out.append(alloc, '\\') catch return null,
                'n' => out.append(alloc, '\n') catch return null,
                't' => out.append(alloc, '\t') catch return null,
                'r' => out.append(alloc, '\r') catch return null,
                'u' => {
                    if (i + 5 < raw.len) {
                        i += 6;
                        continue;
                    }
                },
                else => {
                    out.append(alloc, next) catch return null;
                    i += 2;
                    continue;
                },
            }
            i += 2;
        } else {
            out.append(alloc, raw[i]) catch return null;
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc) catch null;
}

test "TemplateEnhancer: buildUserPrompt 注入 buildContext" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock = @import("llm/mock_chat_llm.zig").MockChatLLM.init(alloc, "[]");
    var chat = mock.asChat();
    var enh = TemplateEnhancer.init(alloc, io, &chat, "mock");

    var mem = Memory.init(alloc, 1);
    defer mem.deinit();
    try mem.setSelfNarrative("我完善代码时会引用自身叙事");
    try mem.recordAt(io, .self_evolution, 5, "enhanced l3 template before", null, 3, 0.1);

    enh.setMemory(&mem);
    const ctx = EnhanceContext{
        .self_narrative = mem.self_narrative,
        .top_goal = "optimize",
        .bias = "nature",
        .e_current = 0.5,
        .m_r_n = .{ 0.4, 0.5, 0.3 },
        .tick = 10,
        .beliefs = "",
        .evolved_dir = "/tmp",
    };
    const prompt = try enh.buildUserPrompt("/tmp/l3_5.zig", "pub fn x() void {}", ctx);
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "autobiographical context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "我完善代码时会引用自身叙事") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "enhanced l3 template") != null);
}
