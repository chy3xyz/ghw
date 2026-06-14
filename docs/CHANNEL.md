# UserChannel — Spec (v1)

> **Status**: Week 3 of Phase 1 (GHW-as-CRM)
> **Branch**: `feature/week3-user-channel`
> **Pairs with**: `docs/LLM_DRIVER.md`, `docs/PRODUCT_INTENT.md`, `docs/KPI.md`

## 1. Purpose

`UserChannel` is the **bidirectional communication layer** between a
GHW digital life and the human(s) it serves. The protocol layer
(see `ProductIntent.channel_routing`) decides **where** a message
goes; `UserChannel` decides **what** is sent, **when** it is
allowed to fire (throttling), and **what** the human said in
return.

This is the third "soul" of the GHW-as-CRM architecture:

| Soul | Lives in | Layer |
|---|---|---|
| Math/Protocol | `existence_degree.zig`, `SelfEvolutionGuard`, `ProductIntent` | axiomatic, never consults the LLM |
| Semantic | `llm_driver.zig`, 11 typed roles | LLM-driven, typed contract |
| **Communication** | **`user_channel.zig`** | **the bridge between the above two and the human** |

## 2. The 5 triggers

`UserChannel` has 5 trigger types. Each trigger is a *reason* the
digital life speaks. The product's `channel_routing` config says
*where* the message goes; this module says *what* and *when*.

| Trigger | When | Channels (CRM default) | Throttle |
|---|---|---|---|
| `e_saturated` | 9-palace E variance < 0.01 for 64 cycles | `admin_dashboard`, `slack_webhook` | 24h per tenant |
| `user_quiet_24h` | Primary user inactive ≥ 24h | `email_digest` | 7d per user |
| `l5_about_to_apply` | L5 module about to be adopted (consent required) | `admin_dashboard`, `email` | none (consent) |
| `anomaly` | KPI crossed critical threshold (configurable) | `slack_urgent`, `pagerduty` | none (critical) |
| `experiment_done` | A/B reached `min_duration_days` | `admin_dashboard`, `email_monthly_report` | 30d per tenant |

Week 3 implements **`e_saturated` only**. The other 4 are
deferred to Week 3.5+ and follow the same pattern.

## 3. Two-direction architecture

```
┌──────────────────────────────────────────────────────────┐
│  user_channel.zig                                         │
│                                                            │
│  InboundRing  (user → digital life)                       │
│  ──────────────────────────────────                       │
│  InboundMsg {                                              │
│    msg_id: u64,                                           │
│    user_id: []const u8,                                   │
│    text: []const u8,                                      │
│    sentiment: f32,    // -1..+1, filled by parse_user_msg  │
│    intent: UserIntent, // filled by parse_user_msg        │
│    received_at: u64,                                      │
│  }                                                        │
│                                                            │
│  OutboundRing  (digital life → user)                      │
│  ───────────────────────────────────                      │
│  OutboundMsg {                                             │
│    msg_id: u64,                                           │
│    trigger: ChannelTrigger,                                │
│    channel: []const u8,                                   │
│    payload_json: []const u8,                              │
│    created_at: u64,                                       │
│    delivered: bool,                                       │
│  }                                                        │
│                                                            │
│  ThrottleTable (per-trigger, per-tenant)                  │
│  ───────────────────────────────────                      │
│  last_fired_at: [ChannelTrigger]u64                       │
│  ─ dedupes "spammy" triggers                              │
└──────────────────────────────────────────────────────────┘
```

Both rings are **bounded** (default 256 entries each) and
**overwrite-oldest** when full. This is the standard "drop-oldest
queue" pattern; we never block the writer.

## 4. `e_saturated` trigger — the Week 3 implementation

This is the first trigger we implement because it is the simplest
(no external condition beyond internal state), the most visible
(direct user feedback that the digital life is healthy), and
the lowest-risk (it cannot cause user-facing harm — the user
can always ignore it).

### 4.1 Detection

```
every cycle:
  e_history_buf[idx] = ed.e()
  idx = (idx + 1) % 64
  if count >= 64:
    compute variance of e_history_buf
    if variance < 0.01 AND no fire in last 24h:
      fire e_saturated trigger
```

