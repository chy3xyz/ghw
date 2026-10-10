# C SDK

GHW exposes a C ABI so that host products written in C/C++/Rust/Go can embed GHW as a digital life kernel.

## Installation

```bash
zig build install-sdk
```

Artifacts:

```text
zig-out/include/ghw.h
zig-out/lib/libghw.a
```

## Lifecycle

```c
GhW* g = ghw_init("my-product-life", 42);
// ...
ghw_deinit(g);
```

All `char*` return values must be released with `ghw_free_string`.

```c
char* state = ghw_get_state(g);
puts(state);
ghw_free_string(state);
```

## LLM and Memory

```c
ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");
ghw_open_memory(g, "/tmp/ghw.db");
ghw_world_set(g, "top_procs: ui_server 3%, queue healthy");
```

API keys are only read from environment variables and are never hardcoded in source code.

## Core Loop

```c
char* report = ghw_step(g, "{}");
printf("%s\n", report);
ghw_free_string(report);
```

You can also call the steps individually:

```c
int n = ghw_propose(g);
char* action = ghw_action_run(g);
ghw_reflect(g);
ghw_free_string(action);
```

## KPI Bridge

Raw KPI bridge:

```c
ghw_kpi_configure(g, 24, 1, 0.25f, 0.30f, 0.35f, 0.10f);
int updated = ghw_kpi_feed(g, 0.92f, 0.24f, 42.0f, 0.80f, NAN, 0.01f, now);
double k = ghw_kpi_composite(g);
```

In product runtime mode, prefer `ghw_product_kpi_feed`, because it also writes an audit entry.

## Product Runtime SDK

```c
int rc = ghw_product_intent_load(g, "product_intent.example.crm.json");
```

Feed the KPI:

```c
int updated = ghw_product_kpi_feed(
  g,
  0.92f,
  0.24f,
  42.0f,
  0.80f,
  NAN,
  0.01f,
  now
);
```

Propose, approve, apply, rollback:

```c
int64_t change_id = ghw_product_propose_crm_followup(g, "acme", 30, 0.04f, now);
ghw_product_approve_change(g, change_id, "sales_manager", "safe to try", now + 10);
ghw_product_apply_change(g, change_id, now + 20);
ghw_product_rollback_change(g, change_id, now + 30);
```

Audit:

```c
char* audit = ghw_product_audit_json(g);
puts(audit);
ghw_free_string(audit);
```

## Error Handling

Functions typically return:

- `0`: success.
- `1`: success with an update, e.g. the KPI written into E.
- `-1`: failure.
- `NULL`: failed string return.

After a failure, call:

```c
const char* err = ghw_last_error(g);
```

## ABI Principles

- `GhW` is an opaque handle.
- Struct internals are not exposed to C.
- String ownership is explicit.
- JSON serves as the cross-language data boundary.
- Product changes must go through approval and audit.
