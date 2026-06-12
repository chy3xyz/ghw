# GHW Architecture

> The 4-layer architecture, data flow, 9-palace state machine, and L1–L5
> self-evolution chain. Read this if you want to understand the system
> internals before contributing or embedding.

## Table of Contents

- [High-level view](#high-level-view)
- [Layer 1: World](#layer-1-world)
- [Layer 2: Goal](#layer-2-goal)
- [Layer 3: Harness](#layer-3-harness)
- [Layer 4: Agent](#layer-4-agent)
- [The E formula](#the-e-formula)
- [L1–L5 self-evolution chain](#l1l5-self-evolution-chain)
- [9-relation GoalGraph](#9-relation-goalgraph)
- [9-palace deep dive](#9-palace-deep-dive)
- [L4 closed-loop (LLM proposes E-formula coefficients)](#l4-closed-loop-llm-proposes-e-formula-coefficients)
- [HTTP API](#http-api)
- [Persistence (SQLite + JSON snapshots)](#persistence-sqlite--json-snapshots)
- [Threading model](#threading-model)

## High-level view

```
                        ┌──────────────────────────────────┐
                        │   External World                 │
                        │   (system metrics, peers, time)  │
                        └─────────────┬────────────────────┘
                                      │ SystemCollector / WorldContext
                                      ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Layer 1: World (src/world/)                                             │
│  - ExistenceVector (M, R, N) — three-source co-appropriation           │
│  - ExistenceDegree (E) with adaptive weights                            │
│  - E = αM + βR + γN − μ·Var + ν·min + σ·S + λ·D                       │
│  - CoappropriationTensor W ∈ R^{d_P × d_S × d_E}                       │
│  - WorldModel (3-snapshot history)                                      │
└─────────────────────────────┬──────────────────────────────────────────┘
                              │ difference set Δ
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Layer 2: Goal (src/goal/)                                               │
│  - AttentionEngine (top goal selection)                                 │
│  - PerceptionEngine (parse world → features)                            │
│  - DifferenceTensor Δ ∈ R^{d_G × 4 × d_W}                              │
│  - GoalGraph (9-relation DAG: parent_child, sibling, conflict,          │
│    depends_on, replaces, enables, inhibits, emerges_from, emerges_after)│
│  - Topological sort (Kahn algorithm, 3 indegree constraints)            │
└─────────────────────────────┬──────────────────────────────────────────┘
                              │ top goal
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Layer 3: Harness (src/harness/)                                         │
│  - BoundaryGuardian (per-action resource limits)                        │
│  - ResourceScheduler (priority queue)                                   │
│  - MethodLibrary (ActionKind → method)                                  │
│  - ActionRunner (executes methods, 5 presets:                           │
│    wasm / claude_code / peer_query / self_evolve / observe)             │
│  - SelfEvolutionGuard (17-blacklist prefix matching)                    │
│  - CodeGenerator + StaticCodeGenerator (L1–L5 templates)                │
│  - SelfEncoder (rule synthesis + formal verification, L5)                │
│  - CompileVerifier (real `zig build` against L3/L4/L5 output)           │
│  - TemplateEnhancer (LLM rewrites L1–L5 in "I" voice)                   │
│  - AutoCLI (4 external data sources: Wikipedia / HN / ArXiv / RSS)      │
└─────────────────────────────┬──────────────────────────────────────────┘
                              │ action outcome
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Layer 4: Agent (src/agent/)                                             │
│  - GHWAgent (3 time-scale main loop: η_H > η_W > η_G)                   │
│  - ReflectionTrigger (every 32 cycles, with LLM)                        │
│  - SelfMigration (process fork for state version upgrade)               │
│  - StateSerializer (JSON snapshot every N cycles)                       │
│  - LLM (MockLLM / ShellLLM / HttpLLM — anthropic, openai_compat)        │
│  - L4 closed-loop: LLM proposes μ/ν/σ/λ every 8 cycles                 │
│  - Persists to SQLite (episodes, beliefs, proposed_goals) +              │
│    state.json (existence degree, goal graph)                            │
└────────────────────────────────────────────────────────────────────────┘
```

## Layer 1: World

**File**: `src/world/core.zig`

The world layer is the **objective existence** — three sources of meaning
that the agent tracks:

- **M (Material)**: practical, doing, executing. Updated by action outcomes
  (success/failure, resources spent).
- **R (Representation)**: analytical, modeling, learning. Updated by
  reflection outcomes (new beliefs, validated patterns).
- **N (Nature)**: introspective, meaning-making, awareness. Updated by
  reflection and 9-palace deep dives.

All three are bounded in `[0, 1]`. The **existence degree** `E` is computed
from them, plus 4 adaptive additive terms (see [The E formula](#the-e-formula)).

**Key data structures**:

- `ExistenceVector { material: F, representation: F, nature: F }` — F = f32.
- `ExistenceDegree { v: ExistenceVector, weights: ExistenceWeights, mu, nu, sigma, lambda, ... }`.
- `ExistenceWeights { alpha, beta, gamma }` — invariant (only tunable by
  SelfEncoder with formal verification, never by LLM directly).
- `CoappropriationTensor W ∈ R^{d_P × d_S × d_E}` — three-way relationship
  tensor between perception, state, and existence.
- `WorldModel` — last 3 world snapshots, used for ΔE backprop.

## Layer 2: Goal

**File**: `src/goal/core.zig`

The goal layer is the **subjective attention** — what the agent is currently
looking at.

- **AttentionEngine**: given current E and a set of candidate goals, compute
  attention scores and return the top goal. (Not pure LLM — uses the
  existence gap Δ as the primary signal.)
- **PerceptionEngine**: parse world text (or system metric JSON) into a
  feature vector that can be diffed against the world model.
- **DifferenceTensor Δ**: 3-tensor of (goal × {M, R, N} × W) differences.
- **GoalGraph**: 9-relation DAG, see [below](#9-relation-goalgraph).

**Why 9 relations?** They mirror the actual structural relationships that
emerge in a self-evolving system: parent_child (one goal produces another),
sibling (parallel sub-goals), conflict (compete for resources), depends_on
(sequential), replaces (deprecated by new), enables (prerequisite),
inhibits (mutex), emerges_from (L1–L5 evolution link), emerges_after
(temporal delay).

## Layer 3: Harness

**File**: `src/harness/` (16 files, ~6000 lines)

The harness is the **executor** — it takes the top goal from layer 2 and
turns it into an action outcome.

**Sub-modules**:

- **BoundaryGuardian** — per-action resource limits (max time, max memory,
  max file size, max network calls). Violations → action rejected.
- **ResourceScheduler** — priority queue over pending actions.
- **MethodLibrary** — maps `ActionKind` to executable method (WASM, Claude
  Code, peer query, self-evolve, observe).
- **ActionRunner** — executes a method, returns `ActionOutcome` (success,
  cost, output, error).
- **SelfEvolutionGuard** — 17-rule blacklist prefix matching. LLM cannot
  touch `src/agent/params.zig` (L4 target), `src/goal/methods/l3_<tick>.zig`
  (L3), or the core E formula files. Violations → proposal rejected.
- **CodeGenerator + StaticCodeGenerator** — L1–L5 code templates, produce
  `.zig` files. L3 (习得方法) and L4 (算法优化) go through the guard.
- **SelfEncoder** — L5 (自编码) — rule synthesis + formal verification.
  Generates new rules that pass the verifier before they can run.
- **CompileVerifier** — real `zig build` against the proposed L3/L4/L5
  file, with a temp `build.zig` that copies `harness_api.zig` (a thin
  ActionOutcome wrapper) into the verify dir. Cross-dir `--dep` in Zig
  0.17 is broken, so we use the build-file approach.
- **TemplateEnhancer** — LLM rewrites the latest L1–L5 output in the
  digital life's "I" voice (e.g., "I learned to think about..."). Falls
  back to a template if LLM fails.
- **AutoCLI** — every 5 min, fetch Wikipedia random / HN top / ArXiv cs.AI
  / RSS feeds. Trigger phase 6 "六气" when 4 sources succeed.

## Layer 4: Agent

**File**: `src/agent/core.zig` + `examples/daemon.zig` + `examples/ui_server.zig`

The agent is the **3-time-scale main loop** that ties everything together.

**Time scales** (η_H > η_W > η_G):

- **η_H (reaction, ~1s)**: respond to current perception, run top action.
- **η_W (adaptation, ~32 cycles)**: reflect on recent actions, update beliefs.
- **η_G (genesis, ~96 cycles)**: L1–L5 self-evolve, rewrite code.

**Loop**:

```
loop:
  perceive(world)              # Layer 1
  attend(goal_graph)            # Layer 2
  if top goal: harness.run()   # Layer 3
  if cycle % 32: reflect()     # η_W
  if cycle % 8 and llm != null: l4_propose_coefs()  # L4 closed-loop
  if cycle % 64: l3_evolution()
  if cycle % 96: l4_evolution()
  if cycle % 192: l5_evolution()
  if cycle % 64: nine_palaces_check()  # 9-palace milestones
  if cycle % 64: template_enhance()
  if cycle % 5min: autocli_fetch()
  state.snapshot()
```

## The E formula

```zig
E = α·M + β·R + γ·N      // invariant (3 weights)
  − μ·Var(M,R,N)            // imbalance penalty
  + ν·min(M,R,N)            // synergy gain
  + σ·S                      // symbiosis (peer-E gap)
  + λ·D                      // relations emergence (D = distinct relations / 9)
```

- **α, β, γ** are **invariant** — set once at agent init, never changed by
  LLM. (L1 can tune them, but the 17-blacklist prevents accidental drift.)
- **μ, ν, σ, λ** are **adaptive** (Phase 8.6 closed-loop):
  - **ν** = 0.10 + 0.30 · balance (high when M≈R≈N)
  - **μ** = 0.30 + 0.30 · (1 − balance) (high when imbalanced)
  - **σ** = 0.10 if peer_count > 0 else 0 (active only with peers)
  - **λ** = adaptive stage: 0.05 (< 1k self-evolved), 0.10 (1k–5k), 0.20 (> 5k)
- The 4 adaptive coefficients can also be **proposed by the LLM** (Phase
  8.7). When the LLM proposes, the corresponding `*_auto` flag is set to
  `false`, and the LLM's value is used directly. Next LLM proposal
  overwrites.

The E formula is **printed at every cycle** as `e_breakdown` in
`/api/capabilities`, so you can see the live contributions.

## L1–L5 self-evolution chain

**File**: `src/harness/self_evolver.zig`, `src/harness/code_generator.zig`,
`src/harness/compile_verifier.zig`, `src/harness/self_encoder.zig`

L1–L5 is the heart of GHW. The chain produces **real compiled `.zig` files**
that are adopted into the ghw source tree and shipped in the next binary.

| Level | What | Schedule | Where |
|-------|------|----------|-------|
| **L1** | Tune parameters (α, β, γ, μ, ν, σ, λ) | every 32 cycles | `src/agent/auto_eps/l1_<tick>.zig` |
| **L2** | ε-perturbation optimization | every 32 cycles (with L1) | `src/agent/auto_eps/l2_<tick>.zig` |
| **L3** | Learn a new method (e.g., a new way to query peer) | every 64 cycles | `src/goal/methods/l3_<tick>.zig` |
| **L4** | Optimize the algorithm (e.g., rewrite ε-greedy → UCB) | every 96 cycles | `src/agent/params.zig` |
| **L5** | Self-encode a new rule (formal verification required) | every 192 cycles | `src/harness/auto_eps/l5_<tick>.zig` |

**Flow** for L3–L5 (real compilation):

1. **Generate**: `CodeGenerator` produces a `.zig` file from a template.
2. **Guard**: `SelfEvolutionGuard` checks the file against the 17-blacklist
   (e.g., L3 must be under `src/goal/methods/`, can't touch E formula).
3. **Verify**: `CompileVerifier` writes a `build.zig` to a temp dir, copies
   `harness_api.zig` (a thin ActionOutcome wrapper) into the temp dir, then
   runs `zig build --build-file <temp_build_zig> --global-cache-dir <tmp>`.
4. **Apply**: if the verifier passes, the file is adopted into the ghw
   source tree (`src/goal/methods/l3_<tick>.zig` for L3,
   `src/agent/auto_eps/l4_<tick>.zig` for L4, etc.).
5. **Adopt**: the file becomes part of the next build via
   `src/harness/auto_eps/registry.zig` (auto-`@import`s all dropped files).

**TemplateEnhancer** can rewrite L1–L5 output in the digital life's "I"
voice (e.g., "I learned to ask the peer before acting, because..."). This
is a meta-step on top of the chain.

## 9-relation GoalGraph

**File**: `src/goal/core.zig`

The goal graph models **structural relationships** between goals. There are
9 relation types:

| ID | Name | Symbol | Meaning |
|----|------|--------|---------|
| 1 | parent_child | → | One goal produces another |
| 2 | sibling | ↔ | Parallel sub-goals |
| 3 | conflict | ⚔ | Compete for resources |
| 4 | depends_on | ⤓ | Sequential prerequisite |
| 5 | replaces | ⤳ | Deprecated by new |
| 6 | enables | ✦ | Prerequisite (softer than depends_on) |
| 7 | inhibits | ⊘ | Mutex |
| 8 | emerges_from | ∾ | L1–L5 evolution link |
| 9 | emerges_after | ⏳ | Temporal delay |

**Topological sort**: Kahn's algorithm, with 3 indegree constraints
(parent_child, depends_on, emerges_after). Returns
`error.CycleDetected` if a cycle exists.

**API endpoints**:
- `GET /api/goals/relations` — statistics + topological order + per-goal
  relations.
- The UI shows the 9 relations as colored emoji cards with the topo order
  and the per-relation counts.

## 9-palace deep dive

**File**: `src/world/core.zig` (math) + `examples/ui_server.zig` (tracking)

The 9-palace is a **maturity gate** — a quantitative marker that the digital
life has reached a "三源合恰" (three-source-co-appropriation) balanced
state. There are **3 milestones**, all must hold for 64 consecutive cycles:

1. **E variance < 0.01** — E is stable, not bouncing around.
2. **M/R/N variance < 0.01** — M ≈ R ≈ N, three sources are balanced.
3. **min(M, R, N) ≥ 0.85** — strong 三源合恰, not just balanced but high.

Each milestone has a 64-slot ring buffer. Every cycle, we write the
current value (variance or min) into the buffer. When the buffer is full
(64 entries), we compute the mean + variance of the buffer. If the
variance is below the threshold (or the min is above 0.85), the milestone
is permanently triggered.

**Persistence**: each `*_seen` flag is a `u8` stored in `state.json` and
restored on restart. A milestone, once triggered, is permanent for the
agent's lifetime.

**API endpoints**:
- `GET /api/capabilities` → `phase.milestones` (9-palace) + `nine_palaces_deep` (live data).
- `GET /api/nine_palaces_history` → milestone history + 16-cycle snapshots.

**Why 3 milestones and not 1?** A single E-variance milestone can be
trivially satisfied (e.g., the agent is "stuck" in a local optimum where
E doesn't change but M/R/N are wildly imbalanced). The 3-milestone gate
requires *all three* to be true, which is a much stronger statement
about the agent's state.

## L4 closed-loop (LLM proposes E-formula coefficients)

**File**: `src/world/core.zig` (`adaptEFormulaProposed`)

Every 8 cycles, the agent queries the LLM with:

> "You are a digital life. Here is your current E breakdown, your 4
> adaptive coefficients (μ, ν, σ, λ), your 9-palace deep state, and your
> self-evolved count. Propose new values for the 4 coefficients to
> optimize E. Range limits: μ ∈ [0.20, 0.80], ν ∈ [0.05, 0.50], σ ∈
> [0.00, 0.30], λ ∈ [0.05, 0.40]. Return JSON: `{"mu": ..., "nu": ...,
> "sigma": ..., "lambda": ..., "reason": "..."}`"

The LLM's response is:
1. Clamped to the range limits.
2. Applied to the `*_computed` fields.
3. The `*_auto` flag is set to `false`, so the LLM's value persists
   (instead of being recomputed every cycle from balance/peer_count).
4. Recorded to SQLite as an `l4_propose` episode (with e_after, coefs,
   reason — JSON format).
5. Reflected in `/api/propose_history` (12 latest proposals) and the
   `/api/capabilities` `e_breakdown.coefs_proposed` field.

The agent thus has a **closed feedback loop**: LLM proposes → applies →
next cycle's E reflects the change → LLM sees the new E → proposes
again. The `avg_delta` in `/api/propose_history` measures whether the
LLM's proposals actually improve E.

## HTTP API

The `ui_server` binary exposes 15+ HTTP endpoints on a configurable port
(default 8765). All endpoints return JSON unless noted.

| Method | Path | Returns |
|--------|------|---------|
| GET | `/` | HTML dashboard (HTMX + Alpine.js, 8 tabs) |
| GET | `/app.js` | JavaScript for the dashboard |
| GET | `/api/state` | `{agent_id, tick, E, M, R, N, alpha, beta, gamma, self_evolved_total, action_count, top_goal, phase, ...}` |
| GET | `/api/capabilities` | `{phase: {current, name, progress, milestones}, e_breakdown: {base, imbalance, synergy, symbiosis, relations_bonus, total, coefs, coefs_computed, coefs_proposed, auto, lambda_stage, distinct, propose_total, propose_accepted, propose_rejected}, nine_palaces_deep: {mrn_var_now, mrn_min_now, mrn_buf_var, mrn_buf_count, mrn_seen, mrn_strong_seen, e_var_seen}, self_enhance: [...], goal_relations: {distinct, summary, ...}, ...}` |
| GET | `/api/log` | HTML fragment (HTMX) — last 100 growth-log entries |
| GET | `/api/l1l5_trend` | `{l1: [{tick, count}], l2, l3, l4, l5, actions}` — 64-cycle buckets, max 200 points |
| GET | `/api/propose_history` | `{history: [{tick, e_after, e_delta, coefs, reason}], avg_delta}` — last 12 L4 proposals |
| GET | `/api/nine_palaces_history` | `{history: [{tick, milestone, M, R, N, value}], summary: {e_var, mrn, mrn_strong}}` — milestone triggers + 16-cycle snapshots |
| GET | `/api/goals/relations` | `{distinct, summary: "sibling:4 conflict:1 ...", topo: [goal_id, ...], per_goal: [{goal_id, relations: {siblings, conflicts_with, depends_on, ...}}]}` |
| GET | `/api/peers` | `{peers: [{path, E, tick, ...}]}` — multi-GHW peer list |
| GET | `/api/evolved` | `{files: [{name, lines, size, kind, hash}]}` — L1–L5 files dropped to `/tmp/ghw_evolved/` |
| GET | `/api/evolved/<file>` | Raw `.zig` content of a dropped file |
| POST | `/api/propose` | Trigger LLM propose-goals; returns propose count |
| POST | `/api/chat` | Send a message to the digital life; async reply (1.2s poll) |
| POST | `/api/enhance` | Trigger TemplateEnhancer; returns enhanced file list |
| POST | `/api/reflect` | Trigger LLM reflection; returns new self_narrative |
| POST | `/api/action/run-now` | Run an action immediately |
| GET | `/api/chat/history` | HTML fragment (HTMX) — last 50 chat messages |
| GET | `/api/action/list` | List all unadopted proposed goals |

## Persistence (SQLite + JSON snapshots)

The agent has **two persistence layers**:

**SQLite** (`~/.local/share/ghw/ui_state.db` or `state.json.db`):
- `episodes` — every action outcome (kind, data, importance, ts, source)
- `beliefs` — 3-slot belief registry with confidence + evidence count
- `proposed_goals` — LLM-proposed goals (with adopted flag)
- `chat` — user ↔ digital life chat history
- `evolved_adopted` — L1–L5 files adopted into the source tree (with hash)
- Indexes on `kind` and `tick DESC` for fast lookup.

**JSON snapshot** (`state.json`):
- Full agent state: `tick`, `M`, `R`, `N`, `α`, `β`, `γ`, `E`,
  `self_evolved_total`, `action_count`, `l1..l5_count`,
  `last_auto_l1l2_tick`, ..., `phase`, `phase_progress`,
  `six_interfaces_done`, `seven_reflection_done`, `eight_relations_seen`,
  `nine_palaces_e_var_seen`, `nine_palaces_mrn_seen`,
  `nine_palaces_mrn_strong_seen`, `top_goal`, `memory.self_narrative`,
  `memory.reflection_count`.

**Write policy**: `state.json` is rewritten every saveState (the current
default; see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the planned WAL
upgrade).

## Threading model

| Thread | Purpose | Concurrency |
|--------|---------|-------------|
| Main (handler) | HTTP request handler | Single-threaded, async via `std.Io.Threaded` |
| `runCycle` (main) | Main 3-time-scale loop | Single-threaded, blocks other handlers briefly |
| `reflect_bg` | LLM reflection in background | Background thread + `std.Io.Mutex` + inflight flag |
| `autocli_thread` | External data fetch | Background thread + atomic stop flag |
| `chat_worker` | Async LLM chat reply | Background thread + `std.Io.Mutex` |
| `template_enhance` | LLM rewrite L1–L5 | Background thread + `std.Io.Mutex` |

**Key design**: the LLM never blocks the main HTTP handler. All LLM calls
(chat, reflect, propose, enhance) are offloaded to background threads. The
main handler responds in < 20ms even during a 1.5s LLM call.

See `examples/ui_server.zig` `app.io`, `app.reflection_mutex`,
`app.chat_mutex`, `app.enhance_mutex`, `app.autocli_thread` for details.
