# Security Policy

> **TL;DR**: GHW is a research-grade digital life framework. It runs on your machine with the privileges of whatever user invokes it. Read this once before deploying.

## Supported versions

| Version | Supported          |
|---------|--------------------|
| v0.5.1+ | ✅ active          |
| < v0.5  | ❌ legacy, please upgrade |

## Threat model

GHW is designed for:

- **Single-user or small-team trusted environments** (your laptop, your LAN, your docker-compose).
- **Educational / research deployments** where you want to observe a digital life, not run critical infrastructure.

GHW is **not** designed for:

- Multi-tenant SaaS deployments.
- Public internet exposure (without TLS + reverse proxy + auth).
- Adversarial network environments.

## Security boundaries

### 1. Process boundary

- The `daemon` binary runs as whatever user invokes it. It can read/write files in your `$HOME` (state files) and `/tmp/` (logs, sockets).
- **Recommendation**: run as a dedicated low-privilege user (`_ghw`) on production.

### 2. Local IPC (Unix socket)

- `examples/ui_server.zig` creates Unix sockets in `/tmp/ghw_*.sock`.
- **Anyone who can read/write to `/tmp/`** on your machine can talk to your GHW daemon.
- **Mitigation**: the socket uses `0600` permissions by default. Do not chmod it open.

### 3. Cross-host Link (TCP + HMAC)

- `src/harness/ghw_link_tcp.zig` adds HMAC-SHA256 challenge-response for cross-host communication.
- **v0.5.1 limitation**: the server-side mock handler does NOT actually verify the `auth.hmac` field — it accepts any client. This is documented in `docs/CROSS_HOST.md` § 6 and `tests/cross_host_test.zig` Test 3.
- **Phase 10+ will add real server-side HMAC verification.** Until then, **do not expose the cross-host port to untrusted networks**.
- **Transport is unencrypted TCP** (no TLS 1.3 yet). **Do not expose to the public internet.**

### 4. LLM API keys

- **Never hardcoded in source code.** Pass via env var (`--api-key-env OPENAI_API_KEY` etc.).
- The `keychain.zig` wrapper stores in macOS Keychain or Linux `secret-tool`.
- **Never commit a key.** `.gitignore` blocks `*.key`, `*.pem`, `*secret*`, `.env`.
- If you accidentally committed a key, **rotate it immediately** and use `git filter-repo` to scrub history.

### 5. Self-evolution (L1-L5)

- The framework writes `.zig` files into a configurable directory (default `/tmp/ghw_evolved/`).
- The 17-blacklist `self_evolution_guard.zig` blocks known-bad patterns (rm -rf, curl | sh, fork bombs, etc.).
- **The blacklist is not exhaustive.** Treat L1-L5 output as untrusted code. Run in a sandboxed user account.

### 6. WASM sandbox

- `src/sandbox/wasm_runtime.zig` uses `wasmtime 33.0.0+`.
- WASM modules run in the wasmtime default sandbox (no `syscalls` available, capped memory, capped fuel).
- **Do not** run arbitrary WASM modules from the internet through this sandbox. Validate them first.

### 7. SQLite database

- `state.json.db` (and `.db-wal`, `.db-shm`, `.db-journal`) hold episodes, beliefs, and proposed goals.
- **Permissions**: default `0600`. Do not chmod it open.
- **Backups**: snapshot via WAL replay (see `state_serializer.zig`).

## Reporting a vulnerability

**Do NOT file a public GitHub issue for security issues.**

Email **security@ghw.knot3.dev** (placeholder) with:

- Description of the issue
- Reproduction steps (or a PoC)
- Impact assessment
- Your timeline preference (silent fix vs coordinated disclosure)

Knot3 Labs will respond within 7 days. We follow a 90-day coordinated disclosure window by default.

## Security checklist before deploying

- [ ] `daemon` runs as a dedicated low-privilege user (not root)
- [ ] `--cross-host-port 0` (default) OR if enabled, behind a firewall / WireGuard
- [ ] No real LLM API keys in environment when running demos
- [ ] Unix sockets in `/tmp/` are `0600`
- [ ] `state.json.db` is `0600` and backed up
- [ ] L1-L5 output directory (`/tmp/ghw_evolved/`) reviewed periodically
- [ ] launchd / systemd unit restricts `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`
- [ ] Reverse proxy (nginx / Caddy) in front of `ui_server` if exposed to LAN

## Hall of fame

We thank the following researchers for responsible disclosures:

(none yet — be the first!)

---

> Last updated: 2026-06-12. See `CHANGELOG.md` for security-related changes.
