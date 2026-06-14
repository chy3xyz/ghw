# Consent — Spec (v1)

> **Status**: Week 4 of Phase 1 (GHW-as-CRM). Phase 1 final.
> **Branch**: `feature/week4-consent-and-demo`
> **Pairs with**: `docs/PRODUCT_INTENT.md`, `docs/LLM_DRIVER.md`,
> `docs/CHANNEL.md`, `docs/KPI.md`

## 1. Purpose

`Consent` is the **human-in-the-loop gate** that stands between
a digital life's *proposal* and its *application*. It enforces
the rule that **any change to a digital life's behavior that
would be visible to, or affect, humans must be approved by a
human first**.

This is the fourth "soul" of GHW-as-CRM (alongside math/protocol,
semantic, and communication), and it is the soul most directly
under the user's control. The user *is* the consent authority.

Without `Consent`, the digital life is a research framework.
*With* `Consent`, it is a product-grade digital life kernel.

## 2. The 4 tiers

Every L1–L5 change is classified into one of 4 consent tiers.
The tier determines the workflow, the timeout, and the approvers.

| Tier | Examples | Workflow | Default timeout | Approvers |
|---|---|---|---|---|
| `minor` | L1 coefficient tweak ±0.01 | async log only | 24h auto-revert if not acknowledged | none (auto) |
| `standard` | L3 add a new method | async notification | 72h auto-revert if not acknowledged | sales_manager |
| `major` | L5 change a sales workflow rule | sync modal + sign-off | 168h (7d) auto-revert | sales_manager + sales_director |
| `critical` | change ProductIntent, 23-blacklist, E axiom | sync modal + multi-role + 7d hesitation | 168h (7d) auto-revert | CEO + ops_lead + security_lead (2 of 3 required) |

The 4 tiers are **configurable** (the thresholds come from
`ProductIntent.consent_defaults`) but the **names** are fixed.
Lowering the thresholds = more freedom for the digital life but
more human attention required. Raising them = more conservative.

## 3. The change classification

The tier for a given L5 module change is computed by `Consent.classify`
based on three signals:

1. **Severity score** (0..1) — how much the change affects humans.
   - L1 only: 0.0
   - L3 only: 0.3
   - L5 file change to non-blacklist code: 0.6
   - L5 change to blacklist-adjacent code: 0.9
   - L5 change to ProductIntent or E axiom: 1.0

2. **Blast radius** (0..1) — how many users are affected.
   - Affects self only: 0.0
   - Affects 1 team: 0.3
   - Affects 1 tenant: 0.6
   - Affects all tenants (in cohort learning): 0.9
   - Affects all tenants globally: 1.0

3. **Reversibility** (0..1) — can the change be rolled back?
   - Trivially reversible (state flag): 0.0
   - Reversible within 24h via config: 0.3
   - Reversible within 7d via code re-deploy: 0.6
   - Reversible only via DB rollback: 0.9
   - Irreversible (e.g. emails already sent): 1.0

The combined `risk_score = (severity + blast + reversibility) / 3`
maps to a tier:

```
risk_score < 0.2   → minor
risk_score < 0.5   → standard
risk_score < 0.8   → major
risk_score >= 0.8  → critical
```

These thresholds are tunable via `ProductIntent.consent_defaults`.

## 4. The lifecycle of a consent request

```
  proposal arrives
        │
        ▼
  classify (compute risk_score → tier)
        │
        ▼
  ┌─────────────────────────────────────┐
  │  if tier == minor:                   │
  │    apply immediately                 │
  │    log to audit                      │
  │    done                              │
  │  else:                               │
  │    create ConsentRequest             │
  │    route to approver (per tier)      │
  │    start timeout countdown           │
  └─────────────────────────────────────┘
        │
        ▼
  poll for decision OR timeout
        │
        ├─ approve received ─→ apply change, log decision
        ├─ deny received ────> discard change, log denial
        └─ timeout ──────────> auto-revert (per tier default)
```

## 5. The 4 deferred-but-planned triggers (roadmap)

`Consent` integrates with the 4 other `UserChannel` triggers
(deferred from Week 3):

| Trigger | Consent interaction |
|---|---|
| `user_quiet_24h` | none — informational |
| `l5_about_to_apply` | **direct**: this trigger fires *because* a major/critical consent request is created |
| `anomaly` | none — auto-detected, ops notified via slack_urgent |
| `experiment_done` | none — informational; experiment was already consented at start |

The `l5_about_to_apply` trigger is the **first** `Consent`-driven
trigger. It is the visible "I am about to change something big,
do you consent?" message that the digital life sends before
applying a major/critical change.

## 6. Anti-patterns

1. **Bypassing Consent for "obvious" cases** — never. Even
   `minor` tier writes an audit log; the digital life cannot
   *silently* change itself.
2. **Single-approver for `critical` tier** — never. Two of
   three senior roles must approve. (This is the `critical_tier_requires_double_approval`
   flag in `ProductIntent.consent_defaults`.)
3. **Timeout longer than 7 days for any tier** — the default
   for `critical` is 7 days; longer invites "I'll get to it next
   week" delays that leave changes pending in a half-applied state.
4. **Allowing the digital life to "decide" a tier downgrade**
   — never. The tier is a product axiom; the digital life may
   *request* a downgrade (via Consent itself, a meta-request),
   but it cannot *apply* one.
5. **Persist the change before consent is granted** — the
   `ConsentRequest` itself is persisted (for audit), but the
   proposed change is **never** written to state.json until
   approved.

## 7. Failure modes

| Failure | Behaviour |
|---|---|
| Approver unreachable (Slack/email 500) | Retry 3× with exponential backoff. After 3, escalate to next approver in the tier. |
| `ConsentRequest` is created but the daemon crashes before decision | On restart, the request is still in the persistence file. The daemon re-loads it and continues the countdown. |
| The user clicks "approve" after timeout | The change has already auto-reverted. The approval is rejected with `error.ExpiredConsent`. |
| Two approvers give conflicting decisions (one approves, one denies) | Deny wins. The approver is asked to re-affirm or escalate. |
| `ConsentRequest` is created for a tier whose timeout is 0 (i.e. disabled) | Treated as `critical` and forces an explicit decision. |

## 8. Open questions for v0.5

- [ ] Should `ConsentRequest` support batched approval? "Approve
      all minor+standard for the next 7 days" — common pattern
      to reduce consent fatigue. Lean yes.
- [ ] Should the digital life be able to *escalate* a `standard`
      request to `major` if its predicted impact turns out to be
      larger than initially estimated? Lean yes, with a separate
      `ConsentEscalation` request type.
- [ ] Should `ConsentRequest` carry a "predicted_KPI_delta" that
      the LLM rationale includes? Lean yes — operators want to
      know "if I approve, my NRR will go up by 3%".

## 9. Change log

- **v1 (2026-06-14)**: Initial spec, drafted as Week 4 of
  GHW-as-CRM Phase 1. Phase 1 final deliverable.
