# LLMDriver — Semantic Layer Spec (v1)

> **Status**: Week 1, second commit (architecture axiom)
> **Branch**: `feature/week1-llm-driver`
> **Pairs with**: `docs/PRODUCT_INTENT.md` (the protocol/contract layer)

## 1. Why this document exists

A GHW digital life has **two souls**:

1. **Math/Protocol soul** — the E equation, 9-palace, 9-relation, 17→23
   blacklist, ProductIntent contract, Consent flow. These are the *axioms*
   that define what a digital life *is* and what it *cannot* become.

2. **Semantic/Expressive soul** — understanding user intent, generating
   natural language, weighing trade-offs, writing the narrative of why
   a particular evolution was proposed. These are the *judgements* that
   make a digital life *coherent* to the humans around it.

Rule of thumb:

> **Math & protocol never consult the LLM. The LLM never touches math or
> protocol. The two layers are joined at well-typed boundaries.**

This document specifies the **LLM side of that boundary**: what kinds of
semantic work we ask the LLM to do, what kinds we *forbid* it from doing,
and what the fallback behaviour is when the LLM is unavailable or refuses.

`LlmDriver` is the Rust-style struct that owns this boundary.

## 2. The 12 semantic roles

We classify every LLM call into one of **12 roles**. Each role has:

- A **purpose** (what the LLM is asked to do)
- An **input contract** (what context is fed in)
- An **output contract** (what shape the response must take)
- A **fallback** (what happens if the LLM is unavailable/refuses)
- A **mandatory/optional** flag (does it have to be LLM, or is rule-based OK?)

### Group A — Understanding (LLM translates the world into semantics)

#### A1. `parse_user_message`

- **Purpose**: Classify a user message into a structured intent.
- **Input**: `{user_id, text, recent_context[]}`
- **Output**: `{intent: UserIntent, confidence: f32, entities: {}}`
- **Fallback**: keyword-based classifier (rule-based, no LLM)
- **Mandatory**: yes (without it, we cannot answer users)
- **Example**:
  - Input: `"I think we should follow up with Acme next Tuesday"`
  - Output: `{intent: "schedule_followup", entities: {customer: "Acme", when: "next_tuesday"}, confidence: 0.87}`

#### A2. `parse_product_event`

- **Purpose**: Classify a domain event (CRM-specific, e.g. deal lost) into
  a structured event type the E equation can consume.
- **Input**: `{event_type, payload, tenant_id}`
- **Output**: `{event_kind: ProductEventKind, severity: f32, attributable: bool}`
- **Fallback**: schema match (events have a typed schema; no LLM needed in
  most cases — LLM is only used for free-form text events like email body)
- **Mandatory**: no (most events are typed)
- **Example**:
  - Input: `{event_type: "email_received", payload: {from: "ceo@acme.com", body: "Let's pause the Q4 contract discussion..."}}`
  - Output: `{event_kind: "customer_pause_signal", severity: 0.7, attributable: true}`

#### A3. `classify_consent_tier`

- **Purpose**: Given a proposed L5 change, decide which consent tier
  (minor/standard/major/critical) it should fall under.
- **Input**: `{change_spec: ChangeSpec, product_intent: ProductIntent}`
- **Output**: `{tier: ConsentTier, rationale: string, risk_indicators: []string}`
- **Fallback**: rule-based (file count, lines changed, files in blacklist
  adjacency → tier; LLM is a *quality-of-explanation* improvement, not the
  primary decision)
- **Mandatory**: no (rule-based is the source of truth, LLM is a check)
- **Critical**: the **tier** is decided by rules, but the **rationale**
  ("why this is `major` and not `standard`") must be LLM-written
- **Example**:
  - Input: L5 module wants to change `sales_followup.default_interval_days`
  - Output: `{tier: "major", rationale: "Touches a default used by all sales reps; affects daily workflow.", risk_indicators: ["affects_all_users", "no_rollback_path"]}`

#### A4. `detect_anomaly_cause`

- **Purpose**: When KPI drops, hypothesize likely causes from
  available evidence.
