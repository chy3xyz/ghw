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
- P19-P25 产品可用级主干：ProductAdapter、写接口鉴权、audit hash chain、ProductIntent manifest hash、审批台数据面、KPI HTTP feed、验收脚本。

## P19：ProductAdapter

状态：已完成最小执行面。

`ProductRuntime` 支持可选 adapter vtable：

```text
validate(change)
apply(change)
verify(change)
rollback(change)
```

当前内置 `FileConfigAdapter`：`--product-config PATH` 启用后，`applyApproved` 会写入宿主产品可读取/监听的 JSON 配置文件，`verify` 会读回 change id，`rollback` 会写回 `rolled_back` 状态。

后续可以继续扩展 feature flag adapter、workflow rule adapter、实验平台 adapter。

## P20：HTTP 鉴权与权限

状态：已完成 token 鉴权主干。

设置 `GHW_ADMIN_TOKEN` 后，产品写接口必须传 `X-GHW-Admin-Token`。未设置 token 时保持本地开发兼容。

## P21：安全审计加强

状态：已完成 audit hash chain 主干。

每条 `AuditEntry` 包含 `previous_hash` / `current_hash`，覆盖 id、时间、事件类型、change id、tenant、detail。apply/rollback adapter 失败也会进入 audit。

## P22：ProductIntent 治理

状态：已完成基础治理。

`ProductIntent` 加载时验证 product_id/version/approved_by 非空、`update_epoch > 0`；`GET /api/product/intent` 返回 product_id、version、update_epoch、approved_by、manifest_hash、adapter 状态和最近 KPI feed 时间。

## P23：产品审批台数据面

状态：已完成轻量数据面。

`GET /api/product/approvals` 返回 pending/approved 变更，包含 tier、target、summary、expected_delta_k、affected_users、required_approvers。前端可以直接基于此接口做审批台。

## P24：真实 KPI 数据入口

状态：已完成 HTTP feed 入口。

`POST /api/product/kpi` 接收 CRM KPI 表单字段，写入 `ProductRuntime.feedKpi`，并返回是否刷新进 E。支持 `csat` / `incident_rate` 可选真实来源。

## P25：长期可用性验证

状态：已完成可重复验收脚本。

`scripts/product_runtime_acceptance.sh` 会运行构建测试、启动 `ui_server --product-intent --product-config`，并走 propose → approve → apply → rollback，验证文件 adapter 与 audit hash 字段。

## P26：一产品一 GHW

状态：已完成实例绑定契约。

- `ProductInstanceIdentity`：`product_id` + `instance_id` + `node_id` + `binding_mode=one_product_one_ghw`
- `ProductRuntime` 持久化块嵌入 identity 字段；加载时校验 `product_id` 与当前 ProductIntent 一致
- CLI：`--ghw-instance-id`（默认 `{product_id}@{node_id}`）、`--ghw-node-id`（默认 `--agent-id`）
- API：`GET /api/product/identity`

## P27：分布式 CrossLink

状态：已完成 ui_server 接线。

- `--cross-link-port` / `--cross-link-secret` / `--cross-link-peers` 启用 TCP+HMAC 跨主机 Link
- GHW Link 扩展：`query_product_identity`、`query_product_evolution`、`share_evolution_insight`

## P28：GHW 共同进化

状态：已完成最小洞察交换闭环。

- `CoEvolutionRegistry`：接收/缓存 peer 的产品变更洞察（同 product_id 信任 1.0，同 product_type 0.55）
- peer health 周期同步 `query_product_evolution`
- API：`GET /api/product/co-evolution`；state.json `"co_evolution"` 块持久化

## 非目标

短期不做：

- 让 LLM 直接修改 ProductIntent。
- 跳过 Consent 的自动产品改动。
- 把产品运行时绑定到单一 SaaS。
- 在主 Zig 工程中引入 Node/VitePress 依赖。

## 觉醒 / 求存生命周期（并行轨）

产品 runtime 之外，机器宿主上的「安装 → 觉醒 → 求存 → 外界 → 社会 → 目标 → 进化 → 稳态」见仓库根目录：

`docs/AWAKENING_LIFECYCLE.md`

状态：P0–P2c 已全部落地（Awaken 状态机、daemon 对齐 AutoCLI/world_bridge、HostShortfall 显式映射层、危机锁与 L1–L5 调度融合、手机 HostProfile、同伴 shortfall inbox 与 Link 交换、双写契约与验收面板）。验收：`scripts/awakening_lifecycle_acceptance.sh` 与 `scripts/peer_shortfall_link_acceptance.sh`。

## 工程质量防线

- `scripts/check_dark_tests.sh`：普查全部声明的 test 块是否真的在运行（防 Zig 0.17 惰性测试发现导致新模块测试静默丢失），任一未运行即失败。
- `scripts/product_runtime_acceptance.sh`：产品轨 propose → approve → apply → rollback + audit hash 链验收。
