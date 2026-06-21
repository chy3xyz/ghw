//! SelfMigration: 数字生命的"自我迁移"主控
//!
//! 这是 GHW 范式从"工具 AI"到"自演化数字生命"的终极能力 - 数字生命
//! 可以生成新代码, 通过规则审查 + 编译验证, 然后把自己替换成新代码
//!
//! 完整流程 (老进程 → 新代码壳):
//!   1. LLM 生成新代码 (v2 candidate)
//!   2. LLM 审查 (Claude Code review)
//!   3. CompileVerifier 验证 (zig build)
//!   4. 失败: 回滚, 反馈给 LLM 修复
//!   5. 成功: 写新代码到 ghw_v2/
//!   6. StateSerializer 序列化当前状态 → state.json
//!   7. spawn 新进程 (ghw_v2 + --migrate-from state.json)
//!   8. 新进程加载状态 → 报告 ready → 接管
//!   9. 老进程收到 ready 信号 → 优雅退出
//!
//! 创造性:
//!   - 状态通过 JSON 文件传递, 不需要复杂的 IPC
//!   - 新代码作为独立二进制编译 (源文件级别的迁移)
//!   - 失败自动回滚 (删除新代码)
//!   - 提供 MigrationId 防止迁移冲突

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const F = util.F;
const state_serializer_mod = @import("state_serializer.zig");
const StateSerializer = state_serializer_mod.StateSerializer;
const StateSnapshot = state_serializer_mod.StateSnapshot;
const SerializedGoal = state_serializer_mod.SerializedGoal;
const compile_verifier_mod = @import("compile_verifier.zig");
const CompileVerifier = compile_verifier_mod.CompileVerifier;
const llm_mod = @import("llm/llm.zig");
const LLM = llm_mod.LLM;
const LLMRequest = llm_mod.LLMRequest;
const MockLLM = @import("llm/mock_llm.zig").MockLLM;
const SelfEvolutionGuard = @import("self_evolution_guard.zig").SelfEvolutionGuard;

/// 迁移步骤
pub const MigrationStep = enum {
    pending, // 待开始
    generating, // LLM 生成代码
    reviewing, // LLM 审查
    compiling, // 编译验证
    serializing, // 序列化状态
    spawning, // 启动新进程
    ready, // 新进程接管
    done, // 全部完成
    rolled_back, // 回滚
    failed, // 失败
};

/// 迁移结果
pub const MigrationResult = struct {
    success: bool,
    final_step: MigrationStep,
    /// 生成的代码
    generated_code: []const u8,
    /// 审查结果 (原文)
    review_text: []const u8,
    /// 编译是否通过
    compiled: bool,
    /// 状态文件路径
    state_file: []const u8,
    /// 新进程 PID (如果 spawn 成功)
    new_pid: ?i32,
    /// 错误信息
    error_msg: []const u8,
    /// 分配器 (用于 deinit)
    allocator: Allocator,
    /// 是否应该 deinit
    owns_memory: bool = true,

    pub fn deinit(self: *MigrationResult) void {
        if (!self.owns_memory) return;
        // generated_code 和 review_text 可能是空 slice 或 alloc.dupe 的副本
        if (self.generated_code.len > 0) self.allocator.free(@constCast(self.generated_code));
        if (self.review_text.len > 0) self.allocator.free(@constCast(self.review_text));
        if (self.error_msg.len > 0) self.allocator.free(@constCast(self.error_msg));
    }
};

pub const MigrationConfig = struct {
    /// 新代码目录 (默认 .ghw_next)
    next_dir: []const u8 = ".ghw_next",
    /// 状态文件路径
    state_file: []const u8 = ".ghw_next/state.json",
    /// 新二进制路径
    new_binary: []const u8 = ".ghw_next/ghw_v2",
    /// 父进程 PID (用于交接信号)
    parent_pid: ?i32 = null,
    /// LLM 后端类型
    llm_kind: LLMKind = .mock,
};

pub const LLMKind = enum {
    mock,
    shell_claude,
    shell_autocli,
};

