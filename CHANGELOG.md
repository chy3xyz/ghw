# CHANGELOG — GHW Digital Life Framework

All notable changes to the project. Version numbers follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

- **GitHub Actions CI** — `.github/workflows/ci.yml` (ubuntu, Zig 0.17.0): `zig build`, `zig build test`, dark-test census, self-evolution A/B benchmark, product-runtime acceptance — runs on push to `main` and every PR; CI badge in readme

- **Reproducible self-evolution A/B benchmark** — deterministic evidence that the closed loop (LLM-proposed rule → SelfEvolutionGuard → SelfEncoder adoption → RuleBias → ΔE) raises existence degree E in an R-deficient world
  - New module `src/harness/self_evolution_bench.zig` (4 unit tests: determinism, guard-in-the-loop, mechanism, JSON contract), runner `examples/bench_self_evolution.zig`, acceptance wrapper `scripts/self_evolution_bench.sh`, methodology `docs/BENCHMARK.md`
  - Two arms identical except the rule library (same seed, frozen L4 auto flags, constant zero-feature world, MockChatLLM — no network/API keys); pass bar `AUC_IMPROVE_MIN = 1.02` as a named, documented constant

## [v0.5] — 2026-06-12

### 🎯 Major Improvements

- **Loop Engineering coordinator** (Boris Cherny 2025-11 "My job is to write loops")
  - New module `src/harness/loop_engine.zig` (988 lines)
  - HarnessLoopEngine implements Boris's 6 core components (scheduling / workspace / external memory / subagents / exit conditions / evaluation)
  - Plan-Do-Check-Act 4-phase PDCA loop, 1 Plan every 8 cycles
  - 10 unit tests + verified working in a real 11h run
- **Loop Engine state persistence** (Boris 6.3 external memory truly implemented)
  - `saveToFile` / `loadFromFile` real JSON files
  - Default `~/.local/share/ghw/loop_state.json` (same directory as state.json)
  - Atomic write once every 5 min (time-based; cycle increment = 0 when the 9-palace is in full-health state)
- **Time-based progress logging**
  - `--log-every-ms 300000` (5 min) runs in parallel with cycle-based `--log-every`
  - Under full-health 9-palace conditions the cycle count never reaches 1024, so time-based logging is the safety net
  - Verified in a real 13h run: RSS 4.5 MB, KPIs continuously visible

### 🐛 Bug Fixes

- **0.17 `init.args.iterate()` cannot get args** (pre-existing in memory)
  - Switched to direct access via `init.args.vector` + manual alloc + free
  - `parseArgs` now starts at `i=0` (in sync with args_list; it previously skipped args[0] by mistake)
  - `--cycles 200` actually runs 200 cycles (previously always 32 no matter what was passed)
- **shouldPlan `u64` underflow panic** (newly discovered)
  - On restart tick=0 while last_plan_tick=161216 (loaded from file)
  - Fix: `tick <= self.last_plan_tick` pre-check guard
- **DebugAllocator leak detection found 2 unreleased arg copies**
  - Added manual `for (args_list.items) |a| alloc.free(a);`

### 📊 Unit Tests

- **149/150 → 150/150** (100% pass)
  - Fixed 1 failing self_encoder test (L5 template `pub const Module` replaces the old `SelfTunedWeights`)
  - 6 modules with explicit addTest; all 13 loop_engine tests discovered

### 🏗 Engineering

- **build.zig 0.17 addTest fix**
  - Previously addTest did not scan submodule test blocks; the total was stuck at 140
  - Switched to 6 separate addTest calls explicitly listing the modules
  - Actually runs 150/150 tests (140 old + 10 loop_engine)
- **Daemon 5 new flags**
  - `--loop-disable` / `--loop-plan-cycle` / `--loop-check-window`
  - `--loop-miss-act` / `--loop-miss-stop` (Boris PR night-watch rules)
  - `--loop-state-in` / `--loop-state-out` (persistence)
  - `--loop-state-save-every-ms` / `--log-every-ms` (time-based)
- **UI endpoint** `/api/loop_state`
  - Reads `~/.local/share/ghw/loop_state.json` (daemon writes, UI reads)
  - Returns `{"loop_state": {...}, "source": "daemon_file"}`
  - On par with the other 8 endpoints

### 📚 Documentation

- **ghw-lunwen.md ("GHW paper")** reorganized, +293 lines (5855 → 6148)
  - **D.3.5 GHW Paradigm: Engineering Principles of Consciousness Generation** (new section)
    - E formula / 9-palace / 9 relations / L1-L5 / Loop Engineering / 4 homeostatic mechanisms / 11h empirical results / dialogue with the various schools in D.3
  - **Appendix E: Long-Running Empirical Evidence of Digital Life** (new appendix)
    - 11h continuous observation report: PID 88800, RSS 4.5 MB, hit_rate 1.0, miss_streak 0
    - Experimental setup / process data / KPI numerical analysis / verification of the 4 homeostatic mechanisms / reproduction guide / statement of limitations
- **ghw-platform.md** (memory) +75 lines
  - Phase 10 Loop Engineering complete design notes

### 📈 Score

```
A++ (97) ── v0.5 ── A+++ (99)
       +1.0 100% test pass
       +1.0 0.17 init.args bug fixed
       +0.5 /api/loop_state endpoint
       -0.5 no git tag (GHW is not a git repo, skipped)
```

### 🐛 Known Issues (Phase 10+ TODO)

- Loop Engine UI endpoint returns the entire loop_state.json JSON **unparsed**; the client has to parse it
- `peer_hypotheses` cross-instance injection (Boris 6.4): hook reserved, not yet implemented
- LLM-proposed hypotheses (reusing Phase 8.7, 1 call / kPlanCycle): hook reserved, not yet implemented
- 0.17 `init.args.iterate()` has been replaced with vector, but later 0.17 releases may change the API

## [v0.4] — 2026-06-08 (Foundation)

### 🎯 Key Modules

- L1-L5 self-evolution (real compile-to-disk: 18 L3 + 14 L4 + 7 L5 real .zig files)
- Multi-GHW interconnection, 6 items (PROTOCOL.md / peer discovery / health check / UI dashboard / multi_agent demo / docker-compose)
- Production, 4 items (WAL+keychain+metrics+docker distroless)
- Production docs, 5-piece suite (README/ARCHITECTURE/FAQ/TROUBLESHOOTING/SDK)
- 9-palace deep dive (3-palace milestone + 64-cycle ring buffer)
- 9-relation GoalGraph schema (9 relation types + topological sort)
- L4 closed loop with 4-coefficient self-tuning (ν/μ/σ/λ coupled with balance/peer/evolution)
- LLM-proposed 4 coefficients (Phase 8.7, 1 per 8 cycles)
- Phase 8.6 4-coefficient end-to-end verification

### 📈 Score

```
A+ (95) ── v0.4 ── A++ (97)
```

## [v0.3] — 2026-05-15 (C SDK Foundation)

- C SDK v0.3: 15 C ABI functions, libghw.a 9.2 MB
- Real C client embed_demo_v3.c working
- First step toward a cross-language SDK

## [v0.1] — 2026-04-01 (Initial Version)

- 4-layer architecture (World / Goal / Harness / Agent)
- E formula with 5 base terms (α/β/γ + Var + min)
- Digital-life main loop
- Simple LLM integration

---

[0.5]: #v05--2026-06-12
[0.4]: #v04--2026-06-08
[0.3]: #v03--2026-05-15
[0.1]: #v01--2026-04-01
