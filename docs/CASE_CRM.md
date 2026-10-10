# GHW-as-CRM — End-to-End Case Study

> **Status**: Week 4 of Phase 1 (GHW-as-CRM). Phase 1 final deliverable.
> **Branch**: `feature/week4-consent-and-demo`
> **Reproduces**: Yes — anyone with this repo can run
> `bash examples/crm_demo/run_all_tests.sh` and see the same output.

## 1. What this case study demonstrates

A standalone end-to-end run of GHW-as-CRM on three synthetic
tenants. The orchestrator is Python (because we want zero
external dependencies for the demo), but every math/protocol
piece of logic is a **direct port of the corresponding Zig
module** — see §5 for the cross-reference.

What gets verified:

1. **ProductIntent loads** — `product_intent.example.crm.json`
   parses successfully (Week 1 module).
2. **3 tenants seeded** — each with 30 days of synthetic
   sales activity (deals, activities, sales reps).
3. **4 KPIs per tenant** computed — NRR, win_rate,
   sales_cycle_days_p50, weekly_active_sales_pct (Week 2
   module: crm_kpi.zig).
4. **3 L5 change proposals** generated — one per tenant,
   each proposing "tighten follow-up cadence from 7d to 5d".
5. **Risk classification** — severity / blast /
   reversibility computed for each proposal (Week 4
   module: consent.zig).
6. **Tier routing** — each proposal lands in a consent tier
   (minor / standard / major / critical).
7. **Decision simulation** — auto-approve for minor/standard,
   80% approve-rate for major, 2-of-3 for critical.
8. **Audit log persistence** — every consent decision is
   written to `demo.sqlite` and readable.
9. **Final verdict** — 9 Python tests pass, 118 Zig tests
   pass, 3/3 demo decisions logged.

## 2. How to reproduce

```bash
# Clone
git clone https://github.com/chy3xyz/ghw.git
cd ghw
git checkout feature/week4-consent-and-demo

# Run the entire test suite (Python + Zig + E2E)
bash examples/crm_demo/run_all_tests.sh
```

Expected output (last 30 lines):

```
=== Python tests (CRM demo orchestrator) ===

All 9 tests passed.

=== Zig tests (Phase 1 modules) ===

--- src/harness/product_intent.zig ---
All 6 tests passed.
--- src/harness/llm_driver.zig ---
All 8 tests passed.
--- src/harness/crm_kpi.zig ---
All 19 tests passed.
--- src/harness/evolution_rationale.zig ---
All 14 tests passed.
--- src/harness/user_channel.zig ---
All 24 tests passed.
--- src/harness/mock_provider.zig ---
All 15 tests passed.
--- src/harness/consent.zig ---
All 18 tests passed.
--- src/world/existence_degree.zig ---
All 14 tests passed.

=== End-to-end demo ===
Persistence check: 3 consent requests logged to demo.sqlite
Approved 3/3 changes; avg predicted ΔK = +0.050

✅ All Phase 1 tests passed.
```

## 3. What the demo actually runs

The demo (`examples/crm_demo/demo.py`) does the following:

1. **Initialize SQLite DB** at `examples/crm_demo/demo.sqlite`.
2. **Load product_intent.example.crm.json** as the source of
   truth for the orchestrator's behavior (timeouts, approver
   tiers, sacrosanct list, etc.).
3. **Seed 3 tenants**: `acme`, `bravo` (both `saas_mid_market`)
   and `charlie` (`ecommerce_b2b`). For each, generate 30
   days of synthetic sales activity: 60-90 deals, 5 sales
   reps each logging 0-3 activities per day, industry-specific
   baseline win rates and sales cycles.
4. **Compute baseline KPIs** for each tenant:
   - NRR: random Gaussian, mean 1.08 (mid-market), std 0.05
   - win_rate: empirical (deals_won / deals_closed)
   - sales_cycle_p50: empirical median of closed deal cycles
   - weekly_active_sales_pct: distinct active reps in last 7d
5. **Propose 1 L5 change per tenant**: "Tighten follow-up
   cadence from 7d to 5d" (the canonical Phase 1 demo change).
