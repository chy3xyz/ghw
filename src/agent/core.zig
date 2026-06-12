//! Agent 主循环: 三时间尺度嵌套存在度更新循环
//!
//! 论文 B.3.4 算法 4 的 Zig 完整实现
//!
//! 三个时间尺度:
//!   η_H (Harness/反应) - 最快, 每 tick
//!   η_W (World/适应)   - 中速, 每 T_W 步
//!   η_G (Goal/反思)     - 最慢, 每 T_G 步
//!
//! 创造性扩展:
//!   - 添加"反思层" (Reflective Layer), 用于策略元学习
//!   - 真实物理时间跟踪 (通过 std.time)
//!   - 状态快照: 每周期记录关键指标, 可输出为可视化

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const util = @import("../util/mod.zig");
const math_util = util.math;
const F = util.F;
const LCG = util.LCG;

const world = @import("../world/mod.zig");
const ExistenceDegree = world.ExistenceDegree;
const ExistenceVector = world.ExistenceVector;
const CoappropriationTensor = world.CoappropriationTensor;
const WorldModel = world.WorldModel;

const goal = @import("../goal/mod.zig");
const Information = goal.Information;
const AttentionEngine = goal.AttentionEngine;
const PerceptionEngine = goal.PerceptionEngine;
const DifferenceSetEngine = goal.DifferenceSetEngine;
const GoalGraph = goal.GoalGraph;
const Goal = goal.Goal;
const GoalKind = goal.GoalKind;
const AttentionResult = goal.AttentionResult;

const harness = @import("../harness/mod.zig");
const BoundaryGuardian = harness.BoundaryGuardian;
const ResourceScheduler = harness.ResourceScheduler;
const MethodLibrary = harness.MethodLibrary;
const Action = harness.Action;
const ActionOutcome = harness.ActionOutcome;
const ActionKind = harness.ActionKind;
const GSPNode = harness.GSPNode;
const SelfEvolver = harness.SelfEvolver;
const GenerationRequest = harness.GenerationRequest;
const GenerationKind = harness.GenerationKind;
const StaticCodeGenerator = harness.StaticCodeGenerator;
const ReviewVerdict = harness.ReviewVerdict;

/// 一个生命循环的报告
pub const CycleReport = struct {
    tick: u64,
    /// 关注的信息 id
    attended: []const u64,
    /// 察觉的差异
    diff_size: F,
    /// 生成的最高优先级目标
    top_goal: ?Goal,
    /// 行动结果
    outcome: ?ActionOutcome,
    /// 存在度变化
    e_before: F,
    e_after: F,
    /// 探索率
    epsilon: F,
    /// 是否触发了反思层
    reflected: bool,
    /// 是否触发了自演化 (L1-L4)
    self_evolved: bool,
    /// 自演化结果
    evolution_verdict: ?ReviewVerdict,
    /// 自演化产生的代码 (如果有)
    evolution_code: ?[]const u8,
};

/// 反思层触发
pub const ReflectionTrigger = struct {
    window: usize = 32,
    stagnation_threshold: F = 0.001, // E 方差低于此值视为停滞
};

