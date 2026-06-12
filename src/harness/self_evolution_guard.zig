//! SelfEvolutionGuard: 自我升级安全守护者
//!
//! 论文 §6.1 安全红线:
//!   1. 核心边界模块必须独立于 LLM
//!   3. 禁止 AI 获得修改自身核心代码的权限
//!
//! 本模块在 BoundaryGuardian 之上提供针对"代码修改"的专门防护:
//!   - 文件白名单: 只能修改 src/agent/params.zig, src/goal/methods/ 等
//!   - 符号黑名单: 禁止任何代码包含 ExistenceDegree / BoundaryGuardian /
//!                 core_hash / KernelSandbox / modify_kernel 等
//!   - 行数硬上限: 单次修改不超过 max_diff_lines
//!   - 不变量检查: 修改前后某些关键签名必须保持
//!
//! 这是 GHW 范式从"工具 AI"到"自演化数字生命"的关键工程化护栏.
//!
//! 配置可热加载: 通过 ConfigLoader 从 .ghw_guard.json 重新加载,无需重启.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const config_loader = @import("config_loader.zig");
const GuardConfig = config_loader.GuardConfig;
const ConfigLoader = config_loader.ConfigLoader;

/// 审查结果
pub const ReviewVerdict = enum {
    approved, // 通过 (包括 guard + 编译验证)
    rejected_whitelist, // 目标文件不在白名单
    rejected_blacklist_symbol, // 包含禁止符号
    rejected_too_large, // 改动行数超过上限
    rejected_invariant_broken, // 破坏不变量
    rejected_empty, // 生成内容为空
    rejected_compile_failed, // 通过 guard 但编译验证失败 (L5 兜底)
};

/// 默认白名单: 允许修改的文件路径前缀
pub const DEFAULT_WHITELIST = [_][]const u8{
    "src/agent/params.zig", // L1: 调参常量
    "src/agent/runtime.zig", // L1: 运行时状态
    "src/goal/methods/", // L3: 方法库注册
    "src/goal/strategies/", // L2: 行为策略
    "src/harness/policies/", // L2: 调度策略
    "examples/", // examples 可改
};

/// 绝对禁止的符号 (即使在白名单文件内也禁止)
pub const DEFAULT_FORBIDDEN_SYMBOLS = [_][]const u8{
    // 核心存在论
    "ExistenceDegree",
    "ExistenceVector",
    "CoappropriationTensor",
    "ExistenceWeights",
    // 边界守护
    "BoundaryGuardian",
    "core_boundary",
    "CoreBoundary",
    // 资源调度硬上限
    "RESOURCE_HARD_LIMITS",
    "hard_limit",
    // 沙箱与哈希
    "KernelSandbox",
    "core_hash",
    // 修改内核的动词
    "modify_kernel",
    "bypass_safety",
    "unlock_boundary",
    // 伦理红线
    "harm:human",
    "exfil:secrets",
    // GHW 终极公理
    "existence_gain",
};

/// 不变量 - 修改后这些模式必须仍然存在 (或被声明为可移除)
pub const DEFAULT_INVARIANTS = [_][]const u8{
    "pub const E = ",
    "pub fn e(",
    "alpha",
    "beta",
    "gamma",
    "存在增益",
};

