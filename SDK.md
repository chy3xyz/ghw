# GHW SDK (Phase 3)

Lets any C/C++/Rust/Go product use GHW as a digital life kernel.

> **Looking for general docs?** See [`README.md`](README.md) (overview),
> [`ARCHITECTURE.md`](ARCHITECTURE.md) (4-layer + L1–L5 + 9-palace),
> [`FAQ.md`](FAQ.md) (common questions), and
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (failure modes).
>
> **This document is specifically about the C ABI (`libghw.a` + `ghw.h`).**
> The HTTP API (15+ endpoints exposed by `ui_server`) is documented in
> [`ARCHITECTURE.md#http-api`](ARCHITECTURE.md#http-api).

## Install the SDK

```bash
zig build install-sdk          # generates zig-out/include/ghw.h + zig-out/lib/libghw.a
```

## C client usage (v0.3 full pipeline)

```c
#include "ghw.h"

int main() {
    GhW* g = ghw_init("my-agent", 42);

    // 1. Configure the LLM (read the key from an env var; zero keys in source)
    ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");

    // 2. Open sqlite memory + ActionRunner
    ghw_open_memory(g, "/tmp/my-agent.db");

    // 3. Set the world (the C client formats it itself)
    ghw_world_set(g, "top_procs: claude 12%, node 8%\n...");

    // 4. Run cycles (triggers LLM proposals + automatic actions)
    for (int i = 0; i < 5; i++) {
        char* report = ghw_step(g, "{}");
        printf("%s\n", report);
        ghw_free_string(report);
    }

    // 5. LLM proposal + action + reflection (can be stepped individually)
    int n = ghw_propose(g);          // LLM proposes N goals
    char* ar = ghw_action_run(g);   // run 1 action (WASM/Claude/peer)
    ghw_reflect(g);                  // LLM writes self_narrative

    ghw_deinit(g);
}
```

## Compiling (from the user's perspective)

```bash
cc -O2 -I zig-out/include -L zig-out/lib -L /opt/homebrew/Cellar/sqlite/3.49.2/lib \
    my_app.c -lghw -lsqlite3 -o my_app
./my_app
```

> Note: libghw.a already bundles libsqlite3 (statically linked); the reason users
> also add `-lsqlite3` when linking is to satisfy libsqlite3's own dynamic fallback.
> The actual artifact has 0 runtime dependencies.

## C ABI interface (v0.3 — 15 functions)

| Category | Function | Purpose |
|------|------|------|
| Lifecycle | `ghw_init(agent_id, seed)` / `ghw_deinit(g)` | Create / release |
| Core | `ghw_step(g, world_json)` / `ghw_get_state(g)` | Run a cycle / get state |
| Accessor | `ghw_get_tick` / `ghw_get_E` / `ghw_version` | Cheap queries |
| Memory | `ghw_free_string(s)` / `ghw_increment_self_evolved(g)` | Free / external action hook |
| LLM | `ghw_setup_llm(g, provider, api_key_env, model)` | Configure LLM; key comes from an env var |
| Memory | `ghw_open_memory(g, path)` | Open sqlite + ActionRunner |
| Action | `ghw_action_run(g)` | Run 1 top unadopted goal |
| Link | `ghw_link_listen` / `ghw_link_query` / `ghw_link_stop` | Multi-GHW interconnection (Phase 1) |
| World | `ghw_world_set(g, world_text)` | Set the world description |
| Propose | `ghw_propose(g)` | LLM proposes goals (returns # proposed) |
| Reflect | `ghw_reflect(g)` | LLM writes self_narrative |

## Design principles

- **Opaque pointer** (`struct GhW`) — the internal implementation can evolve freely; the ABI stays stable
- **JSON-first** — world/cycle reports go through JSON; zero friction across languages
- **Errors return -1** (POSIX-style); no exceptions thrown
- **Clear string ownership** — the caller frees strings returned by ghw_* with ghw_free_string
- **Zero hard-coded keys** — `ghw_setup_llm(provider, api_key_env, model)` goes entirely through env vars
- **Zero runtime dependencies** — libghw.a bundles libsqlite3 via static linking; users have no runtime library requirements

## End-to-end demo

`examples/embed_demo_v3.c` — 130 lines of C; runs 5 cycles + LLM propose + action + reflect.

```bash
cc -O2 -I zig-out/include -L zig-out/lib -L /opt/homebrew/Cellar/sqlite/3.49.2/lib \
    examples/embed_demo_v3.c -lghw -lsqlite3 -o embed_demo_v3

DEEPSEEK_API_KEY=sk-xxx ./embed_demo_v3
# === GHW Embed Demo v0.3 (full SDK pipeline) ===
# version: ghw-sdk/0.1.0
# [1] ghw_init
# [2] ghw_setup_llm(deepseek): rc=0
# [3] ghw_open_memory: rc=0
# [4] ghw_world_set: ok
# [5] 5 cycles: E 0.487 → 0.502, self_evolved_total 0 → 4
# [6] ghw_propose: 3 goals
# [7] ghw_action_run: WASM compiled + ran, success
# [8] ghw_reflect: rc=0
# [9] Final: E=0.502, self_evolved_total=6
```

Works without an LLM too (no-LLM mode: propose/reflect return 0 / no-op).

## Current limitations (v0.3)

- ghw_reflect only updates self_narrative; parsing the beliefs array is left to v0.4
- after ghw_link_listen starts, the handler is the default (query_state); a custom callback API is left to v0.5
- LLM error messages are not exposed via the C ABI (Zig logs go to stderr)

## Roadmap (GHW's three phases)

- ✅ **Phase 1**: multi-GHW interconnection protocol (JSONL over Unix socket, 5 methods)
- ✅ **Phase 2**: Claude Code bridge (ActionRunner `claude_code` preset)
- ✅ **Phase 3**: GHW-as-kernel SDK (C ABI, libghw.a + ghw.h, 15 func)
  - ✅ v0.1: 8 func (init/step/state)
  - ✅ v0.2: +5 func (LLM/memory/action/link)
  - ✅ v0.3: +3 func (world/propose/reflect)

See `readme.md` §16 for details.
