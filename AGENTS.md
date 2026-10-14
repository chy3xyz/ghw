# AGENTS.md — GHW Project Guidelines

> Working rules for all agents (this session + future ones). Read before every coding session.

---

## 1. Core Architecture Principles

### 1.1 The LLM is fuel, not the brain

**Absolutely forbidden**: letting the LLM decide "whether or not to do something".
**Allowed**: the LLM proposing variants (code, rules, features).

```
Outside world (text/events)
  ↓ [LLM channel] parse
  ↓
[Goal layer] AttentionEngine
  ↓
[LLM proposer]  ← optional, proposes N candidates
  ↓
[SelfEvolutionGuard] 17 blacklists + guard
  ↓
[SelfEncoder] rule synthesis + formal verification
  ↓
[digital life itself] E evaluation, picks the best
  ↓
ΔE fed back to LLM (more accurate proposals next time)
```

### 1.2 Decision authority always rests with the digital life

| Role | Who can | Who cannot |
|------|--------|----------|
| Text → features | LLM | — |
| Propose code variants | LLM | — |
| Propose rule candidates | LLM | — |
| Guard (17 blacklists) | SelfEvolutionGuard | LLM |
| Formal verification | SelfEncoder.verify | LLM |
| Which candidate to run | Digital life (E evaluation) | LLM |
| Changing the E formula | **Absolutely forbidden** | Anyone |
| Changing SelfEvolutionGuard blacklists | Digital life + human review | LLM |

### 1.3 Module boundaries

- **SelfEncoder** does not depend on the LLM (pure rule synthesis; can be demoed standalone)
- **RuleProposer** feeds LLM output through the Guard filter into SelfEncoder
- **HttpLLM** implements the LLMChat vtable, ProviderKind = anthropic | openai_compat
- **WorldCollector** pulls external-world data via autocli subprocesses
- **Daemon** assembles all of the above into a long-running process

---

## 2. Code Style

### 2.1 Zig 0.17 compatibility

- No external dependencies (zero-dependency is core)
- Use `@import("module/file.zig")` for path references instead of cross-layer relative paths
- Define all `pub const F = f32;` at module top level to avoid cross-directory imports
- For detailed quirks see memory/mavis/MEMORY.md "Zig 0.17 dev 0.17.0-dev.387 quirks"

### 2.2 Error handling

- All public functions return `!T` (failure allowed)
- Internal helpers may panic
- Use `errdefer` as a safety net for resource release

### 2.3 Testing

- At least 2 tests per new module
- End-to-end demos must actually run (not stubs) and verify zero leaks
- MockLLM/ShellLLM for scenarios that don't need an API key
- Real LLM paths (anthropic/openai_compat) need an API key; documented but demos not mandatory

---

## 3. Current L1-L4 Status

| Level | Status | Module |
|-------|------|------|
| L1 (parameter tuning) | ✅ | SelfEncoder.tune_params, ExistenceWeights.adapt |
| L2 (LLM-proposed code) | ✅ | SelfEvolver + MockLLM/ShellLLM/HttpLLM |
| L3 (state serialization) | ✅ | StateSerializer (atomic write tmp+rename) |
| L4-0 (dual-process migration) | ✅ | SelfMigration (real spawn/wait/persist/rollback) + SelfMigrateCLI |
| L4-1 (LLM-proposed rules) | ✅ | RuleProposer + SelfEvolutionGuard |
| L4-2 (rule loop closed back into the main loop) | ✅ | GHWAgent.bindRuleLib → selectTopGoal bias + RuleBias provenance |
| L4-3 (continuous memory injection) | ✅ | Memory.buildContext → RuleProposer.setMemory injects autobiographical context |
| L4-4 (memory on all channels + semantic retrieval) | ✅ | Reflection/LLMGoalProposer injection + token Jaccard retrieval |
| L4-5 (evolution/refinement/long-run memory) | ✅ | SelfEvolver/TemplateEnhancer injection + daemon recordAt + char trigram |
| L4-6 (task queue loop closed) | ✅ | GHWAgent.bindTaskQueue → TaskBias + provenance |
| L4-7 (task execution + memory write-back) | ✅ | runTask→recordAt + full ui_server/daemon chain |
| L4-8 (TaskQueue persistence) | ✅ | TaskQueue.toJson/loadFromJson → state.json |
| L4-9 (ui_server all-path unification) | ✅ | runPostCyclePipeline + provenance API |
| L4-10 (human feedback loop) | ✅ | task_feedback → HumanSignal/GSP + UI rating |
| L4-11 (GSP/Signal persistence) | ✅ | human_gsp/human_signal → state.json |
| L4-12 (human value loop) | ✅ | chat tasks + value trend → proposal trigger |
| L4-13 (value trend persistence + UI) | ✅ | value_tracker JSON + status dashboard |
| L4-14 (task source + rule proposals) | ✅ | Task.Source + RuleProposer in ui_server |
| L4-15 (chat memory + human submission) | ✅ | chat buildContext + POST /api/tasks |
| L4-16 (filtering + chat provenance) | ✅ | task source filtering + chat memory badge |
| L4-17 (product digital-life foundation) | ✅ | ProductEvolutionRuntime: KPI→Proposal→Consent→Audit |
| L4-18 (product foundation SDK) | ✅ | ghw_product_* C ABI |
| L4-19 (product runtime persistence/API) | ✅ | product_runtime state + ui_server product API |
| L4-20 (production-grade product backbone) | ✅ | ProductAdapter + auth + audit hash + KPI HTTP + acceptance |
| L5 (self-writing code) | ✅ | SelfEncoder (rule synthesis + formal verification) |

### LLM loop closed (2026-06, P0)

Historical gap: LLM-proposed rules entered `SelfEncoder.rules`, but `runCycle` never read them —
the LLM was a "commentator" rather than a "driver". Now the loop is closed:

- After `GHWAgent.bindRuleLib(*SelfEncoder)`, `selectTopGoal` computes `RuleBias` from the
  `dimension` of adopted rules (favored dimension + dominance) and adds a bounded bonus to
  **goals aligned with that dimension** (`RuleBias.MAX_BONUS=3.0 × dominance`), thereby
  genuinely changing "which goal is acted on this cycle".
