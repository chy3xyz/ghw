//! Wasm 沙箱 v1: 用 wasmtime CLI 子进程跑 wasm 模块
//!
//! 走 std.process.run (Zig 0.17 真 subprocess API), 不需要 link wasmtime
//!
//! 优势:
//!   - 零编译复杂度
//!   - wasmtime CLI 是工业级 (Bytecode Alliance), 隔离性可靠
//!   - 写文件 + 跑进程 + 读 stdout, 3 行 Zig
//!
//! 限制:
//!   - 每次调用 spawn 进程, ~20ms 启动开销
//!   - 不支持传复杂 host imports (但 wasm32-freestanding 不需要)
//!   - log 输出靠 stdout/stderr

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WasmError = error{
    WriteModuleFailed,
    SpawnFailed,
    RunFailed,
    Timeout,
    NonZeroExit,
    ParseError,
    WasmtimeNotInstalled,
};

pub const WasmResult = struct {
    return_value: i64,
    log_output: []u8,
    duration_counter: i64,
    alloc: Allocator,

    pub fn deinit(self: *const WasmResult) void {
        self.alloc.free(self.log_output);
    }
};

var g_counter: std.atomic.Value(u64) = .init(0);
fn nextCounter() i64 {
    return @intCast(g_counter.fetchAdd(1, .monotonic));
}

pub const WasmSandbox = struct {
    alloc: Allocator,
    io: std.Io,
    log_buf: std.ArrayList(u8) = .empty,
    /// wasmtime CLI 路径
    wasmtime_path: []const u8 = "/opt/homebrew/bin/wasmtime",

    pub fn init(alloc: Allocator, io: std.Io) WasmSandbox {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *WasmSandbox) void {
        self.log_buf.deinit(self.alloc);
    }

    /// 跑 wasm 模块, 调 entry 函数
    /// wasm_bytes: wasm 二进制
    /// entry: 函数名 (e.g. "answer")
    pub fn runModule(
        self: *WasmSandbox,
        wasm_bytes: []const u8,
        entry: []const u8,
    ) !WasmResult {
        self.log_buf.clearRetainingCapacity();
        const start = nextCounter();

        // 1. 写 wasm 到临时文件
        const tmp_path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/ghw_wasm_{d}_{d}.wasm",
            .{ std.posix.system.getpid(), start },
        );
        defer self.alloc.free(tmp_path);

        {
            const file = try std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, wasm_bytes);
        }
        defer std.Io.Dir.deleteFileAbsolute(self.io, tmp_path) catch {};

        // 2. spawn wasmtime
        const argv = [_][]const u8{
            self.wasmtime_path,
            "run",
            "--invoke",
            entry,
            tmp_path,
        };
        const result = std.process.run(self.alloc, self.io, .{
            .argv = &argv,
            .stdout_limit = std.Io.Limit.limited(64 * 1024),
            .stderr_limit = std.Io.Limit.limited(64 * 1024),
        }) catch |err| {
            std.debug.print("[sandbox] wasmtime 启动失败: {t} (确保 brew install wasmtime)\n", .{err});
            return WasmError.SpawnFailed;
        };
        const duration = nextCounter() - start;
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);

        // log = stderr
        try self.log_buf.appendSlice(self.alloc, result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print("[sandbox] exit={d}, stderr={s}\n", .{ code, result.stderr });
                    return WasmError.NonZeroExit;
                }
            },
            .signal => |sig| {
                std.debug.print("[sandbox] killed by signal {d}\n", .{sig});
                return WasmError.Timeout;
            },
            .stopped, .unknown => return WasmError.RunFailed,
        }

        // 解析 stdout → i64
        const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
        const return_value = std.fmt.parseInt(i64, trimmed, 10) catch |err| {
            std.debug.print("[sandbox] parse stdout '{s}' 失败: {t}\n", .{ trimmed, err });
            return WasmError.ParseError;
        };

        return .{
            .return_value = return_value,
            .log_output = try self.alloc.dupe(u8, self.log_buf.items),
            .duration_counter = duration,
            .alloc = self.alloc,
        };
    }

    /// 把 zig 源码编译成 wasm32-freestanding 字节码
    /// 输出: 写到 out_path
    /// 例: compileZigToWasm(alloc, io, "export fn add(a:i32,b:i32) i32 { return a+b; }", "/tmp/guest.wasm")
    /// export_names: 多个 export 名字, 都会被加 --export= 标记 (Zig 0.17 DCE 会删没标的)
    pub fn compileZigToWasm(
        alloc: Allocator,
        io: std.Io,
        zig_source: []const u8,
        out_path: []const u8,
        export_names: []const []const u8,
        zig_bin: []const u8,
    ) !void {
        std.debug.print("[sandbox] compileZigToWasm: bin={s} out={s} exports={d}\n", .{ zig_bin, out_path, export_names.len });
        for (export_names) |e| std.debug.print("  export: {s}\n", .{e});
        // 1. 写源码到 tmp
        const compile_id = nextCounter();
        const src_path = try std.fmt.allocPrint(alloc, "/tmp/ghw_wasm_src_{d}_{d}.zig", .{ std.posix.system.getpid(), compile_id });
        defer alloc.free(src_path);
        defer std.Io.Dir.deleteFileAbsolute(io, src_path) catch {};

        {
            const file = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, zig_source);
        }
        std.debug.print("[sandbox] wrote source: {s}\n", .{src_path});

        // 2. spawn zig build-exe (--export=<entry> 必须有, 不然 export fn 被 DCE 掉)
        const emit_arg = try std.fmt.allocPrint(alloc, "-femit-bin={s}", .{out_path});
        defer alloc.free(emit_arg);
        // 构造 argv: 基础 + 多个 --export=
        var argv_buf = std.ArrayList([]const u8).empty;
        defer argv_buf.deinit(alloc);
        try argv_buf.append(alloc, zig_bin);
        try argv_buf.append(alloc, "build-exe");
        try argv_buf.append(alloc, "--global-cache-dir");
        try argv_buf.append(alloc, "/tmp/ghw_zig_cache");
        try argv_buf.append(alloc, "-O");
        try argv_buf.append(alloc, "Debug"); // Debug 不删 export
        try argv_buf.append(alloc, "-target");
        try argv_buf.append(alloc, "wasm32-freestanding");
        try argv_buf.append(alloc, "-fno-entry");
        for (export_names) |name| {
            const exp = try std.fmt.allocPrint(alloc, "--export={s}", .{name});
            try argv_buf.append(alloc, exp);
        }
        try argv_buf.append(alloc, emit_arg);
        try argv_buf.append(alloc, src_path);
        std.debug.print("[sandbox] spawn zig argv len={d}\n", .{argv_buf.items.len});
        for (argv_buf.items, 0..) |a, i| std.debug.print("  [{d}] {s}\n", .{ i, a });
        const result = std.process.run(alloc, io, .{
            .argv = argv_buf.items,
            .stdout_limit = std.Io.Limit.limited(64 * 1024),
            .stderr_limit = std.Io.Limit.limited(64 * 1024),
        }) catch |err| {
            std.debug.print("[sandbox] spawn failed: {t}\n", .{err});
            return WasmError.SpawnFailed;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        std.debug.print("[sandbox] zig done, term={any}\n", .{result.term});

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("[sandbox] zig compile 失败:\n  stderr: {s}\n", .{result.stderr});
            return WasmError.RunFailed;
        }
    }
};
