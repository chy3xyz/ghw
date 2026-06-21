# 产品数字生命底座

GHW 的产品底座目标是：让一个软件产品拥有可审计、可审批、可回滚、可持续学习的演化内核。

它不是让 agent 直接改生产系统，而是提供一条强制闭环：

```text
ProductIntent
  -> KPI
  -> ChangeProposal
  -> Consent
  -> Apply / Rollback
  -> Audit
  -> Existence Degree
```

## 已具备的能力

| 能力 | 状态 | 入口 |
| --- | --- | --- |
| ProductIntent 加载 | 已实现 | `product_intent.example.crm.json`, `--product-intent` |
| KPI 进入 E | 已实现 | `KpiBridge`, `ghw_product_kpi_feed` |
| 变更提案 | 已实现 | `ProductEvolutionRuntime.proposeChange` |
| CRM 样板提案 | 已实现 | `proposeCrmFollowupTightening` |
| 审批/拒绝 | 已实现 | `approve`, `deny` |
| 应用/回滚状态机 | 已实现 | `applyApproved`, `rollbackApplied` |
| 审计日志 | 已实现 | `auditJson`, `/api/product/audit` |
| 持久化恢复 | 已实现 | `product_runtime` state block |
| 真实产品 Adapter | 规划中 | 需要宿主系统实现 |

## 运行时结构

`ProductEvolutionRuntime` 持有：

- `product`：只读 ProductIntent。
- `bridge`：KPI Bridge，用于把原始产品指标变成 `K`。
- `changes`：产品变更提案列表。
- `audit`：KPI 刷新、提案、审批、应用、回滚日志。
- `next_change_id` / `next_audit_id`：跨重启递增 ID。

## 启用方式

```bash
./zig-out/bin/ui_server \
  --state /tmp/ghw-product-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

启用后：

- `saveState` 会保存 `"product_runtime"` 块。
- 启动时会恢复 `changes` 和 `audit`。
- `/api/product/*` endpoints 可用。

## 边界

当前 `applyApproved` 表示“GHW 已进入应用状态并写审计”，但不直接修改宿主产品。生产接入需要一个产品 Adapter，把已审批变更映射到：

- 配置中心
- feature flag
- 工作流规则
- 实验平台
- 代码生成/部署流水线

这是下一阶段产品可用级工作的重点。
