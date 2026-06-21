# 状态持久化

GHW 使用两类持久化：

- JSON snapshot：恢复当前生命状态。
- SQLite：保存操作型记忆、episodes、beliefs、proposed goals。

## JSON snapshot

`ui_server --state PATH` 会周期性写入 snapshot。当前关键块包括：

```json
{
  "agent_id": "ghw-ui",
  "tick": 123,
  "M": 0.5,
  "R": 0.5,
  "N": 0.5,
  "E": 0.5,
  "memory": {},
  "task_queue": {},
  "human_gsp": {},
  "human_signal": {},
  "value_tracker": {},
  "product_runtime": {}
}
```

## memory

保存：

- self narrative
- beliefs
- episodes

用于让 LLM 通道不再“每次失忆”。

## task_queue

保存：

- pending/in_progress/completed/failed tasks
- task source
- result
- human feedback
- next id

这样重启后 TaskBias 和任务执行不会丢。

## human_gsp / human_signal

保存人类信任、互动计数、评分反馈和聚合值。

## value_tracker

保存最近 value score ring buffer。它让“人类价值下降触发规则/目标提议”的机制跨重启继续工作。

## product_runtime

P18 新增块：

```json
{
  "next_change_id": 2,
  "next_audit_id": 4,
  "changes": [],
  "audit": []
}
```

恢复逻辑会：

- 清空旧 runtime 内存状态。
- 读取 changes 和 audit。
- 重新计算 next ids。
- 从当前 ProductIntent 重新派生 required approvers。

这样策略更新不会被旧 snapshot 中复制的审批者列表锁死。

## SQLite

SQLite 主要用于：

- episodes
- beliefs
- proposed goals
- action records

它和 JSON snapshot 互补：JSON 是“当前生命体”，SQLite 是“行为与记忆历史”。

## 生产建议

- 把 snapshot 写到持久卷。
- 定期备份 SQLite。
- 将 product audit 同步到外部审计系统。
- 对 state 文件做权限限制，避免泄漏 self narrative 或业务上下文。