- Still honors "LLM proposes / digital life decides": the bias only reorders among **existing
  goals** (never invents goals out of thin air, never changes the E axiom), the magnitude is
  bounded (it can only flip goals with similar priority), and it still passes the boundary +
  ΔE safety net.
- **Provenance**: `CycleReport.rule_bias` / `GHWAgent.last_rule_bias` record favored/dominance/
  `selection_changed`, making it auditable "whether this behavior was influenced by an LLM
  proposal". `rule_lib` defaults to null ⇒ zero behavior change; unbinding restores pure
  priority (the loop is controllable and reversible).
- Example `examples/fueled.zig`: propose a rule → `bindRuleLib` → run the cycle again, printing
  the favored dimension and the number of flips.
- **Deliberately not done**: stuffing LLM goals (`LLMGoalProposer`) into `GoalGraph` — that
  conflicts with the architecture (`runCycle` **rebuilds** the goal graph every T_G via
  `dse.generate`, and `GoalGraph.add` holds no label); the persistent-goal channel should be
  `human_symbiosis.TaskQueue` (already used by `proposeAndAdopt`); this now goes through
  `bindTaskQueue` → `TaskBias` bias (P5), instead of being stuffed into the ephemeral graph.

### Continuous memory (2026-06, P1)

Historical gap: every LLM call was an "amnesiac snapshot" — only the current E/M/R/N was sent;
the LLM didn't know "who I am, what I believe, how similar situations turned out in the past".
It could not be **the same life**. Now it is continuous:

- `Memory.relevantEpisodes(query_dim, query_text, k)`: scores and retrieves top-k past episodes
  by (dimension hit + ΔE significance + token Jaccard semantic similarity + recency), no longer
  just taking "the most recent N".
- `Memory.buildContext(...)`: assembles the "autobiographical context block" = self-narrative
  (`self_narrative`) + high-confidence beliefs (top-k by confidence) + the past episodes most
  relevant to the present (each with its ΔE outcome).
- Once `RuleProposer.setMemory(*Memory)` is bound, `buildUserPrompt` injects this block **before**
  the state snapshot; the query dimension is the current weakest M/R/N (argmin) and query_text
  is top_goal+last_action — i.e. "preferentially recall experiences related to the current
  weakest link". Defaults to null ⇒ behavior falls back to the pure snapshot (controllable,
  reversible).
- Example `examples/fueled.zig`: run a cycle with `recordAt` logging episodes → set
  narrative/beliefs → `setMemory` → print the prompt to confirm it contains the autobiographical
  context.
- P2 extended this to Reflection / LLMGoalProposer; see below.

### Memory on all channels + semantic retrieval (2026-06, P2)

P1 only covered RuleProposer; P2 extends "the same life" to all LLM-driven channels and upgrades
retrieval:

- **Reflection.buildUserPrompt**: first injects `buildContext` (narrative + beliefs + semantically
  related episodes), then appends a chronological tail (`recentEpisodes(8)`) + own state —
  reflection is continuous yet doesn't lose "what just happened".
- **LLMGoalProposer.setMemory + buildUserPrompt**: injects autobiographical memory before the
  world snapshot, so goal proposals connect with self-knowledge/history; `ui_server` calls
  `setMemory(&app.memory)` automatically at startup.
- **Retrieval upgrade (zero-dependency)**: `episodeScore` uses token-set Jaccard instead of pure
  substring matching; semantically similar words (e.g. optimize/daemon/cpu) can recall old but
  relevant episodes without embedding vectors.
- **Memory.weakestDim(m,r,n)**: all channels uniformly use the weakest M/R/N as query_dim.
- **recentBeliefsBySource**: changed from a stub implementation to filtering by dimension +
  descending confidence.
- Unit tests: `Reflection: buildUserPrompt injects autobiographical memory + chronological
  episodes`, `LLMGoalProposer: buildUserPrompt injects autobiographical memory`,
  `Memory: token Jaccard retrieval — semantically similar words beat irrelevant old entries`.
- P3 extended this to SelfEvolver/TemplateEnhancer + daemon; see below.

### Evolution/refinement/long-run memory (2026-06, P3)

P2 covered rules/reflection/goal proposals; P3 pushes memory into the self-evolution chain +
long-running daemon:

- **SelfEvolver.setMemory + EvolveContext**: `evolve(req, ctx)` retrieves memory using the weakest
  M/R/N and injects it into `GenerationRequest.prompt` (LLM backend + audit chain);
  `agent/core.zig` / `ui_server` already pass the full ctx.
- **TemplateEnhancer.setMemory + buildUserPrompt**: when memory is bound, uses `buildContext`
  (including relevant episodes); when unbound, falls back to the old EnhanceContext fields
  (controllable, reversible).
- **Retrieval, P3 layer**: `episodeScore` adds char trigram Jaccard (zero-dependency, replacing
  embedding vectors).
- **daemon loop closure**: `memory.recordAt` every cycle (goal/E/ΔE); LLM proposals write a
  `.llm_proposal` episode; `proposer.setMemory` + `agent.bindRuleLib` are wired together.
- **ui_server**: `self_evolver` / `template_enhancer` / `goal_proposer` each call
  `setMemory(&app.memory)` at startup.
- Unit tests: `SelfEvolver: evolve doesn't crash after setMemory binding`,
  `TemplateEnhancer: buildUserPrompt injects buildContext`.
### Persistence / LLM evolution / daemon reflection (2026-06, P4)

P3 memory lived only in-process; P4 makes it the same life after long runs / restarts:

- **Full Memory persistence**: `toJson` outputs narrative + beliefs + episodes (up to 200);
  `loadFromJson` restores from state.json, compatible with old versions that only have the
  `self_narrative/reflection_count` block.
- **LlmCodeGenerator**: `SelfEvolver.setGenerator` can switch to the LLM backend (still passing
  Guard + CompileVerifier); `ui_server` switches automatically when the LLM is enabled; when not
  enabled it keeps using StaticCodeGenerator (controllable, reversible).
