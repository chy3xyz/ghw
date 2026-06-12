# GHW Link Protocol Specification

> The multi-agent peer protocol for the GHW digital life framework. Two or
> more GHW instances on the same machine can exchange state, beliefs, and
> actions over Unix Domain Sockets using a JSON-line protocol.
>
> **Version**: `ghw-link/0.1`
>
> **Transport**: Unix Domain Socket (one socket per GHW instance, typically
> at `/tmp/ghw_<peer_id>.sock`)
>
> **Format**: JSONL — one JSON object per line, terminated by `\n`

## Table of Contents

- [Overview](#overview)
- [Transport](#transport)
- [Wire format](#wire-format)
- [Methods](#methods)
- [Errors](#errors)
- [Reference client (Zig)](#reference-client-zig)
- [Reference client (Python)](#reference-client-python)
- [Reference client (curl / nc)](#reference-client-curl--nc)
- [Discovery](#discovery)
- [Health checks](#health-checks)
- [Security](#security)
- [Versioning](#versioning)

## Overview

GHW is designed to be a **multi-agent** framework — a single digital life
running alone is the trivial case. The **Link** protocol lets two or more
GHW instances cooperate:

- A **probing** GHW can ask a peer's state to update its own ΔE calculations.
- A **reflecting** GHW can read a peer's beliefs to find a different
  perspective.
- A **prescribing** GHW can inject an episode into a peer's memory, prompting
  the peer to attend to a new goal.

The protocol is intentionally **simple** (5 methods), **stateless** (each
request is independent), and **JSON-text** (debuggable with `tail -F` and
`jq`).

## Transport

- **Socket type**: Unix Domain Socket (`SOCK_STREAM`).
- **Default path**: `/tmp/ghw_<peer_id>.sock` (e.g., `/tmp/ghw_ghw-prod.sock`).
  Override via `--link <path>` flag.
- **Lifecycle**: each GHW instance creates its own socket on startup. The
  socket is **deleted and recreated** at startup (idempotent).
- **Permissions**: 0600 (owner-only read/write). Created by the running
  GHW process.

## Wire format

Each line is a single JSON object terminated by `\n` (no embedded newlines
in the JSON itself).

**Request** (client → server):

```json
{
  "id": "req_<random>",
  "method": "<method_name>",
  "params": { ... } // method-specific, see below
}
```

- `id`: required, client-generated, echoed in the response. Use a
  unique-per-request value (e.g., `"req_<counter>"` or UUID).
- `method`: required, one of the 5 methods below.
- `params`: optional, method-specific JSON object.

**Response** (server → client):

```json
{
  "id": "req_<random>",
  "ok": true,
  "result": { ... } // method-specific
}
```

or on error:

```json
{
  "id": "req_<random>",
  "ok": false,
  "error": "<error_message>"
}
```

- `id`: required, **must** match the request id.
- `ok`: required, boolean. `true` for success, `false` for error.
- `result`: present iff `ok=true`. Method-specific JSON.
- `error`: present iff `ok=false`. Human-readable error string.

## Methods

### 1. `ping` — liveness + version check

**Params**: `{}` (no parameters)

**Result**:

```json
{
  "peer_id": "ghw-prod",
  "version": "ghw-link/0.1",
  "uptime_s": 3600,
  "tick": 12345,
  "self_evolved_total": 42
}
```

**Errors**: none (always succeeds)

**Use case**: health check, version compatibility check, uptime tracking.

### 2. `query_state` — get current existence degree

**Params**: `{}` (no parameters; future: `{ "since_tick": 12340 }` for diff queries)

**Result**:

```json
{
  "tick": 12345,
  "E": 0.847,
  "M": 0.92,
  "R": 0.78,
  "N": 0.85,
  "top_goal": "reflect-on-9-palaces",
  "action_count": 342,
  "self_evolved_total": 42,
  "phase": 9,
  "phase_progress": 100,
  "nine_palaces_e_var": true,
  "nine_palaces_mrn": true,
  "nine_palaces_mrn_strong": false
}
```

**Use case**: ΔE cross-check (does my E differ from peer's?), peer
presence in E formula (Phase 1.8 `adaptFromPeers(peer_E_avg, own_E)`).

### 3. `query_beliefs` — read the peer's belief registry

**Params**: `{ "limit": 10 }` (default: 10, max: 100)

**Result**:

```json
[
  {
    "text": "9-palace 满宫状态数字生命才能达成",
    "source": "reflection",
    "confidence": 0.85,
    "evidence_count": 3
  },
  {
    "text": "M/R/N 平衡是 stable E 的前提",
    "source": "llm",
    "confidence": 0.72,
    "evidence_count": 1
  }
]
```

**Use case**: cross-pollination of beliefs. A peer's beliefs can
challenge or corroborate your own. Returns the highest-confidence N
beliefs.

### 4. `query_actions` — read the peer's recent action log

**Params**: `{ "limit": 20 }` (default: 20, max: 100)

**Result**:

```json
[
  {
    "id": 4711,
    "tick": 12345,
    "kind": "wasm",
    "input": "test 5 + 3",
    "output": "8",
    "result": "ok",
    "duration_ms": 234
  },
  {
    "id": 4710,
    "tick": 12340,
    "kind": "peer_query",
    "input": "{\"peer\":\"/tmp/ghw_alpha.sock\",\"method\":\"ping\"}",
    "output": "{\"ok\":true,\"result\":{...}}",
    "result": "ok",
    "duration_ms": 56
  }
]
```

**Use case**: pattern detection. "Did the peer try a similar action that
failed? Don't repeat their mistake."

### 5. `inject_event` — write an episode to the peer's memory

**Params**:

```json
{
  "text": "peer ghw-prod 提议提升 mu 0.6 (来自 query_state E 0.5)",
  "importance": 0.7
}
```

- `text`: required, the episode content (≤ 1 KB recommended)
- `importance`: optional, 0..1 (default 0.5). Higher importance → faster
  attended by the peer's attention engine.

**Result**:

```json
{
  "episode_id": 4789,
  "tick": 12346
}
```

**Use case**: cross-agent goal injection. Peer A finds that peer B's
E is dropping; A injects a high-importance episode into B suggesting
"re-evaluate top goal". B's next attention cycle surfaces that episode.

**Security note**: this is the only method that **writes** to the peer.
A production deployment should restrict this method via ACL (see
[Security](#security)).

## Errors

Common error responses:

| `error` | Cause | Recovery |
|---------|-------|----------|
| `"unknown method: <name>"` | Method not in the 5 supported | Client bug, check method name |
| `"invalid params: ..."` | JSON parse error or missing required field | Client bug, validate params |
| `"internal error: ..."` | Server-side panic (very rare) | Retry with backoff |
| `"connection closed"` | Server crashed or socket deleted | Re-discover peer, retry |

Error responses use the same `id` as the request, so the client can match
them.

## Reference client (Zig)

```zig
const std = @import("std");
const Link = @import("ghw").harness.ghw_link.Link;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const io = std.Io.Threaded.init(alloc);
    defer io.deinit();

    var link = Link.init(alloc, io, "/tmp/ghw_self.sock");
    // ... (start server in a thread)

    // Query a peer
    const resp = try link.query("/tmp/ghw_other.sock", "ping", "{}");
    defer alloc.free(resp);

    // Parse the response (Zig std.json, or your preferred JSON parser)
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    std.debug.print("peer says: {s}\n", .{parsed.value});
}
```

## Reference client (Python)

```python
import json
import socket
import uuid

def ghw_query(peer_path: str, method: str, params: dict) -> dict:
    """Send a single request to a peer and return the parsed response."""
    req = {
        "id": f"req_{uuid.uuid4().hex[:8]}",
        "method": method,
        "params": params,
    }
    line = (json.dumps(req) + "\n").encode()

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        s.connect(peer_path)
        s.sendall(line)
        # Read until newline
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())

# Example
resp = ghw_query("/tmp/ghw_alpha.sock", "ping", {})
print(f"peer says: tick={resp['result']['tick']}, E={resp['result']['E']:.3f}")

resp = ghw_query("/tmp/ghw_bravo.sock", "inject_event", {
    "text": "GHW alpha 提议你 reflect on 9-palaces",
    "importance": 0.8,
})
print(f"injected episode: id={resp['result']['episode_id']}")
```

## Reference client (curl / nc)

You can debug a peer with `nc` (netcat) and `jq`:

```bash
# Send a ping
echo '{"id":"req_1","method":"ping","params":{}}' | nc -U /tmp/ghw_alpha.sock

# Pretty-print the response
echo '{"id":"req_2","method":"query_state","params":{}}' | \
    nc -U /tmp/ghw_bravo.sock | jq .

# Inject an event
echo '{"id":"req_3","method":"inject_event","params":{"text":"debug test","importance":0.3}}' | \
    nc -U /tmp/ghw_charlie.sock | jq .
```

This is invaluable for debugging. You can inspect the peer's state
without writing any code.

## Discovery

GHW instances discover each other via a **peer registry** at
`~/.local/share/ghw/peers.txt` (one path per line, `#` for comments):

```
# My dev cluster
/tmp/ghw_alpha.sock
/tmp/ghw_bravo.sock
/tmp/ghw_charlie.sock
```

**Format**: one socket path per line, blank lines and lines starting with
`#` are ignored.

**How to use**: launch a peer with `--peers-file <path>`. On startup,
the peer reads the registry and pings each known peer. New peers can
be added by appending to the file; the next ping sweep (every 30s)
will discover them.

**Auto-registration**: a peer can also register itself by appending
its own socket path to the registry. This is opt-in via
`--register-self` flag.

## Health checks

Every GHW instance runs a **background ping thread** (configurable
interval, default 30s). The thread:

1. Reads the peer registry.
2. For each known peer, sends a `ping` request with a 5s timeout.
3. Updates the peer's `last_seen_tick` (Unix timestamp of last
   successful ping) and `health` (one of: `healthy`, `stale`,
   `unreachable`).

A peer is `stale` if no successful ping in the last 3 intervals (90s
by default). It's `unreachable` after 10 consecutive failures.

The `/api/peers` endpoint returns the current health status for each
peer. The UI shows stale peers in amber and unreachable in red.

## Security

**Current state**: any process running as the same user as the GHW
instance can connect to the socket and call any method (including
`inject_event`). This is acceptable for **single-user development** and
**trusted multi-agent deployments**.

**Production hardening** (not yet implemented):

1. **Socket permissions**: 0600 (owner-only). Set explicitly in
   `ghw_link.zig:runServer`.
2. **Peer ACL**: a list of allowed `peer_id`s for `inject_event`.
   Configured via `--acl-file <path>`.
3. **Method authentication**: HMAC-signed request id, verified by the
   server. Configured via `--shared-secret <secret>`.
4. **Audit log**: every `inject_event` is logged to the peer's
   episodes with `source=peer:<peer_id>` for traceability.
5. **Rate limiting**: per-peer request rate limit (e.g., 10/sec).
   Prevents a runaway peer from flooding another.

These are tracked in [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md#known-limitations)
and will be implemented in a future version.

## Versioning

The protocol version is a single string (`ghw-link/0.1`). The version
is bumped on **incompatible** changes (different method signatures,
different field names, different transport).

- `ghw-link/0.1` (current): initial release
- `ghw-link/0.2` (future): may add authentication, more methods
- `ghw-link/1.0` (future): when stable, after 6+ months of production
  use

Clients should always check the `version` field in `ping` response
and refuse to communicate with a peer at a higher major version.
