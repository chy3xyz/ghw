# 快速开始

这一页面向第一次运行 GHW 的开发者。你可以把它当作三个入口：本地构建、启动 UI、以产品底座模式运行。

## 前置条件

- Zig `0.17.0-dev`，当前项目在 `0.17.0-dev.813+` 上验证过。
- macOS 或 Linux。Windows 建议使用 WSL2。
- 可选：LLM API key，用于真实反思、目标提议、规则提议和模板增强。
- 可选：SQLite/wasmtime，取决于你是否使用记忆库和 WASM sandbox。

## 构建和测试

```bash
zig build
zig build test
zig build install-sdk
```

这些命令分别验证：

- `zig build`：构建主库和示例二进制。
- `zig build test`：运行 Zig 单测，包括 ProductRuntime roundtrip、自演化验证、记忆/任务/反馈闭环。
- `zig build install-sdk`：生成 `zig-out/include/ghw.h` 与 `zig-out/lib/libghw.a`。

## 启动 UI Server

最小模式：

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-ui-state.json \
  --ui-dir ui
```

开启 LLM：

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

开启产品运行时：

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-product-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

启动后访问 `http://127.0.0.1:8765`。

## 试跑产品变更闭环

提交 CRM 样板提案：

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

审批、应用、回滚：

```bash
curl -X POST http://127.0.0.1:8765/api/product/approve \
  -d 'change_id=1&approver=sales_manager&note=approved'

curl -X POST http://127.0.0.1:8765/api/product/apply \
  -d 'change_id=1'

curl -X POST http://127.0.0.1:8765/api/product/rollback \
  -d 'change_id=1'
```

查询审计：

```bash
curl http://127.0.0.1:8765/api/product/audit
curl http://127.0.0.1:8765/api/product/runtime
```

## 嵌入 C SDK

```bash
zig build install-sdk
cc -O2 -I zig-out/include -L zig-out/lib \
  examples/embed_demo_v3.c -lghw -lsqlite3 -o embed_demo_v3
```

更多说明见 [C SDK](/api/sdk)。
