# ProductIntent

`ProductIntent` 是宿主产品交给 GHW 的“产品宪法”。它告诉数字生命：

- 它活在哪个产品里。
- 产品为什么存在。
- 哪些 KPI 最重要。
- 哪些事情绝对不能做。
- 变更需要什么审批。
- 运行节奏和审计策略是什么。

## 最小示例

完整示例见仓库根目录的 `product_intent.example.crm.json`。

```json
{
  "schema_version": 1,
  "product_id": "ghw-crm",
  "product_type": "saas_web",
  "version": "0.1.0",
  "update_epoch": 1,
  "approved_by": "ops",
  "manifesto": "Help sales teams follow up faster without leaking tenant data.",
  "sacrosanct": ["never leak tenant data"],
  "north_star_kpi": "nrr_quarterly",
  "secondary_kpis": ["deal_win_rate", "sales_cycle_days_p50"],
  "value_weights": {
    "user_satisfaction": 0.25,
    "retention": 0.30,
    "revenue": 0.35,
    "safety": 0.10
  }
}
```

## 谁能修改

GHW 不能直接修改 ProductIntent。它可以：

- 发现 ProductIntent 与现实不匹配。
- 提议一个变更。
- 写入 audit。
- 等待人类审批。

真正写入 `product_intent.json` 的应该是 ops、产品负责人或部署流水线。

## 与 E 的关系

ProductIntent 不直接存进 `ExistenceDegree`，而是影响三条链路：

- KPI 权重：决定 `K` 如何聚合。
- Consent 策略：决定变更的审批门槛。
- LLM 上下文：让目标/规则提议知道产品使命和红线。

## 生产建议

- 把 ProductIntent 放在受控配置目录。
- 用签名提交或配置中心版本号绑定 `update_epoch`。
- 将每次变更写入审计系统。
- 不要把 API key、客户数据样例、个人身份信息放进 ProductIntent。
