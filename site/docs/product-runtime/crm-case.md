# CRM 场景

CRM 是 GHW 获取产品存在度的第一个完整场景。它证明 GHW 可以把产品 KPI、变更提案、审批和审计接入同一条生命循环。

## 场景目标

让 CRM 产品中的数字生命关注：

- 客户留存是否变好。
- 销售跟进是否更及时。
- 成交率是否提升。
- 事故率和客户满意度是否可接受。

## 样板变更

当前内置 canonical proposal：

```text
Tighten follow-up cadence from 7d to 5d
```

对应目标是缩短销售跟进间隔，预期提升 win rate 和 NRR。

## 运行方式

```bash
./zig-out/bin/ui_server \
  --port 8765 \
  --state /tmp/ghw-crm-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

提交提案：

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

查询完整状态：

```bash
curl http://127.0.0.1:8765/api/product/runtime
```

## 当前实现和旧 demo 的关系

早期 `docs/CASE_CRM.md` 描述的是 Python demo orchestrator。现在主线已经把核心产品 runtime 迁回 Zig：

- `src/harness/product_runtime.zig`
- `src/harness/crm_kpi.zig`
- `src/harness/kpi_bridge.zig`
- `src/harness/consent.zig`
- `examples/ui_server.zig` 的 `/api/product/*`
- `ghw.h` 的 `ghw_product_*` SDK

Python demo 可以继续作为解释性材料，但 Zig 模块是生产语义来源。

## 下一步

CRM 场景要达到真实产品可用，还需要接入：

- 真实 CRM 数据源。
- 真实 ProductAdapter。
- 多租户权限和审批身份。
- 指标异常告警。
- 应用后验证，比如跟踪 7/14/30 天 KPI 是否改善。
