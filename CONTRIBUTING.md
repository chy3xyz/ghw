# Contributing to GHW

> **The GHW project welcomes contributions.** Whether you're fixing a typo, adding a 5-line utility, or designing a new L5 rule synthesis pass — every PR matters. This document tells you how to get started.

## Project overview

GHW (Goal-Harness-World) is a digital life paradigm implemented in **Zig 0.17.0** with **zero external dependencies** (besides Zig stdlib + optional `wasmtime` / `sqlite3` for the sandbox). The codebase aims to be:

- **Readable** — the E formula (`E = α·M + β·R + γ·N − μ·Var + ν·min + σ·S + λ·D`) is documented in 5 places; the 9-palace state machine is one switch.
- **Tested** — `zig build test` runs 400 tests with 100% pass.
- **Reproducible** — `zig build` produces a 5.9 MB statically-linked `daemon` binary that runs forever.
- **Educational** — every module has a top-of-file comment explaining the WHY before the WHAT.

## Code of conduct

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). TL;DR: be respectful, assume good faith, no harassment.

## How to get started

1. **Read [`AGENTS.md`](AGENTS.md)** — the AI-agent guidelines also apply to humans. It spells out the core architecture rules (LLM is a proposer, never the decider; the E formula is sacred; the 17-blacklist self-evolution guard).
2. **Read [`ARCHITECTURE.md`](ARCHITECTURE.md)** — the layered view (World / Goal / Harness / Agent) and data flow.
3. **Read [`FAQ.md`](FAQ.md)** — answers 10 common questions, including "what is the 9-palace?" and "why does `ps` show 7.9 GB but `vm_stat` shows 11.6 GB used?".
4. **Build and test:**
   ```bash
   zig build           # 5.9 MB daemon
   zig build test      # 150+ tests, EXIT=0 expected
   ```
5. **Run the daemon for at least 1 hour** before opening a PR. Long-running is the whole point.

## What we accept

| Type | Welcome? | Where |
|------|----------|-------|
| Bug fix (with a test) | ✅ | `src/...` |
| New L1-L5 evolution example (rule or method template) | ✅ | `src/harness/auto_eps/` or `src/goal/methods/` |
| New 9-palace milestone | ✅ | `src/world/core.zig` (add to milestone ring) |
| New 9-relation goal graph edge type | ⚠️ Discuss first | `src/goal/core.zig` |
| New LLM provider (Anthropic / OpenAI / DeepSeek) | ✅ | `src/harness/llm/` |
| New ActionRunner preset (e.g. Slack, Discord) | ⚠️ Discuss first | `src/sandbox/action_runner.zig` |
| New cross-host transport (TLS, gRPC) | ⚠️ Discuss first | `src/harness/ghw_link_tcp.zig` |
| Changes to the E formula | ❌ **HARD NO** | — |
| Changes to the 17-blacklist self-evolution guard | ⚠️ Requires Knot3 Labs sign-off | — |
| Refactor of 50+ files in one PR | ❌ Too big to review | — |

## Coding conventions

- **Zero new external deps.** If you need a new library, vendor it as a Zig source file or argue the case in the PR.
- **Use `Module` (L5) not `SelfTunedWeights`.** When adding a new L5 rule template, follow the `src/harness/auto_eps/l5_*.zig` pattern.
- **Public functions return `!T`.** Internal helpers may panic.
- **Resource allocators use `errdefer`.**
- **Every new module ships with ≥ 2 unit tests.**
- **All new code must pass `zig build test` with 0 leak.** Zig 0.17 has DebugAllocator on by default — leaks abort.
- **Follow existing naming and module boundaries** — see `src/harness/mod.zig` for the canonical module export order.

## Testing requirements

Every PR must include:

1. **Unit tests for new code** — `zig build test` EXIT=0.
2. **End-to-end smoke test** — at least one of:
   - `zig build run-daemon -- --cycles 100` (daemon runs 100 cycles cleanly)
   - `zig build run-cross_host_test` (cross-host 2-link test passes)
   - `zig build run-multi_agent_demo` (multi-GHW peer demo runs)
3. **Updated docs** — if your change adds a CLI flag, update `readme.md` + `readme.zh-CN.md`. If your change adds a public API, update `SDK.md`.

## Pull request workflow

1. **Branch from `main`.** Branch name: `feature/<short-desc>` or `fix/<short-desc>`.
2. **One logical change per PR.** Don't bundle 5 features.
3. **Commit messages:**
   ```
   <scope>: <imperative one-liner>

   <body — why, not what>

   Tested:
   - zig build test  # EXIT=0
   - zig build run-daemon -- --cycles 50  # clean exit, 0 leak
   ```
4. **PR description** — link to the issue (if any), explain motivation, list alternative approaches you considered, show before/after KPIs if perf-related.
5. **Be patient.** Knot3 Labs reviews PRs async. Expect 1-7 days.

## Reporting issues

Use GitHub Issues. **Include:**
- Zig version (`zig version`)
- OS (macOS / Linux distro + version)
- `zig build test` output (full, not truncated)
- `ghw_diagnose.sh` output (if from `TROUBLESHOOTING.md`)
- The CLI flag combination that triggered the bug
- Expected vs actual behavior

For **security issues**, see [`SECURITY.md`](SECURITY.md) — do NOT file a public issue.

## Long-term roadmap

| Phase | Status | Theme |
|-------|--------|-------|
| 1-9 | ✅ | Self-evolution (L1-L5), E formula, 9-palace, 9-relation GoalGraph |
| 10 | 🚧 | Loop Engineering (Boris Cherny 6 components — partial) |
| 11 | 📋 | Cross-host ΔE feedback (peer E → L4 closed loop) |
| 12 | 📋 | TLS 1.3 cross-host (public network) |
| 13 | 📋 | chaos_test 1k cycle (long-run validation) |
| 14 | 📋 | Benchmark vs LangChain / AutoGen (paper B.5.3) |
| 15 | 📋 | GHW-as-kernel SDK v1.0 |

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Questions?

Open a GitHub Discussion (preferred) or file an issue with the `question` label.

---

> Maintained by [Knot3 Labs](https://github.com/chy3xyz/ghw) and the open-source community. GHW is independent research, not affiliated with any LLM vendor.