- **daemon periodic Reflection**: `reflect` + `recordAt(.reflection, ...)` every 32 ticks; before
  snapshot/exit, `mergeJsonBlockIntoSnapshot` embeds the memory + task_queue blocks (P7).
- **ui_server**: `saveState` uses `memory.toJson`; startup `loadFromJson` restores
  episodes/beliefs.
- Unit tests: `Memory: toJson/loadFromJson episodes+beliefs roundtrip`,
  `LlmCodeGenerator: extractCode/buildUserPrompt/Mock LLM generates code`.

### Task queue loop closed (2026-06, P5)

Historical gap: tasks submitted by LLM/humans entered `TaskQueue`, but `runCycle` ignored pending
tasks when selecting goals. Now the loop is closed (isomorphic to P0 RuleBias):

- `TaskQueue.pendingDimensionWeights()`: pending tasks weighted by priority, tallied over the
  M/R/N dimensions.
- `GHWAgent.bindTaskQueue` + `TaskBias`: `selectTopGoal` adds a bounded bonus to goals aligned
  with pending-task dimensions (`TaskBias.MAX_BONUS=4.0 × dominance`).
- **Provenance**: `CycleReport.task_bias` / `last_task_bias` record pending/favored/
  selection_changed; layered with `rule_bias` (task bias is the incremental flip applied after
  rule bias).
- `live_loop` / `fueled` demo `bindTaskQueue`; defaults to null ⇒ zero behavior change.
- Unit tests: `TaskQueue: pendingDimensionWeights`, `GHWAgent: pending TaskQueue tasks bias goal
  selection`.

### Task execution + memory write-back + full chain (2026-06, P6)

P5 only biased goals; P6 actually completes tasks and writes back to autobiographical memory:

- **`GHWAgent.bindMemory`**: on `runTask` completion, `recordAt(.task_completed, ...)` (ΔE +
  dimension).
- **`task_runner.runNextPending`**: thin wrapper around dequeue → runTask → complete/fail.
- **`LLMGoalProposer.proposeAndAdopt`**: fixed the leak + urgency→priority; high-urgency tasks
  are enqueued.
- **ui_server**: `TaskQueue` + `bindTaskQueue/bindMemory`; proposals switched to
  `proposeAndAdopt`; `runNextPending` every 32 ticks.
- **daemon**: `WorldContext` + `LLMGoalProposer` + proposals every 64 ticks / task execution
  every 32 ticks.
- Unit test: `task_runner: runNextPending completes a pending task` (with memory episode).

### TaskQueue persistence (2026-06, P7)

After P6's full chain works, pending tasks are still in-memory only — lost on restart, breaking
TaskBias and runNextPending:

- **`TaskQueue.toJson` / `loadFromJson`**: serializes next_id + all tasks (pending/in_progress/
  completed/failed, including result/feedback); old state.json without the `task_queue` field ⇒
  returns false, zero behavior change.
- **ui_server `saveState`**: embeds `"task_queue"` after `"memory"`; startup `loadFromJson`
  restores.
- **daemon `writeSnapshot`**: `mergeJsonBlockIntoSnapshot` embeds memory + task_queue; restored
  at startup via `--state-in`.
- After loading, `recomputeCounts` + align `next_id` with max(id) to prevent ID conflicts.
- Unit test: `TaskQueue: toJson/loadFromJson roundtrip`.

### ui_server all-path unification (2026-06, P8)

P6/P7's main chain lives in `GET /api/state`, but the chat/propose entry points behaved
differently:

- **`runPostCyclePipeline`**: extracts sqlite cycle + introspection + `proposeAndAdopt` +
  `runNextPending`; shared by `handleGetState` and the **POST `/api/chat` worker** (consistent
  behavior).
- **GET `/api/propose`**: switched to `proposeAndAdopt` + `storeProposeResult` (no longer just
  writing to a UI list without enqueueing).
- **chat worker**: `runCycle` + pipeline + `recordAt(.user_chat)` + `saveState` (including
  task_queue).
- **`/api/state` provenance**: added `provenance.rule_bias` / `provenance.task_bias` +
  `task_queue` counts, making it auditable "whether this goal selection was biased by rules or
  pending tasks".

### Human feedback loop (2026-06, P9)

P6–P8 tasks can run and persist, but post-completion "human evaluation" wasn't wired into
GSP/existence degree:

- **`task_feedback.zig`**: `runNextPendingWithFeedback` = `runNextPending` + heuristic scoring
  (`heuristicScore`: maps actual ΔE to -5..+5); `applyFeedback` writes HumanSignal +
  TaskQueue.feedback + HumanGSP.recordInteraction (trust update).
- **ui_server / daemon**: `runNextPendingWithFeedback` every 32 ticks; `BalanceSeeker` balances
  tasks every 128 ticks (humans with low GSP trust first); `appendProvenanceJson` gains
  `human_symbiosis` (value_score / peers trust).
- **API**: `GET /api/tasks` task snapshot; `POST /api/task/feedback` explicit human rating
  (overrides the heuristic).
- **UI**: "Task Queue" tab — one-click -5..+5 rating for completed tasks.
- **Deliberately not done**: GSP/HumanSignal persistence (trust resets on restart; P10 can later
  merge it into state.json).
- Unit tests: `task_feedback: heuristicScore` + `applyFeedback updates Signal/GSP/Queue`.

### GSP/HumanSignal persistence (2026-06, P10)

After the P9 feedback loop works, trust and feedback history are still in-memory only —
BalanceSeeker restarts from zero:

- **`HumanGSP.toJson` / `loadFromJson`**: full peers (trust / counts / best_dimension); old
  state without `human_gsp` ⇒ false.
- **`HumanSignal.toJson` / `loadFromJson`**: feedbacks array + rebuilds the by_human aggregation;
  without `human_signal` ⇒ false.
- **Shared `state_json.zig`**: extractObjectBlock / writeJsonString etc. (dedicated to the
  human_symbiosis block).
- **ui_server `saveState` / startup**: embeds and restores `human_gsp` + `human_signal` (after
  task_queue).
