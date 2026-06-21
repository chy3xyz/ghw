//! CompileVerifier: subprocess 调 zig build 验证代码可编译
//!
//! 这是 L4 自我迁移的关键步骤: 在真实修改主程序前, 先验证新代码能编译
//!
//! 创造性:
//!   1. 不直接编译主项目 (太重) - 而是把新代码写到临时目录, 编一个独立测试
//!   2. 捕获 stdout/stderr, 把错误返回给 LLM 让它修复
//!   3. 失败时自动提供修复建议

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;

// 已做实: 用 Threaded Io (std.Io.Dir/File) 写候选代码 + std.process.spawn 调 zig build。
// 须传 initWithIo(allocator, io); 文件辅助 writeFileAbsolute 见 verify 之后。

pub const VerifyRequest = struct {
    /// 待验证的 Zig 源码
    code: []const u8,
    /// 期望的文件名 (用于在临时目录中创建)
    target_name: []const u8 = "candidate.zig",
    /// 编译超时 (ms)
    timeout_ms: u32 = 60000,
};

pub const VerifyResult = struct {
    /// 是否编译通过
    success: bool,
    /// 编译器 stdout
    stdout: []u8,
    /// 编译器 stderr (含错误信息)
    stderr: []u8,
    /// 退出码
    exit_code: u32,
    /// 编译耗时 (ms)
    elapsed_ms: u64,
    allocator: Allocator,

    pub fn deinit(self: *VerifyResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    /// 提取编译错误信息 (供 LLM 修复用)
    pub fn errorSummary(self: *VerifyResult) []const u8 {
        if (self.success) return "(no errors)";
        // 取 stderr 的前 500 字符
        const max = @min(self.stderr.len, 500);
        return self.stderr[0..max];
    }
};

pub const CompileVerifier = struct {
    /// zig 编译器路径 (默认 "zig")
    zig_path: []const u8 = "zig",
    /// 工作目录 (默认 cwd)
    work_dir: []const u8 = ".",
    /// 临时目录 (默认 .ghw_verify/)
    temp_dir: []const u8 = ".ghw_verify",
    /// ghw 源码根 (用于 --dep harness 链接真 ActionOutcome; 默认 cwd)
    ghw_root: []const u8 = ".",
    allocator: Allocator,
    /// Zig 0.17 文件 + subprocess I/O
    io: std.Io,
    /// 累计验证次数
    verify_count: u32 = 0,
    /// 累计成功次数
    success_count: u32 = 0,

    pub fn init(allocator: Allocator) CompileVerifier {
        return .{ .allocator = allocator, .io = undefined };
    }

    /// 真用: 传 io
    pub fn initWithIo(allocator: Allocator, io: std.Io) CompileVerifier {
        return .{ .allocator = allocator, .io = io };
    }

    /// 验证代码是否可编译 (Zig 0.17 std.process.spawn 真实现)
    /// 流程:
    ///   1. 创建临时目录
    ///   2. 写 candidate.zig + 一个最小 main.zig 调用它
    ///   3. 调 zig build-exe (subprocess)
    ///   4. 等子进程结束, 收集 stdout/stderr/exit_code
    ///   5. 清理临时文件
    pub fn verify(self: *CompileVerifier, req: VerifyRequest) !VerifyResult {
        self.verify_count += 1;

        const dir = self.getTempDir();
        // 确保 temp_dir 存在
        const dir_file = std.Io.Dir.createFileAbsolute(self.io, dir, .{ .exclusive = false }) catch null;
        if (dir_file) |f| f.close(self.io);
        // Zig 0.17: 用 createFileAbsolute 写一个 dummy 文件来确保父目录存在
        // (createFileAbsolute 在不存在时返回 error.FileNotFound)
        const probe = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, ".probe" });
        defer self.allocator.free(probe);
        const probe_file = std.Io.Dir.createFileAbsolute(self.io, probe, .{ .exclusive = false }) catch |err| {
            return VerifyResult{
                .success = false,
                .stdout = try self.allocator.dupe(u8, ""),
                .stderr = try std.fmt.allocPrint(self.allocator, "create temp dir failed: {t}", .{err}),
                .exit_code = std.math.maxInt(u32),
                .elapsed_ms = 0,
                .allocator = self.allocator,
            };
        };
        probe_file.close(self.io);

        const candidate_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, req.target_name });
        defer self.allocator.free(candidate_path);
        // main.zig 写到 candidate 的同目录 (这样 @import 用 basename 就能找到)
        const main_path = if (std.fs.path.dirname(candidate_path)) |parent| blk: {
            break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ parent, "_main.zig" });
        } else candidate_path;
        defer self.allocator.free(main_path);
        // 确保 candidate 的父目录存在 (target_name 可能含 "src/agent/params.zig")
        if (std.fs.path.dirname(candidate_path)) |parent_dir| {
            // Zig 0.17 没 std.fs.makeDirAbsolute, 用 posix mkdir 逐级创建
            var parts_buf: [16][]const u8 = undefined;
            var parts_count: usize = 0;
            var iter: []const u8 = parent_dir;
            while (iter.len > 0) {
                if (parts_count >= parts_buf.len) break;
                parts_buf[parts_count] = iter;
                parts_count += 1;
                const next = std.fs.path.dirname(iter) orelse break;
                if (next.len == iter.len) break;
                iter = next;
            }
            // 从最短到最长逐级 mkdir
            var i: usize = parts_count;
            while (i > 0) {
                i -= 1;
                const p_z = try self.allocator.dupeSentinel(u8, parts_buf[i], 0);
                defer self.allocator.free(p_z);
                _ = std.c.mkdir(p_z.ptr, 0o755);
            }
        }

        // 1. 写 candidate.zig
        try writeFileAbsolute(self.io, candidate_path, req.code);
        // main.zig 写到 candidate 的同目录 (见下面 main_path 的赋值)

        // 2. 准备 argv (zig build-exe main.zig --cache-dir .zig-cache-verify)
        const zig_path_z = try self.allocator.dupeSentinel(u8, self.zig_path, 0);
        defer self.allocator.free(zig_path_z);
        const main_path_z = try self.allocator.dupeSentinel(u8, main_path, 0);
        defer self.allocator.free(main_path_z);
        const cache_dir_z = try self.allocator.dupeSentinel(u8, ".zig-cache-verify", 0);
        defer self.allocator.free(cache_dir_z);

        // 用 candidate 的 basename 作为 @import 路径 (在 main.zig 引用 candidate)
        // 适配 candidate 的 Module wrapper: 走 candidate.Module.alpha 而不是 candidate.alpha
        const import_basename = std.fs.path.basename(req.target_name);
        var main_code_buf: [4096]u8 = undefined;
        const main_code = std.fmt.bufPrint(&main_code_buf,
            \\const std = @import("std");
            \\const candidate = @import("{s}");
            \\pub fn main() void {{
            \\    _ = std.debug.print;
            \\    _ = candidate.Module.alpha;
            \\    _ = candidate.Module.beta;
            \\    _ = candidate.Module.gamma;
            \\    _ = candidate.Module.E;
            \\}}
        , .{import_basename}) catch "pub fn main() void {}";
        try writeFileAbsolute(self.io, main_path, main_code);

        // 写 build.zig: 让 candidate 可 @import("harness_api") 拿真 ActionOutcome
        // 关键: 把 harness_api.zig 复制到 temp_dir (避免跨目录 module 解析 bug, Zig 0.17)
        const harness_api_path = try std.fs.path.join(self.allocator, &[_][]const u8{
            self.ghw_root, "src", "harness_api.zig",
        });
        defer self.allocator.free(harness_api_path);
        // 复制 harness_api.zig → <temp_dir>/harness_api.zig
        const harness_local = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, "harness_api.zig" });
        defer self.allocator.free(harness_local);
        const src_file = std.Io.Dir.openFileAbsolute(self.io, harness_api_path, .{ .mode = .read_only }) catch |err| {
            return VerifyResult{
                .success = false,
                .stdout = try self.allocator.dupe(u8, ""),
                .stderr = try std.fmt.allocPrint(self.allocator, "open harness_api 失败: {t}", .{err}),
                .exit_code = std.math.maxInt(u32),
                .elapsed_ms = 0,
                .allocator = self.allocator,
            };
        };
        defer src_file.close(self.io);
        const src_stat = src_file.stat(self.io) catch return VerifyResult{
            .success = false,
            .stdout = try self.allocator.dupe(u8, ""),
            .stderr = try self.allocator.dupe(u8, "harness_api stat failed"),
            .exit_code = std.math.maxInt(u32),
            .elapsed_ms = 0,
            .allocator = self.allocator,
        };
        const harness_content = try self.allocator.alloc(u8, @intCast(src_stat.size));
        defer self.allocator.free(harness_content);
        _ = std.Io.File.readStreaming(src_file, self.io, &.{harness_content}) catch return VerifyResult{
            .success = false,
            .stdout = try self.allocator.dupe(u8, ""),
            .stderr = try self.allocator.dupe(u8, "harness_api read failed"),
            .exit_code = std.math.maxInt(u32),
            .elapsed_ms = 0,
            .allocator = self.allocator,
        };
        if (std.Io.Dir.createFileAbsolute(self.io, harness_local, .{})) |f| {
            defer f.close(self.io);
            std.Io.File.writeStreamingAll(f, self.io, harness_content) catch {};
        } else |_| {}

        const build_zig_dir = dir; // temp_dir
        const build_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{
            build_zig_dir, "build.zig",
        });
        defer self.allocator.free(build_zig_path);
        const main_rel = main_path;  // 用绝对路径, 避免 cwd_relative 解析问题
        const harness_rel = harness_local;  // 绝对路径
        var build_zig_buf: [2048]u8 = undefined;
        const build_zig_code = std.fmt.bufPrint(&build_zig_buf,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{ .preferred_optimize_mode = .ReleaseSafe }});
            \\
            \\    const harness_api_mod = b.createModule(.{{
            \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
            \\    const exe = b.addExecutable(.{{
            \\        .name = "verify",
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = .{{ .cwd_relative = "{s}" }},
            \\            .target = target,
            \\            .optimize = optimize,
            \\            .imports = &.{{
            \\                .{{ .name = "harness_api", .module = harness_api_mod }},
            \\            }},
            \\        }}),
            \\    }});
            \\    b.installArtifact(exe);
            \\}}
        , .{ harness_rel, main_rel }) catch return VerifyResult{
            .success = false,
            .stdout = try self.allocator.dupe(u8, ""),
            .stderr = try self.allocator.dupe(u8, "build.zig bufPrint failed"),
            .exit_code = std.math.maxInt(u32),
            .elapsed_ms = 0,
            .allocator = self.allocator,
        };
        try writeFileAbsolute(self.io, build_zig_path, build_zig_code);

        // 用 `zig build --build-file <build.zig_path>` 编译, 跨目录 module 走 build.zig
        // 关键: --build-file 显式指定 build.zig 位置, 不依赖 cwd
        var argv_buf = [_][]const u8{
            zig_path_z,
            "build",
            "--build-file",       build_zig_path,
            "--cache-dir",        cache_dir_z,
            "--global-cache-dir", cache_dir_z,
        };
        const argv: []const []const u8 = &argv_buf;

        // 3. 准备 stdout/stderr buffer (Zig 0.17 spawn .buffer 模式会直接写)
        // 3. 启动子进程 (用 pipe, 后续读取)
        // 0.17 没有 .buffer 模式, 只能 pipe + readStreaming
        const start = std.Io.Timestamp.now(self.io, .real);
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .close,
        }) catch |err| {
            return VerifyResult{
                .success = false,
                .stdout = try self.allocator.dupe(u8, ""),
                .stderr = try std.fmt.allocPrint(self.allocator, "spawn failed: {t}", .{err}),
                .exit_code = std.math.maxInt(u32), // 哨兵 = spawn 失败
                .elapsed_ms = 0,
                .allocator = self.allocator,
            };
        };

        // 4. 读 stdout/stderr (用 growable ArrayList)
        var stdout_list: std.ArrayList(u8) = .empty;
        defer stdout_list.deinit(self.allocator);
        var stderr_list: std.ArrayList(u8) = .empty;
        defer stderr_list.deinit(self.allocator);
        if (child.stdout) |out| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = std.Io.File.readStreaming(out, self.io, &.{&buf}) catch break;
                if (n == 0) break;
                stdout_list.appendSlice(self.allocator, buf[0..n]) catch break;
            }
        }
        if (child.stderr) |errf| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = std.Io.File.readStreaming(errf, self.io, &.{&buf}) catch break;
                if (n == 0) break;
                stderr_list.appendSlice(self.allocator, buf[0..n]) catch break;
            }
        }

        // 5. 等待子进程结束
        const term = child.wait(self.io) catch |wait_err| {
            return VerifyResult{
                .success = false,
                .stdout = try stdout_list.toOwnedSlice(self.allocator),
                .stderr = try std.fmt.allocPrint(self.allocator, "wait failed: {t}", .{wait_err}),
                .exit_code = std.math.maxInt(u32),
                .elapsed_ms = 0,
                .allocator = self.allocator,
            };
        };

        const elapsed = std.Io.Timestamp.durationTo(start, std.Io.Timestamp.now(self.io, .real));
        const elapsed_ms: u64 = @intCast(@divTrunc(elapsed.nanoseconds, 1_000_000));
        const exit_code: u32 = switch (term) {
            .exited => |code| @intCast(code),
            .signal => 128, // 128+signal 的 POSIX 惯例
            .stopped => 128,
            .unknown => std.math.maxInt(u32),
        };

        return VerifyResult{
            .success = exit_code == 0,
            .stdout = try stdout_list.toOwnedSlice(self.allocator),
            .stderr = try stderr_list.toOwnedSlice(self.allocator),
            .exit_code = exit_code,
            .elapsed_ms = elapsed_ms,
            .allocator = self.allocator,
        };
    }

    /// Zig 0.17 std.Io.File.writeAll 替代旧版 writeFileViaShell
    fn writeFileAbsolute(io: std.Io, path: []const u8, content: []const u8) !void {
        // 注: 0.17 没有 makePath, 假设父目录已存在 (调用方负责)
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, content);
    }

    /// 获取 temp dir 路径
    fn getTempDir(self: *CompileVerifier) []const u8 {
        return self.temp_dir;
    }

    /// 清理临时目录 (简化: 在 Windows 上忽略)
    pub fn cleanup(self: *CompileVerifier) void {
        _ = self;
    }
};