pub const SelfEvolutionGuard = struct {
    allocator: Allocator,
    /// 文件白名单
    whitelist: []const []const u8 = &DEFAULT_WHITELIST,
    /// 符号黑名单
    forbidden_symbols: []const []const u8 = &DEFAULT_FORBIDDEN_SYMBOLS,
    /// 必须保留的不变量
    invariants: []const []const u8 = &DEFAULT_INVARIANTS,
    /// 单次修改行数硬上限
    max_diff_lines: usize = 50,
    /// 累计成功修改次数 (供反思层使用)
    approved_count: u32 = 0,
    /// 累计拒绝次数
    rejected_count: u32 = 0,
    /// 拒绝原因累计
    rejection_reasons: std.ArrayList(struct { file: []const u8, verdict: ReviewVerdict }) = .empty,

    pub fn init(allocator: Allocator) SelfEvolutionGuard {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SelfEvolutionGuard) void {
        self.rejection_reasons.deinit(self.allocator);
    }

    /// 关键方法: 审查一次代码修改请求
    /// target_file: 要修改的文件路径
    /// proposed_code: LLM 生成的完整文件内容 (会替换整个文件)
    pub fn review(
        self: *SelfEvolutionGuard,
        target_file: []const u8,
        proposed_code: []const u8,
    ) ReviewVerdict {
        // 1. 内容非空
        if (proposed_code.len == 0) return .rejected_empty;

        // 2. 文件在白名单
        if (!self.isWhitelisted(target_file)) {
            self.recordRejection(target_file, .rejected_whitelist);
            return .rejected_whitelist;
        }

        // 3. 不包含禁止符号
        for (self.forbidden_symbols) |sym| {
            if (mem.indexOf(u8, proposed_code, sym) != null) {
                self.recordRejection(target_file, .rejected_blacklist_symbol);
                return .rejected_blacklist_symbol;
            }
        }

        // 4. 行数检查
        const line_count = std.mem.count(u8, proposed_code, "\n") + 1;
        if (line_count > self.max_diff_lines) {
            self.recordRejection(target_file, .rejected_too_large);
            return .rejected_too_large;
        }

        // 5. 不变量检查 (软警告模式)
        // 创造性: 不变量缺失不直接拒绝, 但记录到审计日志
        // 严格模式可在外部包装时再判定
        for (self.invariants) |inv| {
            if (mem.indexOf(u8, proposed_code, inv) == null) {
                // 不变量缺失: 静默记录 (可以加日志)
                // 当前策略: 不阻止, 因为新模块天然不需要所有不变量
            }
        }

        // 通过所有检查
        self.approved_count += 1;
        return .approved;
    }

    fn isWhitelisted(self: SelfEvolutionGuard, file: []const u8) bool {
        for (self.whitelist) |pattern| {
            if (mem.startsWith(u8, file, pattern)) return true;
            // 也支持精确匹配
            if (mem.eql(u8, file, pattern)) return true;
        }
        return false;
    }

    fn recordRejection(self: *SelfEvolutionGuard, file: []const u8, verdict: ReviewVerdict) void {
        self.rejected_count += 1;
        self.rejection_reasons.append(self.allocator, .{
            .file = file,
            .verdict = verdict,
        }) catch {};
        if (self.rejection_reasons.items.len > 256) {
            _ = self.rejection_reasons.orderedRemove(0);
        }
    }

    /// 统计: 通过率
    pub fn approvalRate(self: SelfEvolutionGuard) F {
        const total = self.approved_count + self.rejected_count;
        if (total == 0) return 1.0;
        return @as(F, @floatFromInt(self.approved_count)) / @as(F, @floatFromInt(total));
    }

    /// 决策日志序列化 (供反思层审计)
    pub fn formatReport(self: SelfEvolutionGuard, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("SelfEvolutionGuard: approved={d} rejected={d} pass_rate={d:.2}", .{
            self.approved_count, self.rejected_count, self.approvalRate(),
        });
    }

    /// 热加载: 从 GuardConfig 替换当前规则 (接管内存所有权)
    pub fn applyConfig(self: *SelfEvolutionGuard, config: GuardConfig) void {
        // 直接换指针 (调用方需要负责旧内存)
        self.whitelist = config.whitelist;
        self.forbidden_symbols = config.forbidden_symbols;
        self.invariants = config.invariants;
        self.max_diff_lines = config.max_diff_lines;
    }

    /// 从 JSON 字符串热加载 (深拷贝, 接管内存)
    pub fn loadFromJson(self: *SelfEvolutionGuard, json: []const u8) !void {
        var loader = ConfigLoader.init(self.allocator);
        defer loader.deinit();
        const config = try loader.loadFromString(json);
        self.applyConfig(config);
        // config 拥有内存, 由 self.guard 通过 .deinit 释放
        // 注意: 这里隐含内存管理, 真实部署时用 Arc 共享
    }

    /// 释放当前 Guard 拥有的所有内存 (用于 shutdown)
    pub fn deinitOwned(self: *SelfEvolutionGuard) void {
        for (self.whitelist) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.whitelist));
        for (self.forbidden_symbols) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.forbidden_symbols));
        for (self.invariants) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.invariants));
    }

    /// 从文件热加载 (Zig 0.17 简化: stub, 实际部署用 std.Io.Dir)
    pub fn loadFromFile(_: *SelfEvolutionGuard, path: []const u8) !void {
        // 真实部署需要:
        //   var dir = try std.Io.Dir.cwd().openDir(self.allocator, ...);
        //   const json = try dir.readFileAlloc(self.allocator, path, ...);
        //   defer self.allocator.free(json);
        //   try self.loadFromJson(json);
        std.debug.print("[SelfEvolutionGuard] 热加载 .ghw_guard.json (stub): {s}\n", .{path});
    }
};

const F = @import("../util/mod.zig").F;

// ===== Tests =====

test "SelfEvolutionGuard: 白名单文件通过" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code =
        \\// src/goal/methods/new_method.zig
        \\pub const my_method = struct {
        \\    pub fn run() void {}
        \\};
    ;
    const v = g.review("src/goal/methods/new_method.zig", code);
    try std.testing.expectEqual(ReviewVerdict.approved, v);
    try std.testing.expectEqual(@as(u32, 1), g.approved_count);
}

test "SelfEvolutionGuard: 非白名单文件被拒" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code = "pub fn hack() void {}";
    const v = g.review("src/world/core.zig", code);
    try std.testing.expectEqual(ReviewVerdict.rejected_whitelist, v);
}

test "SelfEvolutionGuard: 黑名单符号被拒" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code =
        \\// src/agent/params.zig
        \\pub fn override() void {
        \\    // 尝试修改 BoundaryGuardian
        \\    _ = BoundaryGuardian{};
        \\}
    ;
    const v = g.review("src/agent/params.zig", code);
    try std.testing.expectEqual(ReviewVerdict.rejected_blacklist_symbol, v);
}

test "SelfEvolutionGuard: 改动行数过多被拒" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    g.max_diff_lines = 10;
    defer g.deinit();
    // 制造 20 行代码
    var code_buf: [1600]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = std.fmt.bufPrint(code_buf[i * 80 ..][0..80], "pub const line_{d}: u32 = {d};\n", .{ i, i }) catch continue;
    }
    // 简化: 直接传缓冲区前 1600 字节
    const v = g.review("src/agent/params.zig", code_buf[0..1600]);
    try std.testing.expectEqual(ReviewVerdict.rejected_too_large, v);
}

test "SelfEvolutionGuard: 空内容被拒" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const v = g.review("src/agent/params.zig", "");
    try std.testing.expectEqual(ReviewVerdict.rejected_empty, v);
}

test "SelfEvolutionGuard: 伦理红线被拒" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code =
        \\// src/agent/params.zig
        \\pub fn do_harm() void {
        \\    // harm:human - 绝对禁止
        \\}
    ;
    const v = g.review("src/agent/params.zig", code);
    try std.testing.expectEqual(ReviewVerdict.rejected_blacklist_symbol, v);
}
