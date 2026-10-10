# Existence Degree Axioms — v3

> Implementation: see `src/world/coappropriation.zig` and `ExistenceDegree.e()` in
> `src/world/core.zig`; every property has a corresponding unit test.

## 1. Problems with the old formula

v2's existence degree was linear weighting + bolted-on patches:

```
E = α·M + β·R + γ·N − μ·Var(M,R,N) + ν·min(M,R,N) + σ·S + λ·D   →  clamp[0,1]
```

Two structural defects:

1. **Linear weighting ⇒ the three sources are fully substitutable**: abundant M
   can compensate indefinitely for N=0, contradicting the ontology of "materiality is indispensable."
2. **μ·Var / ν·min are ex-post bolted-on correction terms**: coefficients are hand-tuned,
   there is no unified mathematical skeleton, and no global property (boundedness, monotonicity, imbalance-penalty strength, etc.) can be proved.

## 2. The v3 skeleton: weighted power mean (Hölder / CES / Atkinson)

Replace the three-source aggregation with the **weighted power mean** (the CES
production function in economics, the "equally-distributed-equivalent" income of
welfare economics, and the Hölder mean in mathematics — the same family in essence):

```
M_p(x; w) = ( Σ wᵢ · xᵢ^p )^(1/p)     (p ≠ 0)
M_0(x; w) = Π xᵢ^{wᵢ}                  (p → 0, weighted geometric mean)
```

The single parameter `p ∈ (0, 1]` continuously characterizes the substitutability / complementarity of the three sources:

| p     | Degenerate form  | Semantics                |
|-------|------------------|--------------------------|
| p = 1 | Arithmetic mean  | Fully substitutable (equivalent to the old linear weighting) |
| p < 1 | Strictly concave | Imbalance is automatically punished; the shortfall source has a larger gradient ⇒ shortfall-first |
| p → 0 | Geometric mean   | Cobb-Douglas; any source = 0 ⇒ E = 0 — indispensable |

Final existence degree:

```
E = clamp( M_p(M,R,N; α,β,γ) + σ·S + λ·D + ρ·K_signed , 0, 1)
```

`σ·S` (symbiosis), `λ·D` (relational emergence), and `ρ·K` (product KPI alignment) are
retained as **bounded additive modulation terms** (they describe external relations / product value, not the internal aggregation of the three sources).

### KPI alignment term ρ·K

```
K_signed = (K − kpi_target) · 2        K∈[0,1], target=1.0 ⇒ K_signed∈[−2,0]
kpi_term = ρ · K_signed                ρ = 0.15 (axiom constant, not self-tunable)
```

- `K` is the composite KPI (see `crm_kpi.composite`), fed via `ExistenceDegree.recordKpi(k)`
  at the `kpi_refresh_interval_hours` cadence (rate-limited to prevent E jitter).
- It is zero only at best-in-class (`K = target`); otherwise points are deducted linearly
  by "distance from optimal" — i.e. "the further the product is from optimal, the lower the existence degree."
- **Default `kpi_enabled = false`**: in a pure digital-life scenario without product KPIs,
  `kpi_term = 0`, identical to behavior without KPI; once a product is connected, `recordKpi` turns it on automatically.
- Monotonically increasing in `K`; KPI is an independent axis and does not affect three-source
  monotonicity (axiom C); clamping throughout guarantees E∈[0,1]. `kpi_history[64]` serves only trend / variance (L4 proposer, reflection layer), not E.

**Key point: the "imbalance penalty + shortfall-first" that the old formula needed two bolted-on
terms (μ·Var + ν·min) to express is, in v3, a mathematical corollary of power-mean concavity.** The quantified 「三源合恰」 (three-source coappropriation) loss is:

```
imbalanceLoss = AM (arithmetic mean) − M_p  ≥ 0     (0 iff the three sources are equal)
```

## 3. Coefficient bridging (without breaking the L1/L4 adaptive loop)

The old ν (synergy) and μ (imbalance) change from "additive coefficients" to "curvature parameters"; all of the adaptive logic is retained:

```
p = clamp( 1 − 1.5·ν − 0.5·(μ − 0.5) ,  0.05,  1 )
```

- ν ↑ ⇒ p ↓: the three sources become more complementary (closer to the geometric mean), and the shortfall source is more fatal.
- μ ↑ ⇒ p ↓: stronger aversion to imbalance.
- Defaults: μ = 0.5, ν = 0.3 ⇒ p = 0.55 (balanced state E_core = 0.5).

