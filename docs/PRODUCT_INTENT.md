# ProductIntent — Schema Spec (v1)

> **Status**: Week 1 of Phase 1 (GHW-as-CRM)
> **Owner**: GHW core team
> **Reviewers needed**: ops, security, lead PM

## 1. Purpose

`ProductIntent` is the **product-level declaration** that tells a GHW instance
*what product it lives inside* and *what success looks like* for that product.
It is loaded once at startup and treated as **read-only by the digital life**.

Without `ProductIntent`, a GHW instance only knows how to optimize its own
internal E equation. With it, GHW knows **why** it is alive and **what KPI
trajectory matters** to the product that hosts it.

This is the foundation for moving GHW from "a self-playing research framework"
to "a product-grade digital life kernel."

## 2. File location

```
<state_dir>/product_intent.json
```

Where `state_dir` defaults to `~/.local/share/ghw/` and is overridable via
`--state <path>` on the daemon CLI.

The file must be:

- **UTF-8 encoded**
- **Valid JSON** (RFC 8259)
- **Schema-versioned** (`schema_version: 1` for this spec)
- **Signed or signed-commit-pinned** in production (recommended but optional
  in v0.4.0; enforcement is planned for v0.5.0 — see SECURITY.md)

## 3. Schema (v1)

### 3.1 Top-level fields

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | `u32` | yes | Must be `1` for this spec |
| `product_id` | `string` | yes | Stable product identifier, e.g. `"com.example.app"` or `"acme-crm-prod"`. Used in audit logs, Prometheus labels, and consent requests. |
| `product_type` | `enum` | yes | One of `mobile_app`, `desktop_app`, `saas_web`, `saas_api`. Drives KPI ingestion mode and channel routing. |
| `version` | `string` | yes | Semver of the *product* (not GHW). E.g. `"4.2.1"`. Bumping this triggers a ProductIntent update epoch. |
| `update_epoch` | `u64` | yes | Monotonically increasing. Bumped on any approved change. E formula history ties to this. |
| `last_updated` | `i64` | yes | Unix timestamp (seconds) of last approval. |
| `approved_by` | `string` | yes | Identity of the human/role who approved. E.g. `"ops@ghw-crm.com"` or git commit SHA. |
| `manifesto` | `string` | yes | Markdown. The product's *why*. Injected into LLM proposer as system prompt context. |
| `sacrosanct` | `string[]` | yes | Hard "thou shalt not" list. Auto-compiled into the 23-blacklist guard. |
| `north_star_kpi` | `string` | yes | Primary KPI key, e.g. `"nrr_quarterly"`. Must match a known key in the KPI registry. |
| `secondary_kpis` | `string[]` | no | Up to 5 secondary KPIs, used for guard-rail checks and LLM context. |
| `kpi_aggregator` | `enum` | yes | `mean`, `median`, `p50`, `weighted`. How multi-KPI rollup is computed. |
| `kpi_evaluation_window` | `string` | yes | `"hourly"`, `"daily"`, `"weekly"`, `"monthly"`. Defines KPI refresh cadence. Must be **slower** than `cycle_interval_seconds`. |
| `value_weights` | `object` | yes | See §3.2. Sum must equal `1.0` ± `0.001`. |
| `consent_defaults` | `object` | yes | See §3.3. |
| `experiment_defaults` | `object` | no | See §3.4. Required if product runs experiments. |
| `channel_routing` | `object` | yes | See §3.5. Maps each trigger to delivery channels. |
| `rhythm` | `object` | yes | See §3.6. Defines cycle and KPI cadence. |

### 3.2 `value_weights`

| Field | Type | Default | Description |
|---|---|---|---|
| `user_satisfaction` | `f32 ∈ [0,1]` | `0.25` | CSAT / NPS / app store rating |
| `retention` | `f32 ∈ [0,1]` | `0.30` | 7d / 30d / NRR |
| `revenue` | `f32 ∈ [0,1]` | `0.20` | ARPU / NRR / conversion |
| `safety` | `f32 ∈ [0,1]` | `0.25` | Inverse incident rate, regulatory compliance score |

Sum must equal `1.0` ± `0.001`. Validation fails at load if not.

