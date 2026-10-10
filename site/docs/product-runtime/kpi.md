# KPI and Existence Degree E

A production-grade GHW must be able to derive its existence degree from the real product. KPI is the main channel through which product scenarios enter E.

## The ρ·K Term

GHW's product alignment term is denoted `ρ·K`:

- `K` is the product KPI composite, in the range `[0, 1]`.
- `ρ` is an axiomatic constant that the LLM cannot tune by itself.
- `ProductIntent.value_weights` determines the weight of each KPI axis.

This means: when the product improves, the digital life's existence degree rises; when it worsens, the digital life "feels" the existence degree dropping, which triggers goal, task, or rule proposals.

## CRM Default KPIs

The CRM example uses four inputs:

| Field | Meaning | Trend |
| --- | --- | --- |
| `nrr_quarterly` | Net revenue retention | Higher is better |
| `deal_win_rate` | Deal win rate | Higher is better |
| `sales_cycle_days_p50` | Median sales cycle | Lower is better |
| `weekly_active_sales_pct` | Weekly active sales percentage | Higher is better |

Optional inputs:

- `csat`: customer satisfaction; `NaN` means no source.
- `incident_rate`: incident rate; `NaN` means no source.

## Feeding via SDK

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

Return value:

- `1`: E was written this time, and a `kpi_refreshed` audit was generated.
- `0`: throttled by the refresh interval; E was not written.
- `-1`: runtime not configured or input failure.

## HTTP/API Scenarios

`ui_server` currently provides product runtime audit queries and change operations. KPI feeding should still go through the SDK or in-process host calls first; a `POST /api/product/kpi` can be added later as an entry point for external data pipelines.

## Debounce Principle

KPI should not be written into E at high frequency on every cycle. `KpiBridge` throttles writes according to the ProductIntent rhythm, so the digital life does not chase short-term noise.
