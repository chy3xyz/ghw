# KPI — Schema Spec (v1)

> **Status**: Week 2 of Phase 1 (GHW-as-CRM)
> **Branch**: `feature/week2-kpi-rho`
> **Pairs with**: `docs/PRODUCT_INTENT.md`, `docs/LLM_DRIVER.md`

## 1. Purpose

KPI (Key Performance Indicator) is the **product-level metric** that
tells a GHW instance *what success looks like* for the product it is
embedded in. Combined with `ProductIntent`, KPI is the second half
of the bridge between a digital life's internal E equation and
the product it serves.

The KPI module is intentionally **separate** from `ProductIntent`:

- `ProductIntent` is **ops-owned** and changes only when humans
  update `product_intent.json`.
- `KPI` is **continuously updated** by the product's own data
  pipeline. The digital life never writes to KPI directly; it
  only *reads* the most recent value.

This separation ensures that the digital life cannot "game" the
KPI it is being scored on.

## 2. File location

KPI values are **not** stored in `product_intent.json`. They are
fed in via a registered callback at daemon startup:

```zig
ghw_kpi_register_source("nrr", &crmNrrProvider, NULL);
```

The CRM backend (or any other product backend) provides a
function that returns the current KPI value. The daemon polls
it on the `kpi_refresh_interval_hours` cadence from
`ProductIntent.rhythm`.

## 3. GHW-as-CRM: the 4 KPIs

This spec ships with the four KPIs that the CRM demo uses. Other
products may register different KPI keys via the same callback
interface; the math layer treats them as opaque floats with a
0..1 normalization.

### 3.1 `nrr_quarterly` (north star)

- **What it is**: Net Revenue Retention, computed quarterly.
  NRR = (Starting ARR + Expansion - Downgrade - Churn) / Starting ARR.
- **Why it's north star**: SaaS industry consensus is that NRR
  above 100% means existing customers are net-expanding. A
  digital life that improves NRR is making existing customers
  *more* valuable, which is the most capital-efficient growth.
- **Range**: typically 0.85 - 1.30. We normalize linearly:
  - `0.85` → `0.0` (gross churn exceeding expansion)
  - `1.00` → `0.5` (the breakeven point)
  - `1.15` → `1.0` (solid mid-market SaaS; values above clamp to 1.0)
- **Source**: CRM backend's billing/subscription table.

### 3.2 `deal_win_rate` (secondary, sales productivity)

- **What it is**: Closed-won deals / total closed deals in the
  trailing 30 days.
- **Why it matters**: A direct measure of sales effectiveness.
  The digital life can propose follow-up cadence / lead scoring
  changes that improve this.
- **Range**: 0.10 - 0.40 typical. Normalize linearly: 0.10 → 0.0,
  0.40 → 1.0.
- **Source**: CRM `deals` table where `stage = closed_won` or
  `closed_lost`.

### 3.3 `sales_cycle_days_p50` (secondary, sales velocity)

- **What it is**: Median days from `lead_created` to
  `closed_won` for the trailing 90 days. **Lower is better.**
- **Why it matters**: A shorter sales cycle means cash arrives
  faster and salespeople can run more deals per quarter.
- **Range**: 20 - 90 days typical. Normalize inverted:
  - `20 days` → `1.0` (best)
  - `60 days` → `0.5` (industry average)
  - `90 days` → `0.0` (concerning)
- **Source**: CRM `deals` table.

### 3.4 `weekly_active_sales_pct` (secondary, team health)

- **What it is**: % of sales reps who logged ≥1 meaningful CRM
  activity in the trailing 7 days.
- **Why it matters**: A digital life can spot a rep falling
  behind and propose nudges; but if 30% of the team is inactive,
  the problem is structural, not individual.
- **Range**: 0.40 - 0.95 typical. Normalize linearly: 0.40 → 0.0,
  0.95 → 1.0.
- **Source**: CRM `activities` table (calls, emails, meetings).

## 4. E formula integration — the ρ term

E now has 6 terms. The new one is the **KPI** term:

```
E = α·M + β·R + γ·N - μ·Var + ν·min + σ·S + λ·D + ρ·K
```

Where:

