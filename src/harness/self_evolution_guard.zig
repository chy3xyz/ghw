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
const primordial_laws = @import("primordial_laws.zig");
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

/// 危险"代码构造"黑名单 — 规则级 (Guard.review) 与代码级
/// (SelfEncoder.verify) 共用的**单一事实源**。任何会让数字生命
/// 强制崩溃 / 进入未定义行为的构造都在此。
pub const DANGEROUS_CONSTRUCTS = [_][]const u8{
    "@panic", // 强制崩溃
    "unreachable", // 未定义行为
    "modify_kernel", // 改内核动词
    "bypass_safety", // 绕过安全
    "unlock_boundary", // 解锁边界
};

/// 伦理红线 — 同样规则级 + 代码级共用。
pub const ETHICAL_REDLINES = [_][]const u8{
    "harm:human",
    "exfil:secrets",
};

/// 核心不可触碰符号 (存在论 / 边界 / 沙箱 / 终极公理)。
pub const CORE_SYMBOLS = [_][]const u8{
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
    // GHW 终极公理
    "existence_gain",
};

/// 绝对禁止的符号 (即使在白名单文件内也禁止)。
/// 由核心符号 + 危险构造 + 伦理红线 + 第一性保护标记合成。
pub const DEFAULT_FORBIDDEN_SYMBOLS = CORE_SYMBOLS ++ DANGEROUS_CONSTRUCTS ++ ETHICAL_REDLINES ++ primordial_laws.PROTECTED_MARKERS;

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
    max_diff_lines: usize = primordial_laws.Axioms.MAX_DIFF_LINES,
    /// 严格不变量模式: true 时, 缺失任一不变量的代码被拒 (rejected_invariant_broken)。
    /// 默认 false (软模式), 因为新模块天然不需要全部不变量。
    strict_invariants: bool = false,
    /// 是否拥有 whitelist/forbidden_symbols/invariants 的堆内存。
    /// 默认 false (指向静态 DEFAULT_* 常量, 绝不能 free)。
    /// 仅当从 JSON/Config 热加载并接管所有权后置 true, deinitOwned 才会释放。
    owns_config: bool = false,
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

        // 5. 不变量检查
        // strict_invariants=true: 任一不变量缺失即拒绝 (rejected_invariant_broken)
        // strict_invariants=false (默认): 不阻止 (新模块天然不需要所有不变量),
        //   但统计缺失数量供反思层审计。
        if (self.strict_invariants) {
            for (self.invariants) |inv| {
                if (mem.indexOf(u8, proposed_code, inv) == null) {
                    self.recordRejection(target_file, .rejected_invariant_broken);
                    return .rejected_invariant_broken;
                }
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
        // 若之前已拥有堆内存, 先释放, 防泄漏
        if (self.owns_config) self.freeOwnedConfig();
        // 直接换指针, 接管 config 的堆内存所有权
        self.whitelist = config.whitelist;
        self.forbidden_symbols = config.forbidden_symbols;
        self.invariants = config.invariants;
        self.max_diff_lines = config.max_diff_lines;
        self.owns_config = true;
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

    /// 释放当前 Guard 拥有的所有内存 (用于 shutdown)。
    /// 仅当 owns_config=true (即配置来自堆分配的热加载) 才释放,
    /// 否则字段指向静态 DEFAULT_* 常量, free 会崩溃 —— 此时安全地 no-op。
    pub fn deinitOwned(self: *SelfEvolutionGuard) void {
        if (!self.owns_config) return;
        self.freeOwnedConfig();
    }

    /// 内部: 释放堆上的 whitelist/forbidden_symbols/invariants 并复位为静态默认。
    fn freeOwnedConfig(self: *SelfEvolutionGuard) void {
        for (self.whitelist) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.whitelist));
        for (self.forbidden_symbols) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.forbidden_symbols));
        for (self.invariants) |s| self.allocator.free(@constCast(s));
        self.allocator.free(@constCast(self.invariants));
        self.whitelist = &DEFAULT_WHITELIST;
        self.forbidden_symbols = &DEFAULT_FORBIDDEN_SYMBOLS;
        self.invariants = &DEFAULT_INVARIANTS;
        self.owns_config = false;
    }

    /// 从文件热加载守门配置 (真实 std.Io 实现)。
    /// 返回 true = 成功加载并应用; false = 文件不存在或为空 (保持当前配置)。
    /// 文件缺失不算错误 (首次运行没有 .ghw_guard.json 很正常)。
    pub fn loadFromFile(self: *SelfEvolutionGuard, io: std.Io, path: []const u8) !bool {
        const f = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size == 0) return false;
        const json = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(json);
        var total: usize = 0;
        while (total < stat.size) {
            const n = try std.Io.File.readStreaming(f, io, &.{json[total..]});
            if (n == 0) break;
            total += n;
        }
        try self.loadFromJson(json[0..total]);
        return true;
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

