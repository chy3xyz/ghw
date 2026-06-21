# KPI 与存在度 E

产品可用级 GHW 必须能从真实产品获得存在度。KPI 是产品场景进入 E 的主要通道。

## ρ·K 项

GHW 的产品对齐项记为 `ρ·K`：

- `K` 是产品 KPI composite，范围 `[0, 1]`。
- `ρ` 是不可由 LLM 自调的公理常量。
- `ProductIntent.value_weights` 决定不同 KPI 轴的权重。

这意味着：产品变好会提高数字生命的存在度，产品变差会让它感到“存在度下降”，从而触发目标、任务或规则提议。

## CRM 默认 KPI

CRM 示例使用四个输入：

| 字段 | 含义 | 趋势 |
| --- | --- | --- |
| `nrr_quarterly` | 净收入留存 | 越高越好 |
| `deal_win_rate` | 成交率 | 越高越好 |
| `sales_cycle_days_p50` | 销售周期中位数 | 越低越好 |
| `weekly_active_sales_pct` | 周活跃销售占比 | 越高越好 |

可选输入：

- `csat`：客户满意度，`NaN` 表示无来源。
- `incident_rate`：事故率，`NaN` 表示无来源。

## SDK 喂入

```c
int updated = ghw_product_kpi_feed(
  g,
  0.91f,  // nrr_quarterly
  0.22f,  // deal_win_rate
  45.0f,  // sales_cycle_days_p50
  0.76f,  // weekly_active_sales_pct
  NAN,    // csat unavailable
  0.02f,  // incident_rate
  now_unix
);
```

返回值：

- `1`：本次写入 E，并生成 `kpi_refreshed` audit。
- `0`：被 refresh interval 限频，没有写 E。
- `-1`：未配置 runtime 或输入失败。

## HTTP/API 场景

`ui_server` 目前提供产品 runtime 审计查询和变更操作。KPI 喂入仍优先走 SDK 或宿主进程内调用；后续可补 `POST /api/product/kpi` 作为外部数据管道入口。

## 防抖原则

KPI 不应按 cycle 高频写入 E。`KpiBridge` 会根据 ProductIntent rhythm 限频，避免数字生命追逐短期噪声。
