# C SDK

GHW 提供 C ABI，让 C/C++/Rust/Go 等宿主产品把 GHW 当数字生命内核嵌入。

## 安装

```bash
zig build install-sdk
```

产物：

```text
zig-out/include/ghw.h
zig-out/lib/libghw.a
```

## 生命周期

```c
GhW* g = ghw_init("my-product-life", 42);
// ...
ghw_deinit(g);
```

所有 `char*` 返回值用 `ghw_free_string` 释放。

```c
char* state = ghw_get_state(g);
puts(state);
ghw_free_string(state);
```

## LLM 与记忆

```c
ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");
ghw_open_memory(g, "/tmp/ghw.db");
ghw_world_set(g, "top_procs: ui_server 3%, queue healthy");
```

API key 只通过环境变量读取，不写入源码。

## 核心循环

```c
char* report = ghw_step(g, "{}");
printf("%s\n", report);
ghw_free_string(report);
```

也可以分步调用：

```c
int n = ghw_propose(g);
char* action = ghw_action_run(g);
ghw_reflect(g);
ghw_free_string(action);
```

## KPI Bridge

裸 KPI bridge：

```c
ghw_kpi_configure(g, 24, 1, 0.25f, 0.30f, 0.35f, 0.10f);
int updated = ghw_kpi_feed(g, 0.92f, 0.24f, 42.0f, 0.80f, NAN, 0.01f, now);
double k = ghw_kpi_composite(g);
```

产品 runtime 模式优先使用 `ghw_product_kpi_feed`，因为它会写 audit。

## 产品运行时 SDK

```c
int rc = ghw_product_intent_load(g, "product_intent.example.crm.json");
```

喂 KPI：

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

提交、审批、应用、回滚：

```c
int64_t change_id = ghw_product_propose_crm_followup(g, "acme", 30, 0.04f, now);
ghw_product_approve_change(g, change_id, "sales_manager", "safe to try", now + 10);
ghw_product_apply_change(g, change_id, now + 20);
ghw_product_rollback_change(g, change_id, now + 30);
```

审计：

```c
char* audit = ghw_product_audit_json(g);
puts(audit);
ghw_free_string(audit);
```

## 错误处理

函数通常返回：

- `0`：成功。
- `1`：成功并发生更新，例如 KPI 写入 E。
- `-1`：失败。
- `NULL`：字符串返回失败。

失败后调用：

```c
const char* err = ghw_last_error(g);
```

## ABI 原则

- `GhW` 是 opaque handle。
- 结构体细节不暴露给 C。
- 字符串所有权明确。
- JSON 作为跨语言数据边界。
- 产品变更必须通过审批和审计。