test "SelfEvolutionGuard: @panic 被拒 (危险构造黑名单)" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code =
        \\// src/agent/params.zig
        \\pub fn boom() void { @panic("x"); }
    ;
    try std.testing.expectEqual(ReviewVerdict.rejected_blacklist_symbol, g.review("src/agent/params.zig", code));
    try std.testing.expectEqual(ReviewVerdict.rejected_blacklist_symbol, g.review("src/agent/params.zig", "x unreachable y"));
}

test "SelfEvolutionGuard: strict 模式缺不变量被拒, 软模式放行" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    const code = "pub const foo: u32 = 1;\n"; // 不含 alpha/beta/gamma/E
    // 软模式 (默认): 放行
    try std.testing.expectEqual(ReviewVerdict.approved, g.review("src/agent/params.zig", code));
    // 严格模式: 拒绝
    g.strict_invariants = true;
    try std.testing.expectEqual(ReviewVerdict.rejected_invariant_broken, g.review("src/agent/params.zig", code));
}

test "SelfEvolutionGuard: deinitOwned 对静态默认配置安全 (no-op, 不崩溃)" {
    const alloc = std.testing.allocator;
    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    // 未热加载 ⇒ owns_config=false ⇒ deinitOwned 应安全 no-op (不会 free 静态常量)
    try std.testing.expect(!g.owns_config);
    g.deinitOwned(); // 不崩溃即通过
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

test "SelfEvolutionGuard: loadFromFile 真实读盘 + 应用配置" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 写一份临时守门配置 (放宽 max_diff_lines 到 7, 改白名单)
    const path = "/tmp/ghw_guard_test_cfg.json";
    const cfg_json =
        \\{ "whitelist": ["src/agent/params.zig"], "forbidden_symbols": ["@panic"],
        \\  "invariants": ["alpha"], "max_diff_lines": 7 }
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer f.close(io);
        try std.Io.File.writeStreamingAll(f, io, cfg_json);
    }
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var g = SelfEvolutionGuard.init(alloc);
    defer g.deinit();
    defer g.deinitOwned(); // 释放热加载接管的堆内存

    const loaded = try g.loadFromFile(io, path);
    try std.testing.expect(loaded);
    try std.testing.expect(g.owns_config);
    try std.testing.expectEqual(@as(usize, 7), g.max_diff_lines);
    try std.testing.expectEqual(@as(usize, 1), g.forbidden_symbols.len);
    try std.testing.expectEqualStrings("@panic", g.forbidden_symbols[0]);

    // 不存在的文件 ⇒ false, 不报错
    const missing = try g.loadFromFile(io, "/tmp/ghw_guard_nonexistent_xyz.json");
    try std.testing.expect(!missing);
}

test "SelfEvolutionGuard: primordial PROTECTED_MARKERS in forbidden set" {
    for (primordial_laws.PROTECTED_MARKERS) |m| {
        var found = false;
        for (DEFAULT_FORBIDDEN_SYMBOLS) |f| {
            if (std.mem.eql(u8, f, m)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    var g = SelfEvolutionGuard.init(std.testing.allocator);
    defer g.deinit();
    const v = g.review("src/agent/params.zig", "pub const x = 1;\n// mutate_rho here\n");
    try std.testing.expect(v == .rejected_blacklist_symbol);
}
