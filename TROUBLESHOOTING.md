# GHW Troubleshooting

> Common failures, their causes, and fixes. If your problem isn't here,
> please open an issue with the output of `ghw_diagnose` (see
> [the diagnostic section](#ghw_diagnose-sh) at the bottom).

## Table of Contents

- [Memory & performance](#memory--performance)
- [Daemon won't start](#daemon-wont-start)
- [Daemon dies repeatedly](#daemon-dies-repeatedly)
- [UI server returns 502 / connection refused](#ui-server-returns-502--connection-refused)
- [LLM features don't work](#llm-features-dont-work)
- [9-palace milestones don't trigger](#9-palace-milestones-dont-trigger)
- [L1–L5 files aren't being dropped](#l1l5-files-arent-being-dropped)
- [L1–L5 files are dropped but not adopted](#l1l5-files-are-dropped-but-not-adopted)
- [`zig build` fails with "found another zig file"](#zig-build-fails-with-found-another-zig-file)
- [SQLite database is locked](#sqlite-database-is-locked)
- [WebSocket / chat reply never comes](#websocket--chat-reply-never-comes)
- [`ghw_diagnose.sh` — one-shot diagnostic](#ghw_diagnosesh--one-shot-diagnostic)
- [Known limitations](#known-limitations)

## Memory & performance

### "My ghw-daemon is using 7 GB / 14 GB of RAM!"

**It isn't. Activity Monitor's "Memory" column shows the system's
total PhysMem, not a single process.**

macOS reports memory as "PhysMem Used" at the top of Activity Monitor,
which is the sum of:

- `Pages active` — currently in use by apps
- `Pages wired down` — locked by the kernel (drivers, etc.)
- `Pages stored in compressor` — compressed inactive pages in swap

It's a **system-wide** number, not per-process. To find the real per-process
memory:

```bash
ps -ax -o pid,etime,rss,command | grep -E "ghw-daemon|ui_server" | grep -v grep
# Column 3 is RSS in KB
# 8288  → 8.3 MB
```

A real ghw-daemon run is typically **2–10 MB RSS**, regardless of uptime
or tick count. The 22-hour production run that produced 1.5B ticks had
RSS ~8 MB.

To find the actual top memory consumers:

```bash
ps -ax -o pid,user,rss,command | sort -k3 -n -r | head -10
```

Typical macOS dev machine top consumers (in 2026-06 audit):
- MiniMax Code (Renderer) — ~461 MB
- opencode serve — ~392 MB
- Google Chrome (3 processes) — ~700 MB combined
- WeChat (3 processes) — ~600 MB combined
- Claude Code (node) — ~176 MB

If `ghw-daemon` shows up at the top of this list, **that's abnormal** —
please open an issue with the output of
[`ghw_diagnose.sh`](#ghw_diagnosesh--one-shot-diagnostic).

### "Daemon CPU usage is 100%"

This is normal during LLM reflection (1–3 second blocking call) or
during L1–L5 compilation (zig build subprocess). For continuous 100%
CPU, check:

```bash
ps -ax -o pid,etime,pcpu,rss,command | grep ghw
# If pcpu is consistently 100+ for > 1 minute, that's a bug
```

Common causes:
- LLM call stuck (no timeout, see
  [known limitations](#known-limitations))
- An infinite loop in a newly-adopted L1–L5 file (roll back via
  `state.json` restore)

## Daemon won't start

### `launchctl load` says "service already loaded"

```bash
launchctl unload ~/Library/LaunchAgents/com.ghw.ui.plist
sleep 1
launchctl load -w ~/Library/LaunchAgents/com.ghw.ui.plist
```

If that doesn't work, check if the binary is in the right place:

```bash
ls -la ~/.local/bin/ghw-daemon
# Should exist, executable, ~2 MB
```

If the binary is missing, re-run `./install.sh`.

### "Killed: 9" or "Segmentation fault" on startup

The binary was compiled with a different Zig version than the one in
your PATH. The codebase requires **Zig 0.17.0** release (or a 0.17 dev build
≥ `0.17.0-dev.704`, e.g. `0.17.0-dev.2151`).

```bash
zig version
# Should be 0.17.0, or 0.17.0-dev.704 or later

# If wrong version:
# macOS (Homebrew)
brew install zig

# Manual
curl -L https://ziglang.org/download/index.json | \
    jq -r '.["0.17.0-dev.704"]."x86_64-macos".tarball' | \
    xargs curl -L -o /tmp/zig.tar.xz
tar -xJf /tmp/zig.tar.xz -C /tmp/
mv /tmp/zig /Users/n0x/.zig/zig
export PATH=/Users/n0x/.zig/zig:$PATH
```

Then rebuild:

```bash
./install.sh
```

### "error: linkSystemLibrary 'sqlite3' not found" (Linux)

The Linux build requires `libsqlite3-dev` to be installed:

```bash
# Debian / Ubuntu
sudo apt install libsqlite3-dev

# Fedora / RHEL
sudo dnf install sqlite-devel

# Arch
sudo pacman -S sqlite
```

Then rebuild.

### "cannot find wasmtime" warning

WASM sandbox is optional. If you don't have wasmtime:

```bash
brew install wasmtime          # macOS
# or
cargo install wasmtime-cli     # if you have Rust
```

If you don't need WASM, ignore the warning — the agent will skip WASM
actions and use other ActionRunner presets (Claude Code, peer, observe).

## Daemon dies repeatedly

### launchd keeps restarting it (every 10 seconds)

Check the log:

```bash
tail -50 /tmp/ghw-ui.log
# or
log stream --predicate 'process == "ghw-daemon"' --info
```

Common patterns:

| Last log line | Cause | Fix |
|---------------|-------|-----|
| `error: out of memory` | Allocator OOM, usually due to a runaway L1–L5 file | Restore `state.json` from backup |
| `error: SqliteError.StepFailed` | SQLite DB corruption (rare) | `sqlite3 ~/.local/share/ghw/state.db ".recover"` |
| `error: Zig 0.17 ...` | Compilation crashed during L1–L5 | Check `/tmp/ghw_verify/` for stderr |
| `Killed: 9` | Memory limit hit (macOS) | Check `ulimit -v` in launchd plist |
| `illegal instruction` | CPU architecture mismatch (e.g., ARM binary on Intel) | Rebuild on the target machine |

If the daemon dies within 1 second of startup, it's usually a missing
dependency (sqlite, wasmtime) or a config error. Run it in the
foreground to see the error:

```bash
launchctl unload ~/Library/LaunchAgents/com.ghw.ui.plist
~/.local/bin/ghw-daemon --id test --cycles 10
# Now you see the error directly
```

## UI server returns 502 / connection refused

### "Connection refused on port 8765"

```bash
lsof -i :8765
# If empty, the ui_server isn't running
```

Check the launchd status:

```bash
launchctl list | grep ghw
# If "com.ghw.ui" is not listed, the plist isn't loaded
launchctl load -w ~/Library/LaunchAgents/com.ghw.ui.plist
```

### "502 Bad Gateway" or "Connection reset"

The ui_server is running but a child process (e.g., wasmtime) crashed.
Check:

```bash
tail -50 /tmp/ghw-ui.log
# Look for "wasm done, term=" lines
```

If you see repeated `term=.{ .exited = 1 }`, the WASM module is
malformed. This is usually caused by a bad L1–L5 adoption. To roll back:

```bash
# Stop the daemon
launchctl unload ~/Library/LaunchAgents/com.ghw.ui.plist

# Find the offending file
ls -lt /tmp/ghw_evolved/ | head
# The most recent file is likely the culprit

# Move it out of the way (it'll be re-adopted on next L1–L5 trigger)
mv /tmp/ghw_evolved/l3_<tick>.zig /tmp/ghw_evolved/l3_<tick>.zig.broken

# Restore state.json from the last good snapshot
# (if you have backups — we recommend daily snapshot cron)
cp ~/.local/share/ghw/state.json.bak ~/.local/share/ghw/state.json

# Restart
launchctl load -w ~/Library/LaunchAgents/com.ghw.ui.plist
```

## LLM features don't work

### "reflect failed: LLM 失败"

The LLM call returned an error or timed out. Check:

```bash
# 1. Is the API key set?
echo $DEEPSEEK_API_KEY | head -c 10
# Should show "sk-..."

# 2. Can you reach the API?
curl -s https://api.deepseek.com/v1/models \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" | jq '.data[0].id'
# Should return "deepseek-chat" or similar

# 3. Check the daemon log
tail -F /tmp/ghw-ui.log | grep -E "LLM|deepseek|anthropic"
```

Common causes:
- **API key invalid** — re-check the key on the provider's dashboard.
- **API key in plist but env not set** — the plist EnvironmentVariables
  override the user's shell. Check `launchctl getenv DEEPSEEK_API_KEY`.
- **API rate limit hit** — back off. The daemon doesn't have automatic
  backoff yet (see [known limitations](#known-limitations)).
- **Network firewall** — corporate networks often block OpenAI API
  domains. Try a different network.

### LLM responses are slow (> 5 seconds)

This is normal for Claude (`claude-3-5-sonnet`) — 2-3 seconds is
typical. DeepSeek should be < 1 second for `deepseek-chat`.

If responses are > 10 seconds, the daemon is blocking. Check:

```bash
# Use the background reflect/chat threads
grep -E "reflect_bg|chat_worker" /tmp/ghw-ui.log | tail
# Should show the thread spawning and finishing
```

If the threads are stuck, it's usually a `std.Io.Mutex` deadlock —
report with the full log.

## 9-palace milestones don't trigger

### "I have M=R=N=1.0 but 9-palace still says false"

The milestones require the condition to hold for **64 consecutive
cycles** without breaking. If M/R/N is jumping around (e.g., during a
busy self-evolution period), the milestone won't trigger even if the
*average* condition is met.

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
#   "e_var_seen": true
# }
```

- If `mrn_buf_count < 64`, the buffer hasn't filled yet. Wait.
- If `mrn_buf_var > 0.01`, the condition isn't holding. Common causes:
  - Heavy LLM propose activity (4 coefficients change every 8 cycles)
  - L1–L5 self-evolution runs (cycle 64/96/192 cause brief E jumps)
- Wait for a "quiet" period (no L1–L5 fires, no LLM proposes for 64
  cycles) and the 9-palace will fill.

### "Once triggered, can a milestone be un-triggered?"

No. The `*_seen` flag is **permanent for the agent's lifetime**. This is
intentional — once the digital life has demonstrated 三源合恰, it has
demonstrated it. The flag is a *milestone*, not a *state*.

To "reset" the milestones, delete `state.json` and restart (this also
loses all other state — last resort).

## L1–L5 files aren't being dropped

### `/tmp/ghw_evolved/` is empty after hours of running

L1–L5 has **scheduled triggers**:

- **L1 + L2**: every 32 cycles
- **L3**: every 64 cycles
- **L4**: every 96 cycles
- **L5**: every 192 cycles

The agent's `tick` is not the same as wall-clock time — it's the
internal cycle counter. To check tick count:

```bash
curl http://localhost:8765/api/state | jq '.tick'
# Should be at least 192 for L1–L5 to have triggered
```

If `tick > 192` and `/tmp/ghw_evolved/` is still empty, check:

```bash
# Was the LLM configured? L1–L5 needs the LLM for proposal generation
echo $DEEPSEEK_API_KEY | head -c 10
# If empty, L1–L5 will skip (the guard rejects proposals without LLM signature)

# Check the log for L1–L5 activity
grep -E "L1|L2|L3|L4|L5|self_evolve" /tmp/ghw-ui.log | tail -20
```

Common reasons L1–L5 might be silent:
- LLM is `none` (no API key) — L1–L5 needs the LLM to generate proposals
- `last_auto_lX_tick` in state.json is set to a future tick (from a
  previous run that hit the cap) — check the value:
  ```bash
  jq '.last_auto_l1l2_tick, .last_auto_l3_tick, .last_auto_l4_tick, .last_auto_l5_tick' \
      ~/.local/share/ghw/state.json
  ```
  If they're > current tick, the next L1–L5 fire is delayed.

## L1–L5 files are dropped but not adopted

### "Files in `/tmp/ghw_evolved/` but not in `src/goal/methods/`"

`adoptIntoGhwSource` only adopts if the verifier passed AND the path
is in the whitelist. Check the log:

```bash
tail -F /tmp/ghw-ui.log | grep -E "adopt|verdict"
```

If you see `verdict=approved applied=false`, verification passed but
adoption was skipped. This is usually:
- **Path whitelist miss** — the file path doesn't match the expected
  pattern (e.g., L3 must be under `src/goal/methods/`).
- **`adopt` step in self_evolver.zig failed** — check for I/O errors
  (disk full, permission denied).

## `zig build` fails with "found another zig file"

This is a **Zig 0.17 dev quirk** — cross-directory `--dep` is broken.
The `compile_verifier.zig` works around it by:

1. Writing a `build.zig` to a temp dir
2. Copying `src/harness_api.zig` (a thin ActionOutcome wrapper) into
   the temp dir
3. Running `zig build --build-file <temp_build_zig>` (instead of
   `zig build-exe`)

If you see this error, the workaround has likely been bypassed
(e.g., by manually running `zig build-exe` with `--dep`). To fix:

```bash
rm -rf /tmp/ghw_verify/
# Restart the daemon; it will re-create the temp dir
```

If the error persists, the L1–L5 file is referencing a module that's
not in `harness_api.zig`. Add it to the wrapper or modify the L1–L5
proposal to not use that module.

## SQLite database is locked

### "SqliteError: database is locked"

Only one process can have the SQLite DB open in write mode at a time.
This happens if:
- Two daemon instances are running against the same state file
- The daemon crashed and the SQLite WAL files weren't cleaned up

```bash
# Check for running instances
ps -ax | grep -E "ghw-daemon|ui_server" | grep -v grep

# If multiple, kill the extras
kill <pid>

# Check for stale WAL files
ls -la ~/.local/share/ghw/state.db*
# Should be: state.db, state.db-wal, state.db-shm
# If you see state.db-wal with size > 1MB, the previous process
# didn't checkpoint properly. Force a checkpoint:
sqlite3 ~/.local/share/ghw/state.db "PRAGMA wal_checkpoint(TRUNCATE);"
```

## WebSocket / chat reply never comes

The chat reply is **async** — the worker thread writes the reply to
`app.chat_history` after the LLM call returns, and the client polls
`/api/chat/history` every 1.2 seconds.

If the reply never comes:

```bash
# Check the chat worker thread
grep -E "chat_worker|chat reply" /tmp/ghw-ui.log | tail
# Should show "chat reply written" within 5 seconds of your message
```

Common causes:
- LLM call failed (see [LLM features don't work](#llm-features-dont-work))
- The chat history buffer is full (> 50 messages, the worker overwrites
  the oldest)
- Browser-side: the HTMX polling isn't running (check the
  browser console for errors)

## `ghw_diagnose.sh` — one-shot diagnostic

Save this as `scripts/ghw_diagnose.sh` and run it before opening an
issue:

```bash
#!/usr/bin/env bash
# ghw_diagnose.sh — collect diagnostic info for GHW troubleshooting
set -e

echo "=== Zig version ==="
zig version || echo "Zig not in PATH"

echo
echo "=== Running GHW processes ==="
ps -ax -o pid,etime,rss,pcpu,command | grep -E "ghw-daemon|ui_server" | grep -v grep

echo
echo "=== Recent daemon log (last 50 lines) ==="
tail -50 /tmp/ghw-ui.log 2>/dev/null || echo "No /tmp/ghw-ui.log"

echo
echo "=== state.json snapshot ==="
ls -la ~/.local/share/ghw/state.json 2>/dev/null
jq '{tick, E, M, R, N, self_evolved_total, action_count, phase, l1..l5_count}' \
    ~/.local/share/ghw/state.json 2>/dev/null || echo "No state.json"

echo
echo "=== L1–L5 files in /tmp/ghw_evolved/ ==="
ls -la /tmp/ghw_evolved/ 2>/dev/null || echo "No /tmp/ghw_evolved/"

echo
echo "=== Top memory consumers ==="
ps -ax -o pid,user,rss,command | sort -k3 -n -r | head -10

echo
echo "=== PhysMem usage ==="
vm_stat | head -10

echo
echo "=== Network test (if LLM configured) ==="
if [ -n "$DEEPSEEK_API_KEY" ]; then
    curl -s -o /dev/null -w "deepseek.com: HTTP %{http_code} (%{time_total}s)\n" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        https://api.deepseek.com/v1/models
fi
```

## Known limitations

These are **known issues** that we're tracking but haven't fixed yet:

| Issue | Severity | Workaround |
|-------|----------|------------|
| API keys stored in plaintext in launchd plist | High | Use env vars; Keychain migration planned |
| No graceful shutdown (SIGTERM = abrupt exit) | Medium | launchd restarts automatically; state saved every 100 cycles |
| No WAL rotation (`state.json` rewritten whole) | Medium | Backup daily via cron |
| No Prometheus / OpenTelemetry export | Medium | Use the JSON HTTP API for now |
| No Docker image | Medium | Build from source |
| LLM calls have no automatic backoff / retry | Low | Restart daemon if you hit a rate limit |
| `bindText` is a stub (use `bindTextAlloc` instead) | Low | Don't extend SqliteDb without checking which one is the real one |
| ~~The 1 failing test~~ (fixed — `zig build test` is now 396/396 green) | — | — |
| L1–L5 can't be cleanly disabled | Low | Comment out the cycle-N triggers in `examples/ui_server.zig` |
| No automatic state.json backup | Low | Add `cron` daily backup |

## Getting help

If your problem isn't here:

1. Run [`ghw_diagnose.sh`](#ghw_diagnosesh--one-shot-diagnostic) and
   include the output in your issue.
2. Check the existing GitHub issues for similar problems.
3. Open a new issue with:
   - Your OS and version (`sw_vers` on macOS, `lsb_release -a` on Linux)
   - Your Zig version (`zig version`)
   - The output of `ghw_diagnose.sh`
   - The relevant log lines (with timestamps)
   - A minimal reproduction if possible

We're a small project but we respond to issues within a few days.