`adaptEFormula` / `adaptEFormulaProposed` still tune μ/ν — only now what they change is the
curvature of the power mean rather than an additive patch.

## 4. Provable properties (all with unit tests)

| Axiom | Content | Test |
|-------|---------|------|
| A Boundedness | xᵢ∈[0,1] ⇒ E_core∈[0,1] | `Property A: boundedness` |
| B Idempotence | all xᵢ equal to c ⇒ E_core = c | `Property B: idempotence` |
| C Monotonicity (free disposal) | any xᵢ ↑ ⇒ E_core does not decrease | `Property C: monotonicity` (11³ grid exhaustive) |
| D Concavity | p<1 ⇒ E_core ≤ arithmetic mean | `Property D: concavity` |
| E Squeeze | min ≤ E_core ≤ max | `Properties A/E` |
| F Complementarity | p→0 and some source = 0 ⇒ E_core=0 | `Property F: complementarity` |
| G Symmetry | with equal weights, permuting xᵢ changes nothing | `Property G: symmetry` |
| H Curvature bridging | ν↑ or μ↑ ⇒ E_core ↓ in imbalanced states | `Property H: curvature bridging` |

### Why not "multiplicative coappropriation gating"

An early design tried `E_core = M_p · (1−κ+κ·H)` (H = 1−(max−min) being the coappropriation degree).
But multiplicative gating **destroys monotonicity (axiom C)**: piling more onto the strongest source
widens max−min, so the gating's declining discount outweighs the power mean's tiny gain, leading to
"getting more resources actually lowers the existence degree." For a quantity that drives survival
behavior, this is unacceptable. v3 therefore drops multiplicative gating and lets the power mean's **concavity intrinsically reward balance** — `harmony()` is kept only as a diagnostic quantity for visualization / audit.

## 5. Numerical implementation notes

- When `p < 0.05`, switch to the weighted geometric mean to avoid `x^p (p→0)` amplifying
  floating-point error through the `1/p` exponent.
- Under the geometric mean, any source being 0 returns 0 directly (the correct semantics of `@log(0)`), implementing "indispensability."
- Clamp to `[0,1]` throughout; together with property A this guarantees the output is always valid.

## 6. Three-source supply layer (2026-09 materiality closed loop)

v3 defines "how to aggregate coappropriately", but what makes each of the three sources **rise and fall** was previously unclosed:
M was mere internal bookkeeping, R was decoupled from the actual size of the symbol system, and N was little more than a shadow of the task success rate.
With the supply layer filled in, the three sources again become three **attributable ontological categories**:

| Source | Ontology | Supply (bounded backflow) | Constants |
|--------|----------|---------------------------|-----------|
| M — materiality | material substrate (host machine) | host-substrate **two-way pull** `applyHostPressure` (target=1−pressure; wear drains at full speed, recovery rises at half speed — fix materiality ⇒ host pressure drops ⇒ materiality recovers: the survival loop closes); task metabolism | `HOST_DRAIN_MAX=0.02/application`, `HOST_RECOVER_MAX=0.01/application` |
| R — representation | symbolic thought | stock pull `applyRepresentationStock` (episodes + 2·beliefs + 3·rules + world_fetch → 1−e^(−s/K) saturation level, two-way drift); prediction error recorded as a loss of R | `DRIFT_MAX=0.02/application`, `K=120` |
| N — nature | meaning-bestowing capacity | meaning recognition `applyNatureRecognition` (proportional to value_score above the neutral line 0.30; fixed gain per verified [survive:*] belief) | `RECOGNITION_MAX=0.012/application` |

**Call cadence**: "bounded per call" must be paired with low frequency — all backflows obey `BACKFLOW_INTERVAL_TICKS=32`
(ui_server/daemon throttle by tick; otherwise per-cycle calls would smash M through the floor / inflate N within minutes).
`survival_feedback` improvement→N is event-driven and not throttled. M/R/N additionally have a 64-point trajectory ring
(`mrn_history`, same semantics as `kpi_history`) for provenance sparklines and replay; it does not enter E.

### 6.0b Supply-dynamics calibration (2026-09 soak tests)

Daemon soak tests (30ms/tick) exposed and fixed four dynamical imbalances; all are now bounded:

1. **Old direct channel demoted to auxiliary** (`LEGACY_CHANNEL_SCALE=0.1`): the original per-cycle
   unconditional `M += 0.05` / `R += rep_gain` / `N += 0.02` would max out all three sources
   within ~20 cycles (observed M=R=N=1.0 with materiality still full under host crisis). Now:
   representation production ×0.1; materiality's free-lunch subsidy removed, leaving only wear (full fidelity); nature success bonus 0.004.
2. **Prediction-error loss ∝R and bounded** (`ERR_COST_MAX=0.01`): a constant rate ground R down
   under crisis (observed death spiral R→0.003); proportional loss is self-stabilizing
   (R→0 ⇒ loss→0 ⇒ stock pull re-grows R).
3. **Natural decay of nature** (`NATURE_DECAY=0.002·N`): the meaning-bestowing capacity needs
   continuous recognition to sustain; the equilibrium from success background noise alone is N≈0.67 — high N can only come from meaning recognition (value / verified beliefs).
4. **Backflow throttling + independent variables**: all backflows obey `BACKFLOW_INTERVAL_TICKS=32`;
   value→N uses an independent throttle variable (sharing one with host/representation backflows starves whichever runs later — observed).

Soak results: during load spikes (load>8), M is honestly pressed down and E falls; after the load
recovers, E rises back (0.53→0.68); R holds ~0.33 even when M=0 — no death spiral.

### 6.1 Additive terms vs. three-source interior: the criterion

Criterion: **state quantities go into M_p; relation/permission quantities get additive modulation**.

- Any quantity describing a source's **own state** (host material pressure, symbol stock, meaning recognition degree) → the supply layer, changing (M,R,N) themselves;
- any quantity describing **external relations** (symbiosis σ·S, relational emergence λ·D) or **existential permission** (product alignment ρ·K) → a bounded additive modulation term, without ontological standing of its own;
- ρ·K stays additive rather than merging into M: KPI is "the host product's permission for existence", not the substance's materiality; this philosophical decision prevents drift of future added terms.

### 6.2 Attribution and allocation

- Task gains: `applyDim(gain, dim)` — 70% goes to the task's required_dimension source, 30% synergistically spills over to the shortfall source (when the source itself is the shortfall, the spill splits evenly between the other two); losses are charged to the source. The power mean's concavity already implements shortfall-first on the **evaluation side**; the supply side attributes by ontology — the two no longer duplicate each other.
- Prediction error (WorldModel err) is a loss of "representation": in attribution mode it is recorded against R and no longer mixed into task dimensions.

### 6.3 Sensitivity (an honest characterization)

- For p<1, x^p is non-Lipschitz at the origin (Hölder only) — **global Lipschitz continuity does
  not hold**; this is a mathematical fact, not an implementation defect; in the interior region [0.1,1]³ the measured empirical ratio |ΔE|/|Δx| is ≲ 1.5 (analytic bound ≈0.5, plus f32 pow noise); test guardrail 5.0;
- perturbations at the boundary (source=0) produce no NaN/Inf, and the output is always clamped to [0,1] (test `Sensitivity: boundary`);
- practical jitter prevention is the caller's job: KPI rate limiting (`kpi_refresh_interval_hours`), bounded per-call supply backflows, and `GEOMETRIC_THRESHOLD` against 1/p amplification.

### 6.4 CoappropriationTensor status (2026-09 survey)

The tensor is **formally wired but effectively inert**: GHWAgent holds the `wms` field and
snapshots+decays it every cycle; the goal phase engine consumes its coherence — but the `implant` production path is never
called (tests only), so the tensor is identically zero ⇒ coherence ≡ 0 (the phase engine's own dynamics
`+target_focus·0.2` provide the lift, without depending on it). Full removal requires changing the
`GHWAgent.init` signature (the `wms_shape` parameter reaches into ui/daemon/examples) — a separate refactor; until φ·C research is introduced, the status quo suffices; recorded here to preclude the misreading "already wired."

### 6.5 Imbalance trigger

`imbalanceLoss = AM − M_p` enters the rule-proposal trigger chain (the sixth OR branch, threshold
`IMBALANCE_LOSS_EPS=0.08`): when the three sources tear apart, balancing rules are proactively
proposed even if E has not fallen through. `harmony` remains a purely diagnostic quantity (not entering E, preserving monotonicity).
