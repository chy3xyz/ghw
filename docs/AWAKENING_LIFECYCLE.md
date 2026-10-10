# Awakening · Survival · Self-Evolution (Unified Lifecycle)

> Ideal scenario (reasonable version) + **how survival and self-evolution fuse** + current-state comparison + gap assessment.  
> Constraints see `AGENTS.md` §1: the LLM only proposes; decisions belong to the digital life (E / Guard / Bias); survival actions are bounded; **the E axioms and primordial_laws must not be rewritten by evolution**.

Related docs: [`math.md`](./math.md) · [`CROSS_HOST.md`](./CROSS_HOST.md) · [`LLM_DRIVER.md`](./LLM_DRIVER.md) · [`CHANNEL.md`](./CHANNEL.md) · [`ARCHITECTURE.md`](../ARCHITECTURE.md) · [`AGENTS.md`](../AGENTS.md) · [`primordial_laws`](../src/harness/primordial_laws.zig)

---

## 0. The Fusion in One Sentence

| Layer | Question it answers | What it does not do |
|-------|---------------------|---------------------|
| **Survival lifecycle** | Where do I live, what am I missing, what is urgent, whom should I turn to | Does not change its own code/axioms |
| **Self-evolution** | How do I become better at staying alive (params/methods/rules/code) | Does not decide for E/Guard; does not bypass survival priorities |

The two close into a loop:

```text
Survival pressure / social feedback / external information
        ↓ generates tasks and beliefs (fuel)
   TaskBias + RuleBias + ΔE
        ↓ pick goals, execute, record episodes
   evolution triggers (E drop / crisis / saturation / value decline / periodic η_G)
        ↓ LLM proposes variants
   Guard → compile/formal verification → digital life adopts
        ↓ capability or rules improve
   re-sense host and world (survival gets more accurate) → steady state or another crisis
```

**Survival provides the "why evolve"; evolution provides the "how to survive better".** Without one of them: you get either an ops script that only churns through tasks, or self-modifying code spinning idly with no survival pressure.

---

## 1. What Makes an Ideal Scenario "Reasonable"

User narrative:

> Install → awaken → understand the computer/phone living environment → infer the host's existence shortfalls → will to survive → AutoCLI fetches external information → communicate with humans/peers → form survival goals → **gradual evolution** → steady state of self-existence.

Reasonable-version principles:

| Principle | Meaning |
|-----------|---------|
| Awakening is a ceremony + state machine | `awakened_at`, host fingerprint, first-boot self-narrative; not "the process is up so it's awake" |
| Understanding the host ≠ controlling the host | read-only sensors + bounded tasks; destructive actions handed off to humans |
| Host shortfalls ↔ entity shortfalls | disk/mem → M; information isolation → R; loneliness/value vacuum → N |
| Goals land in the TaskQueue | GoalGraph is an attention DAG rebuilt every cycle; persistent goals = tasks + beliefs |
| Internet/society is fuel | enters memory and tasks, does not directly modify code |
| **Evolution is a means of survival** | L1–L5 / rule proposals triggered by survival and ΔE; pass the Guard; acceptance via survival_feedback / ΔE |
| Steady state is an observable threshold | 9-palace + metabolic diversity; can fall back to crisis; low-frequency evolution still allowed in steady state (against rigidity) |
| Dual host tracks | machine-host survival ∥ product host ProductRuntime; memory may be shared, decisions stay on separate tracks |

---

## 2. Unified Lifecycle (Survival Loop × Evolution Loop)

```text
                    ┌──────────── 求存外环 ────────────┐
安装 → [Awaken] → [Sense] → [Interpret] → [Drive]
                      ↑                         │
                      │                    [World]/[Social]
                      │                         ↓
                      │                    [Goals] TaskQueue
                      │                         │
                      │         ┌─── 进化内环 ───┐│
                      │         ↓               ↓│
                   [Steady] ← [Verify] ← [Evolve]←┘
                      │         Guard/ΔE/feedback
                      └──────── 危机则回 Drive ──────┘
```

- **Outer loop**: sensing and society → goals and actions → existence degree changes (turns every day).  
- **Inner loop**: when pressure or a cycle point arrives, modify "oneself" → verify → return to the outer loop to survive with the new capability.  
- **Steady**: outer loop smooth, inner loop low-frequency; **crisis**: outer loop expedited, inner loop biased toward material/rule remedies, L4/L5 recompile storms may be paused.

