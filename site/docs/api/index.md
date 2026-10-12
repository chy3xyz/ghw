---
order: 3
---

# API

GHW exposes the product runtime and the digital life loop through two interfaces:

- [HTTP API](http.md) — the `ui_server` REST surface for state, chat, tasks, human feedback, product runtime, and metrics.
- [C SDK](sdk.md) — the `ghw_*` C ABI for embedding GHW in a host product.
- [State Persistence](state.md) — the `state.json` layout, atomic writes, and what is restored on restart.

Both interfaces are entry points onto the same runtime: the C SDK exports it as a
C ABI for embedding, while `ui_server` exposes it over HTTP for monitoring and control.
