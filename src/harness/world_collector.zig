//! WorldCollector: 用 autocli / 其他 CLI 工具从外部世界获取数据
//!
//! 数字生命的"世界知识"不能只来自它自己的 toy 模型 — 必须能从真实世界拉数据
//! autocli 是"通用命令行 AI 助手" — 可以:
//!   - 搜索互联网
//!   - 读网页/文档
//!   - 执行 shell 命令
//!   - 查天气/股票/新闻
//!
//! 设计: WorldCollector 是一个"外部观察通道", 输出和 Information 同构
//! (id + label + 4 维特征) — 这样能直接喂给 GHWAgent.runCycle
//!
//! 用法:
//!   var wc = WorldCollector.init(alloc, io, "autocli");
//!   defer wc.deinit();
//!   const info = try wc.collect("当前 AI 领域有什么新进展", 5);  // 拉 5 条
//!   defer info.deinit();
//!   for (info.items) |i| { ... }

const std = @import("std");
const Allocator = std.mem.Allocator;
const F = @import("../util/math.zig").F;
const Information = @import("../goal/core.zig").Information;
const LCG = @import("../util/math.zig").LCG;

pub const WorldData = struct {
    items: []Information,
    raw_output: []u8, // autocli 原始输出, 供审计
    allocator: Allocator,
    rng: LCG,

    pub fn deinit(self: *WorldData) void {
        for (self.items) |item| {
            self.allocator.free(item.label);
        }
        self.allocator.free(self.items);
        self.allocator.free(self.raw_output);
    }
};

pub const WorldCollector = struct {
    allocator: Allocator,
    io: std.Io,
    /// 命令名, 默认 "autocli"
    command: []u8,
    /// 子命令, 默认 "ask" (autocli 的子命令)
    subcommand: []u8,
    /// LCG 种子, 用于 id 生成
    rng: LCG,
    /// 调用统计
    call_count: u64 = 0,
    total_chars: u64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, command: []const u8) !WorldCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .command = try allocator.dupe(u8, command),
            .subcommand = try allocator.dupe(u8, "ask"),
            .rng = LCG.init(@intCast(std.time.milliTimestamp())),
        };
    }

    pub fn deinit(self: *WorldCollector) void {
        self.allocator.free(self.command);
        self.allocator.free(self.subcommand);
    }

    /// 调 autocli 拉一次, 解析成 Information
    pub fn collect(self: *WorldCollector, query: []const u8, max_items: u32) !WorldData {
        self.call_count += 1;

        // 构造 argv: autocli ask "query"
        const argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.command);
        try argv.append(self.allocator, self.subcommand);
        try argv.append(self.allocator, query);
        try argv.append(self.allocator, "--max-tokens=1024");

        // 用 std.process.run (Zig 0.17 真实 subprocess)
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch |err| {
            std.debug.print("[WorldCollector] subprocess failed: {t}\n", .{err});
            return self.emptyResult();
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("[WorldCollector] autocli exit code: {}, stderr: {s}\n", .{
                if (result.term == .exited) result.term.exited else 0,
                result.stderr,
            });
            return self.emptyResult();
        }

        const output = result.stdout;
        self.total_chars += @intCast(output.len);
        return parseOutput(self.allocator, &self.rng, output, max_items);
    }

    fn emptyResult(self: *WorldCollector) WorldData {
        return .{
            .items = &[_]Information{},
            .raw_output = self.allocator.dupe(u8, "") catch &[_]u8{},
            .allocator = self.allocator,
            .rng = self.rng,
        };
    }
};

/// 把 autocli 的输出解析成 Information 列表
/// 简单策略: 按行分割, 每行用启发式生成 4 维特征
fn parseOutput(alloc: Allocator, rng: *LCG, output: []const u8, max_items: u32) WorldData {
    var items: std.ArrayList(Information) = .empty;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);

    const raw_dup: []u8 = alloc.dupe(u8, output) catch &[_]u8{};
    errdefer alloc.free(raw_dup);
    var id_counter: u64 = 0;

    var i: usize = 0;
    while (i < output.len) {
        if (output[i] == '\n' or i == output.len - 1) {
            const end = if (output[i] == '\n') i else i + 1;
            if (line_buf.items.len > 0 and line_buf.items.len < 512) {
                // 跳过空行和 markdown 标题
                if (line_buf.items[0] != '#' and line_buf.items[0] != ' ') {
                    const label = alloc.dupe(u8, line_buf.items) catch "";
                    const features = deriveFeatures(line_buf.items, rng);
                    items.append(alloc, .{
                        .id = id_counter,
                        .label = label,
                        .features = features,
                    }) catch continue;
                    id_counter += 1;
                    if (items.items.len >= max_items) break;
                }
            }
            line_buf.clearRetainingCapacity();
            i = end + 1;
        } else {
            line_buf.append(alloc, output[i]) catch break;
            i += 1;
        }
    }

    return .{
        .items = items.toOwnedSlice(alloc) catch &[_]Information{},
        .raw_output = raw_dup,
        .allocator = alloc,
        .rng = rng.*,
    };
}

/// 启发式: 从文本行推 4 维特征
///  - resonance: 长度 (越长越能引起共鸣)
///  - impact: 是否含数字/百分比/钱 ($ %, number)
///  - novelty: 含问号/感叹号/特殊词 (new/新/突/首次)
///  - cost: 行长度惩罚 (越长越贵)
fn deriveFeatures(line: []const u8, rng: *LCG) [4]F {
    const len = @as(F, @floatFromInt(line.len));
    const base_resonance = @min(0.9, len / 200.0);
    const resonance = base_resonance + rng.float() * 0.1;

    var impact: F = 0.3;
    for (line) |c| {
        if (c == '%' or c == '$' or c == '¥' or (c >= '0' and c <= '9')) {
            impact += 0.15;
        }
    }
    impact = @min(0.95, impact);

    var novelty: F = 0.3;
    if (std.mem.indexOf(u8, line, "?") != null or std.mem.indexOf(u8, line, "新") != null or std.mem.indexOf(u8, line, "新") != null or std.mem.indexOf(u8, line, "首") != null) {
        novelty += 0.3;
    }
    novelty = @min(0.95, novelty + rng.float() * 0.1);

    const cost: F = @min(0.95, len / 500.0);

    return .{ resonance, impact, novelty, cost };
}