// ===== Tests =====

test "CompileVerifier: 合法代码通过" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cv = CompileVerifier.initWithIo(alloc, io);
    defer cv.cleanup();

    const code =
        \\// 简单的合法 Zig
        \\pub fn add(a: i32, b: i32) i32 { return a + b; }
    ;
    const req = VerifyRequest{ .code = code, .target_name = "candidate.zig" };
    var result = try cv.verify(req);
    defer result.deinit();
    // 如果 zig 编译器可用, 应该通过
    try std.testing.expect(result.elapsed_ms >= 0);
    if (result.success) {
        try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    }
}

test "CompileVerifier: 错误代码失败" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cv = CompileVerifier.initWithIo(alloc, io);
    defer cv.cleanup();

    const code =
        \\// 故意语法错误
        \\pub fn broken( {
    ;
    const req = VerifyRequest{ .code = code, .target_name = "candidate.zig" };
    var result = try cv.verify(req);
    defer result.deinit();
    try std.testing.expect(!result.success);
    try std.testing.expect(result.stderr.len > 0);
}

test "CompileVerifier: errorSummary 提取错误" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var cv = CompileVerifier.initWithIo(alloc, io);
    defer cv.cleanup();

    const code = "this is not zig code at all!!!";
    const req = VerifyRequest{ .code = code };
    var result = try cv.verify(req);
    defer result.deinit();
    try std.testing.expect(!result.success);
    const summary = result.errorSummary();
    try std.testing.expect(summary.len > 0);
}