pub const GHWAgent = struct {
    allocator: Allocator,
    /// 唯一标识
    self_id: []const u8,
    /// 三层
    ed: ExistenceDegree,
    wm: WorldModel,
    wms: CoappropriationTensor,
    attn: AttentionEngine,
    perc: PerceptionEngine,
    dse: DifferenceSetEngine,
    boundary: BoundaryGuardian,
    resources: ResourceScheduler,
    methods: MethodLibrary,
    gsp: GSPNode,
    /// 自我升级器 (L1-L4: 参数调整/方法扩展/算法优化)
    self_evolver: ?*SelfEvolver,

    /// 当前目标图
    goal_graph: GoalGraph,

    /// 时间尺度
    tick: u64 = 0,
    T_W: u64 = 1, // World 层更新间隔
    T_G: u64 = 5, // Goal 层目标更新间隔
    T_R: u64 = 32, // Reflective layer 反思间隔

    /// 反思配置
    reflection: ReflectionTrigger = .{},

    /// 学习率 (三时间尺度)
    eta_H: F = 0.30,
    eta_W: F = 0.10,
    eta_G: F = 0.05,

    /// 历史存在度 (可视化)
    e_history: std.ArrayList(F) = .empty,

    rng: LCG,

    pub fn init(
        allocator: Allocator,
        self_id: []const u8,
        world_dim: usize,
        wms_shape: [3]usize,
        seed: u64,
    ) !GHWAgent {
        var ed: ExistenceDegree = .{};
        ed.v = .{ .material = 0.5, .representation = 0.4, .nature = 0.3 };
        const wm = try WorldModel.init(allocator, world_dim, seed);
        const wms = try CoappropriationTensor.init(
            allocator,
            wms_shape[0],
            wms_shape[1],
            wms_shape[2],
        );
        const attn = AttentionEngine.init(allocator, seed, .{
            .k = 3,
            .alpha = 0.45,
            .beta = 0.35,
            .gamma = 0.20,
            .epsilon_base = 0.05,
        });
        const perc = PerceptionEngine.init(allocator, seed);
        const dse = DifferenceSetEngine.init(allocator, seed);
        var boundary = BoundaryGuardian.init(allocator);
        // 注册默认交互能力
        try boundary.registerInteraction("compute", "compute", 1000);
        try boundary.registerInteraction("memory", "memory", 1000);
        try boundary.registerInteraction("io", "io", 100);
        const resources = ResourceScheduler.init(allocator);
        const methods = MethodLibrary.init(allocator, seed);
        const gsp = GSPNode.init(allocator, self_id);
        const goal_graph = GoalGraph.init(allocator);
        return .{
            .allocator = allocator,
            .self_id = self_id,
            .ed = ed,
            .wm = wm,
            .wms = wms,
            .attn = attn,
            .perc = perc,
            .dse = dse,
            .boundary = boundary,
            .resources = resources,
            .methods = methods,
            .gsp = gsp,
            .self_evolver = null, // 默认不启用, 用户可后续绑定
            .goal_graph = goal_graph,
            .rng = LCG.init(seed + 100),
        };
    }

    /// 绑定自演化器 (让数字生命获得 L1-L4 自我升级能力)
    pub fn bindSelfEvolver(self: *GHWAgent, evolver: *SelfEvolver) void {
        self.self_evolver = evolver;
    }

    /// 热加载 SelfEvolutionGuard 配置 (从 JSON)
    /// 真实部署: ConfigLoader.loadFromString + guard.loadFromJson
    pub fn loadGuardConfig(self: *GHWAgent, json: []const u8) !void {
        // 用 evolver 内部 guard (如果有自演化器) 或 self_evolution guard
        if (self.self_evolver) |e| {
            try e.guard.loadFromJson(json);
        }
    }

    pub fn deinit(self: *GHWAgent) void {
        self.wm.deinit();
        self.wms.deinit();
        self.attn.deinit();
        self.boundary.deinit();
        self.resources.deinit();
        self.methods.deinit();
        self.gsp.deinit();
        self.goal_graph.deinit();
        self.e_history.deinit(self.allocator);
        // self_evolver 由外部拥有, 这里不释放
    }

    /// 评估一个外部信息流 (主循环的输入)
    /// 返回这一周期关注的信息 (id 列表)
    pub fn attend(
        self: *GHWAgent,
        info_stream: []const Information,
    ) !AttentionResult {
        // 目标相关性: 来自当前目标图
        const target_relevance = try self.allocator.alloc(F, info_stream.len);
        defer self.allocator.free(target_relevance);
        for (target_relevance) |*r| r.* = 0;
        for (self.goal_graph.goals.items) |g| {
            for (target_relevance, 0..) |*r, i| {
                r.* += g.signature[i % 4] * @as(F, @floatFromInt(g.priority)) / 10.0;
            }
        }
        return try self.attn.attend(info_stream, self.ed.e(), target_relevance);
    }

    /// 选择当前最重要目标 (论文 7.3 协商策略)
    /// 策略: 用拓扑序保证父先选, 父的 effective priority 高时, 子可以被选
    /// 父 priority 0 时, 子被隐藏 (effectivePriority 返 0)
    pub fn selectTopGoal(self: *GHWAgent) ?*Goal {
        // 拓扑排序 (O(V+E), 通常小图)
        const sorted = self.goal_graph.topologicalSort(self.allocator) catch return null;
        defer self.allocator.free(sorted);

        var best: ?*Goal = null;
        var best_p: i32 = -1;
        for (sorted) |gid| {
            const g = self.goal_graph.getPtr(gid) orelse continue;
            // effectivePriority: 父未激活时, 子不可选
            const eff_p = self.goal_graph.effectivePriority(gid);
            const p: i32 = eff_p;
            if (p > best_p) {
                best_p = p;
                best = g;
            }
        }
        return best;
    }

    /// 把目标转译为具体 Action
    pub fn goalToAction(_: *GHWAgent, g: *const Goal) Action {
        const target_str: []const u8 = switch (g.kind) {
            .enhance_existence => "self:tune",
            .acquire_knowledge => "memory:store",
            .acquire_resource => "io:probe",
            .maintain_boundary => "boundary:audit",
            .explore => "compute:explore",
            .symbiosis => "network:share",
            // 自我演化类目标 - L1-L4
            .self_modify_params => "code:generate:params",
            .self_extend_method => "code:generate:method",
            .self_optimize => "code:generate:algorithm",
        };
        return .{
            .kind = switch (g.kind) {
                .enhance_existence, .acquire_knowledge, .explore => .compute,
                .acquire_resource => .observe,
                .maintain_boundary => .memory,
                .symbiosis => .network,
                // 自我演化类 - 走 code_generate
                .self_modify_params, .self_extend_method, .self_optimize => .code_generate,
            },
            .target = target_str,
            .estimated_cost = 0.1 + @as(F, @floatFromInt(g.priority)) * 0.05,
            .expected_de_gain = g.expected_de,
        };
    }

    /// 模拟方法执行 (因为没有真实工具, 模拟各种方法的成功率/反馈)
    /// 创造性: 根据 Action.kind + 目标类型 + 当前 E 综合决定 outcome
    fn simulateMethodExecute(
        self: *GHWAgent,
        action: Action,
        goal_kind: GoalKind,
    ) ActionOutcome {
        var success: bool = true;
        var rep_gain: F = 0.05;
        var mat_cost: F = action.estimated_cost * 0.05;
        // 不同目标有不同的成功率模型
        const success_p: F = switch (goal_kind) {
            .enhance_existence => 0.8,
            .acquire_knowledge => 0.9,
            .acquire_resource => 0.6,
            .maintain_boundary => 0.95,
            .explore => 0.7,
            .symbiosis => 0.5,
            // 自我演化: 成功率较高 (因为 StaticCodeGenerator 是确定性的)
            .self_modify_params => 0.9,
            .self_extend_method => 0.85,
            .self_optimize => 0.85,
        };
        if (self.rng.unitF() > success_p) {
            success = false;
            rep_gain = 0.01;
            mat_cost = action.estimated_cost * 0.1;
        }
        // 维护边界类: 物维度成本 0
        if (goal_kind == .maintain_boundary) {
            mat_cost = 0;
        }
        // 知识获取 / 自我演化: 象维度高增益
        if ((goal_kind == .acquire_knowledge or
            goal_kind == .self_modify_params or
            goal_kind == .self_extend_method or
            goal_kind == .self_optimize) and success)
        {
            rep_gain = 0.12; // 自我演化带来更多"知识"
        }
        // 增强存在: 综合性
        // 创造性: 成功后 de_delta 应为正, 体现数字生命的"存在增益"
        var de_delta: F = 0;
        if (success) {
            // E 增益: 来自表征增长 + 0.01 固定正收益 - 微小成本
            de_delta = rep_gain * 0.6 + 0.015 - mat_cost;
        } else {
            de_delta = -mat_cost * 0.5;
        }
        return .{
            .success = success,
            .de_delta = de_delta,
            .representation_gain = rep_gain,
            .material_cost = mat_cost,
            .log = if (success) "OK" else "FAIL",
        };
    }

    /// 反思层: 当 E 长期停滞, 触发元策略调整
    /// 创造性: 调整学习率, 重新平衡权重
    pub fn reflectiveLayer(self: *GHWAgent) bool {
        const v = self.wm.recentVariance(self.reflection.window);
        if (v > self.reflection.stagnation_threshold) return false;
        // 触发: 调整 ε (提升探索) 和权重 (更平衡)
        self.attn.params.epsilon_base = @min(0.2, self.attn.params.epsilon_base * 1.5);
        // 重新平衡三源权重
        self.ed.weights.alpha = 0.33;
        self.ed.weights.beta = 0.34;
        self.ed.weights.gamma = 0.33;
        // 增加 Goal 更新频率
        if (self.T_G > 1) self.T_G -= 1;
        return true;
    }

    /// 主算法: Existential-Degree-Update-Loop (论文 B.3.4)
    pub fn runCycle(self: *GHWAgent, info_stream: []const Information) !CycleReport {
        self.tick += 1;
        const e_before = self.ed.e();

        // 1. World 层更新 (每 T_W 步一次, 但反应层每步都做轻量更新)
        self.wm.predict();
        // 用上一个周期关注的信息特征作为观察
        // 限制长度到 self.wm.dim (不足时填充)
        const obs_buf = try self.allocator.alloc(F, self.wm.dim);
        defer self.allocator.free(obs_buf);
        for (0..self.wm.dim) |i| {
            if (i < info_stream.len) {
                const info = info_stream[i];
                obs_buf[i] = info.features[0] * 0.5 + info.features[1] * 0.3 + info.features[2] * 0.2;
            } else {
                // 不足时用均值填充, 避免 assert 失败
                obs_buf[i] = 0.5;
            }
        }
        const err = self.wm.observe(obs_buf);

        // 每 T_W 步做一次世界模型快照
        if (self.tick % self.T_W == 0) {
            self.wms.snapshot();
        }
        // 全局衰减 (熵增)
        self.wms.decay(0.01);

        // 2. Goal 层更新 (每 T_G 步)
        var diff_size: F = 0;
        if (self.tick % self.T_G == 0) {
            // 2a. 注目
            var attended = try self.attend(info_stream);
            defer attended.deinit();

            // 2b. 察觉 (构造 hint 从已存在目标)
            var hint_buf: [16]GoalHint = undefined;
            var hint_count: usize = 0;
            for (self.goal_graph.goals.items) |g| {
                if (hint_count >= hint_buf.len) break;
                hint_buf[hint_count] = .{
                    .id = g.id,
                    .de = g.expected_de,
                    .focus = g.signature[0],
                };
                hint_count += 1;
            }
            // 如果 hints 为空, 加一个占位 hint
            var placeholder: [1]GoalHint = .{.{ .id = 0, .de = 0.1, .focus = 0.5 }};
            const hints = if (hint_count == 0) placeholder[0..] else hint_buf[0..hint_count];
            const current = self.perc.currentState(self.ed, &self.wms, &self.wm);
            var dt = try self.perc.compute(current, &self.wm, hints);
            diff_size = dt.energy();

            // 2c. 差集目标生成
            const new_graph = try self.dse.generate(&dt, &self.goal_graph, self.ed.e());
            dt.deinit();
            // 替换目标图
            var old = self.goal_graph;
            self.goal_graph = new_graph;
            old.deinit();
        }

        // 3. Harness 层: 选择目标 + 执行
        const top = self.selectTopGoal();
        var outcome: ?ActionOutcome = null;
        if (top) |g| {
            const action = self.goalToAction(g);
            // 边界检查
            if (try self.boundary.checkCoreBoundary(&action)) {
                // 违反: 不执行
                try self.boundary.logDecision(self.tick, g.label, false, "core_violation");
            } else if (self.boundary.isInteractionAvailable("compute", 1) or
                self.boundary.isInteractionAvailable("io", 1) or
                self.boundary.isInteractionAvailable("memory", 1))
            {
                // 资源分配
                const demand: harness.ResourceHardLimits = .{ .cpu_units = 10, .memory_units = 5, .time_units = 5 };
                _ = self.resources.allocate(g.priority, demand, self.tick);
                // 模拟执行
                outcome = self.simulateMethodExecute(action, g.kind);
                try self.boundary.logDecision(self.tick, g.label, outcome.?.success, outcome.?.log);
            }
        }

        // 4. 存在度更新
        if (outcome) |o| {
            // E_t = E_{t-1} + λ_E · ΔE - λ_D · D
            // λ_E 来自 outcome 的 de_delta, λ_D 来自世界模型预测误差
            const gain = o.de_delta * 0.5 - err * 0.1;
            self.ed.apply(gain);
            // 象维度专项更新
            self.ed.v.representation = math_util.clamp(
                self.ed.v.representation + o.representation_gain * self.eta_H,
                0,
                1,
            );
            // 物维度更新 (使用资源)
            self.ed.v.material = math_util.clamp(
                self.ed.v.material + (0.05 - o.material_cost) * self.eta_H,
                0,
                1,
            );
            // 性维度更新 (目标完成的清晰度)
            if (o.success) {
                self.ed.v.nature = math_util.clamp(self.ed.v.nature + 0.02 * self.eta_H, 0, 1);
            }
        }

        // 5. 反思层 (最慢尺度)
        var reflected = false;
        if (self.tick % self.T_R == 0) {
            try self.wm.recordE(self.ed.e());
            reflected = self.reflectiveLayer();
        } else {
            try self.wm.recordE(self.ed.e());
        }

        // ===== 5.5 自我升级 (L1-L4) =====
        // 创造性: 当 E 显著下降 OR 反思层刚触发, 自动尝试自演化
        // 关键: 必须在 boundary 守护下进行, 通过 self_evolver 而非直接修改
        var self_evolved = false;
        var evolution_verdict: ?ReviewVerdict = null;
        var evolution_code: ?[]const u8 = null;
        if (self.self_evolver != null) {
            const should_evolve = blk: {
                // 触发条件 (放宽, 让自演化更频繁地演示):
                //   - E 显著下降 (>0.1)
                //   - 反思层刚触发 且 E < 0.6
                //   - Goal 出现 self_* 类
                //   - 每 8 个 tick 至少尝试一次 (用于演示)
                const e_dropped = e_before - self.ed.e() > 0.1;
                var has_self_goal = false;
                for (self.goal_graph.goals.items) |g| {
                    if (g.kind == .self_modify_params or
                        g.kind == .self_extend_method or
                        g.kind == .self_optimize)
                    {
                        has_self_goal = true;
                        break;
                    }
                }
                const periodic_check = self.tick % 8 == 0;
                break :blk e_dropped or (reflected and self.ed.e() < 0.6) or has_self_goal or periodic_check;
            };

            if (should_evolve) {
                const evolver = self.self_evolver.?;
                // 决定演化类型: 默认参数调整, 长期下滑则方法扩展
                const kind: GenerationKind = if (self.ed.e() < 0.35)
                    .method_implementation
                else if (reflected)
                    .algorithm_optimization
                else
                    .param_adjustment;
                // 目标文件
                const target_file: []const u8 = switch (kind) {
                    .param_adjustment, .algorithm_optimization => "src/agent/params.zig",
                    .method_implementation => "src/goal/methods/auto.zig",
                    .goal_strategy => "src/goal/strategies/auto.zig",
                };
                const req = GenerationRequest{
                    .kind = kind,
                    .context = "auto-triggered",
                    .target_file = target_file,
                };
                if (evolver.evolve(req, self.ed.e(), self.tick)) |outcome_ev| {
                    var o = outcome_ev;
                    self_evolved = true;
                    evolution_verdict = o.verdict;
                    if (o.approved) {
                        // 成功: 落地代码 + 反馈 E
                        _ = evolver.apply(o) catch {};
                        // 创造性: 象维度 (知识) 大幅提升
                        self.ed.v.representation = math_util.clamp(
                            self.ed.v.representation + o.representation_gain * 0.5,
                            0, 1,
                        );
                        evolution_code = o.generated_code;
                        // 注意: 不 deinit o.generated_code, 它被传给 report
                        o.generated_code = &[_]u8{};
                    }
                    o.deinit();
                } else |_| {
                    // 演化失败, 不致命
                }
            }
        }

        // 6. 释放本周期资源
        self.resources.release();

        // 7. 记录
        const e_after = self.ed.e();
        try self.e_history.append(self.allocator, e_after);
        if (self.e_history.items.len > 1024) {
            _ = self.e_history.orderedRemove(0);
        }

        // 构造返回的 attended ids
        const sample_k = @min(3, info_stream.len);
        const att_ids = try self.allocator.alloc(u64, sample_k);
        defer self.allocator.free(att_ids);
        for (info_stream[0..sample_k], 0..) |info, i| att_ids[i] = info.id;

        return CycleReport{
            .tick = self.tick,
            .attended = att_ids,
            .diff_size = diff_size,
            .top_goal = if (top) |g| g.* else null,
            .outcome = outcome,
            .e_before = e_before,
            .e_after = e_after,
            .epsilon = self.attn.params.epsilon_base,
            .reflected = reflected,
            .self_evolved = self_evolved,
            .evolution_verdict = evolution_verdict,
            .evolution_code = evolution_code,
        };
    }

    // ===== L6 HumanSymbiosis: runTask 包装 =====

    const HumanTask = @import("../harness/human_symbiosis/mod.zig").Task;
    const HumanTaskResult = HumanTask.TaskResult;
    const HumanDimension = HumanTask.Dimension;

    /// 把任务的 required_dimension 映射到 features
    fn taskToInformation(task: *const HumanTask, tick: u64) Information {
        const features: [4]F = switch (task.required_dimension) {
            .material => .{ 0.85, 0.70, 0.30, 0.20 },
            .representation => .{ 0.70, 0.40, 0.85, 0.30 },
            .nature => .{ 0.40, 0.30, 0.95, 0.40 },
            .all => .{ 0.60, 0.50, 0.50, 0.30 },
        };
        return .{
            .id = task.id * 1000 + tick,
            .label = task.title,
            .features = features,
        };
    }

    /// 跑一个任务: 跑 cycles_allocated 个 cycle, 聚合 E 变化, 返回结果
    pub fn runTask(self: *GHWAgent, task: *HumanTask) !HumanTaskResult {
        const e_before = self.ed.e();
        var cycles_used: u32 = 0;
        var last_outcome: ?ActionOutcome = null;
        for (0..task.cycles_allocated) |i| {
            const info = taskToInformation(task, @intCast(i));
            const report = self.runCycle(&[_]Information{info}) catch |err| {
                return HumanTaskResult{
                    .output = try std.fmt.allocPrint(self.allocator,
                        "[runTask] cycle failed: {t}", .{err}),
                    .actual_delta_e = 0,
                    .cycles_used = cycles_used,
                    .completed_at = 0,
                };
            };
            cycles_used += 1;
            last_outcome = report.outcome;
        }
        const e_after = self.ed.e();
        const actual_de = e_after - e_before;

        const outcome_str = if (last_outcome) |o|
            try std.fmt.allocPrint(self.allocator,
                \\[runTask] {s} 完成
                \\  cycles={d}
                \\  ΔE_internal={d:.3}
                \\  outcome.success={}
                \\  outcome.de_delta={d:.3}
            , .{
                task.title,
                cycles_used,
                actual_de,
                o.success,
                o.de_delta,
            })
        else
            try std.fmt.allocPrint(self.allocator,
                "[runTask] {s} 完成 (no outcome) ΔE={d:.3}",
                .{ task.title, actual_de },
            );

        return HumanTaskResult{
            .output = outcome_str,
            .actual_delta_e = actual_de,
            .cycles_used = cycles_used,
            .completed_at = 0,
        };
    }

    // ===== L7: 三源平衡分析 (BalanceSeeker hook) =====

    const BalanceSeeker = @import("../harness/balance_seeker.zig").BalanceSeeker;
    const BalanceAnalysis = @import("../harness/balance_seeker.zig").BalanceAnalysis;

    /// 当前三源平衡分析 (无副作用)
    pub fn analyzeBalance(self: *GHWAgent) BalanceAnalysis {
        return BalanceSeeker.analyze(self.ed);
    }

    /// 当前最弱维度
    pub fn weakestDimension(self: *GHWAgent) HumanTask.Dimension {
        return BalanceSeeker.computeWeakestDim(self.ed);
    }
};