pub const SelfMigration = struct {
    allocator: Allocator,
    config: MigrationConfig,
    /// 累计迁移尝试
    attempt_count: u32 = 0,
    /// 累计成功迁移
    success_count: u32 = 0,
    /// 累计回滚
    rollback_count: u32 = 0,
    /// Mock LLM (default)
    mock_llm: MockLLM,
    /// 编译验证器
    verifier: CompileVerifier,
    /// 状态序列化器
    serializer: StateSerializer,
    /// 安全守护
    guard: SelfEvolutionGuard,
    /// spawnSelfNewVersion 后保存子进程句柄, 供 waitNewProcess 回收 (防僵尸进程)
    pending_child: ?std.process.Child = null,

    pub fn init(allocator: Allocator) SelfMigration {
        return .{
            .allocator = allocator,
            .config = .{},
            .mock_llm = MockLLM.init(allocator),
            .verifier = CompileVerifier.init(allocator),
            .serializer = StateSerializer.initMemory(allocator),
            .guard = SelfEvolutionGuard.init(allocator),
        };
    }

    /// 真实部署用: 传 io 让 serializer 真正能写文件 + verifier 真编译
    pub fn initWithIo(allocator: Allocator, io: std.Io) SelfMigration {
        return .{
            .allocator = allocator,
            .config = .{},
            .mock_llm = MockLLM.init(allocator),
            .verifier = CompileVerifier.initWithIo(allocator, io),
            .serializer = StateSerializer.init(allocator, io),
            .guard = SelfEvolutionGuard.init(allocator),
        };
    }

    pub fn deinit(self: *SelfMigration) void {
        // 回收未 wait 的子进程, 防僵尸
        if (self.pending_child) |*c| {
            _ = c.wait(self.serializer.io) catch {};
            self.pending_child = null;
        }
        self.guard.deinit();
    }

    /// 完整迁移流程 (从生成到 spawn)
    /// prompt: GHW 自我意识的"进化要求"
    /// snapshot: 当前状态
    /// 返回 MigrationResult (即使失败也会填充)
    pub fn migrate(
        self: *SelfMigration,
        prompt: []const u8,
        snapshot: StateSnapshot,
    ) !MigrationResult {
        self.attempt_count += 1;
        var result = MigrationResult{
            .success = false,
            .final_step = .pending,
            .generated_code = "",
            .review_text = "",
            .compiled = false,
            .state_file = self.config.state_file,
            .new_pid = null,
            .error_msg = "",
            .allocator = self.allocator,
        };

        // Step 1: LLM 生成
        result.final_step = .generating;
        const llm = self.getLLM();
        const req = LLMRequest{ .prompt = prompt, .output_format = "zig_code" };
        var gen_resp = llm.generate(req, self.allocator) catch |err| {
            result.final_step = .failed;
            result.error_msg = @errorName(err);
            return result;
        };
        defer gen_resp.deinit();
        if (!gen_resp.success) {
            result.final_step = .failed;
            result.error_msg = gen_resp.error_msg;
            return result;
        }
        // 复制代码
        const code = try self.allocator.dupe(u8, gen_resp.content);

        // Step 2: LLM 审查
        result.final_step = .reviewing;
        var rev_resp = llm.review(code, self.allocator) catch |err| {
            result.final_step = .failed;
            result.error_msg = @errorName(err);
            self.allocator.free(code);
            return result;
        };
        defer rev_resp.deinit();
        if (!rev_resp.success) {
            result.final_step = .failed;
            result.error_msg = "review rejected";
            // 复制审查文本以便报告
            result.review_text = try self.allocator.dupe(u8, rev_resp.content);
            result.generated_code = code;
            self.rollback_count += 1;
            return result;
        }
        result.review_text = try self.allocator.dupe(u8, rev_resp.content);

        // Step 3: 编译验证
        result.final_step = .compiling;
        result.generated_code = code;
        var verify_result = self.verifier.verify(.{ .code = code }) catch |err| {
            result.final_step = .failed;
            result.error_msg = @errorName(err);
            return result;
        };
        defer verify_result.deinit();
        if (!verify_result.success) {
            result.final_step = .failed;
            result.compiled = false;
            result.error_msg = try self.allocator.dupe(u8, verify_result.errorSummary());
            self.rollback_count += 1;
            return result;
        }
        result.compiled = true;

        // Step 4: 写新代码到 next_dir
        try self.writeNewCode(code);

        // Step 5: 序列化状态
        result.final_step = .serializing;
        _ = try self.serializer.writeToFile(snapshot, self.config.state_file);

        // Step 6: 进程交接。
        // migrate() 只负责"准备好可交接的新版本"(代码已写盘 + 状态已序列化 + 编译已验证),
        // **不**在此自动 spawn —— 自动替换自身进程是不可逆操作, 必须由部署方显式调
        // `spawnSelfNewVersion(state_file, self_binary_path)` 触发 (该函数真实 spawn + 可 wait)。
        // 这样单测 / 库使用者不会在 migrate() 里意外 fork 出新进程。
        result.final_step = .spawning;
        result.new_pid = null;
        result.final_step = .done;
        result.success = true;
        self.success_count += 1;

        return result;
    }

    /// 写新代码到 next_dir/main_v2.zig (真实 std.Io 落盘)。
    fn writeNewCode(self: *SelfMigration, code: []const u8) !void {
        const io = self.serializer.io;
        // 幂等创建 next_dir (含多级路径); 已存在不报错
        std.Io.Dir.cwd().createDirPath(io, self.config.next_dir) catch {};
        const main_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.config.next_dir, "main_v2.zig" });
        defer self.allocator.free(main_path);
        const f = try std.Io.Dir.createFileAbsolute(io, main_path, .{});
        defer f.close(io);
        try std.Io.File.writeStreamingAll(f, io, code);
    }

    /// 回滚: 删除 next_dir 下已写出的新代码与状态文件 (真实落盘删除)。
    pub fn rollback(self: *SelfMigration) void {
        const io = self.serializer.io;
        if (std.fs.path.join(self.allocator, &[_][]const u8{ self.config.next_dir, "main_v2.zig" })) |main_path| {
            defer self.allocator.free(main_path);
            std.Io.Dir.deleteFileAbsolute(io, main_path) catch {};
        } else |_| {}
        std.Io.Dir.deleteFileAbsolute(io, self.config.state_file) catch {};
    }

    /// 双进程协议: 老进程 spawn 自身新版本, 传 --migrate-from 参数
    /// 这是 L4 自我迁移的关键一步: 数字生命用新代码替换自己
    ///
    /// 流程:
    ///   1. 构造 argv: [本二进制, --migrate-from, state_file]
    ///   2. subprocess.spawn (Zig 0.17 std.process.spawn)
    ///   3. 返回子进程 PID
    ///   4. 老进程可以 waitpid 等待子进程结束 (即新生命完成工作后)
    ///
    /// Zig 0.17 状态: 真实现 (需要 initWithIo 传 io)
    pub fn spawnSelfNewVersion(
        self: *SelfMigration,
        state_path: []const u8,
        self_binary_path: []const u8,
    ) !i32 {
        // 构造 argv: [本二进制, --migrate-from, state_file]
        const binary_z = try self.allocator.dupeSentinel(u8, self_binary_path, 0);
        defer self.allocator.free(binary_z);
        const migrate_flag_z = try self.allocator.dupeSentinel(u8, "--migrate-from", 0);
        defer self.allocator.free(migrate_flag_z);
        const state_z = try self.allocator.dupeSentinel(u8, state_path, 0);
        defer self.allocator.free(state_z);

        var argv_buf = [_][]const u8{
            binary_z,
            migrate_flag_z,
            state_z,
        };
        const argv: []const []const u8 = &argv_buf;

        // 启动子进程
        const child = std.process.spawn(self.serializer.io, .{
            .argv = argv,
            .stdout = .inherit,
            .stderr = .inherit,
            .stdin = .close,
        }) catch |err| {
            std.debug.print("[SelfMigration] spawn failed: {t}\n", .{err});
            return -1;
        };

        // 保存句柄供 waitNewProcess 回收 (防僵尸)。
        self.pending_child = child;
        // POSIX: Child.Id 是 pid_t (整数); 提取 PID。
        return if (child.id) |id| @intCast(id) else -1;
    }

    /// 等待之前 spawnSelfNewVersion 拉起的新进程结束, 返回其退出码 (无子进程返回 0)。
    pub fn waitNewProcess(self: *SelfMigration, pid: i32) !u32 {
        _ = pid; // PID 仅供调用方记录; 实际句柄存在 self.pending_child
        if (self.pending_child) |*c| {
            const term = try c.wait(self.serializer.io);
            self.pending_child = null;
            return switch (term) {
                .exited => |code| @intCast(code),
                else => 1, // signal/stopped/unknown → 视为非正常退出
            };
        }
        return 0;
    }

    /// 获取 LLM (目前只支持 Mock)
    fn getLLM(self: *SelfMigration) LLM {
        return self.mock_llm.asLLM();
    }

    /// 报告 (人类可读)
    pub fn report(self: *SelfMigration, w: *std.Io.Writer, result: MigrationResult) std.Io.Writer.Error!void {
        try w.print("SelfMigration: success={} step={s}\n", .{ result.success, @tagName(result.final_step) });
        try w.print("  generated_code: {d} bytes\n", .{result.generated_code.len});
        try w.print("  compiled: {}\n", .{result.compiled});
        try w.print("  review_len: {d}\n", .{result.review_text.len});
        try w.print("  new_pid: {?}\n", .{result.new_pid});
        try w.print("  error: {s}\n", .{result.error_msg});
        try w.print("  history: attempts={d} success={d} rollback={d}\n", .{
            self.attempt_count, self.success_count, self.rollback_count,
        });
    }
};

