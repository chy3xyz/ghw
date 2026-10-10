# ProductIntent

`ProductIntent` is the "product constitution" that the host product hands to GHW. It tells the digital life:

- Which product it lives in.
- Why the product exists.
- Which KPIs matter most.
- Which things must never be done.
- What approval a change requires.
- What the operating cadence and audit policy are.

## Minimal example

For a complete example, see `product_intent.example.crm.json` in the repository root.

```json
{
  "schema_version": 1,
  "product_id": "ghw-crm",
  "product_type": "saas_web",
  "version": "0.1.0",
  "update_epoch": 1,
  "approved_by": "ops",
  "manifesto": "Help sales teams follow up faster without leaking tenant data.",
  "sacrosanct": ["never leak tenant data"],
  "north_star_kpi": "nrr_quarterly",
  "secondary_kpis": ["deal_win_rate", "sales_cycle_days_p50"],
  "value_weights": {
    "user_satisfaction": 0.25,
    "retention": 0.30,
    "revenue": 0.35,
    "safety": 0.10
  }
}
```

## Who can modify it

GHW cannot modify ProductIntent directly. It can:

- Discover that ProductIntent no longer matches reality.
- Propose a change.
- Write to the audit log.
- Wait for human approval.

What actually writes `product_intent.json` should be ops, the product owner, or the deployment pipeline.

## Relationship to E

ProductIntent is not stored directly in `ExistenceDegree`; instead it influences three pathways:

- KPI weights: determine how `K` is aggregated.
- Consent policy: determines the approval threshold for changes.
- LLM context: lets goal/rule proposals know the product mission and red lines.

## Production recommendations

- Keep ProductIntent in a controlled configuration directory.
- Bind `update_epoch` to signed commits or a config-center version number.
- Write every change to the audit system.
- Do not put API keys, customer data samples, or personally identifiable information into ProductIntent.
