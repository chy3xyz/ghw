# GHW SDK (Phase 3)

让任何 C/C++/Rust/Go 产品把 GHW 当数字生命内核用.

> **Looking for general docs?** See [`README.md`](README.md) (overview),
> [`ARCHITECTURE.md`](ARCHITECTURE.md) (4-layer + L1–L5 + 9-palace),
> [`FAQ.md`](FAQ.md) (common questions), and
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (failure modes).
>
> **This document is specifically about the C ABI (`libghw.a` + `ghw.h`).**
> The HTTP API (15+ endpoints exposed by `ui_server`) is documented in
> [`ARCHITECTURE.md#http-api`](ARCHITECTURE.md#http-api).

## 装 SDK

```bash
zig build install-sdk          # 生成 zig-out/include/ghw.h + zig-out/lib/libghw.a
```

## C 客户端用法 (v0.3 完整 pipeline)

```c
#include "ghw.h"

int main() {
    GhW* g = ghw_init("my-agent", 42);

    // 1. 配 LLM (用 env var 拿 key, 源码零密钥)
    ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");

    // 2. 开 sqlite 记忆 + ActionRunner
    ghw_open_memory(g, "/tmp/my-agent.db");

    // 3. 设世界 (C 客户端自己格式化)
    ghw_world_set(g, "top_procs: claude 12%, node 8%\n...");

    // 4. 跑 cycle (会触发 LLM 提议 + 自动行动)
    for (int i = 0; i < 5; i++) {
        char* report = ghw_step(g, "{}");
        printf("%s\n", report);
        ghw_free_string(report);
    }

    // 5. LLM 提议 + 行动 + 反思 (可分步调)
    int n = ghw_propose(g);          // LLM 提议 N 个 goals
    char* ar = ghw_action_run(g);   // 跑 1 个 action (WASM/Claude/peer)
    ghw_reflect(g);                  // LLM 写 self_narrative

    ghw_deinit(g);
}
```

## 编译 (用户视角)

```bash
cc -O2 -I zig-out/include -L zig-out/lib -L /opt/homebrew/Cellar/sqlite/3.49.2/lib \
    my_app.c -lghw -lsqlite3 -o my_app
./my_app
```

> 注: libghw.a 已 bundle libsqlite3 (静态链接), 用户 link 时也加 `-lsqlite3` 是为了满足
> libsqlite3 自带的 dynamic fallback. 实际产物是 0 运行时依赖.

## C ABI 接口 (v0.3 — 15 个 func)

| 分类 | 函数 | 作用 |
|------|------|------|
| Lifecycle | `ghw_init(agent_id, seed)` / `ghw_deinit(g)` | 创建/释放 |
| Core | `ghw_step(g, world_json)` / `ghw_get_state(g)` | 跑 cycle / 取 state |
| Accessor | `ghw_get_tick` / `ghw_get_E` / `ghw_version` | 廉价查询 |
| Memory | `ghw_free_string(s)` / `ghw_increment_self_evolved(g)` | 释放 / 外部行动钩子 |
| LLM | `ghw_setup_llm(g, provider, api_key_env, model)` | 配 LLM, key 走 env var |
| Memory | `ghw_open_memory(g, path)` | 开 sqlite + ActionRunner |
| Action | `ghw_action_run(g)` | 跑 1 个 top unadopted goal |
| Link | `ghw_link_listen` / `ghw_link_query` / `ghw_link_stop` | 多 GHW 互联 (Phase 1) |
| World | `ghw_world_set(g, world_text)` | 设世界描述 |
| Propose | `ghw_propose(g)` | LLM 提议 goals (返 # 提议) |
| Reflect | `ghw_reflect(g)` | LLM 写 self_narrative |

## 设计原则

- **Opaque pointer** (`struct GhW`) — 内部实现自由演进, ABI 稳定
- **JSON 优先** — world/cycle report 走 JSON, 跨语言零摩擦
- **错误返回 -1** (类似 POSIX), 不抛异常
- **字符串所有权清晰** — ghw_* 返回的 caller 用 ghw_free_string 释放
- **零硬编码密钥** — `ghw_setup_llm(provider, api_key_env, model)` 全走 env
- **零运行时依赖** — libghw.a bundle libsqlite3 静态链接, 用户无运行时库要求

## 端到端 demo

`examples/embed_demo_v3.c` — 130 行 C, 跑 5 cycle + LLM propose + action + reflect.

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

无 LLM 也跑得通 (no-LLM 模式, propose/reflect 返 0/无变化).

## 当前限制 (v0.3)

- ghw_reflect 只更新 self_narrative, beliefs 数组解析留 v0.4
- ghw_link_listen 启动后 handler 是默认 (query_state), 自定义 callback API 留 v0.5
- LLM 错误信息不暴露 C ABI (Zig log 走 stderr)

## 路线图 (GHW 三阶段)

- ✅ **Phase 1**: 多 GHW 互联协议 (JSONL over Unix socket, 5 method)
- ✅ **Phase 2**: Claude Code 桥 (ActionRunner `claude_code` preset)
- ✅ **Phase 3**: GHW-as-kernel SDK (C ABI, libghw.a + ghw.h, 15 func)
  - ✅ v0.1: 8 func (init/step/state)
  - ✅ v0.2: +5 func (LLM/memory/action/link)
  - ✅ v0.3: +3 func (world/propose/reflect)

详见 `readme.md` §16.