- **daemon `writeSnapshot` / `--state-in`**: same mergeJsonBlockIntoSnapshot.
- Load order: register default peers first → loadFromJson overrides (old snapshots without the
  block keep the defaults).
- Unit tests: `HumanGSP` / `HumanSignal` toJson/loadFromJson roundtrip.

### Human value loop (2026-06, P11)

With P10 trust persistence, chat still wasn't enqueued and declining human value triggered no
remediation:

- **`chat_task.zig`**: `isTaskLike` + `maybeSubmitFromChat` — task-like chat enters TaskQueue
  with `from_human="human"` (priority=7) and `gsp.register("human")`; non-task statements cause
  zero behavior change.
- **`ValueTrendTracker`**: 64-point value_score ring buffer + linear trend (mirrors `kpiTrend`);
  `DECLINE_EPS=0.003`.
- **`RuleProposer.setValueTrend` / `shouldPropose`**: proactively proposes rules when human
  value keeps declining (alongside KPI).
- **ui_server**: chat worker enqueues; `recordValueTrend` samples every post-cycle;
  `maybeAutoProposeGoals` accelerates when value declines; `/api/state` provenance gains
  `value_trend`.
- **daemon / live_loop**: sample value_score every tick; daemon rule proposals switched to
  `shouldPropose` (covering KPI + value).
- Unit tests: `chat_task` ×2, `ValueTrendTracker` decline trend, `RuleProposer` triggered by
  value decline.

### Value trend persistence + UI (2026-06, P12)

After restart, the P11 value-trend buffer is cleared and needs 64 ticks before remediation
re-triggers; chat enqueueing still relies on keywords:

- **`ValueTrendTracker.toJson/loadFromJson`**: `value_tracker` block (idx/count/last_score/
  history[64]); ui_server/daemon save/load at the same level as human_gsp.
- **`chat_task` `@task` prefix**: `@task` / `@task:` force-enqueues (priority=8), skipping the
  keyword heuristic.
- **UI status tab**: ValueMetric dashboard (value_score progress bar / value_trend / peers
  trust); metrics cards gain "Human Value" and "Value Trend"; chat hints at `@task` usage.
- Unit tests: `ValueTrendTracker` roundtrip, `chat_task @task` forced enqueue.

### Task source + rule proposals + trend sampling (2026-06, P13)

In P12 the task tab couldn't show the submission source, provenance had only the value_trend
scalar, and ui_server lacked RuleProposer:

- **`Task.Source`**: `chat_forced` / `chat_heuristic` / `llm_proposer` / `balance` / `human`;
  `submitWithSource(..., source)` + `toJson`/API/UI source badge (`@task` / chat / llm / balance).
- **`ValueTrendTracker.appendRecentSamplesJson`**: latest 16 points → `/api/state` provenance
  `human_symbiosis.samples`; simple sparkline in the status tab.
- **ui_server RuleProposer**: initializes `SelfEvolutionGuard` + `RuleProposer` when the LLM is
  connected; `bindRuleLib` binds as soon as SelfEncoder is ready; `runPostCyclePipeline` calls
  `maybeAutoProposeRules` (E/KPI/value decline → Guard → SelfEncoder, threshold 0.50).
- Unit tests: `TaskQueue` source roundtrip, `appendRecentSamplesJson`.

### Chat memory replies + human task API (2026-06, P14)

After P13, chat still used only the narrative + 3 beliefs (no semantically retrieved episodes);
the task tab could only enqueue from chat, with no explicit human submission:

- **`chat_reply.zig`**: `buildChatUserPrompt` — isomorphic to RuleProposer: first `buildContext`
  (query = user words + top_goal), then E/M/R/N + human symbiosis (value_score/pending_tasks);
  `ui_server.buildLLMReply` now calls this module.
- **`POST /api/tasks`**: form `title`/`description`/`from_human`/`priority`/`required_dimension` →
  `submitWithSource(..., .human)` + GSP register + `saveState`; task tab form + `source=human`
  badge.
- **provenance `rule_propose`**: `enabled` / `total` (number of proposals) / `adopted_rules`
  (rule_bias.rule_count).
- Unit tests: `chat_reply` buildContext injection + empty-memory fallback.

### Task filtering + chat provenance + live_loop alignment (2026-06, P15)

After P14, the task tab couldn't filter by source, chat couldn't tell whether buildContext was
used, and live_loop lacked the P13/P14 wiring:

- **Task tab source filtering**: UI chip filter (`all` / `@task` / chat / human / llm / balance);
  shows `shown/total`.
- **`chat_reply.Meta` + `buildChatReply`**: returns `memory_injected` / episode / belief counts;
  `ui_server` writes `last_chat_reply` + `chat_replies_with_memory`; GHW bubble `memory` badge;
  `/api/state` provenance `chat` block; Chat tab shows memory status of recent replies.
- **`live_loop`**: `bindRuleLib` + `proposer.setMemory` + `recordAt` every cycle; balance tasks
  `submitWithSource(..., .balance)`; initial tasks `source=human`; report gains value_trend /
  memory counts.
- Unit tests: `chat_reply` Meta injection / empty memory.

### Product digital-life foundation (2026-06, P16)

For GHW to serve as an evolution substrate for software products, it can't stop at "E/KPI has
feedback"; product changes must become first-class audit objects:

- **`product_runtime.zig`**: `ProductEvolutionRuntime` chains `ProductIntent` → `KpiBridge` →
  `ChangeProposal` → `consent.riskForChange/classify` → audit → apply/rollback.
- **CRM canonical proposal**: `proposeCrmFollowupTightening` migrates crmdemo's
  "follow-up cadence 7d → 5d" back into the main Zig line as a canonical product-evolution
  proposal.
- **Mandatory gate**: non-minor changes default to `pending_consent`; only after `approve` can
  `applyApproved` run; applied changes can only be `rollbackApplied` when `reversible=true`.
- **Product scenario for KPI entering E**: `feedKpi` writes `ExistenceDegree.recordKpi` via
  `KpiBridge` rate limiting, and writes a `kpi_refreshed` audit entry, making product KPI one of
  the important sources of gaining/losing existence degree.