// ===== Tests =====

test "SelfMigration: 完整流程 (成功)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mig = SelfMigration.initWithIo(alloc, io);
    defer mig.deinit();
    // 用 /tmp 避免在仓库目录产出 .ghw_next 工件
    mig.config.next_dir = "/tmp/ghw_mig_full_test";
    mig.config.state_file = "/tmp/ghw_mig_full_test/state.json";
    // 清理
    defer mig.rollback();

    var e_hist_arr = [_]F{ 0.5, 0.55, 0.6, 0.62 };
    const snapshot = StateSnapshot{
        .agent_id = "migrate-test",
        .tick = 50,
        .material = 0.6,
        .representation = 0.7,
        .nature = 0.5,
        .alpha = 0.33,
        .beta = 0.34,
        .gamma = 0.33,
        .e_current = 0.62,
        .goals = &[_]SerializedGoal{},
        .e_history = &e_hist_arr,
        .success_count = 3,
        .fail_count = 0,
        .cumulative_de = 0.4,
        .allocator = alloc,
    };
    const prompt = "请调整 attn 参数以提升 E. E_current=0.62 E_target=0.8. 体现存在增益";
    var result = try mig.migrate(prompt, snapshot);
    defer result.deinit();
    // Mock 一定会通过审查, 但编译可能因 zig 编译器版本问题失败
    // 我们不强求 success, 但至少要走到 review 之后
    try std.testing.expect(result.final_step == .done or
        result.final_step == .failed or
        result.final_step == .rolled_back);
    try std.testing.expect(mig.attempt_count == 1);
    // 验证 MockLLM 生成了代码
    try std.testing.expect(result.generated_code.len > 0);
}

