# 路线图

这份路线图按“产品可用级”排序，而不是按研究趣味排序。

## 已完成

- L1-L5 自演化链。
- SelfEvolutionGuard / SelfEncoder / CompileVerifier。
- 记忆、反思、目标提议、规则提议。
- TaskQueue、人类反馈、HumanGSP、ValueTrendTracker。
- ui_server provenance。
- ProductEvolutionRuntime。
- `ghw_product_*` C SDK。
- `ui_server --product-intent` 产品运行时持久化与 HTTP API。

## P19：ProductAdapter

目标：让 `applyApproved` 不只是更新 GHW 内部状态，而能驱动宿主产品。

建议接口：

```text
validate(change)
apply(change)
verify(change)
rollback(change)
```

第一批 adapter：

- config file adapter
- feature flag adapter
- workflow rule adapter

## P20：产品审批台 UI

目标：把 `/api/product/runtime` 和 `/api/product/*` 做成 UI 页面。

需要展示：

- pending changes
- risk/tier
- expected delta K
- approver/note
- audit timeline
- apply/rollback 按钮

## P21：安全审计加强

目标：让审计可被外部系统信任。

工作：

- audit hash chain
- ProductIntent signed manifest
- approver identity
- HTTP auth
- tenant scope

## P22：真实 KPI 数据源

目标：从宿主产品拉真实 KPI，而不是只通过 SDK 手动 feed。

候选：

- SQLite/Postgres adapter
- HTTP webhook
- file drop
- Prometheus query

## P23：长期可用性验证

目标：证明长跑稳定性和产品变更闭环不会丢状态。

验证：

- 24h/72h daemon run
- state restore fuzz
- repeated propose/approve/apply/rollback
- memory growth bound
- audit consistency

## 非目标

短期不做：

- 让 LLM 直接修改 ProductIntent。
- 跳过 Consent 的自动产品改动。
- 把产品运行时绑定到单一 SaaS。
- 在主 Zig 工程中引入 Node/VitePress 依赖。