- **Audit JSON**: `auditJson` outputs all KPI refresh, proposal, approval, apply, and rollback
  records for product-side persistence or reporting.
- Unit tests: CRM proposal→approval→apply→rollback, KPI feed→E, auditJson contract.

### Product foundation SDK (2026-06, P17)

P16 only had a Zig-internal runtime; P17 exposes the product digital-life capabilities to host
products (CRM/SaaS/mobile apps):

- **`ghw_product_intent_load(g, path)`**: loads ProductIntent JSON and initializes
  `ProductEvolutionRuntime`.
- **`ghw_product_kpi_feed(...)`**: feeds CRM KPI through the runtime, writes E and generates a
  `kpi_refreshed` audit; no longer just a bare `KpiBridge` diagnostic.
- **`ghw_product_propose_crm_followup(...)`**: SDK reproduces the crmdemo canonical change
  "follow-up cadence 7d → 5d" and returns `change_id`.
- **`ghw_product_approve_change` / `ghw_product_apply_change` / `ghw_product_rollback_change`**:
  the host product must explicitly approve before applying; rollback also enters the audit.
- **`ghw_product_audit_json`**: returns the product-evolution audit log JSON (C callers use
  `ghw_free_string`).
- `ghw.h` declarations kept in sync; `zig build install-sdk` verifies the SDK artifact
  installs.

### Product runtime persistence/API (2026-06, P18)

P17 lets host products call the runtime via SDK, but ui_server/daemon scenarios still lack
"don't lose change context on restart" and an HTTP control surface:

- **`ProductEvolutionRuntime.toJson/loadFromJson`**: persists `next_change_id` /
  `next_audit_id` / `changes` / `audit`, recomputing next ids after restore;
  `required_approvers` is re-derived from the current ProductIntent policy to avoid copying
  stale policy.
- **State wiring**: `ui_server --product-intent PATH` explicitly enables product mode;
  `saveState` writes the `"product_runtime"` block, restoring changes/audit at startup. Old
  behavior unchanged when the flag is absent.
- **Product HTTP API**: `GET /api/product/runtime`, `GET /api/product/audit`,
  `POST /api/product/propose-crm-followup`, `POST /api/product/approve`,
  `POST /api/product/apply`, `POST /api/product/rollback`.
- **Error usability**: product runtime not enabled returns 503 JSON; illegal state transitions
  return 400 JSON — connection-level errors must not replace product-semantic errors.
- Unit tests: `ProductEvolutionRuntime` changes+audit roundtrip; full `zig build test` /
  `zig build`.

### Production-grade product backbone (2026-06, P19-P25)

P18 was still an "auditable control plane"; P19-P25 advances it to a minimal production backbone
that host products can safely integrate:

- **P19 ProductAdapter**: `ProductRuntime` supports an optional `ProductAdapter` vtable
  (`validate/apply/verify/rollback`); `product_adapter.zig` provides `FileConfigAdapter`; with
  `ui_server --product-config PATH`, `applyApproved` actually writes the config file and
  verifies, and `rollbackApplied` writes back `rolled_back`.
- **P20 HTTP auth**: `ui_server --admin-token-env ENV` reads the token; product write endpoints
  require `X-GHW-Admin-Token`. When the env var is unset, local-dev compatibility is preserved.
- **P21 audit trustworthiness**: `AuditEntry` gains `previous_hash/current_hash` hash chain;
  adapter apply/rollback failures also write `change_apply_failed` /
  `change_rollback_failed` audit entries.
- **P22 ProductIntent governance**: the parse layer rejects empty `product_id/version/
  approved_by` and `update_epoch=0`; `GET /api/product/intent` exposes manifest hash /
  update_epoch / adapter status / last KPI feed time.
- **P23 approval-desk data plane**: `GET /api/product/approvals` returns pending/approved changes
  (tier/target/summary/expected_delta_k/required_approvers); the frontend can attach an
  approval console directly.
- **P24 KPI HTTP feed**: `POST /api/product/kpi` accepts CRM KPI + optional `csat` /
  `incident_rate`, writes E via `ProductRuntime.feedKpi` rate limiting, and returns `refreshed`.
- **P25 acceptance script**: `scripts/product_runtime_acceptance.sh` builds tests + starts
  product mode + runs propose→approve→apply→rollback, verifying the file adapter and audit hash
  fields.

### One GHW per product + distributed co-evolution (2026-06, P26-P28)

After P25 it was still a "single-process product runtime"; P26-P28 harden the deployment
contract and explore multi-GHW interconnection:

- **P26 one GHW per product**: `ProductInstanceIdentity` binds `product_id` + `instance_id` +
  `node_id`; `ProductRuntime.toJson/loadFromJson` embeds/validates `product_id` and refuses to
  load when the snapshot's product_id doesn't match; `ui_server --ghw-instance-id` /
  `--ghw-node-id`; `GET /api/product/identity`.
