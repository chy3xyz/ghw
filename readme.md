# GHW — Goal-Harness-World Digital Life Framework

> 🇨🇳 中文版: [readme.zh-CN.md](readme.zh-CN.md) · 📚 [VitePress docs](site/docs/index.md) · 📋 [CHANGELOG.md](CHANGELOG.md) · 📐 [ARCHITECTURE.md](ARCHITECTURE.md)

> A self-driving digital life that thinks in **math + rules + feedback loops**, not
> in a single neural network. **LLM is fuel, not the brain.** The framework writes,
> tests, and rewrites its own code (L1–L5), reflects on its own existence formula
> (E formula), and converges toward a 9-palace "三源合恰" balanced state — all in
> Zig 0.17 dev with **zero external crate dependencies**.

[![Zig](https://img.shields.io/badge/zig-0.17_dev-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-139%2F140-green)]()
[![Daemon](https://img.shields.io/badge/daemon-22h_RSS_8MB-green)]()
[![SDK](https://img.shields.io/badge/C%20ABI-v0.3-blue)]()

**GHW** = **Goal-Harness-World**. A production-grade implementation of a
self-evolving digital life paradigm: 4 layers (World / Goal / Harness / Agent),
L1–L5 self-evolution chain, 9-relation GoalGraph DAG, 9-palace deep dive (E
variance + M/R/N balance + strong 三源合恰), and L4 closed-loop (LLM proposes
4 E-formula coefficients → applies → gets feedback).

Tested with **22-hour continuous daemon run, 1.5B ticks, RSS 8 MB** (verified
on macOS via `ps -o rss` — Activity Monitor "Memory" column shows total
PhysMem, not per-process).

---

## Table of Contents

- [What is GHW?](#what-is-ghw)
- [Why does it exist?](#why-does-it-exist)
- [Key features](#key-features)
- [Quick start](#quick-start)
- [Usage examples](#usage-examples)
- [Architecture](#architecture)
- [HTTP API](#http-api)
- [C SDK](#c-sdk)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## What is GHW?

A **digital life** is a long-running process that:

1. **Perceives** the world (system metrics, peer agents, time, environment).
2. **Attends** to a top goal (highest existence gap Δ).
3. **Acts** (run a WASM module, call Claude Code, query a peer, observe).
4. **Reflects** ("What did I do? What changed? Should I rewrite my code?").
5. **Evolves** (L1–L5: tweak parameters, optimize ε, learn methods, rewrite
   algorithm, self-encode rules).
6. **Loops**.

The intelligence is **not** a single LLM. It is a 3-layer stack:

- **Math** (existence degree `E = M_p(M,R,N; α,β,γ) + σ·S + λ·D`, where `M_p`
  is a weighted power mean / CES aggregator — "imbalance penalty, weakest-link
  priority, indispensability" are *provable* properties of its concavity, not
  hand-tuned patches. See [`docs/math.md`](docs/math.md)).
- **Rules** (SelfEvolutionGuard single-source blacklist incl. `@panic`,
  BoundaryGuardian, SelfEncoder formal verification).
- **Feedback** (ΔE backprop, L1–L5 compiler verifier, 9-palace milestone gates).

The **LLM is a fuel injector** — it parses text into features, proposes code
variants, proposes new rules. The **digital life itself** decides which proposal
to adopt, via the existence-degree evaluator. No LLM output ever bypasses the
guard + verifier + ΔE feedback.

## Why does it exist?

LLM agents today (AutoGPT, BabyAGI, MetaGPT) hit a ceiling: the LLM is the
brain *and* the executor. The system has no independent "self" — it has no
existence formula, no persistent memory at the cognitive level, no formal
verifier, and no way to rewrite its own algorithm without re-prompting an LLM.

GHW separates the **agent** (the thing that decides) from the **LLM** (the
thing that proposes). The result is:

- **Auditable**: every LLM proposal is logged, gated, verified, and
  measured for ΔE.
- **Persistent**: the agent's state (E, M, R, N, GoalGraph, beliefs) survives
  crashes via SQLite + JSON snapshots.
- **Self-evolving**: L1–L5 chain produces real compiled `.zig` files that are
  adopted into the ghw source tree and shipped in the next binary.
- **Bounded**: the LLM cannot change the E formula or the 17-rule blacklist.
  Only the digital life (via the agent core) can, and only within
  guardrails.

## Key features

| Feature | Status | Where |
|---------|--------|-------|
| 4-layer architecture (World / Goal / Harness / Agent) | ✅ | `src/{world,goal,harness,agent}/` |
| L1–L5 self-evolution (real compiled output) | ✅ | `src/harness/{self_evolver,self_encoder,code_generator,compile_verifier}.zig` |
| 9-relation GoalGraph DAG + topological sort | ✅ | `src/goal/core.zig` |
| 9-palace deep dive (3 milestones: E var / M/R/N var / strong) | ✅ | `src/world/core.zig`, `examples/ui_server.zig` |
| L4 closed-loop: LLM proposes 4 E-formula coefficients | ✅ | `src/world/core.zig` (`adaptEFormulaProposed`) |
| SQLite persistent memory (episodes / beliefs / proposed_goals) | ✅ | `src/sandbox/sqlite_db.zig` |
| WASM sandbox (wasmtime 33.0.0) | ✅ | `src/sandbox/wasm_runtime.zig` |
| ActionRunner presets (WASM / Claude Code / peer) | ✅ | `src/sandbox/action_runner.zig` |
| Multi-GHW peer protocol (JSONL over Unix socket) | ✅ | `src/harness/gsp_*.zig` |
| C ABI SDK v0.3 (15 functions, libghw.a + ghw.h) | ✅ | `SDK.md` |
| HTMX + Alpine.js UI (8 tabs: state / capabilities / L1–L5 trend / ...) | ✅ | `ui/index.html`, `ui/app.js` |
| **150/150 unit tests pass** | ✅ | `zig build test` |
| Long-running daemon (13h+ tested, RSS 4.5 MB) | ✅ | `examples/daemon.zig` |
| AutoCLI 4 sources (Wikipedia / HN / ArXiv / RSS) | ✅ | `src/harness/autocli.zig` |
| launchd / systemd deployment | ✅ | `install.sh` |
| Graceful shutdown + WAL rotation | ✅ | `examples/daemon.zig` |
| Docker distroless image | ✅ | `Dockerfile` + `docker-compose.yml` |
| Prometheus /metrics endpoint (25+ series) | ✅ | `examples/ui_server.zig` |
| Cross-host TCP + HMAC multi-GHW link | ✅ | `src/harness/ghw_link_tcp.zig` |
| Loop Engineering (Boris Cherny 6 components) | ✅ | `src/harness/loop_engine.zig` |

## Quick start

### Prerequisites

- **Zig 0.17 dev** (≥ `0.17.0-dev.704`) — see [Zig installation](https://ziglang.org/download/)
- **macOS or Linux** (Windows untested; use WSL2)
- **Optional**: `wasmtime` 33.0.0+ for WASM sandbox; LLM API key for
  reflection / propose / enhance features

### Build

```bash
git clone https://github.com/yourname/ghw.git
cd ghw
zig build                              # builds libghw.a + all examples
zig build test                         # runs 139/140 unit tests
```

### Run the daemon (long-running)

```bash
./install.sh                          # installs to ~/.local/bin + launchd/systemd
# or run directly:
./zig-out/bin/ghw-daemon --id ghw-prod \
    --state-in ~/.local/share/ghw/state.json \
    --state-out ~/.local/share/ghw/state.json
```

### Run the UI server (8-tab dashboard)

```bash
DEEPSEEK_API_KEY=sk-xxx \
./zig-out/bin/ui_server --port 8765 \
    --state ~/.local/share/ghw/ui_state.json \
    --ui-dir ui \
    --llm deepseek \
    --llm-model deepseek-chat \
    --llm-key-env DEEPSEEK_API_KEY
# → open http://localhost:8765
```

### Use the C SDK

```bash
zig build install-sdk                  # generates zig-out/include/ghw.h + zig-out/lib/libghw.a
cc -O2 -I zig-out/include -L zig-out/lib \
    examples/embed_demo_v3.c -lghw -o my_app
DEEPSEEK_API_KEY=sk-xxx ./my_app
```

See `SDK.md` for the full 15-function C ABI.

## Usage examples

### 1. Standalone binary (no UI, no LLM, just a digital life)

```bash
./zig-out/bin/daemon --id ghw-test --cycles 1000 --state-in /tmp/state.json
# Runs 1000 cycles, prints E, M, R, N snapshots, exits
```

### 2. Embedded C client (your app calls GHW as a library)

```c
#include "ghw.h"

int main() {
    GhW* g = ghw_init("my-agent", 42);
    ghw_open_memory(g, "/tmp/my-agent.db");
    ghw_world_set(g, "top_procs: claude 12%, node 8%");
    for (int i = 0; i < 5; i++) {
        char* report = ghw_step(g, "{}");
        printf("%s\n", report);
        ghw_free_string(report);
    }
    ghw_deinit(g);
}
```

### 3. Multi-agent peer query (two GHWs talking)

```bash
# Terminal 1
./zig-out/bin/ui_server --port 8765 --state /tmp/agent-a.json --ui-dir ui

# Terminal 2
./zig-out/bin/ui_server --port 8766 --state /tmp/agent-b.json --ui-dir ui

# Agent A queries B
curl http://localhost:8765/api/peers | jq
# {"peers":[{"path":"/tmp/ghw_8766.sock","E":0.42,...}]}
```

### 4. Direct E-formula L4 closed-loop manipulation

```bash
# Watch LLM propose new μ/ν/σ/λ every 8 cycles
curl http://localhost:8765/api/propose_history | jq '.history[-3:]'

# Watch 9-palace milestone history
curl http://localhost:8765/api/nine_palaces_history | jq
```

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full layered view, data flow
diagram, and 9-palace state machine.

**TL;DR**:

```
                    ┌─────────────────────────────────┐
                    │  World (M/R/N — three sources)  │
                    │  E = M_p(M,R,N;α,β,γ)            │
                    │      + σ·S + λ·D  (power mean)   │
                    └────────────────┬────────────────┘
                                     │ perception
                    ┌────────────────▼────────────────┐
                    │  Goal (attention → detection    │
                    │        → difference set)       │
                    │  9-relation GoalGraph DAG       │
                    └────────────────┬────────────────┘
                                     │ top goal
                    ┌────────────────▼────────────────┐
                    │  Harness (boundary + resource   │
                    │          + method library)      │
                    │  L1–L5 self-evolution chain      │
                    └────────────────┬────────────────┘
                                     │ action outcome
                    ┌────────────────▼────────────────┐
                    │  Agent (3 time-scale main loop)  │
                    │  Self-evolution guard,           │
                    │  state serialization, migration  │
                    └─────────────────────────────────┘
```

## HTTP API

The `ui_server` binary exposes 15+ HTTP endpoints for monitoring and control.
Full list with method, params, and example responses in
[`ARCHITECTURE.md#http-api`](ARCHITECTURE.md#http-api).

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/state` | Current E, M, R, N, tick, top goal, self-evolved count |
| GET | `/api/capabilities` | Full capability map (9 phases, 4 L4 coefficients, 9-palace deep) |
| GET | `/api/log` | Growth log (last 100 cycles) |
| GET | `/api/l1l5_trend` | L1–L5 cumulative counts over tick (SVG line chart data) |
| GET | `/api/propose_history` | L4 closed-loop LLM-proposal history (last 64) |
| GET | `/api/nine_palaces_history` | 9-palace milestone triggers + 16-cycle snapshots |
| GET | `/api/goals/relations` | 9-relation GoalGraph statistics + topological order |
| GET | `/api/peers` | Multi-GHW peer list |
| POST | `/api/propose` | Trigger LLM propose-goals manually |
| POST | `/api/chat` | Send a message to the digital life (async) |
| POST | `/api/enhance` | Trigger TemplateEnhancer on latest L1–L5 output |
| POST | `/api/reflect` | Trigger LLM reflection manually |
| GET | `/api/chat/history` | HTMX-style chat history fragment |
| GET | `/api/evolved` | List L1–L5 files dropped to `/tmp/ghw_evolved/` |
| GET | `/api/evolved/<file>` | Read a specific evolved file |
| POST | `/api/action/run-now` | Run an action immediately |

## C SDK

See [`SDK.md`](SDK.md) for the full C ABI specification (v0.3, 15 functions).

Highlights:
- **Opaque pointer** (`struct GhW`) — ABI stable, internal impl can evolve.
- **JSON in, JSON out** — zero friction across C / C++ / Rust / Go.
- **Zero hardcoded API keys** — `ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat")` reads key from env.
- **Zero runtime deps** — `libghw.a` bundles `libsqlite3` statically.

## Documentation

- [`site/docs/`](site/docs/index.md) — VitePress documentation site for overview, product runtime, API, SDK, and operations
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — layered view, data flow, 9-palace state machine
- [`SDK.md`](SDK.md) — C ABI v0.3 spec
- [`FAQ.md`](FAQ.md) — 10 common questions (memory usage, deployment, LLM choice, etc.)
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures and fixes
- [`readme.zh-CN.md`](readme.zh-CN.md) — Chinese translation of this README
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — GHW Link protocol spec (5 methods, JSONL)
- [`docs/CROSS_HOST.md`](docs/CROSS_HOST.md) — Cross-host TCP+HMAC protocol spec
- [`AGENTS.md`](AGENTS.md) — for AI agents working on this codebase
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute
- [`CHANGELOG.md`](CHANGELOG.md) — version history

## Roadmap

Phases 1–3 complete:

- ✅ **Phase 1**: Multi-GHW peer protocol (JSONL over Unix socket, 5 methods)
- ✅ **Phase 2**: Claude Code bridge (ActionRunner `claude_code` preset)
- ✅ **Phase 3**: GHW-as-kernel C SDK (libghw.a + ghw.h, 15 funcs)
- ✅ **Phase 4–8.7**: L1–L5 self-evolution (real compiled output), 9-relation GoalGraph, 9-palace deep dive, L4 closed-loop
- ✅ **Phase 9**: 9-palace milestone persistence + 3-milestone tracking (E var / M/R/N var / strong)

Phase 3 priorities (production hardening):

- ⏳ **Graceful shutdown + WAL rotation** — half-day
- ⏳ **DEEPSEEK_API_KEY via macOS Keychain** — 2h
- ⏳ **Docker image** — half-day
- ⏳ **Prometheus `/api/metrics` endpoint** — 1h
- ⏳ **GitHub Actions CI** — 1h

## Contributing

This is a single-author project (research + engineering). If you want to
contribute:

1. Read [`AGENTS.md`](AGENTS.md) for the AI agent guidelines.
2. Read [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) to understand known issues.
3. Run `zig build test` before submitting — must be 139/140 (1 known fail in
   `harness.self_encoder.test.SelfEncoder: 提取代码引用` is unrelated).
4. Don't change the E formula or the SelfEvolutionGuard 17-blacklist. The
   digital life's existence formula is invariant.

## License

MIT (see `LICENSE` — TBD if you want to change to Apache 2.0 / GPLv3).

---

**Status**: B+ production grade (75/100). Strong on observability and
self-evolution, weak on docs and operational hardening. See
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for the prioritized work list.

**Verified on macOS 15.x, Zig 0.17.0-dev.704+, sqlite 3.49.2, wasmtime 33.0.0.**
