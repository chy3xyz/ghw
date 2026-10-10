# Product Digital Life Foundation

GHW's product foundation goal: give a software product an evolution kernel that is auditable, approval-gated, rollback-capable, and continuously learning.

It does not let an agent directly modify a production system. Instead, it enforces a closed loop:

```text
ProductIntent
  -> KPI
  -> ChangeProposal
  -> Consent
  -> Apply / Rollback
  -> Audit
  -> Existence Degree
```

## Capabilities Already in Place

| Capability | Status | Entry point |
| --- | --- | --- |
| ProductIntent loading | Implemented | `product_intent.example.crm.json`, `--product-intent` |
| KPI feeding into E | Implemented | `KpiBridge`, `ghw_product_kpi_feed` |
| Change proposals | Implemented | `ProductEvolutionRuntime.proposeChange` |
| CRM canonical proposal | Implemented | `proposeCrmFollowupTightening` |
| Approval / denial | Implemented | `approve`, `deny` |
| Apply / rollback state machine | Implemented | `applyApproved`, `rollbackApplied` |
| Audit log | Implemented | `auditJson`, `/api/product/audit` |
| Persistence & recovery | Implemented | `product_runtime` state block |
| Real product Adapter | Planned | Requires host system implementation |

## Runtime Structure

`ProductEvolutionRuntime` holds:

- `product`: the read-only ProductIntent.
- `bridge`: the KPI Bridge, which turns raw product metrics into `K`.
- `changes`: the list of product change proposals.
- `audit`: the log of KPI refreshes, proposals, approvals, applies, and rollbacks.
- `next_change_id` / `next_audit_id`: monotonically increasing IDs across restarts.

## How to Enable

```bash
./zig-out/bin/ui_server \
  --state /tmp/ghw-product-state.json \
  --ui-dir ui \
  --product-intent product_intent.example.crm.json
```

Once enabled:

- `saveState` saves the `"product_runtime"` block.
- `changes` and `audit` are restored on startup.
- `/api/product/*` endpoints are available.

## Boundaries

Currently, `applyApproved` means "GHW has entered the applied state and written the audit entry"; it does not directly modify the host product. Production integration requires a product Adapter that maps approved changes onto:

- Configuration centers
- Feature flags
- Workflow rules
- Experiment platforms
- Code generation / deployment pipelines

This is the focus of the next phase of production-grade product work.