The variance check is **on E**, not on E - ρ·K (the full
composite). The reason: the 9-palace steady-state milestone is
defined in terms of M/R/N balance, not KPI performance. KPI
rising while M/R/N wobbles is *not* steady-state.

### 4.2 Fire flow

```
e_saturated_trigger_fired:
  1. Check ThrottleTable[e_saturated] for current tenant
  2. If last_fired_at + 24h > now: return (throttled)
  3. For each channel in ProductIntent.channel_routing.e_saturated:
     a. LlmDriver.dispatch(.write_user_message, {
          trigger = "e_saturated",
          context = e_history snapshot + KPI snapshot,
          tone_hint = ops_casual_status,
          max_length = 200,
        })
     b. Append OutboundMsg to OutboundRing
     c. Update ThrottleTable[e_saturated] = now
  4. Mark trigger as fired in this cycle (no re-fire same cycle)
```

### 4.3 Throttle table

The throttle table is a simple `std.AutoHashMap(TenantId, [5]u64)`:
each tenant has a last-fired timestamp per trigger. **All access
is single-writer** (the daemon main thread) so no locks needed
in Week 3. Week 3.5 will add multi-threaded dispatchers, at which
point we switch to `std.atomic.Value(u64)` per slot.

### 4.4 Persistence

The `OutboundRing` is **persisted** to a JSONL file
(`<state_dir>/outbound_log.jsonl`), one line per message. This
allows the UI to show "what the digital life said in the last
30 days" even after a daemon restart. The `InboundRing` is **not**
persisted (user messages are already in the chat history; the
ring is just a hot cache).

## 5. Failure modes

| Failure | Behaviour |
|---|---|
| LLMDriver unavailable (provider=none + mandatory role) | Trigger fires; outbound message is `[digital life is currently without LLM; no response available]`. Marked in audit log as `llm_unavailable`. **Note**: this is the only way a MANDATORY role's failure reaches the user; the alternative (silent no-op) is worse. |
| Throttle table full (per-tenant) | Oldest entry is evicted. Loss is bounded to one tenant's history. |
| OutboundRing full (256 entries) | Oldest entry is overwritten. The dropped message is logged. |
| Persistence write fails (disk full) | In-memory ring continues; new messages are not persisted. On restart, the lost messages are gone. Audit log records the failure. |
| Channel delivery fails (e.g. slack webhook 500) | OutboundMsg is marked `delivered = false`. The daemon retries on the next cycle. After 5 retries, the message is dropped. |

## 6. The 4 deferred triggers (roadmap)

| Trigger | Why deferred | Week |
|---|---|---|
| `user_quiet_24h` | Requires persistent user activity log; needs `EpisodicMemory` integration | Week 3.5 |
| `l5_about_to_apply` | Requires Consent flow first; Week 4 deliverable | Week 4 |
| `anomaly` | Requires KPI threshold config + on-call integration | Week 4 |
| `experiment_done` | Requires `experiment.zig` first; Week 5 deliverable | Week 5 |

## 7. Anti-patterns

1. **Trigger spam** — never fire the same trigger twice in 24h
   per tenant. The ThrottleTable enforces this.
2. **Synchronous channel delivery** — never block the daemon
   main thread on an HTTP POST. Use the existing
   `chat worker + mutex + inflight flag` pattern (see
   `evolution_rationale.zig` for the model).
3. **Storing free-form LLM text as channel payload** — all
   `payload_json` is the LLM's *output*, validated against
   the `write_user_message` schema. The receiving channel
   (Slack, email, etc.) is downstream and may or may not
   trust the text. We do not, however, sanitize HTML in
   the daemon itself — that is the channel's responsibility.

## 8. Open questions for v0.5

- [ ] Should we add a "preview" step for `e_saturated`? E.g.
      the digital life drafts a message but does not send
      until a human approves? Lean no — the message is
      informational, not actionable.
- [ ] Should the throttle table be per-tenant or per-user?
      Lean per-tenant (one CRM company = one throttle table).
- [ ] Should outbound messages be signed? The audit log
      captures them, but the message itself is unsigned.
      Lean yes for v0.5 (HMAC).

## 9. Change log

- **v1 (2026-06-14)**: Initial spec, drafted as Week 3 of
  GHW-as-CRM Phase 1. Implements the `e_saturated` trigger
  end-to-end. Other 4 triggers follow.