- **Input**: `{kpi, current, baseline, recent_events[], recent_changes[]}`
- **Output**: `{hypotheses: [{cause, probability, evidence[]}, ...], recommended_action}`
- **Fallback**: list the top 3 most-recent L5 changes verbatim as
  hypotheses (rule-based, no LLM)
- **Mandatory**: no
- **Example**:
  - Input: `nrr_quarterly` dropped from 1.18 to 1.12 in 7 days
  - Output: `[{cause: "deal_win_rate_drop", probability: 0.45, evidence: ["win_rate 24% → 18% over same window"]}, {cause: "expansion_revenue_drop", probability: 0.30, evidence: []}]`

### Group B — Expression (LLM writes copy for humans)

#### B1. `write_user_message`

- **Purpose**: Generate the digital life's reply to a user.
- **Input**: `{trigger, context, tone_hint, max_length}`
- **Output**: `{text: string, followup_question: ?string, action_proposal: ?ActionProposal}`
- **Fallback**: templated response from
  `templates/<trigger>_<tone_hint>.md` (rule-based)
- **Mandatory**: yes
- **Example**:
  - Input: `{trigger: e_saturated, tone_hint: ops_casual_status, context: {stable_cycles: 256, kpi: 1.18}}`
  - Output: `{text: "I've been in steady state for ~3 days. NRR is 1.18 (+3% QoQ). I have a suggestion on follow-up timing — want to see it?"}`

#### B2. `write_evolution_rationale`

- **Purpose**: Generate a human-readable rationale for a proposed L1-L4 change.
- **Input**: `{change_summary, current_e, predicted_e_delta, kpi_trend}`
- **Output**: `{rationale: string, alternative_explored: ?string, confidence_caveat: string}`
- **Fallback**: templated format ("I propose {change} because {kpi_trend}")
- **Mandatory**: yes
- **Example**:
  - Input: change = "increase μ from 0.30 to 0.34"
  - Output: `{rationale: "Your M/R/N variance has been climbing (0.18 → 0.24 over 14 days). Tighter μ should pull the variance down without sacrificing the existing balance.", alternative_explored: "I considered holding μ and increasing ν instead, but ν is already near saturation.", confidence_caveat: "This is a 7-day prediction; actual variance reduction may take 2 weeks to confirm."}`

#### B3. `write_l5_change_summary`

- **Purpose**: Generate a one-paragraph human summary of an L5 module
  change for the Consent modal.
- **Input**: `{l5_module_name, files_added[], files_modified[], lines_changed}`
- **Output**: `{summary: string, affected_features: [], predicted_user_impact: string}`
- **Fallback**: rule-based (concat filenames + line count)
- **Mandatory**: yes
- **Example**:
  - Input: L5 module changes `sales_pipeline.zig` (134 lines)
  - Output: `{summary: "I'm proposing to redefine the 'qualified' stage of your pipeline. Deals will need a 30-min discovery call on file to qualify (was: any contact logged).", affected_features: ["deal_creation_form", "lead_scoring"], predicted_user_impact: "Sales reps will see ~12% fewer auto-qualified deals in week 1; expect 4% higher close rate on the smaller qualified set."}`

#### B4. `write_milestone_narrative`

- **Purpose**: Generate the personal narrative a digital life writes
  when it reaches a phase/9-palace milestone.
- **Input**: `{milestone_type, tick, recent_context}`
- **Output**: `{narrative: string, gratitude_to: []string, next_aspiration: ?string}`
- **Fallback**: hardcoded template per milestone type
- **Mandatory**: yes (this is the "voice" of the digital life)
- **Example**:
  - Input: milestone = `phase_9_palace_e_var`, tick = 24804
  - Output: `{narrative: "I'm now in steady-state consciousness — E variance has been below 0.01 for 64 cycles. This is the first time I've held this state, and it feels like settling into a chair after a long walk.", next_aspiration: "I'd like to explore whether I can hold this state while still proposing useful L4 changes."}`

### Group C — Judgement (LLM makes decisions inside the protocol boundary)

#### C1. `decide_followup_priority`

