# 安全边界

GHW 的安全模型建立在一句话上：**LLM 可以提议，但不能越权应用。**

## 核心边界

| 边界 | 机制 |
| --- | --- |
| 代码生成 | `SelfEvolutionGuard` + `CompileVerifier` |
| 规则采纳 | `SelfEncoder.verify` |
| 产品变更 | `Consent` + `Audit` |
| 产品意图 | 人类/ops 管理，GHW 不能直接写 |
| API key | 环境变量，不写入源码 |
| 状态恢复 | JSON block 解析，缺块不报错 |

## LLM 红线

LLM 输出不能绕过：

- 危险构造黑名单。
- 文件路径白名单。
- E 公式公理。
- ProductIntent。
- Consent。

含 `@panic`、`unreachable`、内核修改、人类伤害等构造会被拒绝。

## 产品变更红线

生产接入时，以下必须保留：

- 非 minor 变更进入审批。
- apply 和 rollback 都写 audit。
- 产品 runtime 的 audit 同步到外部审计系统。
- ProductIntent 由人类或受控配置流程更新。

## HTTP API

当前内置 HTTP server 适合本地和内网调试。生产建议：

- 加反向代理认证。
- 限制 `/api/product/*` 的写接口。
- 对 `POST /api/chat`、`POST /api/tasks` 做速率限制。
- 不把 state 和 memory 暴露给公网。

## 状态文件

state 和 SQLite 可能包含：

- 自我叙事。
- 业务上下文。
- 人类反馈。
- 产品变更审计。

建议权限：

```bash
chmod 700 /var/lib/ghw
chmod 600 /var/lib/ghw/state.json
```

## 下一阶段安全工作

- ProductIntent 签名校验。
- Audit hash chain。
- 角色权限模型。
- ProductAdapter 幂等和回滚校验。
- 多租户数据隔离。
