# 部署与运行

GHW 可以以三种方式运行：

- 研究/本地模式：直接跑 `ui_server`。
- 嵌入模式：宿主产品通过 C SDK 调用。
- 长跑模式：daemon 或服务管理器托管。

## 本地 UI

```bash
zig build
./zig-out/bin/ui_server --port 8765 --state /tmp/ghw.json --ui-dir ui
```

## 产品模式

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /var/lib/ghw/state.json \
  --ui-dir ui \
  --product-intent /etc/ghw/product_intent.json
```

建议：

- `state.json` 放在持久卷。
- `product_intent.json` 走配置管理。
- `/api/product/*` 放在内网或认证代理后面。

## LLM 配置

```bash
DEEPSEEK_API_KEY=sk-xxx \
./zig-out/bin/ui_server \
  --llm deepseek \
  --llm-model deepseek-chat \
  --llm-key-env DEEPSEEK_API_KEY
```

支持的 provider 取决于 `HttpLLM` 当前实现，包括 DeepSeek、OpenAI compatible 和 Anthropic。

## 观测

HTTP:

- `/api/state`
- `/api/metrics`
- `/api/product/audit`
- `/api/tasks`

日志：

- `ui_server` 会把 LLM、任务、product runtime、state restore 关键事件打印到 stderr/stdout。

## 备份

至少备份：

- state snapshot
- SQLite memory DB
- product audit 外部副本
- ProductIntent 历史版本

## 升级

升级前：

```bash
zig build test
zig build
zig build install-sdk
```

升级后检查：

```bash
curl http://127.0.0.1:8765/api/state
curl http://127.0.0.1:8765/api/product/runtime
```

## 生产缺口

当前还建议补：

- HTTP 鉴权。
- ProductAdapter。
- 签名审计。
- 多租户隔离策略。
- CI 长跑和回归矩阵。