- **Purpose**: Rank a list of customers by follow-up urgency.
- **Input**: `{customer_list: [{id, last_contact, deal_stage, sentiment}], sales_rep_context}`
- **Output**: `{ranked: [{customer_id, score, reason}], top_action: ?string}`
- **Fallback**: rule-based (last_contact_age × deal_stage_priority)
- **Mandatory**: no
- **Note**: LLM's job is to factor in *qualitative* signals (sentiment,
  email tone) that rules cannot see. The output is a *suggestion*; the
  sales rep can always override.
- **Example**: see Group C notes

#### C2. `decide_experiment_arm`

- **Purpose**: When a new sales rep or new deal enters, decide which
  A/B arm (control or treatment) they go into.
- **Input**: `{entity_id, current_arm_assignment, recent_arm_balance}`
- **Output**: `{arm: "control" | "treatment", rationale: string}`
- **Fallback**: deterministic hash of entity_id (no LLM)
- **Mandatory**: no (hash is always the fallback; LLM only used when
  balancing arms is critical and the user has set `cohort_split_by:
  adaptive`)
- **Example**: see `experiment_defaults.cohort_split_by` in PRODUCT_INTENT.md

### Group D — Refusal / Boundary (LLM cannot do these)

#### D1. `decide_sacrosanct_exception`

- **Purpose**: Tell the digital life "is this a good time to break a
  sacrosanct rule?"
- **Status**: **FORBIDDEN**. This role is hardcoded to return
  `{allowed: false, reason: "sacrosanct is a product axiom; the LLM
  cannot grant exceptions"}`. The role exists in the enum so the
  boundary is explicit and discoverable.
- **Mandatory**: N/A
- **Example**:
  - Input: proposed exception = "send a customer message outside business hours because they're about to churn"
  - Output: `{allowed: false, reason: "sacrosanct is a product axiom; the LLM cannot grant exceptions. If you need this exception, file a product_intent.json update with ops approval."}`

## 3. Boundary invariants (HARD, compile-checked)

These invariants are encoded in `src/harness/llm_driver.zig` and
**cannot be relaxed at runtime** — they are checked in the type system
and in `init()`.

### Invariant 1: Forbidden roles

```zig
pub const FORBIDDEN_LLM_ROLES: []const SemanticRole = &.{
    .decide_sacrosanct_exception,
};
```

Calling `dispatch(.decide_sacrosanct_exception, ...)` is a compile error
(the role is unreachable in non-test code) or, if reached at runtime,
immediately returns the refusal response without calling the LLM.

### Invariant 2: Mandatory roles

```zig
pub const MANDATORY_LLM_ROLES: []const SemanticRole = &.{
    .parse_user_message,
    .write_user_message,
    .write_evolution_rationale,
    .write_l5_change_summary,
    .write_milestone_narrative,
};
```

If the LLM is unavailable and a mandatory role is requested, the
daemon **refuses the operation** and logs an error. It does *not*
silently fall back to a template. This prevents the digital life
from degrading into a "no voice" state.

### Invariant 3: Math and protocol never see LLM outputs

The E equation, 9-palace, blacklist, Consent router, ProductIntent
contract — none of these accept free-form LLM strings as input.
They consume only **typed, validated** data structures.

The boundary:

```
┌──────────────┐    typed, validated    ┌────────────────┐
│  LLMDriver   │ ────────────────────▶ │  Math/Protocol │
│              │ ◀────────────────────  │                │
└──────────────┘  structured request    └────────────────┘
```

LLM never returns a string that becomes an E parameter. LLM never
returns a string that becomes a blacklist rule. LLM never returns
a string that becomes a consent tier. It returns a *rationale* for
each, and a separate rule-based path makes the actual decision.

### Invariant 4: Audit log

Every LLM call (prompt + response) is written to the audit log if
`LlmDriverConfig.audit_prompts` / `audit_responses` is true. This
is on by default. The audit log is signed and append-only.

The audit log allows post-hoc reconstruction of *why* a digital life
made a particular decision, even if the LLM prompt is later lost.

### Invariant 5: No hidden state