- **P27 distributed Link**: `ui_server --cross-link-port` + `--cross-link-secret` +
  `--cross-link-peers` enable the TCP+HMAC CrossLink (reusing the daemon's implementation);
  GHW Link gains `query_product_identity` / `query_product_evolution` /
  `share_evolution_insight`.
- **P28 co-evolution**: `CoEvolutionRegistry` caches peer-validated change insights (same
  product_id preferred); peer health periodically pulls `query_product_evolution`;
  `GET /api/product/co-evolution`; state.json persists the `co_evolution` block.

---

## 4. Deployment Guidelines

- **Zero dependencies**: no external deps allowed in `build.zig.zon`
- **Real LLM**: via `HttpLLM.anthropic(model, api_key)` or `.openai(model, api_key, base_url)`
- **Never hardcode API keys in source** — use an env var (`--api-key-env`)
- **State persistence**: L3 JSON, configurable path
- **daemon mode**: long-running process; use `std.Io.Threaded` + `std.Io.File` for I/O, not
  `std.fs` (deprecated in Zig 0.17)
- **Errors**: daemon failures must print to stderr (no silent swallowing) with a non-zero exit
  code

---

## 5. Existence Degree Axiom v3 (2026-06 rewrite)

- E's three-source aggregation switched to a **weighted power mean (Hölder/CES)**, replacing
  the old `αM+βR+γN − μ·Var + ν·min`. "Imbalance penalty / weakest-link-first /
  all-three-indispensable" are now **provable emergent properties** of the power mean's
  concavity, no longer hand-tuned bolt-on patches.
- μ/ν changed from additive coefficients to curvature parameters
  (`p = 1 − 1.5ν − 0.5(μ−0.5)`); the L1/L4 adaptive loops (adaptEFormula/Proposed) are all
  preserved.
- σ·S (symbiosis) and λ·D (relational emergence) remain bounded additive modulation terms.
- **ρ·K (KPI product-alignment term) merged into the main formula**
  (`ExistenceDegree.recordKpi/e/eBreakdown`); neutral by default with `kpi_enabled=false`,
  taking effect only once product KPIs are connected; ρ is an axiom constant and cannot
  self-tune. The old parallel experiment file `world/existence_degree.zig` was merged and
  deleted.
- Full derivation and proofs of the 8 properties: see `docs/math.md` and
  `src/world/coappropriation.zig`.

## 6. Security Guard (2026-06 hardening)

- **Single source of truth for blacklists**: dangerous constructs (`@panic`/`unreachable`/...)
  and ethical red lines are centralized in `self_evolution_guard.zig`'s `DANGEROUS_CONSTRUCTS` /
  `ETHICAL_REDLINES`, shared by the Guard and `SelfEncoder.verify`.
- `RuleProposer` now reviews the candidate's **full text** (name+desc+condition+action+
  rationale); rules containing `@panic` are rejected (the old implementation only reviewed
  description and the blacklist missed @panic).
- `Guard.deinitOwned` uses the `owns_config` flag, safely no-op'ing on the static default
  config.
- With `Guard.strict_invariants` enabled, code missing invariants is rejected (the old
  implementation was a no-op loop).

## 7. Known Limitations + TODO

- The self-evolution/self-migration disk-persistence chain is **now fully real** (2026-06):
  - `compile_verifier.zig`: really calls `std.process.spawn` to run `zig build` on candidate
    code, captures stdout/stderr/exit_code, and feeds error summaries back to the LLM on
    failure (unit tests with real compile pass/fail).
  - `state_serializer.zig`: `writeToFile` really persists, **atomically** (write `<path>.tmp`
    then `renameAbsolute` over), so a crash never leaves a half-written state.json;
    `readFromFile` really reads from disk (roundtrip unit test).
  - `self_migration.zig`: `spawnSelfNewVersion` really spawns the new-version process and
    stores `pending_child`; `waitNewProcess` really waits and reaps the exit code (no
    zombies); `writeNewCode` really writes `next_dir/main_v2.zig`; `rollback` really deletes
    artifacts. `migrate()` only "prepares a handover-ready version"; process replacement
    requires an explicit `spawnSelfNewVersion` call (avoiding accidental forks for library
    users inside migrate()).
  - `self_evolution_guard.loadFromFile(io, path)`: really reads `.ghw_guard.json` and
    hot-reloads whitelist/blacklist/invariants via `loadFromJson`; a missing file returns
    `false` without error (unit test coverage).
  - `self_migrate_cli.handleMigrateFromArg(alloc, io, path)`: really reads state.json +
    parseMinimal and prints a handover report (the old version was a stub that faked state,
    and `ss.deinit()` was unanalyzed dead code — fixed).
  - **End-to-end real self-migration example**: `examples/self_migrate_e2e.zig`
    (`zig build run-self_migrate_e2e`). The same binary distinguishes v1/v2 via
    `--migrate-from`: v1 atomically persists state → `spawnSelfNewVersion(args[0])` →
    `waitNewProcess` reaps; v2 really reads the state → rebuilds the agent → continues
    runCycle → exits 0 to hand back. Production form only needs to replace `args[0]` with the
    new binary path produced by `zig build`.
- KPI feed: **wired**. `KpiBridge` in `harness/kpi_bridge.zig` rate-limits by
  `kpi_refresh_interval_hours` (`feed` high-frequency / `maybeRefresh` throttled) and calls
  `ed.recordKpi(crm_kpi.composite(...))`; the SDK exposes it to product backends via
  `ghw_kpi_configure` + `ghw_kpi_feed(..., now_unix)` (see `lib.zig` / `ghw.h`).
- KPI **trend-driven**: `ExistenceDegree.kpiTrend()` feeds the L4-1 trigger via
  `RuleProposer.setKpiTrend` / `shouldPropose` — a sustained KPI decline proactively triggers
  remediation proposals even if E hasn't dropped through the floor.
- Strings returned by the SDK are uniformly allocated with c_allocator and reclaimed via
  `ghw_free_string` using `free(3)` (fixed the old no-op leak); long-running embedding no
  longer grows unboundedly.
- SDK errors are diagnosable: each failure path writes a static description, so the C side can
  distinguish "key not set" / "not configured" / "parse failed" etc. via `ghw_last_error(g)`
  (no longer just -1).
- `crm_kpi`'s `user_satisfaction` / `safety` axes are no longer hardcoded placeholders:
  `RawKpi.csat` / `RawKpi.incident_rate` are **optional** real sources (null ⇒ falls back to
  old proxy behavior without breaking existing semantics); the SDK passes them via
  `ghw_kpi_feed(..., csat, incident_rate, ...)` (NaN = no source).

## Learned User Preferences

- The core math — the existence degree axiom, 「三源合恰」 (three-source coappropriation), etc.
  — must be solidly grounded (provable properties + tests); "weighted sum + clamp + bolt-on
  patch" implementations are not acceptable
