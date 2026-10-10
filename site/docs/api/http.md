# HTTP API

`ui_server` exposes endpoints for monitoring, chat, tasks, human feedback, the product runtime, and more. By default it listens on `127.0.0.1:<port>`.

## Startup

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json \
  --product-config /tmp/ghw-product-config.json
```

For production write endpoints, it is recommended to set `GHW_ADMIN_TOKEN` and pass `X-GHW-Admin-Token` on each call.

## Core state

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/state` | Current E/M/R/N, tick, goals, provenance, task stats |
| `GET` | `/api/log` | Recent growth log |
| `GET` | `/api/capabilities` | Capability map and phase progress |
| `GET` | `/api/metrics` | Prometheus metrics |

## Chat and memory

| Method | Path | Description |
| --- | --- | --- |
| `POST` | `/api/chat` | Send a human message; triggers a cycle and a reply |
| `GET` | `/api/chat/history` | Fetch chat HTML fragment |
| `GET` | `/api/memory/search?q=...&limit=N` | Search autobiographical memory |

`/api/state`'s `provenance.chat` shows whether the latest reply injected memory context.

## Tasks and human feedback

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/tasks` | Query the TaskQueue |
| `POST` | `/api/tasks` | Explicitly submit a human task |
| `POST` | `/api/task/feedback` | Rate a completed task |

Example:

```bash
curl -X POST http://127.0.0.1:8765/api/tasks \
  -d 'title=检查CRM跟进策略&description=评估7d到5d的风险&required_dimension=representation&priority=7'
```

## Product runtime

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/product/runtime` | Query full changes + audit state |
| `GET` | `/api/product/audit` | Query audit only |
| `GET` | `/api/product/intent` | Query ProductIntent identity, update_epoch, manifest_hash, adapter status |
| `GET` | `/api/product/approvals` | Query approval-console data: pending/approved changes |
| `POST` | `/api/product/propose-crm-followup` | Submit the CRM sample proposal |
| `POST` | `/api/product/approve` | Approve a change |
| `POST` | `/api/product/apply` | Apply an approved change |
| `POST` | `/api/product/rollback` | Rollback an applied change |
| `POST` | `/api/product/kpi` | Feed real product KPIs to ProductRuntime |

When `--product-intent` is not enabled, the product endpoints return 503 JSON:

```json
{
  "error": "product runtime disabled; start ui_server with --product-intent PATH"
}
```

Illegal state transitions return 400 JSON, e.g. applying before approval.

Example of a protected write endpoint:

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -H "X-GHW-Admin-Token: $GHW_ADMIN_TOKEN" \
  -d 'tenant_id=acme&affected_users=45&expected_delta_k=0.05'
```

KPI feed example:

```bash
curl -X POST http://127.0.0.1:8765/api/product/kpi \
  -H "X-GHW-Admin-Token: $GHW_ADMIN_TOKEN" \
  -d 'nrr_quarterly=0.88&deal_win_rate=0.24&sales_cycle_days_p50=48&weekly_active_sales_pct=0.71&csat=0.92&incident_rate=0.01'
```

With `--product-config PATH` enabled, `/api/product/apply` writes the host product's config via the file adapter, and `/api/product/rollback` writes back the `rolled_back` state. The audit log contains `previous_hash` and `current_hash`.

## Self-evolution and actions

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/evolved` | List self-evolution on-disk files |
| `GET` | `/api/evolved/<file>` | Read a specific on-disk file |
| `GET` | `/api/l1l5_trend` | L1-L5 count trend |
| `POST` | `/api/action/run-now` | Run an action immediately |
| `GET` | `/api/action/list` | Action history |

## Peer

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/peers` | Peers known to this node |
| `POST` | `/api/peer/query?path=...&method=...` | Query a peer manually |

## Notes

- The current HTTP server is a lightweight built-in implementation, not a full reverse proxy.
- For production deployments, put it on an intranet or behind a reverse proxy.
- `GHW_ADMIN_TOKEN` is the minimal authentication backbone; multi-user production environments should still integrate identity, RBAC, and audit forwarding at the reverse proxy or host product.