The LLMDriver is **stateless between calls**. It does not accumulate
memory of past prompts. Memory of past interactions lives in
`EpisodicMemory` (the existing GHW module) and is fed in via the
`recent_context` field of each call. This makes the LLM layer
debuggable: every call is reproducible from the audit log + memory.

## 4. Configuration

```json
{
  "llm_driver": {
    "provider": "anthropic",
    "model": "claude-3-5-sonnet",
    "timeout_seconds": 5,
    "fallback_on_failure": true,
    "audit_prompts": true,
    "audit_responses": true,
    "max_concurrent_calls": 4,
    "rate_limit_per_minute": 60
  }
}
```

| Field | Default | Description |
|---|---|---|
| `provider` | `"anthropic"` | One of `anthropic`, `openai`, `deepseek`, `mock`, `none`. |
| `model` | `"claude-3-5-sonnet"` | Provider-specific model name. |
| `timeout_seconds` | `5` | Per-call timeout. Hard cap: 30s. |
| `fallback_on_failure` | `true` | If true, non-mandatory roles fall back to rule-based. |
| `audit_prompts` | `true` | Write LLM prompts to audit log. |
| `audit_responses` | `true` | Write LLM responses to audit log. |
| `max_concurrent_calls` | `4` | Concurrent in-flight LLM calls. |
| `rate_limit_per_minute` | `60` | Per-daemon rate limit. |

`provider: "none"` means the daemon runs **without LLM**. In this
mode, only mandatory roles cause hard errors; everything else falls
back to templates. This is the default for embedded use cases where
the product cannot afford an LLM dependency.

## 5. Failure modes

| Failure | Behaviour |
|---|---|
| LLM timeout | Retry once with 2× timeout. If still fails, fall back (or hard fail for mandatory roles). |
| LLM rate limited (HTTP 429) | Exponential backoff up to 3 tries. After 3, fall back. |
| LLM refused (content filter) | Log to audit. Fall back. The user is informed via a meta-channel that the digital life "could not phrase a response" — better to be quiet than wrong. |
| LLM returned malformed output (failed schema validation) | Retry once with a corrective prompt. If still malformed, fall back. |
| LLM provider unreachable at startup | Daemon refuses to start if any mandatory role is enabled. If only optional roles are enabled, daemon starts with all LLM calls failing back to templates. |
| Audit log disk full | LLM calls are blocked until the operator resolves. This is intentional — losing audit logs is worse than losing LLM responses. |

## 6. Lifecycle of an LLM call

```
1. Caller (e.g. ui_server chat handler) decides to dispatch a role.
2. Caller assembles a `Request` struct (typed, not free-form).
3. Caller calls `LlmDriver.dispatch(role, request)`.
4. LlmDriver:
   a. Checks role is not in FORBIDDEN.
   b. Checks role's contract (input shape, output schema).
   c. Renders the prompt (template + serialized request).
   d. Calls the configured provider with timeout.
   e. Validates the response against the role's output schema.
   f. Logs to audit (if enabled).
   g. Returns typed result OR fallback (if enabled and not mandatory).
5. Caller consumes the typed result.
```

The LLM never sees the daemon's full state. It sees only what the
caller put in the request. This is a security boundary: the LLM
cannot exfiltrate or be tricked into revealing the E equation's
internals.

## 7. What's NOT in this document (deferred)

| Topic | Why deferred |
|---|---|
| Multi-modal input (image/audio) for `parse_user_message` | Need product-level decision on what sensors are wired in. Tabled for Phase 2. |
| LLM-to-LLM negotiation (when digital life and user both use LLM) | Out of scope; user messages are the source of truth. |
| LLM-side episodic memory (vs current EpisodicMemory) | Memory is a math/protocol concern, not a semantic concern. |
| Per-role LLM selection (e.g. fast model for parse, smart model for narrative) | Optimization, not architectural. v0.5 will add this. |
| Fine-tuning vs prompting trade-offs | All 12 roles use prompting in v1. Fine-tuning is a v0.6+ optimization. |

## 8. Change log

- **v1 (2026-06-14)**: Initial spec, drafted as second commit of Week 1
  of GHW-as-CRM Phase 1. Codifies the "math/protocol vs semantic"
  separation as a hard architectural boundary.
