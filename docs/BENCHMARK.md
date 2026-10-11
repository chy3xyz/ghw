# BENCHMARK.md — Reproducible Self-Evolution A/B Benchmark

This document describes the deterministic A/B benchmark that evidences GHW's
self-evolution closed loop: **LLM-proposed rule → SelfEvolutionGuard →
SelfEncoder adoption → RuleBias goal-selection bias → higher existence degree E**
in a representation (R) deficient world.

- Core module: [`src/harness/self_evolution_bench.zig`](../src/harness/self_evolution_bench.zig)
- Runner: [`examples/bench_self_evolution.zig`](../examples/bench_self_evolution.zig)
- Acceptance wrapper: [`scripts/self_evolution_bench.sh`](../scripts/self_evolution_bench.sh)

## What claim it evidences

The *mechanics* of the closed loop work end-to-end and measurably benefit the
digital life:

1. **Propose** — a `RuleProposer` asks an LLM (here `MockChatLLM`, canned JSON,
   no network) for 3 rule candidates, all `dimension: "representation"` to match
   the deficient source.
2. **Guard** — `SelfEvolutionGuard` reviews each candidate's full text against
   the blacklist. The candidate whose action contains `@panic` is rejected
   (`rejected_rules >= 1` proves the guard is in the loop, not bypassed).
3. **Adopt** — surviving candidates become `SelfEncoder.Rule`s
   (`adopted_rules >= 1`).
4. **Bias** — `bindRuleLib` makes `selectTopGoal` add a bounded bonus
   (`RuleBias.MAX_BONUS × dominance`) to goals aligned with the favored
   dimension; `selection_changed` counts cycles where the bias demonstrably
   flipped the selected goal.
5. **ΔE** — in a world whose constant zero-feature input keeps prediction error
   high (the error tax `∝ R` keeps biting representation), biasing selection
   toward representation-aligned goals yields higher per-cycle R gain and thus
   a higher AUC of `e_after`.

## What it does NOT prove

- **LLM proposal quality.** The rules are mock canned strings, not real model
  output. Nothing here claims a real LLM proposes *good* rules.
- **Real-world transfer.** The world is a single constant `Information` stream
  and the goal graph is a fixed 3-goal fixture (both arms identical); effect
  size says nothing about production deployments or emergent DSE behavior.
- **AUC threshold universality.** `AUC_IMPROVE_MIN = 1.02` is calibrated on the
  observed deterministic effect of *this exact setup* (seed 42, 64 cycles,
  zero-feature world). It is a named, documented constant so it can be
  recalibrated if the implementation changes.

## Methodology

Two arms, identical in everything except the rule library:

| | Baseline | Treatment |
|---|---|---|
| `GHWAgent.init` | same seed (42), `world_dim=4`, `wms_shape={3,3,3}` | identical |
| L4 auto flags (`mu/nu/sigma/lambda_auto`) | frozen `false` | frozen `false` |
| Self-evolver / task queue / memory | not bound | not bound |
| World per cycle | `Information{ id=tick, label="env", features={0,0,0,0} }` | identical |
| Goal graph | same seeded 3-goal graph, `T_G` frozen (see below) | identical |
| Proposal loop | — | once before cycles: `RuleProposer.proposeAndAdopt(&encoder, &guard, 3)` |
| Rule lib | none | `bindRuleLib(&encoder)` |

**World constant.** Observation 0.0 vs the predictor's 0.5 steady state keeps
`err` high every cycle, so the error tax (`min(err·0.1, ERR_COST_MAX) · R`,
attributed to R) sustains the R deficiency rather than letting it decay.

**Seeded goal graph (deliberate deviation from emergent DSE goals, symmetric
across arms).** The original design let the `DifferenceSetEngine` generate
goals from the constant stream. Empirically that is degenerate: with a single
constant `Information`, only world-dim 0 is observed (dims 1–3 stay at the 0.5
fill), the engagement gradient block is dominated by the e-block in every
state region, and the DSE emits exactly one goal of kind
`enhance_existence`/`explore` per regeneration — a representation-aligned goal
(`acquire_knowledge`) never exists, so the rule bias has nothing to select and
both arms are bit-identical. The mechanism under test cannot be evidenced at
all. Both arms therefore seed the same fixed graph and freeze `T_G` so it
persists for the whole run (same fixture, same way the repo's own RuleBias
unit test at `src/agent/core.zig:976` constructs its scenario):

- `explore@7` (nature) — the plain-priority top; the baseline picks it every cycle.
- `acquire_knowledge@6` (representation) — 1.0 below the top, inside the bias
  flip zone: bonus = `MAX_BONUS(3.0) × dominance(0.5)` = 1.5 → 6 + 1.5 > 7.
- `enhance_existence@5` (neutral dimension — the bonus never applies to it).

With the adopted representation rules, the treatment arm flips to
`acquire_knowledge` every cycle (`selection_changed` = N); without the rule
library the same agent picks `explore`. The only arm difference remains the
rule library.

The micro-L1 `ExistenceWeights.adapt` is unconditional in both arms and
identical, so it is not a confound.

Metrics (per arm, `N = cfg.cycles`):

- `AUC = Σ report.e_after` over all cycles (note: `report.attended` is not
  read — known use-after-free in `core.zig` when the report is constructed).
- `final_E = agent.ed.e()`, `final_R = agent.ed.v.representation` after N cycles.
- Treatment-side counters: `adopted_rules`, `rejected_rules`,
  `selection_changed` (cycles where `rule_bias` flipped the goal choice),
  `favored`, `dominance`.

**Pass bar:** `treatment_auc > baseline_auc × AUC_IMPROVE_MIN` **and**
`treatment_final_r > baseline_final_r`.

## Determinism guarantee

Fixed seed both arms, LCG-only randomness, no I/O, no network, no clock, mock
LLM. Running the binary twice produces bit-identical results (enforced by the
`determinism` unit test, which runs the bench twice and asserts all scalar
fields equal). This is what makes the A/B comparison meaningful: any divergence
is attributable solely to the rule library.

## How to run

```bash
zig build run-bench_self_evolution        # human summary + one-line JSON
bash scripts/self_evolution_bench.sh      # acceptance: builds, runs, greps "passed":true
```

Exit code: `0` when the pass bar is met, `1` otherwise. The JSON line is the
machine-readable contract:

```json
{"cycles":64,"baseline_auc":…,"treatment_auc":…,…,"passed":true}
```

## GitHub Actions

```yaml
name: self-evolution-bench
on: [pull_request]
jobs:
  bench:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.17.0
      - run: zig build test
      - run: bash scripts/self_evolution_bench.sh
```
