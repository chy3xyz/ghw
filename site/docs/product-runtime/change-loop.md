# 变更、审批与审计

产品运行时的核心是把“想改产品”变成一条可治理的状态机。

## 状态机

```text
proposed / pending_consent
  -> approved
  -> applied
  -> rolled_back

pending_consent
  -> denied
```

minor 变更可以直接进入 `approved`，非 minor 变更默认进入 `pending_consent`。

## 提案字段

`ChangeProposal` 保存：

- `tenant_id`
- `kind`：`config`、`workflow`、`feature_flag`、`code_patch`、`experiment`
- `target`
- `summary`
- `rationale`
- `expected_delta_k`
- `affected_users`
- `reversible`
- `tier`
- `risk`
- `status`
- `created_at`
- 审批人和审批备注

## HTTP 操作

提交 CRM 样板提案：

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

审批：

```bash
curl -X POST http://127.0.0.1:8765/api/product/approve \
  -d 'change_id=1&approver=sales_manager&note=approved'
```

应用：

```bash
curl -X POST http://127.0.0.1:8765/api/product/apply \
  -d 'change_id=1'
```

回滚：

```bash
curl -X POST http://127.0.0.1:8765/api/product/rollback \
  -d 'change_id=1'
```

查询：

```bash
curl http://127.0.0.1:8765/api/product/runtime
curl http://127.0.0.1:8765/api/product/audit
```

## 审计事件

审计日志包括：

- `kpi_refreshed`
- `change_proposed`
- `consent_decision`
- `change_applied`
- `change_rolled_back`

每条记录包含时间、tenant、change id 和 detail。

## 当前边界

`applyApproved` 当前只改变 GHW 内部状态并写 audit。生产中必须接入 ProductAdapter：

```text
ChangeProposal
  -> ProductAdapter.validate
  -> ProductAdapter.apply
  -> ProductAdapter.verify
  -> Audit
```

这能防止“审计说已应用，但宿主产品没有真的变化”的错位。
