# CRM Case

CRM is GHW's first complete scenario for acquiring product existence degree (E). It proves that GHW can wire product KPIs, change proposals, approval, and audit into the same life cycle.

## Scenario Goals

Let the digital life inside the CRM product focus on:

- Whether customer retention is improving.
- Whether sales follow-up is more timely.
- Whether the win rate is improving.
- Whether the incident rate and customer satisfaction are acceptable.

## Canonical Change

The canonical proposal currently built in:

```text
Tighten follow-up cadence from 7d to 5d
```

The corresponding goal is to shorten the sales follow-up interval, with the expectation of improving win rate and NRR.

## How to Run

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-crm-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

Submit a proposal:

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

Query the full state:

```bash
curl http://127.0.0.1:8765/api/product/runtime
```

## Relationship Between the Current Implementation and the Old Demo

The earlier `docs/CASE_CRM.md` described a Python demo orchestrator. The mainline has now moved the core product runtime back to Zig:

- `src/harness/product_runtime.zig`
- `src/harness/crm_kpi.zig`
- `src/harness/kpi_bridge.zig`
- `src/harness/consent.zig`
- The `/api/product/*` routes in `examples/ui_server.zig`
- The `ghw_product_*` SDK in `ghw.h`

The Python demo can continue to serve as explanatory material, but the Zig modules are the source of production semantics.

## Next Steps

For the CRM scenario to reach real product readiness, it still needs to integrate:

- Real CRM data sources.
- A real ProductAdapter.
- Multi-tenant permissions and approval identities.
- Metric anomaly alerts.
- Post-apply verification, e.g. tracking whether KPIs improve over 7/14/30 days.
