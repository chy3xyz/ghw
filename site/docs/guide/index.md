# Quick Start

This page is for developers running GHW for the first time. You can treat it as three entry points: local build, starting the UI, and running in product runtime mode.

## Prerequisites

- Zig `0.17.0` stable (also compatible with `0.17.0-dev.2151+`; minimum `0.17.0-dev.813`).
- macOS or Linux. WSL2 is recommended on Windows.
- Optional: an LLM API key, for real reflection, goal proposal, rule proposal, and template enhancement.
- Optional: SQLite/wasmtime, depending on whether you use the memory store and the WASM sandbox.

## Build and Test

```bash
zig build
zig build test
zig build install-sdk
```

These commands respectively verify:

- `zig build`: builds the main library and the example binaries.
- `zig build test`: runs the Zig unit tests, including ProductRuntime roundtrips, self-evolution verification, and the memory/task/feedback loops.
- `zig build install-sdk`: generates `zig-out/include/ghw.h` and `zig-out/lib/libghw.a`.

## Start the UI Server

Minimal mode:

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-ui-state.json \
  --ui-dir ui
```

With LLM enabled:

```bash
DEEPSEEK_API_KEY=sk-xxx \
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-ui-state.json \
  --ui-dir ui \
  --llm deepseek \
  --llm-model deepseek-chat \
  --llm-key-env DEEPSEEK_API_KEY
```

With the product runtime enabled:

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-product-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

After startup, open `http://127.0.0.1:8765`.

## Try the Product Change Loop

Submit the CRM sample proposal:

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

Approve, apply, and roll back:

```bash
curl -X POST http://127.0.0.1:8765/api/product/approve \
  -d 'change_id=1&approver=sales_manager&note=approved'

curl -X POST http://127.0.0.1:8765/api/product/apply \
  -d 'change_id=1'

curl -X POST http://127.0.0.1:8765/api/product/rollback \
  -d 'change_id=1'
```

Query the audit:

```bash
curl http://127.0.0.1:8765/api/product/audit
curl http://127.0.0.1:8765/api/product/runtime
```

## Embed the C SDK

```bash
zig build install-sdk
cc -O2 -I zig-out/include -L zig-out/lib \
  examples/embed_demo_v3.c -lghw -lsqlite3 -o embed_demo_v3
```

For more details, see the [C SDK](/api/sdk).

## Awakening and Survival

For the ideal narrative, architectural boundaries, and implementation gaps of "how to live as a digital life" after installation, see the repository:

`docs/AWAKENING_LIFECYCLE.md`