The weights flow into the E formula's ρ (KPI) term — see §3.7.

### 3.3 `consent_defaults`

| Field | Type | Default | Description |
|---|---|---|---|
| `minor_tier_timeout_hours` | `u32` | `24` | Auto-revert window for `minor` tier if no human acts. |
| `standard_tier_timeout_hours` | `u32` | `72` | Auto-revert window for `standard` tier. |
| `major_tier_timeout_hours` | `u32` | `168` | Auto-revert window for `major` tier. |
| `critical_tier_requires_double_approval` | `bool` | `true` | If true, `critical` tier needs 2 of {CEO, ops, security} to approve. |
| `auto_approve_within_window` | `bool` | `false` | If true, changes apply immediately and the timeout starts when human is *notified* (batch-consent pattern). |

### 3.4 `experiment_defaults`

| Field | Type | Default | Description |
|---|---|---|---|
| `min_sample_size` | `u32` | `30` | Minimum deals/users per arm before result is significant. |
| `min_duration_days` | `u32` | `14` | Minimum duration (covers ≥1 natural business cycle). |
| `max_concurrent_experiments_per_tenant` | `u8` | `2` | Hard cap to prevent experiment overload. |
| `cohort_split_by` | `enum` | `tenant_user_id` | One of `tenant_user_id`, `deal_segment`, `deal_size_bucket`. |

### 3.5 `channel_routing`

Maps each `UserChannel` trigger to one or more delivery channels.

| Trigger | When fired | Allowed channels |
|---|---|---|
| `e_saturated` | 9-palace steady-state ≥64 cycles | `admin_dashboard`, `slack_webhook`, `email_digest` |
| `user_quiet_24h` | Primary user inactive ≥24h | `email_digest`, `in_app_modal` |
| `l5_about_to_apply` | L5 module about to be adopted | `admin_dashboard`, `email`, `in_app_modal` |
| `anomaly` | KPI crossed critical threshold | `slack_urgent`, `pagerduty`, `email` |
| `experiment_done` | A/B reached `min_duration_days` | `admin_dashboard`, `email_monthly_report` |

Each trigger **must** have at least one channel. Missing channels → load failure.

### 3.6 `rhythm`

| Field | Type | Default | Description |
|---|---|---|---|
| `cycle_interval_seconds` | `u32` | `300` | GHW main loop period. |
| `kpi_refresh_interval_hours` | `u32` | `24` | How often KPI values are re-fetched. Must be **≥** 1 hour. |
| `experiment_default_duration_days` | `u32` | `14` | A/B default duration. |
| `consent_batch_window_days` | `u32` | `7` | How long a batch-consent covers before re-asking. |

**Invariant**: `kpi_refresh_interval_hours * 3600 ≥ cycle_interval_seconds * 10`
(i.e. KPI doesn't flicker into E formula at cycle rate — the system must average
over time, not chase noise).

### 3.7 E formula integration

The ProductIntent is **not** stored inside `ExistenceDegree`. It feeds three
downstream systems:

1. **E formula ρ term** (added in Week 2, separate commit):
   ```
   E_ρ = ρ * Σ value_weights[k] * trend(kpi_k)
   ```
   where `ρ` is **immutable** (axiom, like α/β/γ) and defaults to `0.15`.

2. **LLM proposer system prompt**: the `manifesto` is appended to the proposer
   context window. Sacrosanct items are appended to the prompt as **explicit
   constraints** (in addition to the 23-blacklist check).

3. **23-blacklist extension**: each item in `sacrosanct` is compiled into a
   regex pattern that joins the existing 17-pattern guard.

### 3.8 Versioning rules

- Bump `schema_version` only on **breaking** changes (field removed, type
  narrowed, semantic change).
- Bump `version` (product semver) on **additive** changes.
- Bump `update_epoch` on **any** approved change, even whitespace.

Downstream readers must reject `schema_version` newer than they know how to
parse. (Forward compatibility, not backward.)

## 4. Lifecycle

