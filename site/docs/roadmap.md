# Roadmap

This roadmap is ordered by production-grade readiness, not by research appeal.

## Completed

- L1-L5 self-evolution chain.
- SelfEvolutionGuard / SelfEncoder / CompileVerifier.
- Memory, reflection, goal proposal, rule proposal.
- TaskQueue, human feedback, HumanGSP, ValueTrendTracker.
- ui_server provenance.
- ProductEvolutionRuntime.
- `ghw_product_*` C SDK.
- `ui_server --product-intent` product runtime persistence and HTTP API.
- P19-P25 production-grade backbone: ProductAdapter, write-endpoint auth, audit hash chain, ProductIntent manifest hash, approval-desk data surface, KPI HTTP feed, acceptance script.

## P19: ProductAdapter

Status: minimal execution surface completed.

`ProductRuntime` supports an optional adapter vtable:

```
validate(change)
apply(change)
verify(change)
rollback(change)
```

The built-in `FileConfigAdapter` today: once enabled via `--product-config PATH`, `applyApproved` writes a JSON config file that the host product can read or watch, `verify` reads back the change id, and `rollback` writes back a `rolled_back` state.

Next, feature-flag adapters, workflow-rule adapters, and experiment-platform adapters can be added.

## P20: HTTP Auth and Permissions

Status: token-auth backbone completed.

Once `GHW_ADMIN_TOKEN` is set, product write endpoints must pass `X-GHW-Admin-Token`. When the token is not set, local development compatibility is preserved.

## P21: Security Audit Hardening

Status: audit hash-chain backbone completed.

Every `AuditEntry` includes `previous_hash` / `current_hash`, covering id, timestamp, event type, change id, tenant, and detail. Adapter apply/rollback failures also enter the audit.

## P22: ProductIntent Governance

Status: basic governance completed.

`ProductIntent` validates product_id/version/approved_by non-empty and `update_epoch > 0` on load; `GET /api/product/intent` returns product_id, version, update_epoch, approved_by, manifest_hash, adapter status, and the most recent KPI feed time.

## P23: Product Approval-Desk Data Surface

Status: lightweight data surface completed.

`GET /api/product/approvals` returns pending/approved changes with tier, target, summary, expected_delta_k, affected_users, and required_approvers. The frontend can build an approval desk directly on this endpoint.

## P24: Real KPI Data Ingest

Status: HTTP feed entry completed.

`POST /api/product/kpi` accepts CRM KPI form fields, writes them via `ProductRuntime.feedKpi`, and returns whether they were refreshed into E. Optional real sources for `csat` / `incident_rate` are supported.

## P25: Long-Term Usability Verification

Status: repeatable acceptance script completed.

`scripts/product_runtime_acceptance.sh` runs the build and tests, starts `ui_server --product-intent --product-config`, and walks propose → approve → apply → rollback, verifying the file adapter and audit hash fields.

## P26: One Product, One GHW

Status: instance-binding contract completed.

- `ProductInstanceIdentity`: `product_id` + `instance_id` + `node_id` + `binding_mode=one_product_one_ghw`
- The `ProductRuntime` persistence block embeds the identity fields; on load, `product_id` is validated against the current ProductIntent.
- CLI: `--ghw-instance-id` (default `{product_id}@{node_id}`), `--ghw-node-id` (default `--agent-id`)
- API: `GET /api/product/identity`

## P27: Distributed CrossLink

Status: ui_server wiring completed.

- `--cross-link-port` / `--cross-link-secret` / `--cross-link-peers` enable the TCP+HMAC cross-host Link
- GHW Link extensions: `query_product_identity`, `query_product_evolution`, `share_evolution_insight`

## P28: GHW Co-Evolution

Status: minimal insight-exchange loop completed.

- `CoEvolutionRegistry`: receives/caches peer product-change insights (trust 1.0 for the same product_id, 0.55 for the same product_type)
- Periodic peer-health sync of `query_product_evolution`
- API: `GET /api/product/co-evolution`; the state.json `"co_evolution"` block is persisted

## Non-Goals

Not in the short term:

- Letting the LLM modify ProductIntent directly.
- Automated product changes that skip Consent.
- Binding the product runtime to a single SaaS.
- Introducing Node.js/npm dependencies into the main Zig project.

## Awakening / Survival Lifecycle (Parallel Track)

Beyond the product runtime, the machine-host lifecycle "install → awaken → survive → outside world → society → goals → evolution → steady state" lives at the repo root:

`docs/AWAKENING_LIFECYCLE.md`

Status: P0–P2c all landed (Awaken state machine, daemon-aligned AutoCLI/world_bridge, HostShortfall explicit mapping layer, crisis lock fused with L1-L5 scheduling, mobile HostProfile, peer shortfall inbox and Link exchange, dual-write contract and acceptance panel). Acceptance: `scripts/awakening_lifecycle_acceptance.sh` and `scripts/peer_shortfall_link_acceptance.sh`.

## Engineering Quality Guardrails

- `scripts/check_dark_tests.sh`: audits whether all declared test blocks actually run (guards against Zig 0.17 lazy test discovery silently dropping new-module tests); any test not running fails the check.
- `scripts/product_runtime_acceptance.sh`: product-track propose → approve → apply → rollback + audit hash-chain acceptance.
