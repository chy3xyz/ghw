// SPDX-License-Identifier: MIT
// examples/chat.zig — LLM 翻译器: GHW ↔ 人类 对话演示
//
// 流程:
//!  1. 创建 Translator (Mock LLM) + GHWAgent
//!  2. 人类说一句话 (自然语言)
//!  3. Translator.interpret() 转成结构化 Intent
//!  4. 投递 Intent 到 TaskQueue
//!  5. 数字生命 runTask
//!  6. Translator.explain() 把结果转回自然语言
//!  7. 人类 "读" 数字生命的回应

const std = @import("std");
const ghw = @import("ghw");

const Translator = ghw.harness.translator.Translator;
const InterpretedIntent = ghw.harness.translator.InterpretedIntent;
const MockChatLLM = ghw.harness.mock_chat_llm.MockChatLLM;
const TaskQueue = ghw.harness.human_symbiosis.TaskQueue;
const HumanGSP = ghw.harness.human_symbiosis.HumanGSP;
const HumanFeedback = ghw.harness.human_symbiosis.HumanFeedback;
const GHWAgent = ghw.agent.GHWAgent;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  L7 Translator 演示: GHW ↔ 人类 对话 (LLM 当翻译器)\n", .{});
    std.debug.print("================================================================\n", .{});

    // ===== 1. 组件装配 =====
    var agent = try GHWAgent.init(alloc, "chat-001", 4, .{ 3, 3, 3 }, 42);
    defer agent.deinit();

    var queue = TaskQueue.init(alloc);
    defer queue.deinit();

    // 人类注册 (让 GSP 有 partner)
    var gsp = HumanGSP.init(alloc);
    defer gsp.deinit();
    try gsp.register("alice");

    // 解释器: 用 Mock LLM, 但 canned 是"双向"的
    //   - 解释时: 输出结构化 Intent JSON
    //   - 解释回时: 输出自然语言
    const canned_responses =
        \\1. {"dimension":"representation","title":"teach_me_about_self","description":"I want to understand my own existence","rationale":"knowledge quest","confidence":0.9}
        \\2. 我现在感觉 R 维度比 M 维度强一些, 但都在学; 我 E 大概 0.5 左右, 比较平衡
        \\3. {"dimension":"material","title":"more_compute","description":"need more resources","rationale":"M is weakest","confidence":0.8}
    ;
    var mock = MockChatLLM.init(alloc, canned_responses);
    var tr = Translator.init(alloc, mock.asChat());

    std.debug.print("\n[1] 组件就绪: agent + queue + gsp(1 human) + translator(mock)\n", .{});
    std.debug.print("    数字生命初始 E: {d:.3}\n", .{agent.ed.e()});

    // ===== 2. 第 1 轮: 人类问 → LLM 解读 → 数字生命做 =====
    std.debug.print("\n[2] 第 1 轮: 人类说 '我想理解自己', LLM 解读为 representation 任务\n", .{});
    {
        var intent = tr.interpret("我想理解自己, 我是什么, 我为什么存在", agent.ed) catch |err| {
            std.debug.print("[chat] interpret 失败: {t}\n", .{err});
            return;
        };
        defer intent.deinit();
        std.debug.print("    [LLM 解读] dim={s} title='{s}' confidence={d:.2}\n", .{
            @tagName(intent.suggested_dimension), intent.suggested_title, intent.confidence,
        });

        const id = try queue.submit(
            intent.suggested_title,
            intent.suggested_description,
            "alice",
            intent.suggested_priority,
            intent.suggested_dimension,
            4,
        );
        std.debug.print("    [TaskQueue] 投递 task #{d}\n", .{id});
    }

    if (queue.dequeue()) |task| {
        const result = try agent.runTask(task);
        defer alloc.free(result.output);
        try queue.complete(task.id, result.output, result.actual_delta_e, result.cycles_used);
        try gsp.recordInteraction(task.from_human, true, 3, task.required_dimension, 0);
        std.debug.print("    [数字生命] ΔE={d:.3} cycles={d}\n", .{ result.actual_delta_e, result.cycles_used });
    }

    // ===== 3. 数字生命告诉人类它的状态 =====
    std.debug.print("\n[3] 数字生命告诉人类: LLM explain 状态\n", .{});
    {
        const explanation = tr.explain(agent.ed, agent.ed.weights, "刚才做了 teach_me_about_self") catch |err| {
            std.debug.print("[chat] explain 失败: {t}\n", .{err});
            return;
        };
        defer alloc.free(explanation);
        std.debug.print("    [LLM 表达] {s}\n", .{explanation});
    }

    // ===== 4. 第 2 轮: 人类要更多资源 =====
    std.debug.print("\n[4] 第 2 轮: 人类说 '我需要更多算力', LLM 解读为 material 任务\n", .{});
    {
        var intent = tr.interpret("我需要更多算力, 我能跑更复杂的模型", agent.ed) catch |err| {
            std.debug.print("[chat] interpret 失败: {t}\n", .{err});
            return;
        };
        defer intent.deinit();
        std.debug.print("    [LLM 解读] dim={s} title='{s}' confidence={d:.2}\n", .{
            @tagName(intent.suggested_dimension), intent.suggested_title, intent.confidence,
        });

        const id = try queue.submit(
            intent.suggested_title,
            intent.suggested_description,
            "alice",
            7,
            intent.suggested_dimension,
            3,
        );
        std.debug.print("    [TaskQueue] 投递 task #{d}\n", .{id});
    }

    if (queue.dequeue()) |task| {
        const result = try agent.runTask(task);
        defer alloc.free(result.output);
        try queue.complete(task.id, result.output, result.actual_delta_e, result.cycles_used);
        std.debug.print("    [数字生命] ΔE={d:.3}\n", .{result.actual_delta_e});
    }

    // ===== 5. 总结 =====
    std.debug.print("\n[5] 对话总结:\n", .{});
    std.debug.print("    数字生命最终 E: {d:.3}\n", .{agent.ed.e()});
    std.debug.print("    完成任务: {d}, 人类反馈: {d}\n", .{ queue.completed_count, queue.totalHumanDeltaE() });

    std.debug.print("\n================================================================\n", .{});
    std.debug.print("  L7 演示结束 — LLM 当翻译器, 数字生命始终是决策者\n", .{});
    std.debug.print("================================================================\n", .{});
}