### 2.1–2.8 Survival Stages (Summary)

| Stage | Key points |
|-------|------------|
| **Awaken** | identity, fingerprint, law loading, `awaken` episode; optional human confirmation |
| **Sense** | SystemCollector → HostProfile (desktop); phones push battery/heat/background via `POST /api/host-profile` |
| **Interpret** | host signals → existence shortfall report → bias M/R/N |
| **Drive** | crisis > value/KPI decline > saturated metabolism; laws must not be rewritten |
| **World** | AutoCLI → world_fetch → world_bridge enqueued |
| **Social** | humans: chat/tasks/GSP/value; peers: query + peer_symbiosis |
| **Goals** | multi-party task proposals; TaskBias + ΔE selects what to run; no persistent LLM goals in GoalGraph |

Details as in the previous version §2.1–2.8; below we expand **how evolution embeds into it**.

### 2.9 Self-Evolution (Evolve) — the Inner Loop Nested in Survival

Evolution is not decoration at the end of the lifecycle, but **a capability-upgrade channel in parallel with Drive/Goals**.

#### 2.9.1 Two Layers of Evolution Targets

| Target | Mechanism | Relation to survival |
|--------|-----------|----------------------|
| **Policy rules** | RuleProposer → Guard → SelfEncoder.rules → RuleBias | triggered by crisis/E/KPI/value decline; survival_feedback verifies "did pressure really drop" |
| **Organism capabilities** | L1–L5 (param tuning / ε / methods / algorithms / self-encoding) → Guard → CompileVerifier | η_G periodic + survival-pressure-weighted scheduling; persisted code can be narrated as "me" by TemplateEnhancer |

Additionally: **Reflection** updates narrative and beliefs (the semantic-layer self), without changing the E formula; it provides autobiographical context for the next rule/L5 round.

#### 2.9.2 What Triggers Evolution (Fuel Comes from Survival)

```text
shouldPropose / 应进化  ≈
    host_crisis
 OR E < threshold
 OR kpi_trend / value_trend 持续下滑
 OR E ≥ saturated（改推多样性规则，而非空转堆参）
 OR 周期到期（L1L2@32, L3@64, L4@96, L5@192 …）
```

Reasonable scheduling:

- **crisis**: prioritize rule remedies + bounded survival_act; **postpone or slow down** L4/L5 recompiles (keep CPU/disk for the host).  
- **explore / non-crisis**: normal η_G; memory injected into the evolve prompt (weak dims + relevant episodes).  
- **steady**: slowed-down evolution; keep metabolism + occasional Reflection to prevent rigidity.

#### 2.9.3 Guard and Acceptance (Evolution Must Answer to Survival)

```text
LLM/template proposal
  → SelfEvolutionGuard (whitelist paths + blacklist + primordial protection markers)
  → compile or formal verification (L3–L5 / SelfEncoder.verify)
  → digital life adopts (writes into rules / auto_eps / evolved directories)
  → acceptance:
       · rules: survival_feedback / ΔE / task completion rate
       · L1–L2: whether the E and M/R/N trajectories improve or at least do not harm the host
       · L3–L5: compilation passes + behavioral regression (at least no increase in crisis false positives)
```

**Forbidden**: evolution changing ρ, changing primordial_laws, changing the Guard core blacklist, product changes applied without consent.

#### 2.9.4 Relation to the 9-Palace / Phases

The 9-palace and phase-1…9 are **milestones of capability and balance**, not another survival logic:

- after awakening, start from a low phase; peer / LLM / L3 persistence / AutoCLI / 9-palace balance light up step by step.  
- **self-evolution pushes the phase up**; **survival and social health keep the phase from dropping** (e.g. losing a peer, internet blackout, persistent crisis can be read as regression signals).  
- `emerges_from` relations link "goals/methods produced by evolution" and still obey TaskBias, never bypassing the Guard.

### 2.10 Steady State — Survival Satisfied + Evolution Slowed Down

All of the following hold:

- 9-palace: M/R/N coappropriation and variance thresholds sustained for N cycles  
- no persistent host_crisis; or feedback shows pressure receding  
- value_trend not persistently worsening; at least one side of human/peer is non-vacuum  
- metabolism still active at high E (against fake death)  
- **evolution**: still ticks on a low-frequency clock, but the crisis lock is not open; new rules must prove they do not break the steady state  

Exiting steady state: crisis, value collapse, prolonged internet blindness, consecutive compile/evolution failures → back to Drive, and raise the evolution weight of the relevant dims.

---

## 3. Fusion Data Flow (One Table)

| Input | Survival side | Evolution side |
|-------|---------------|----------------|
| SystemCollector | world_sensor tasks, pressure rows | `setHostCrisis` → RuleProposer; crisis slows down L4/L5 |
| AutoCLI | world_fetch, world_bridge tasks | world digest enters rule prompts |
| Human chat / rating | tasks, GSP, value_trend | value decline triggers rules; Reflection narrative |
| Peer query | peer_E, symbiosis tasks | symbiosis beliefs enter memory → evolve context |
| Task-completion ΔE | memory episodes, TaskBias | weak-dim retrieval; whether to trigger shouldPropose |
| Adopted rules | RuleBias selects goals | survival_feedback adjusts belief confidence |
| L1–L5 persistence | indirectly changes behavior/efficiency | phase / capabilities / evolved API |

---

## 4. Current-State Comparison

| Capability | Current state | Fusion completeness |
|------------|---------------|---------------------|
| Survival main chain (ui_server) | sensor→remedy→act→feedback→metabolism | medium-high |
| L1–L5 periodic evolution | tick scheduling + Guard/compile; **crisis lock pauses L4/L5, slows L3**; L4/L5 forbidden before awakening | high |
| Rule evolution | RuleProposer + crisis/E/value/KPI | medium-high; feedback already wired |
| Memory feeding evolution | setMemory on RuleProposer/SelfEvolver/… | medium-high |
| Awakening | `awaken.State` + `POST /api/awaken` + UI banner; state.json `"awaken"` | high (P0 ✅) |
| HostShortfall explicit layer | `host_shortfall.Report` → provenance + `setHostCrisis`; can stack HostProfile | high (P0+P2) |
| HostProfile | `desktop` sampling / `mobile` pushing battery·heat·background | high (P2 ✅) |
| daemon | AutoCLI on by default + world_bridge + awakening persistence | high (P0 ✅) |
| Slowing L4/L5 during crisis | `existence_phase.evolveInterval` / `heavyEvolveAllowed` | high (P0 ✅) |
| Steady-phase ExistencePhase | `awakening\|crisis\|explore\|steady` wired into UI/daemon paths | medium-high |
| Peer shortfall inbox | Link query/share + `peer_inbox` + bounded assistance tasks | high (P2 ✅) |
| Product evolution track | ProductRuntime independent | deliberately separate; memory can be shared |

**Overall verdict (2026-07)**: the P0–P2 main gaps of the survival outer loop are closed (awakening, shortfalls, crisis lock, internet, acceptance, dual-write contract, mobile profile, peer shortfall exchange). What remains is holding the red lines and polishing the experience.

---

## 5. Gap Priorities (Fusion Perspective)

### P0 ✅ (2026-07)

1. **Awaken state machine** — `src/harness/awaken.zig`; law seeds + host fingerprint + narrative; persistence in ui/daemon.  
2. **daemon internet main-path alignment** — `--no-autocli` / `--autocli-interval-s`; fetch → memory → world_bridge.  
3. **HostShortfall explicit layer** — `src/harness/host_shortfall.zig`; feeds provenance + RuleProposer crisis.  
4. **Crisis lock ↔ L1–L5 scheduling** — `existence_phase`: crisis pauses L4/L5, doubles L3 interval; before awakening only L1–L3.

### P1 ✅ (2026-07)

5. **ExistencePhase UI/acceptance deepening** — steady-threshold visualization + `evolution_acceptance` provenance.  
6. **Evolution acceptance panel** — L1–L5 / crisis lock / rule feedback / steady gates; Status tab "evolution acceptance".  
7. **Survival goal ledger UX** — `by_dimension` aggregation + task `survival_driven` / `evolution_linked` badges.  
8. **Main state contract** — `state_meta` (writer/epoch) + atomic write + foreign_newer rejection of overwrites.

