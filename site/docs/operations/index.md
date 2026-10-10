# Deployment and Operations

GHW can run in three ways:

- Research/local mode: run `ui_server` directly.
- Embedded mode: the host product calls it via the C SDK.
- Long-running mode: managed by a daemon or service manager.

## Local UI

```bash
zig build
./zig-out/bin/ui_server --port 8765 --state /tmp/ghw.json --ui-dir ui
```

## Product Mode

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /var/lib/ghw/state.json \
  --ui-dir ui \
  --product-intent /etc/ghw/product_intent.json
```

Recommendations:

- Put `state.json` on a persistent volume.
- Manage `product_intent.json` through configuration management.
- Keep `/api/product/*` behind an intranet or authenticated proxy.

## LLM Configuration

```bash
DEEPSEEK_API_KEY=sk-xxx \
./zig-out/bin/ui_server \
  --llm deepseek \
  --llm-model deepseek-chat \
  --llm-key-env DEEPSEEK_API_KEY
```

Supported providers depend on the current `HttpLLM` implementation, including DeepSeek, OpenAI compatible, and Anthropic.

## Observability

HTTP:

- `/api/state`
- `/api/metrics`
- `/api/product/audit`
- `/api/tasks`

Logs:

- `ui_server` prints key events for LLM, tasks, product runtime, and state restore to stderr/stdout.

## Backups

Back up at least:

- state snapshot
- SQLite memory DB
- external copy of the product audit
- ProductIntent version history

## Upgrades

Before upgrading:

```bash
zig build test
zig build
zig build install-sdk
```

Post-upgrade checks:

```bash
curl http://127.0.0.1:8765/api/state
curl http://127.0.0.1:8765/api/product/runtime
```

## Production Gaps

Recommended additions:

- HTTP authentication.
- ProductAdapter.
- Signed audit.
- Multi-tenant isolation strategy.
- Long-running CI and regression matrix.