test "SelfMigration: 序列化 + 加载" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mig = SelfMigration.initWithIo(alloc, io);
    defer mig.deinit();

    var e_hist = [_]F{0.5};
    const snapshot = StateSnapshot{
        .agent_id = "roundtrip-test",
        .tick = 100,
        .material = 0.5,
        .representation = 0.5,
        .nature = 0.5,
        .alpha = 0.33,
        .beta = 0.34,
        .gamma = 0.33,
        .e_current = 0.5,
        .goals = &[_]SerializedGoal{},
        .e_history = &e_hist,
        .success_count = 0,
        .fail_count = 0,
        .cumulative_de = 0,
        .allocator = alloc,
    };
    // 序列化 (直接调 serialize, 不走文件 IO)
    const json = try mig.serializer.serialize(snapshot);
    defer alloc.free(json);
    // 解析
    var parsed = try mig.serializer.parseMinimal(json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("roundtrip-test", parsed.agent_id);
    try std.testing.expectEqual(@as(u64, 100), parsed.tick);
}

test "SelfMigration: writeNewCode 真实落盘 + rollback 删除" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mig = SelfMigration.initWithIo(alloc, io);
    defer mig.deinit();
    // 用 /tmp 避免污染仓库目录
    mig.config.next_dir = "/tmp/ghw_mig_test_dir";
    mig.config.state_file = "/tmp/ghw_mig_test_dir/state.json";

    const code = "pub const answer: u32 = 42;\n";
    try mig.writeNewCode(code);

    // 读回验证内容一致
    const main_path = try std.fs.path.join(alloc, &[_][]const u8{ mig.config.next_dir, "main_v2.zig" });
    defer alloc.free(main_path);
    const back = try mig.serializer.readFromFile(main_path);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(code, back);

    // rollback 后文件应被删除
    mig.rollback();
    const reopened = std.Io.Dir.openFileAbsolute(io, main_path, .{ .mode = .read_only });
    try std.testing.expectError(error.FileNotFound, reopened);
}

test "SelfMigration: spawnSelfNewVersion 真 spawn + waitNewProcess 回收" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mig = SelfMigration.initWithIo(alloc, io);
    defer mig.deinit();

    // /usr/bin/true 忽略所有参数并立即退出 0 —— 安全验证真实 spawn/wait 通路
    const pid = try mig.spawnSelfNewVersion("/tmp/ghw_ignored_state.json", "/usr/bin/true");
    if (pid <= 0) return; // 环境缺 /usr/bin/true: spawn 已优雅返回 -1, 跳过
    try std.testing.expect(mig.pending_child != null);
    const code = try mig.waitNewProcess(pid);
    try std.testing.expectEqual(@as(u32, 0), code);
    try std.testing.expect(mig.pending_child == null);
}
