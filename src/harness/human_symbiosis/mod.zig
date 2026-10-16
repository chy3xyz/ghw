//! L6 HumanSymbiosis: 数字生命跟人类的共生层
//!
//! 4 个模块:
//!   - HumanSignal   — 人类反馈 → ΔE
//!   - TaskQueue     — 任务队列 + 优先级
//!   - HumanGSP      — 跟人类的信任协议
//!   - ValueMetric   — 综合价值报表
//!
//! 论文 B.5.3 + 我们自己的扩展

pub const human_signal = @import("human_signal.zig");
pub const task_queue = @import("task_queue.zig");
pub const human_gsp = @import("human_gsp.zig");
pub const value_metric = @import("value_metric.zig");
pub const chat_task = @import("chat_task.zig");
pub const chat_reply = @import("chat_reply.zig");

pub const HumanFeedback = human_signal.HumanFeedback;
pub const HumanSignal = human_signal.HumanSignal;
pub const Task = task_queue.Task;
pub const TaskQueue = task_queue.TaskQueue;
pub const HumanPeer = human_gsp.HumanPeer;
pub const HumanGSP = human_gsp.HumanGSP;
pub const ValueMetric = value_metric.ValueMetric;
pub const ValueTrendTracker = value_metric.ValueTrendTracker;
pub const computeScore = value_metric.computeScore;
pub const computeHumanScore = value_metric.computeHumanScore;
pub const ChatTask = chat_task;
