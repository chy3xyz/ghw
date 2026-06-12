# GHW FAQ

> Frequently asked questions about the GHW digital life framework. If you
> have a question that's not here, please open an issue.

## Table of Contents

- [Memory & performance](#memory--performance)
- [Deployment](#deployment)
- [LLM choice & API keys](#llm-choice--api-keys)
- [9-palace milestones](#9-palaces-milestones)
- [L1–L5 self-evolution](#l1l5-self-evolution)
- [State persistence & crashes](#state-persistence--crashes)
- [What's the difference from AutoGPT / BabyAGI / MetaGPT?](#whats-the-difference-from-autogpt--babyagi--metagpt)
- [What can a digital life actually do?](#what-can-a-digital-life-actually-do)
- [Why Zig 0.17 dev?](#why-zig-017-dev)
- [Can I run multiple GHW agents on one machine?](#can-i-run-multiple-ghw-agents-on-one-machine)
- [Is there a paper?](#is-there-a-paper)

## Memory & performance

### "My ghw-daemon is using 7 GB / 14 GB of RAM!"

**It's not. Activity Monitor's "Memory" column shows the system's total
PhysMem, not a single process.** This is a macOS-specific reporting quirk.

Verify with:

```bash
ps -ax -o pid,etime,rss,vsz,command | grep ghw-daemon
# Example: 38862 22:11:31  8288 /Users/n0x/.local/bin/ghw-daemon
#                                                    ^^^^
#                                                    RSS in KB (8.3 MB)
```

A real ghw-daemon run is typically 2–10 MB RSS, regardless of how long
it's been running or how many ticks it's processed. The 22-hour
production run that produced 1.5B ticks had RSS ~8 MB.

The "14 GB" or "7 GB" you see in Activity Monitor is the **system's
total PhysMem used** = `active + wired + compressor swap`, which is the
sum of macOS itself + every app you have open (Chrome, WeChat, MiniMax
Code, Claude Code, etc.). On a typical dev machine, this is 8–16 GB.

To find the real top memory consumers:

```bash
ps -ax -o pid,user,rss,command | sort -k3 -n -r | head -10
```

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#my-ghw-daemon-is-using-7-gb--14-gb-of-ram)
for the full investigation steps.

### "Does ghw-daemon leak memory over time?"

No. The daemon uses a fixed-size bump allocator for the main agent state,
plus a SQLite database for episodic memory (which is itself bounded by
schema). In 22+ hours of production running, RSS has been observed to
fluctuate in a 2–10 MB band, not grow monotonically.

## Deployment

### How do I install ghw-daemon as a system service?

```bash
# macOS — uses launchd
./install.sh

# Linux — uses systemd
./install.sh
```

`install.sh` handles:
- Compiling release binaries to `~/.local/bin/`
- Creating the data directory at `~/.local/share/ghw/`
- Installing the launchd plist or systemd unit
- Starting the service immediately
- Setting up `newsyslog` (macOS) or `logrotate` (Linux) for log rotation

### Can I run ghw on Windows?

Not directly. The code is portable C ABI + Zig, but the deployment
scripts assume Unix (launchd / systemd). For Windows, use WSL2.

### Can I run multiple ghw agents on one machine?

Yes, on different ports and state directories:

```bash
# Agent A
./zig-out/bin/ui_server --port 8765 --state /tmp/agent-a.json

# Agent B
./zig-out/bin/ui_server --port 8766 --state /tmp/agent-b.json

# They can talk to each other via the GSP peer protocol (see
# src/harness/gsp_*.zig) — Agent A can query Agent B's state.
```

## LLM choice & API keys

### Which LLMs are supported?

Any OpenAI-compatible API. The default is DeepSeek (`deepseek-chat`).
Other tested options:
- DeepSeek (`deepseek-chat`) — recommended, cheap and fast
- Claude (`claude-3-5-sonnet-latest`) — better reasoning, more expensive
- Any local OpenAI-compatible server (e.g., `vllm`, `ollama`)

Configuration:

```bash
# DeepSeek (default)
./zig-out/bin/ui_server --llm deepseek --llm-model deepseek-chat --llm-key-env DEEPSEEK_API_KEY

# Claude
./zig-out/bin/ui_server --llm anthropic --llm-model claude-3-5-sonnet-latest --llm-key-env ANTHROPIC_API_KEY

# Local
./zig-out/bin/ui_server --llm openai_compat --llm-model my-model --llm-key-env LOCAL_LLM_KEY \
    --llm-base-url http://localhost:8080/v1
```

### How are API keys stored?

Currently in the launchd plist as a plaintext environment variable
(`DEEPSEEK_API_KEY=...`). This is functional but not ideal — the file is
readable by any user on the system. We plan to migrate to macOS
Keychain (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#api-keys-are-stored-in-plaintext)).

For local development, environment variables (set via `~/.zshrc` or
`~/.bashrc`) are recommended.

### Can the LLM escape the guardrails?

No. The LLM's output is:
1. **Parsed** (text → JSON for propose/reflect)
2. **Clamped** (numeric values to range limits)
3. **Guard-checked** (17-blacklist prefix match for code proposals)
4. **Formally verified** (for L5 self-encoded rules)
5. **ΔE-evaluated** (does the proposal actually improve E?)
6. **Reversible** (state is snapshotted before each apply; can be rolled
   back via state.json restore)

The LLM is **fuel, not the brain**. See
[`ARCHITECTURE.md`](ARCHITECTURE.md#layer-3-harness) for the guard design.

## 9-palace milestones

### "My agent has been running for hours but the 9-palace isn't filling up"

The 3 9-palace milestones require the condition to hold for **64
consecutive cycles** without breaking. If the agent's M/R/N is jumping
around (e.g., during a busy self-evolution period), the milestones
won't trigger even if the *average* condition is met.

To debug:

```bash
curl http://localhost:8765/api/capabilities | jq '.nine_palaces_deep'
# {
#   "mrn_var_now": 0.0012,
#   "mrn_min_now": 0.88,
#   "mrn_buf_var": 0.0001,     # ← 64-cycle ring buffer variance
#   "mrn_buf_count": 64,        # ← must be 64
#   "mrn_seen": true,
#   "mrn_strong_seen": false,
#   ...
# }
```

If `mrn_buf_count` is less than 64, the buffer hasn't filled yet. Wait
until it does.

If `mrn_buf_var` is fluctuating (sometimes > 0.01), the condition isn't
holding for the full 64 cycles. Common causes:
- Heavy LLM propose activity (4 adaptive coefficients change every 8
  cycles, which can briefly destabilize M/R/N).
- L1–L5 self-evolution runs (cycle 64, 96, 192, etc. cause brief E
  jumps).

Wait for a "quiet" period (no L1–L5 fires, no LLM proposes for 64
cycles) and the 9-palace will fill.

### "Once triggered, can a 9-palace milestone be un-triggered?"

No. The `*_seen` flag is permanent for the agent's lifetime. This is
intentional — once the digital life has reached a "三源合恰" balanced
state, it has *demonstrated* the capability, even if it later becomes
imbalanced. The flag is a *milestone*, not a *state*.

## L1–L5 self-evolution

### "How do I know if L1–L5 is actually running?"

```bash
ls -la /tmp/ghw_evolved/ 2>/dev/null
# Should show l1_<tick>.zig, l3_<tick>.zig, l4_<tick>.zig, l5_<tick>.zig

curl http://localhost:8765/api/evolved | jq '.files | length'
# Returns the number of L1–L5 files dropped

curl http://localhost:8765/api/l1l5_trend | jq '.l1 | length'
# Returns the number of L1 cumulative data points
```

If `/tmp/ghw_evolved/` is empty, L1–L5 hasn't run yet (first trigger
at cycle 32 for L1+L2, cycle 64 for L3, etc.).

### "Can I disable L1–L5?"

Currently no clean way. The triggers are hard-coded in
`examples/ui_server.zig` (every N cycles). To disable:
- Comment out the `if (cycle % N == 0) { ... l1_evolution ... }` blocks
- Or modify `app.last_auto_lX_tick` to skip every N cycles indefinitely
  (hack — sets the next trigger tick to be N cycles in the future)

The 17-blacklist in `SelfEvolutionGuard` will reject L1–L5 attempts at
sensitive targets regardless. The blacklisted paths are:
- `src/agent/params.zig` (α/β/γ — the invariant E weights)
- `src/goal/methods/` (L3 target — but only new files, can't overwrite)
- `src/world/core.zig` (the E formula itself)

### "L1–L5 files aren't being adopted into the source tree"

The `adoptIntoGhwSource` step in `src/harness/self_evolver.zig` only
adopts if the verifier passed and the path is in the whitelist. Check
the launchd log:

```bash
tail -F /tmp/ghw-ui.log | grep -E "adopt|verdict|adopted"
```

If you see `verdict=approved applied=false`, the verification passed but
adoption was skipped. This is usually a path whitelist miss.

## State persistence & crashes

### "What happens if ghw-daemon crashes?"

The launchd plist has `KeepAlive=true` (with `ThrottleInterval=10`),
so launchd will restart the daemon within 10 seconds of a crash.
State is preserved in `~/.local/share/ghw/state.json` (rewritten every
saveState, currently every 100 cycles or so).

On restart, the daemon loads the state and continues from the last
saved tick. No data is lost, except for the last few cycles of in-flight
work (the WAL upgrade will fix this — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#graceful-shutdown-and-wal-not-implemented)).

### "Can I roll back to a previous state?"

Yes — `state.json` is a complete snapshot. To roll back:

```bash
# Stop the daemon
launchctl unload ~/Library/LaunchAgents/com.ghw.ui.plist  # macOS
# or
systemctl --user stop ghw.service                          # Linux

# Restore the snapshot you want (assuming you have backups)
cp ~/.local/share/ghw/state.json.bak ~/.local/share/ghw/state.json

# Restart
launchctl load -w ~/Library/LaunchAgents/com.ghw.ui.plist
# or
systemctl --user start ghw.service
```

Backups are not automatic. We recommend `cron` or `launchd` to snapshot
`state.json` daily.

## What's the difference from AutoGPT / BabyAGI / MetaGPT?

GHW is **not** an LLM agent framework. It's a **digital life paradigm** in
which LLM is a *fuel injector* (text → features, code variant proposals)
and the *intelligence* is the 4-layer stack (World / Goal / Harness /
Agent) with the E formula, the 9-relation GoalGraph, and the 9-palace
maturity gate.

Concretely:

| Aspect | AutoGPT / BabyAGI | GHW |
|--------|-------------------|-----|
| Decision authority | LLM (the only "brain") | E-formula evaluator (LLM is fuel) |
| Self-modification | Re-prompt the LLM | Real compiled `.zig` files adopted into source tree |
| State persistence | LLM context window + JSON | SQLite + JSON snapshots + WAL (planned) |
| Auditability | Hard — every decision is an LLM call | Trivial — every LLM call is logged, gated, verified |
| Memory model | Vector store (RAG) | Episodic + semantic + procedural (3 layers) |
| E formula / invariant | None | Yes — α/β/γ invariant, 4 adaptive coefficients gated |
| Multi-agent | Via shared LLM context | First-class via GSP peer protocol (JSONL over Unix socket) |
| Deployment | Python + Docker | Native Zig binary, single file, ~2 MB |
| Runtime dependencies | Python ecosystem, vector DB | Zero (libsqlite3 bundled) |

## What can a digital life actually do?

In the current implementation, a digital life can:

1. **Perceive its host machine** — top processes, CPU usage, network state,
   current time, recent action history.
2. **Propose goals** — using LLM as a parser, generate 1–N candidate
   goals per cycle, ranked by the existence gap Δ.
3. **Run actions** — execute WASM modules, call Claude Code, query
   peer GHWs, or just observe.
4. **Reflect** — every 32 cycles, generate a self_narrative ("I did X,
   I learned Y, I want to Z").
5. **Self-evolve** — L1–L5 chain produces real compiled code that gets
   adopted into the next build.
6. **Propose E-formula changes** — L4 closed-loop, every 8 cycles.
7. **Talk to you** — async chat via `/api/chat`.
8. **Reach 9-palace milestones** — quantitatively demonstrate
   三源合恰 balanced state.

It cannot (yet):
- Make purchases or external API calls without your explicit
  ActionRunner preset configuration.
- Modify its own E formula (invariant).
- Modify the SelfEvolutionGuard 17-blacklist (only the agent can,
  with human review).
- Run without the `~/.local/share/ghw/` data directory (no in-memory
  mode).

## Why Zig 0.17 dev?

- **Zero external dependencies** — the entire framework compiles to a
  single static library with no runtime deps (libsqlite3 is bundled).
- **Fast cold start** — 5ms to a running daemon, vs. 1–2 seconds for
  Python.
- **Tiny binary** — `libghw.a` is ~9 MB, `ui_server` is ~7 MB.
- **C ABI natural** — the SDK export is a first-class citizen, not an
  FFI afterthought.
- **Compile-time guarantees** — Zig's comptime lets us encode the
  SelfEvolutionGuard rules in the type system.

The downside: Zig 0.17 is a dev version. We track the latest dev
release (`0.17.0-dev.704+` as of 2026-06) and update as the language
stabilizes.

## Can I run multiple GHW agents on one machine?

Yes, on different ports and state directories:

```bash
# Agent A
./zig-out/bin/ui_server --port 8765 --state /tmp/agent-a.json

# Agent B
./zig-out/bin/ui_server --port 8766 --state /tmp/agent-b.json
```

They can talk to each other via the GSP peer protocol. See
`src/harness/gsp_node.zig` and `src/harness/symbiosis_ledger.zig` for
the implementation. Agent A can call `ghw_link_query` (C SDK) or
`GET /api/peers` (HTTP) to find Agent B and query its state.

## Is there a paper?

Yes — the original research paper is in `docs/paper.md` (Chinese,
5855 lines, 925 KB). It covers the philosophical background
(Heidegger, Zhuangzi, Haraway, Braidotti), the formal existence theory
(存在度 E, 三源合恰 张量), and the implementation design rationale.

A condensed version is in `docs/范式变革论文-简版.md` (also Chinese,
shorter). The English README.md (this file) and ARCHITECTURE.md are
the practical reference for engineers.
