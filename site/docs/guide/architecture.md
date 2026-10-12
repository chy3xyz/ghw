# Architecture Overview

GHW is divided into four layers: World, Goal, Harness, and Agent. The product runtime and the human symbiosis layer sit between Harness and Agent, responsible for bringing external value and human feedback into the loop.

## Four-Layer Structure

```
External World
  |
  v
World: M/R/N, E, KPI, peer signals
  |
  v
Goal: attention, difference tensor, GoalGraph
  |
  v
Harness: action runner, guard, verifier, memory, product runtime
  |
  v
Agent: cycle loop, reflection, migration, persistence
```

## World

The World layer is responsible for computing the existence degree:

- `src/world/core.zig`: existence degree, M/R/N, KPI term, relation term.
- `src/world/coappropriation.zig`: the 「三源合恰」 (three-source coappropriation) mathematical model.
- `docs/math.md`: formula derivation and property proofs.

Current core sources of E include:

- Three-source aggregation: weighted power mean of M/R/N.
- `σ·S`: symbiosis.
- `λ·D`: relational emergence.
- `ρ·K`: product KPI alignment term.

## Goal

The Goal layer is responsible for attention and goal structure:

- `AttentionEngine` selects the goal most worth pursuing right now.
- `GoalGraph` maintains the relationships between goals.
- RuleBias and TaskBias can reorder existing goals, but they do not create goals out of thin air or bypass E.

## Harness

Harness is the execution and governance layer:

- `ActionRunner` executes actions such as observation, WASM, peer query, and self-evolution.
- `SelfEvolutionGuard` rejects dangerous constructs and out-of-scope files.
- `CompileVerifier` performs real compilation of candidate Zig code.
- `Memory` provides autobiographical memory, beliefs, and retrieval of relevant past episodes.
- `TaskQueue` and `HumanSignal` bring in human tasks and feedback.
- `ProductEvolutionRuntime` brings in product changes, approvals, and audit.

## Agent

Agent is the loop itself:

```
collect world
  -> update E
  -> select top goal
  -> run action
  -> record memory
  -> maybe reflect
  -> maybe propose goals/rules
  -> maybe run tasks
  -> maybe self-evolve
  -> save state
```

Typical cadence:

- High frequency: perception and action.
- Medium frequency: reflection, task execution, human value sampling.
- Low frequency: goal proposals, rule proposals, self-evolution, product changes.

## State Persistence

`ui_server` and the daemon use JSON snapshots to persist key state:

- `memory`
- `task_queue`
- `human_gsp`
- `human_signal`
- `value_tracker`
- `product_runtime`

SQLite is used for operational memory such as episodes, beliefs, and proposed goals. JSON snapshots are used to restore the current life state across restarts.

## Relationship to Existing In-Depth Docs

This page is the entry-level description of the current implementation. More detailed low-level documentation remains in the repo root docs:

- `ARCHITECTURE.md`
- `docs/math.md`
- `docs/PRODUCT_INTENT.md`
- `docs/KPI.md`
- `docs/CONSENT.md`