- `ρ` is the **KPI coefficient**, **immutable** (axiom, same
  status as α/β/γ). Default: `0.15`. (Setting it higher would
  let the KPI term dominate E; setting it lower would let
  the internal components dominate. The default is tuned to
  "the product should matter, but the digital life's own health
  matters too".)
- `K` is the **composite KPI score** in [0, 1], computed as
  `value_weights`-weighted mean of the 4 normalized KPIs.
  (See `ProductIntent.value_weights` — same 4 fields:
  `user_satisfaction`, `retention`, `revenue`, `safety`.)

**Why this design**:

- The 4 KPIs are *input* (data the product feeds in).
- The composite K is *math* (a deterministic function of the
  inputs, gated by ops-set weights).
- The ρ term is *axiom* (immutable, like α/β/γ).

The digital life can tune μ/ν/σ/λ (4 additive coefficients,
Phase 8.6 work) but **cannot** tune ρ, the value_weights, or
the 4 KPI normalizations. All of those are product axioms.

## 5. Composite K computation

```
K = clamp(
    user_satisfaction_weight * csat_normalized +
    retention_weight * nrr_normalized +
    revenue_weight * deal_win_rate_normalized +  // primary weight
    safety_weight * (1.0 - incident_count_normalized)
, 0.0, 1.0)
```

Note: `revenue_weight` is the **primary** weight (default 0.35).
The other three share the remaining 0.65 equally. This matches
the `ProductIntent.value_weights` design where `revenue` is
north-star-adjacent (and `nrr_quarterly` is the north star).

If a product wants a different composite formula, it is encoded
in `ProductIntent.kpi_aggregator` (one of `mean`, `median`,
`p50`, `weighted`). The default for CRM is `weighted` with
`revenue_weight * 1.5` (boost) since NRR is the north star.

## 6. Trend tracking (the anti-flicker invariant)

The `ProductIntent.rhythm.kpi_refresh_interval_hours` is
**at least 10× the cycle_interval_seconds**. This ensures the
KPI term in E does not flicker at cycle rate.

In addition, we keep a **64-cycle ring buffer** of the K
composite. The trend (slope of linear regression over the
ring) is exposed via `/api/kpi_history` and is what the
L4 proposer feeds to the LLM as context for
`write_evolution_rationale`.

The trend is *additive* — it is not part of the E formula
itself, but it is the signal that justifies proposing an L4
change. "K is rising" → propose a μ/ν/σ/λ tweak that
*reinforces* the trend. "K is falling" → propose a tweak
that *reverses* the trend.

## 7. Failure modes

| Failure | Behaviour |
|---|---|
| KPI provider callback returns NaN or out-of-range | Skip this refresh. Log warning. Last valid K is kept. |
| All 4 KPI sources are stale (no refresh in 7 days) | Daemon refuses to compute E (K is undefined). Goes into a "blind" state — no L4 proposes, no L1 coefficients change. |
| Composite K would be negative (e.g. severe churn + bad CSAT) | Clamp to 0.0. The ρ term is then maximally negative. |
| `ProductIntent.north_star_kpi` is not one of the registered keys | `ProductIntent.load` fails (caught at startup, not here). |

## 8. Anti-patterns the digital life must NOT do

1. **Game the KPI** — proposing a change that improves
   `deal_win_rate` by ignoring `nrr_quarterly` is rejected by
   the value_weights aggregation. The composite is holistic.

2. **Latch onto one KPI** — proposing "increase ν" every
   cycle because K is 0.51 → 0.52 (no real change) is
   caught by the L4 hypothesis framework (Boris Cherny
   "consecutive miss" rule in `loop_engine.zig`).

3. **Over-react to trends** — proposing an L4 change after
   one 24h KPI dip is suppressed by the 64-cycle ring. The
   proposer only acts on **durable** trends (≥ 32 cycles of
   consistent direction).

4. **Bypass the ρ term** — proposing "ignore KPI, optimize
   M/R/N only" is rejected at the E-formula level because
   ρ is immutable.

## 9. Open questions for v0.5

- [ ] Should we add a 5th KPI: `csat_score`? Currently
      `user_satisfaction` is computed indirectly from NPS
      (a separate signal). Lean yes.
- [ ] Should the K composite formula be LLM-proposable
      (with constraints), or always ops-fixed? Lean
      ops-fixed (it's part of the product axiom).
- [ ] Should we expose "predicted K" to the LLM proposer?
      Lean yes — let the proposer reason about "if I tweak
      μ, the predicted K will be X".

## 10. Change log

- **v1 (2026-06-14)**: Initial spec, drafted as Week 2 of
  GHW-as-CRM Phase 1. Codifies the ρ term as an E-axiom
  addition (the first new E axiom since Phase 8.6).
