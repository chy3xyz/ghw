const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ===== ghw 核心静态库 =====
    const ghw_mod = b.addModule("ghw", .{
        .root_source_file = b.path("src/ghw.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ===== ghw_sdk 静态库 (C ABI, Phase 3 + v0.2) =====
    // 可选 macOS sqlite3 路径覆盖 (用户可传 -Dsqlite-path=/opt/homebrew/opt/sqlite/lib)
    const sqlite_path = b.option([]const u8, "sqlite-path", "macOS: path to sqlite3 lib dir, e.g. /opt/homebrew/opt/sqlite/lib");
    const sdk_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ghw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // 允许链接到 sqlite3
            .imports = &.{
                .{ .name = "ghw", .module = ghw_mod },
            },
        }),
    });
    // SDK 自带 libsqlite3 (用户不用自己加 -lsqlite3)
    sdk_lib.root_module.linkSystemLibrary("sqlite3", .{});
    if (target.result.os.tag == .macos) {
        const path = sqlite_path orelse "/opt/homebrew/opt/sqlite/lib";
        sdk_lib.root_module.addLibraryPath(.{ .cwd_relative = path });
    }
    b.installArtifact(sdk_lib);

    // 装 ghw.h 到 install dir
    const install_sdk_h = b.addInstallFile(b.path("ghw.h"), "include/ghw.h");
    const install_sdk_step = b.step("install-sdk", "Install GHW SDK (libghw.a + ghw.h)");
    install_sdk_step.dependOn(&install_sdk_h.step);
    const install_lib = b.addInstallArtifact(sdk_lib, .{});
    install_sdk_step.dependOn(&install_lib.step);

    // ===== 单元测试 =====
    // 0.17 addTest 不会自动扫子 module 顶层 test 块. 必须显式给每个 module 加 addTest.
    // 实测: 之前 140 total 锁死, 加 11 个 test 没变化. 修法: 给所有含 test 的 module 显式 addTest.
    // 限制: 只跑不跨目录 @import 的 module (只用 std), 跨目录的走 ghw.zig root (触发整链).
    // 不跨目录的: util/math.zig, sandbox/sqlite_db.zig, harness/config_loader.zig, harness/loop_engine.zig
    // 跨目录的 (只在 ghw.zig root 跑): agent/core.zig, world/core.zig, goal/core.zig, harness/self_encoder.zig,
    //   harness/ghw_link.zig (2026-10 起经 util/net_read.zig 跨目录)
    const test_files_independent = [_][]const u8{
        "src/ghw.zig", // root, 触发整链 (含跨目录的)
        "src/harness/loop_engine.zig",
        "src/harness/config_loader.zig",
        "src/harness/product_instance.zig",
        "src/harness/co_evolution.zig",
        "src/harness/agent_tick_guard.zig",
        "src/util/math.zig",
        "src/sandbox/sqlite_db.zig",
    };
    const test_step = b.step("test", "Run unit tests");
    inline for (test_files_independent) |src_path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
                // product_intent/autocli 等用 std.c.* (libc extern);
                // macOS 默认链 libSystem 故本地不报错, Linux 必须显式声明。
                .link_libc = true,
                .imports = &.{
                    .{ .name = "ghw", .module = ghw_mod },
                },
            }),
        });
        t.root_module.linkSystemLibrary("sqlite3", .{});
        if (target.result.os.tag == .macos) {
            const path = sqlite_path orelse "/opt/homebrew/opt/sqlite/lib";
            t.root_module.addLibraryPath(.{ .cwd_relative = path });
        }
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ===== Examples =====
    const examples = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "demo", .root = "examples/demo.zig" },
        .{ .name = "tournament", .root = "examples/tournament.zig" },
        .{ .name = "spectrum", .root = "examples/spectrum.zig" },
        .{ .name = "selfevolve", .root = "examples/selfevolve.zig" },
        .{ .name = "migrate", .root = "examples/migrate.zig" },
        .{ .name = "self_migrate_e2e", .root = "examples/self_migrate_e2e.zig" },
        .{ .name = "multi_agent_demo", .root = "examples/multi_agent_demo.zig" },
        .{ .name = "migrate2", .root = "examples/migrate2.zig" },
        .{ .name = "selfcode", .root = "examples/selfcode.zig" },
        .{ .name = "daemon", .root = "examples/daemon.zig" },
        .{ .name = "fueled", .root = "examples/fueled.zig" },
        .{ .name = "bench_self_evolution", .root = "examples/bench_self_evolution.zig" },
        .{ .name = "llm_smoke", .root = "examples/llm_smoke.zig" },
        .{ .name = "live_fueled", .root = "examples/live_fueled.zig" },
        .{ .name = "human_symbiosis", .root = "examples/human_symbiosis.zig" },
        .{ .name = "chat", .root = "examples/chat.zig" },
        .{ .name = "balance", .root = "examples/balance.zig" },
        .{ .name = "live_loop", .root = "examples/live_loop.zig" },
        .{ .name = "im_bridge", .root = "examples/im_bridge.zig" },
        .{ .name = "weekly_replay", .root = "examples/weekly_replay.zig" },
        .{ .name = "wechat_bridge", .root = "examples/wechat_bridge.zig" },
        .{ .name = "lark_bridge", .root = "examples/lark_bridge.zig" },
        .{ .name = "ui_server", .root = "examples/ui_server.zig" },
        .{ .name = "cross_host_test", .root = "examples/cross_host_test.zig" },
        // embed_demo: C 程序 link libghw, 演示 Phase 3 SDK
        // 注意: 不通过 zig build 编 (Zig 0.17 + C source 兼容 bug), 用 cc 手动编:
        //   cc -O2 -I zig-out/include -L zig-out/lib examples/embed_demo.c -lghw -o embed_demo
    };
    const install_examples = b.step("examples", "Build all example binaries");
    inline for (examples) |ex| {
        const is_c_file = std.mem.endsWith(u8, ex.root, ".c");
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.root),
                .target = target,
                .optimize = optimize,
                // C 文件不 import ghw_mod (C 不需要 Zig module)
                .imports = if (!is_c_file) &.{
                    .{ .name = "ghw", .module = ghw_mod },
                } else &.{},
            }),
        });
        // C 文件 link libghw (Phase 3 SDK)
        if (is_c_file) {
            exe.root_module.addIncludePath(b.path("."));
            exe.root_module.linkLibrary(sdk_lib);
        } else {
            // Zig exe (e.g. ui_server) 用 ghw_mod 里的 SqliteDb, 必须显式 link sqlite3
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("sqlite3", .{});
            if (target.result.os.tag == .macos) {
                const path = sqlite_path orelse "/opt/homebrew/opt/sqlite/lib";
                exe.root_module.addLibraryPath(.{ .cwd_relative = path });
            }
        }
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run-" ++ ex.name, "Run " ++ ex.name);
        run_step.dependOn(&run_cmd.step);
    }
    _ = install_examples;
}