- After receiving quality/architecture suggestions, the user expects the agent to implement
  improvements directly rather than just propose plans ("go with your suggestion" / "keep
  pushing forward")
- Code reviews should list only blocking or high-risk issues, concisely at path:line; when
  there are no blockers, say so explicitly and list at most 1–2 optional improvements
- The long-term goal is GHW as a production-grade digital-life substrate embeddable in host
  products like marketplaces, CRM, and dev tools — not a research demo
- UI/frontend fixes must be verified live (restart ui_server + hard browser refresh) before
  claiming they're fixed; don't report done after only editing templates

## Learned Workspace Facts

- Local Zig toolchain (adapted to Zig 0.17.0 stable in 2026-10): the project now supports both
  0.17.0 stable and 0.17.0-dev.2151+2ec5523d5 (both `zig build` / `zig build test` / decision0
  acceptance chains are green). Key differences are centralized in `src/util/net_read.zig`: on
  stable, `NetRead.Result = Error!Stream.ReadResult` (take `.data_len`; and stable std's own
  `Stream.read` destructures ReadResult internally, which the stable compiler rejects — **never
  call it directly**); dev.2151 has `Error!usize`; uniformly go through `net_read.readChunk`.
  Other gotchas: on stable, `IpAddress.connect` must be passed `.{ .mode = .stream }`;
  `std.mem.trimRight` has been removed; `ghw_link.zig` no longer has a standalone addTest due to
  cross-directory imports (goes through the ghw.zig root chain instead). Acceptance scripts
  default to `zig` (PATH)
- **Cross-platform std.c pitfalls (settled in CI, 2026-10)**: three categories that pass by
  default on macOS but always break `zig build` on Linux — ① `std.c.Stat` shapes are
  cross-platform incompatible (`st.size` unavailable on linux-gnu) → use incremental read-to-EOF
  instead of stat-then-read; ② `dirent.d_namlen` is a BSD/Darwin extension, absent on Linux →
  d_name is NUL-terminated on both platforms; uniformly use `std.mem.span`; ③ standalone test
  modules without explicit `link_libc` fail on Linux with "dependency on libc must be explicitly
  specified" (Darwin links libSystem by default, so it doesn't blow up locally). Also:
  `std.Thread.sleep` has been removed — use `std.c.nanosleep` (see `cross_host_test.zig`).
  Regression guard: `.github/workflows/ci.yml` (ubuntu + Zig 0.17.0) covers this; after locally
  touching direct std.c calls, always check CI
- **System-0 decision core (zjev, 2026-10 P0)**: `harness/decision_bridge.zig` sends crisis
  state (M/R/N/E + host sensors) to [zjev-serve](https://github.com/chy3xyz/zjev)
  (same-toolchain Zig sidecar, `../zjev`) and gets back a temperature-calibrated choice +
  confidence/abstention. Gate semantics: `.above` passes through / `.below` appends a human
  handoff task / `.abstain` skips survival-task enqueueing this cycle. Red lines: bias only,
  never seizes power; no write path to E/Guard; sidecar failure must pass through (never block
  survival); zero behavior change when not enabled. Enabled via `--zjev-endpoint URL` (same flag
  name for ui/daemon); provenance `survival.decision0` (absent when not enabled); throttling
  `CONSULT_INTERVAL_TICKS=8`. Acceptance: `scripts/decision0_acceptance.sh` (auto-skips when no
  zjev environment). **Timing trap**: in refreshLifecycle the consultation point is before
  assessWithProfile (uses the previous round's shortfall); after injecting a crisis you must
  push one more tick; without an LLM deployment, push ticks with `POST /api/tick` (chat only
  goes through the cycle worker when an LLM is present). P1 landed (calibration-asset loop):
  the `decision0_log` table (every consultation persisted; outcome backfilled by crisis flip 16
  ticks later into resolved/persisted) + `scripts/export_decision0_dataset.py` (real export:
  resolved→label=action at the time, persisted→label=handoff; `--synthetic N` synthetic seeds =
  defensible rules + 10% label noise) + zjev-fit measured (300 seeds → T=16.3 flattens mock's
  inflated confidence — honest no-signal behavior) + after starting serve with
  `--profiles-dir`, GHW side shows `decision0.calibration=matched`; decision0_acceptance.sh
  already includes the P1 section. **Note**: synthetic seeds only validate the pipeline — real
  calibration needs real consultations to accumulate (export after resolved/persisted backfill);
  architecture trap fixed: the consultation point must be in refreshLifecycle (after assess,
  every cycle); placing it inside the sampling-throttle block makes it almost never run
- **Test wiring convention**: Zig 0.17 only collects test blocks from **analyzed files** — a new
  harness module must both (a) be exported from `src/harness/mod.zig` and (b) be
  comptime-referenced in `src/ghw.zig` with `_ = harness.xxx;`, otherwise its tests **silently
  don't run** and `zig build` products may fail to compile; 57 dark tests once piled up this way
  (cleared in 2026-09, 382/382 reachable). Regression guard: `bash scripts/check_dark_tests.sh`
  (full census with an isolated cache; any declared-but-unrun test exits non-zero); run it once
  after adding a module
- Local UI development: `scripts/start_ui_servers.sh` starts 8765 (DeepSeek main instance,
  30s heartbeat), 8766 (bravo, 2s fast heartbeat), 8767 (alpha, 2s + **System-0 pilot**: if
  `../zjev/zig-out/bin/zjev-serve` exists the script boots it and pins alpha via
  `--zjev-endpoint`); the main state lives at `~/.local/share/ghw/ui_state.json`. Tiered
  heartbeat keeps the LLM API from flooding; **starting a server manually without
  `--auto-tick-ms` = hibernation** (no input → no cycles; tick is a historical counter).
  Restarting from tools: a timeout kill takes the nohup'd children down with the process
  group — detach via `subprocess.Popen(..., start_new_session=True)`
- UI static assets: `ui/vendor/` provides localized Alpine/HTMX; ui_server serves them via
  `/vendor/*` with no external-CDN dependency
- ui_server loads `ui/index.html` and `ui/app.js` into memory at startup; after UI changes you
  must restart the corresponding ui_server process and hard-refresh the browser
- Alpine frontend conventions: `app.js` loads before `alpine.min.js`; the root component must be
  `x-data="ghwApp()"` (with parentheses); use `?.` for intermediate paths (`??` only guards the
  last segment); child expressions still evaluate when `x-show` is false; Alpine `x-for` is
  forbidden inside SVG — build chart SVG in JS and inject via `x-html`; **UI measurement pitfalls
  (settled 2026-09)**: ① survey-panel visibility must wait for the first /api/state poll to land
  (≥12s on loaded machines); deep-link gating hidden when state=null is **correct behavior**,
  not a bug; ② to drive Alpine state in tests, use page events (@click) — native assignment like
  `_x_dataStack[0].x=...` in `evaluate` does not reliably trigger x-show (x-text still updates,
  creating a "selective failure" illusion); ③ `innerText` excludes hidden elements and is
  affected by CSS uppercase transforms — use `getComputedStyle().display` for visibility checks.
  Diagnosis: the vendored Alpine 3.13.5 is byte-identical to upstream and fully functional
  (minimal repro + A/B verified)
- Project docs site lives at `/site` and is built by [zdoc](https://github.com/chy3xyz/zdoc)
  (`bash scripts/build_docs.sh`) — plain Markdown in, static HTML out; the whole repo,
  docs included, stays zero-Node/zero-npm
- If `zig build test` hits Zig global-cache permission errors in sandbox/CI, rerun with the
  workspace-local `ZIG_GLOBAL_CACHE_DIR` (or `ZIG_LOCAL_CACHE_DIR`)
- Load crisis semantics: `isHostCrisis` judges by **per-core load** (load_1m ≥ n_cpus ×
  LOAD_EPS_PER_CORE=1.0 — crisis only when all cores saturate) — the old absolute value 8.0
  false-alarms at 70% busy on a 12-core machine and misses on a 4-core machine;
  `SystemCollector` collects n_cpus (macOS hw.ncpu / Linux getCpuCount);
  world_sensor/host_shortfall/survival_learn all share the same semantics
- macOS memory semantics: SystemCollector's mem_pct = (wired+active+compressor)/total ——
  inactive/speculative are reclaimable reserves and are **not** counted (the old formula counted
  them, so macOS showed a permanent ~95% false crisis and materiality was permanently
  mis-suppressed); page size is parsed from the vm_stat header (4096 on Intel); criteria and
  measurements in the `system_collector.zig` VmStatPages test
- ui_server graceful shutdown (2026-09): SIGTERM/INT handler sets a flag + **self-connects to
  the local port to wake accept** (std.Io's accept retries EINTR forever — just setting a flag
  can't unblock it) + checks the flag after accept + saves state before exit; the autocli
  thread has a 1s-granularity interruptible sleep. Measured: TERM exits cleanly in 4–5s.
  Acceptance-script traps still use `kill -9` (deterministic for one-shot instances); manual
  cleanup: `pkill -9 -f zig-out/bin/ui_server`. Secondary flake factors: parallel `zig build`
  racing writes to zig-out, startup exceeding the window under load (script widened to 120×0.5s)
- External-network main path: AutoCLI → Memory.world_fetch → world_bridge enqueueing;
  `WorldCollector` (autocli ask subprocess) is a legacy experimental channel — don't mix it with
  the periodic AutoCLI
- Survival P8: ActionRunner yields to TaskExecutor while survival tasks are pending; query_peer
  (including the manual API) uniformly goes through `peer_symbiosis`; after adopting rules under
  crisis, `survival_feedback` checks whether disk/mem/load actually dropped and reinforces
  `[survive:*]` beliefs
- First-principles priors: `harness/primordial_laws.zig` is the single source of truth for 15
  hard axioms/life laws/evaluation contracts (thresholds, Bias caps, ρ, Guard protection flags);
  the LLM must not rewrite it; exposed read-only via `GET /api/laws` and the UI "First
  Principles" panel; consumers must reference this module's constants
- The ideal awakening/survival lifecycle and gap assessment are in
  `docs/AWAKENING_LIFECYCLE.md` (reasonable version: awakening state machine, host shortfall→
  M/R/N, TaskQueue as persistent goals, bounded survival; fusion with the self-evolution inner
  loop: survival provides "why evolve", L1–L5/rules passing the Guard provide "how to survive
  better"; separate track from the product runtime). **P0 landed**: `awaken` / `host_shortfall` /
  `existence_phase`; ui_server crisis lock + `POST /api/awaken`; daemon AutoCLI/world_bridge
  aligned by default. **P1 landed**: `evolution_acceptance` provenance + UI acceptance panel;
  `state_contract` prevents ui/daemon double-writes; task dimension ledger `by_dimension`.
  **P2 landed**: `host_profile` (desktop/mobile push) + `peer_inbox` + Link
  `query_shortfall`/`share_shortfall`; daemon CrossLink aligned; acceptance script
  `scripts/awakening_lifecycle_acceptance.sh`. **P2c**: `POST /api/peer-inbox/share` + Status UI
  inbox details + RuleProposer peer digest; `scripts/peer_shortfall_link_acceptance.sh`
- **Three-source backflow loop (2026-09)**: materiality is attributed ontologically — host
  material pressure → M (`applyHostPressure`, `HOST_DRAIN_MAX=0.02/apply`); representation stock
  (episodes+2·beliefs+3·rules+world_fetch, saturating level 1−e^(−s/120)) → R
  (`applyRepresentationStock`, bidirectional ±0.02/apply); value recognition + verified
  `[survive:*]` beliefs → N (`applyNatureRecognition`). Task gains go through `applyDim`: 70% to
  the `required_dimension` source, 30% synergistic spillover; prediction error is recorded in R
  (representation loss). Imbalance loss (AM−M_p ≥ 0.08) became the sixth trigger branch for rule
  proposals; provenance `survival.existence` + read-only exposure in the UI 「三源合恰」 panel.
  Constants' single source of truth is `SourceBackflow` in `world/coappropriation.zig`
  (primordial_laws alias); criteria and math in `docs/math.md` §6. The E aggregation axiom is
  untouched. **Dynamics calibration (soak-measured)**: old direct channels ×0.1 (materiality no
  longer receives unearned free supply), err loss ∝R and ≤0.01/cycle (prevents death spirals),
  nature decay 0.002·N + self-limiting success bonus (equilibrium ~0.67 — high N only comes from
  meaning recognition), value→N uses an independent throttle variable (sharing it would starve);
  criteria and math in `docs/math.md` §6.