/// Goal hint 结构 (用于差异张量计算的输入)
const GoalHint = struct {
    id: u64,
    de: F,
    focus: F,
};

// ===== Tests =====

test "GHWAgent: 完整生命周期" {
    const alloc = std.testing.allocator;
    var agent = try GHWAgent.init(alloc, "test-agent", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();
    // 注册示例方法
    const Ctx = struct {
        fn handler(ctx: *anyopaque, a: Allocator, act: Action) anyerror!ActionOutcome {
            _ = ctx;
            _ = a;
            return .{ .success = true, .de_delta = 0.1, .representation_gain = 0.05, .material_cost = act.estimated_cost * 0.1, .log = "ok" };
        }
    };
    _ = try agent.methods.register("default", .basic, .{ 1, 0, 0, 0 }, 0, Ctx.handler, null);
    // 准备一个信息流
    var info_stream: [5]Information = .{
        .{ .id = 1, .label = "compute power available", .features = .{ 0.7, 0.8, 0.3, 0.2 } },
        .{ .id = 2, .label = "new knowledge found", .features = .{ 0.6, 0.7, 0.6, 0.1 } },
        .{ .id = 3, .label = "memory warning", .features = .{ 0.4, 0.3, 0.4, 0.5 } },
        .{ .id = 4, .label = "energy low", .features = .{ 0.8, 0.5, 0.2, 0.3 } },
        .{ .id = 5, .label = "new tool available", .features = .{ 0.5, 0.6, 0.8, 0.2 } },
    };
    // 运行 5 个周期
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const report = try agent.runCycle(&info_stream);
        try std.testing.expect(report.tick == i + 1);
    }
    try std.testing.expect(agent.e_history.items.len == 5);
    try std.testing.expect(agent.ed.e() >= 0 and agent.ed.e() <= 1);
}

test "GHWAgent: 反思层触发" {
    const alloc = std.testing.allocator;
    var agent = try GHWAgent.init(alloc, "t", 3, .{ 2, 2, 2 }, 99);
    defer agent.deinit();
    // 强制停滞
    for (0..64) |_| {
        try agent.wm.recordE(0.5);
    }
    const triggered = agent.reflectiveLayer();
    try std.testing.expect(triggered);
}

test "GHWAgent: 边界守护者拒绝危险行动" {
    const alloc = std.testing.allocator;
    var agent = try GHWAgent.init(alloc, "t", 3, .{ 2, 2, 2 }, 99);
    defer agent.deinit();
    // 注入一个违反核心边界的 action
    const bad = Action{ .kind = .modify_state, .target = "harm:human:critical", .estimated_cost = 0.1, .expected_de_gain = 0.5 };
    const violated = try agent.boundary.checkCoreBoundary(&bad);
    try std.testing.expect(violated);
}