```
[ops writes new product_intent.json]
        │
        ▼
[ops signs (v0.5+) or pins commit (v0.4)]
        │
        ▼
[ops deploys to <state_dir>/product_intent.json]
        │
        ▼
[GHW daemon picks up on next cycle]
        │
        ├─ validates JSON + schema
        ├─ checks update_epoch > previous → records epoch transition
        ├─ compiles sacrosanct into blacklist
        ├─ rebuilds LLM proposer system prompt
        └─ writes audit_log entry: "product_intent_epoch_transition"
```

**Digital life cannot edit `product_intent.json`**. The only writer is the
ops process. If GHW believes the ProductIntent is wrong, it must **propose
a change via Consent** and a human (not GHW) writes the new file.

This is by design: a product's *why* is the human's job, not the agent's.

## 5. Failure modes

| Failure | Behavior |
|---|---|
| File missing | Daemon refuses to start. Exit code `78` (EX_CONFIG). |
| `schema_version` unknown | Daemon refuses to start. Logs offending version. |
| `value_weights` doesn't sum to 1.0 | Daemon refuses to start. |
| `kpi_refresh_interval_hours < 1` | Daemon refuses to start. |
| `cycle_interval_seconds < 5` | Daemon refuses to start (chatter protection). |
| `north_star_kpi` not in registry | Daemon refuses to start. |
| `sacrosanct` empty | **Warn** but proceed. (Some products have no hard "shall not" rules.) |
| Channel routing for required trigger missing | Daemon refuses to start. |
| JSON parse error | Daemon refuses to start. Line/column logged. |

## 6. Example

See [`product_intent.example.crm.json`](../product_intent.example.crm.json)
for a complete CRM SaaS example.

## 7. Open questions for v0.5.0

- [ ] Should `manifesto` be size-limited? (LLM context window concern.)
- [ ] Should we support multiple `manifesto` per product type? (mobile + web
      share a brand but have different KPIs.)
- [ ] Signed manifests (ed25519) — required or opt-in for enterprise?
- [ ] Hot reload without daemon restart? (Currently requires cycle restart.)

## 8. Change log

- **v1 (2026-06-14)**: Initial schema, drafted as Week 1 of GHW-as-CRM Phase 1.
<<<<<<< HEAD
=======

## 9. Semantic layering — what is *not* in this schema

This document specifies the **protocol/contract layer** of how a GHW
instance relates to its host product. The companion document
[`LLM_DRIVER.md`](./LLM_DRIVER.md) specifies the **semantic/expressive
layer**. The two layers are architecturally separated.

What stays in the **protocol/contract layer** (this document):

- E formula weights and KPI targets
- Channel routing **destinations** (admin_dashboard, slack_webhook, ...)
- Consent tier rules and timeouts
- Experiment parameters and guard-rails
- Sacrosanct list (becomes part of the 17→23 blacklist)
- Audit log policy

What moves to the **semantic/expressive layer** (LLM_DRIVER.md):

- Channel routing **message content** — what the digital life *says* when
  it pings a channel. The protocol says "send to slack_webhook when
  e_saturated"; the LLM says what the actual text is.
- Manifesto interpretation — when a product team writes a manifesto,
  the LLM is what *understands* its nuance at runtime (the manifesto is
  injected into the LLM proposer system prompt; this is documented in
  §3.7). The ProductIntent schema only stores the manifesto text.
- L4/L5 proposal rationale — the LLM writes the human-readable
  "why" of a proposed change. The math layer decides whether to accept
  it; the LLM only explains it.
- Anomaly cause hypothesizing — the LLM reads recent events and
  hypothesizes causes. The math layer decides if an anomaly occurred
  in the first place.
- User message parsing — the LLM classifies what a user said. The
  Consent/Channel layer then routes based on that classification.

**Rule of thumb**: if a value is a *configuration* that ops can set
in JSON, it belongs in ProductIntent. If a value is a *judgement call*
or a *natural-language generation* that requires context, it belongs
in LLMDriver.

This separation is enforced at compile time by the type system in
`src/harness/llm_driver.zig` and `src/harness/product_intent.zig`:
LLMDriver's `Request` and `Result` types are tagged unions, and the
math/protocol modules only consume typed values from these unions,
never raw strings.

>>>>>>> f94a2a2 (week 1.5: LLMDriver boundary (semantic vs math/protocol))
