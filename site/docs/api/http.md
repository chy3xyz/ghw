# HTTP API

`ui_server` 暴露监控、聊天、任务、人类反馈、产品运行时等接口。默认监听 `127.0.0.1:<port>`。

## 启动

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json \
  --product-config /tmp/ghw-product-config.json
```

生产写接口建议设置 `GHW_ADMIN_TOKEN`，调用时传 `X-GHW-Admin-Token`。

## 核心状态

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/state` | 当前 E/M/R/N、tick、目标、provenance、任务统计 |
| `GET` | `/api/log` | 最近增长日志 |
| `GET` | `/api/capabilities` | 能力地图和阶段进度 |
| `GET` | `/api/metrics` | Prometheus metrics |

## Chat 与记忆

| Method | Path | 说明 |
| --- | --- | --- |
| `POST` | `/api/chat` | 发送人类消息，触发 cycle 和回复 |
| `GET` | `/api/chat/history` | 获取 chat HTML fragment |
| `GET` | `/api/memory/search?q=...&limit=N` | 搜索自传体记忆 |

`/api/state` 的 `provenance.chat` 会显示最近一次回复是否注入 memory context。

## 任务与人类反馈

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/tasks` | 查询 TaskQueue |
| `POST` | `/api/tasks` | 显式投递 human task |
| `POST` | `/api/task/feedback` | 给完成任务评分 |

示例：

```bash
curl -X POST http://127.0.0.1:8765/api/tasks \
  -d 'title=检查CRM跟进策略&description=评估7d到5d的风险&required_dimension=representation&priority=7'
```

## 产品运行时

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/product/runtime` | 查询 changes + audit 完整状态 |
| `GET` | `/api/product/audit` | 只查询 audit |
| `GET` | `/api/product/intent` | 查询 ProductIntent identity、update_epoch、manifest_hash、adapter 状态 |
| `GET` | `/api/product/approvals` | 查询审批台数据：pending/approved changes |
| `POST` | `/api/product/propose-crm-followup` | 提交 CRM 样板提案 |
| `POST` | `/api/product/approve` | 审批变更 |
| `POST` | `/api/product/apply` | 应用已审批变更 |
| `POST` | `/api/product/rollback` | 回滚已应用变更 |
| `POST` | `/api/product/kpi` | feed 真实产品 KPI 到 ProductRuntime |

未启用 `--product-intent` 时，产品接口返回 503 JSON：

```json
{
  "error": "product runtime disabled; start ui_server with --product-intent PATH"
}
```

非法状态转换返回 400 JSON，例如未审批就 apply。

受保护写接口示例：

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -H "X-GHW-Admin-Token: $GHW_ADMIN_TOKEN" \
  -d 'tenant_id=acme&affected_users=45&expected_delta_k=0.05'
```

KPI feed 示例：

```bash
curl -X POST http://127.0.0.1:8765/api/product/kpi \
  -H "X-GHW-Admin-Token: $GHW_ADMIN_TOKEN" \
  -d 'nrr_quarterly=0.88&deal_win_rate=0.24&sales_cycle_days_p50=48&weekly_active_sales_pct=0.71&csat=0.92&incident_rate=0.01'
```

启用 `--product-config PATH` 后，`/api/product/apply` 会通过文件 adapter 写入宿主产品配置，`/api/product/rollback` 会写回 `rolled_back` 状态。审计日志包含 `previous_hash` 与 `current_hash`。

## 自演化与行动

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/evolved` | 列出自演化落盘文件 |
| `GET` | `/api/evolved/<file>` | 读取某个落盘文件 |
| `GET` | `/api/l1l5_trend` | L1-L5 计数趋势 |
| `POST` | `/api/action/run-now` | 立即运行一个 action |
| `GET` | `/api/action/list` | 动作历史 |

## Peer

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/peers` | 本机已知 peer |
| `POST` | `/api/peer/query?path=...&method=...` | 手动查询 peer |

## 注意事项

- 当前 HTTP server 是轻量内置实现，不是完整反向代理。
- 生产部署建议放在内网或反向代理之后。
- `GHW_ADMIN_TOKEN` 是最小鉴权主干；多人生产环境仍应在反向代理或宿主产品里接入身份、RBAC 和审计转发。