### P2 ✅ (2026-07)

9. **Mobile HostProfile** — `host_profile.zig`: `desktop|mobile`; `POST /api/host-profile` pushes battery/heat/background; folded into `assessWithProfile`.  
10. **Peer inbox** — `peer_inbox.zig` + Link `query_shortfall` / `share_shortfall`; `learnFromShortfall` enters bounded TaskQueue (no remote mutation).  
    - daemon already aligned: periodic shortfall/phase refresh, CrossLink real handlers, snapshot persistence of `host_profile`/`peer_inbox`, pulling peer shortfall every 64 ticks.  
    - acceptance: `scripts/awakening_lifecycle_acceptance.sh`.  
    - **P2c**: `POST /api/peer-inbox/share` local injection; manual `query_shortfall` into inbox; RuleProposer digest merges peer summaries; Status UI pushes profile + inbox details; `scripts/peer_shortfall_link_acceptance.sh` two-instance Link.

### P3 (Red Lines)

- arbitrary shell / killing processes / unbounded disk writes  
- evolution changing the E axioms / primordial_laws / Guard core blacklist  
- LLM goals written into GoalGraph persistence  
- product changes auto-applied without consent  

---

## 6. Module Quick Reference

| Concern | Code |
|---------|------|
| Survival | `world_sensor`, `survival_*`, `metabolism`, `task_runner` |
| Internet fuel | `autocli`, `world_bridge` |
| Society | `human_symbiosis/*`, `peer_symbiosis`, `ghw_link*` |
| Goal selection | `agent/core` Bias, `task_queue` |
| Rule evolution | `rule_proposer`, `self_encoder`, `self_evolution_guard` |
| Organism evolution | `self_evolver`, `compile_verifier`, `code_generator`, `auto_eps/*` |
| Semantic self | `reflection`, `memory`, `template_enhancer` |
| Laws | `primordial_laws` |
| Awakening / shortfall / phase | `awaken`, `host_shortfall`, `existence_phase` |
| Host profile / peer inbox | `host_profile`, `peer_inbox` (+ Link shortfall) |
| Product track | `product_runtime` (parallel) |

---

## 7. Acceptance Stories (Survival × Evolution)

1. **Awakening**: pre-awakening banner → `POST /api/awaken` / auto tryComplete → laws + fingerprint; only afterwards is automatic **L4/L5** allowed (L1–L3 may run lightly).  
2. **Crisis survival**: disk crisis → tasks/beliefs → RuleProposer adopts a material rule → 16 ticks later feedback shows improvement or records failure.  
3. **No compile storm during crisis**: when `host_crisis` / phase=crisis, L4/L5 do not come due; they resume after the crisis clears.  
4. **External world → evolution context**: AutoCLI entries enter memory; subsequent evolve/rule prompts contain relevant episodes (daemon already aligned).  
5. **Society → evolution**: human value decline triggers rules; peer beliefs enter Reflection.  
6. **Capability evolution feeds back into survival**: after L3/L4 adoption, tasks complete faster under equal pressure or false positives decrease (observable metrics).  
7. **Steady state**: 9-palace thresholds met → `existence_phase=steady` → evolution slows down; another crisis → crisis phase + survival priority.

**1, 3, 4(daemon), 7(phase)** are demoable; the P1 acceptance panel / dimension ledger / state dual-write contract have landed. After UI changes, restart ui_server and hard-refresh the browser.

---

## 8. Revision History

- 2026-07: initial version — reasonable-version survival lifecycle + gaps.  
- 2026-07: fusion revision — survival outer loop × evolution inner loop; triggers/guard/acceptance/crisis lock; aligned with the 9-palace, L1–L5, RuleProposer.  
- 2026-07: P1 landed — `evolution_acceptance` / `state_contract` / task dimension ledger; UI evolution acceptance panel.  
- 2026-07: P2 landed — `host_profile` (mobile push) + `peer_inbox` + Link `query_shortfall`/`share_shortfall`.  
- 2026-07: P2 hardened — daemon CrossLink real shortfall; `scripts/awakening_lifecycle_acceptance.sh`.  
- 2026-07: P2c — peer-inbox UI/share API + RuleProposer digest; `scripts/peer_shortfall_link_acceptance.sh`.