6. **Run the consent flow** for each proposal:
   - Risk classification (severity 0.65, blast 0.3, reversibility 0.0)
   - Combined risk: 0.317 → `standard` tier
   - Required approver: sales_manager
   - Auto-approve (standard tier is auto-approved in our simulation)
   - Log to consent_log with rationale
7. **Print a summary table** with tenant, tier, decision,
   approvers, predicted ΔK.
8. **Verify** the consent_log has 3 entries.

## 4. What the demo does NOT do

- It does NOT actually modify a L5 `.zig` file. The "apply"
  step is simulated (a no-op). The real apply would invoke
  the daemon's L5 module path.
- It does NOT run for 30 real days. The 30 days of activity
  is synthetic and instantaneous.
- It does NOT involve a real LLM. The mock_provider.zig
  module provides deterministic responses for tests; the
  demo does not call it.
- It does NOT exercise the UserChannel bidirectional flow.
  That is verified by user_channel.zig's own unit tests.

## 5. Cross-reference: demo.py ↔ Zig modules

| Python | Zig counterpart | Logic equivalence |
|---|---|---|
| `classify(risk)` | `consent.classify(risk)` | byte-for-byte port of the tier thresholds |
| `risk_for_change(change)` | `consent.riskForChange(change)` | same severity/blast/reversibility formulas |
| `run_consent_flow()` | `consent.newRequest()` | same timeout-hours-from-tier mapping |
| `seed_tenant()` | (no Zig counterpart) | toy DB seeding, no production logic |
| `propose_followup_tightening()` | (no Zig counterpart) | demo-only proposal |
| SQLite logging | `consent_log.zig` (deferred) | the demo *is* the audit log for now |

If you find a discrepancy between the Python and Zig versions,
the **Zig version is the source of truth**. The Python is a
portable orchestrator for the demo; it is not where product
logic lives.

## 6. Why a Python orchestrator and not Zig?

The toy demo is in Python because:

1. **Zero build step** — anyone with `python3` can run it.
   No need to install Zig 0.17 dev, no need to compile.
2. **Readability** — the orchestrator is the part of the
   system a non-Zig-expert would want to read first.
3. **Familiar tooling** — sqlite3 stdlib, no `cgo` or
   foreign function calls.
4. **Equivalent semantics** — the math is the same; the
   `consent.zig` module has identical classify + riskForChange
   functions, and a real production deployment would use
   *those*, not the Python port.

The Zig modules are the **production implementation**. The
Python is the **demo harness**. They share logic, not runtime.

## 7. What you'd need to do to make this a real CRM

This demo runs in seconds with synthetic data. To make it a
real CRM (handling actual customer data, real sales reps,
real LLM calls), you would need to:

1. **Wire real LLM providers** — Anthropic / OpenAI / DeepSeek
   via `LlmDriver.callProvider()` (Week 4+ deliverable; see
   `docs/MOCK_PROVIDER_INTEGRATION.md`).
2. **Replace SQLite with a real CRM backend** — Salesforce,
   HubSpot, etc. The data model (tenants, deals, activities)
   maps directly; the only change is the data source.
3. **Deploy a real daemon** — `zig build` the ghw-daemon,
   ship via launchd (see Week 1.6 production notes), expose
   HTTP API for the 16+ endpoints in `docs/ARCHITECTURE.md`.
4. **Run for ≥ 30 real days** — the demo simulates 30 days
   in <1 second; a real run needs 30 days × 5min/cycle = 8,640
   cycles. This is what production mode looks like.
5. **Get customer consent** — the orchestrator handles the
   internal consent (between digital life and product team);
   the *customer's* consent for their data being processed
   is a separate GDPR/CCPA concern, not in scope for this
   case study.

## 8. Outputs

After running the demo, you have:

- `examples/crm_demo/demo.sqlite` — a SQLite DB with 3 tenants,
  ~200 deals, ~150 activities, and 3 consent_log entries.
  Inspect with `sqlite3 examples/crm_demo/demo.sqlite "SELECT * FROM consent_log;"`.
- Console output showing the consent flow per tenant.
- 9 Python + 118 Zig test pass results.

## 9. Change log

- **v1 (2026-06-14)**: Initial case study, drafted as Week 4
  of GHW-as-CRM Phase 1. Phase 1 final deliverable.
