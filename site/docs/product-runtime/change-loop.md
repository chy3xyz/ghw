# Change, Approval, and Audit

The core of the product runtime is turning "I want to change the product" into a governable state machine.

## State Machine

```
proposed / pending_consent
  -> approved
  -> applied
  -> rolled_back

pending_consent
  -> denied
```

Minor changes can go directly to `approved`; non-minor changes enter `pending_consent` by default.

## Proposal Fields

`ChangeProposal` stores:

- `tenant_id`
- `kind`: `config`, `workflow`, `feature_flag`, `code_patch`, `experiment`
- `target`
- `summary`
- `rationale`
- `expected_delta_k`
- `affected_users`
- `reversible`
- `tier`
- `risk`
- `status`
- `created_at`
- approver and approval note

## HTTP Operations

Submit the CRM sample proposal:

```bash
curl -X POST http://127.0.0.1:8765/api/product/propose-crm-followup \
  -d 'tenant_id=acme&affected_users=30&expected_delta_k=0.04'
```

Approval:

```bash
curl -X POST http://127.0.0.1:8765/api/product/approve \
  -d 'change_id=1&approver=sales_manager&note=approved'
```

Apply:

```bash
curl -X POST http://127.0.0.1:8765/api/product/apply \
  -d 'change_id=1'
```

Rollback:

```bash
curl -X POST http://127.0.0.1:8765/api/product/rollback \
  -d 'change_id=1'
```

Query:

```bash
curl http://127.0.0.1:8765/api/product/runtime
curl http://127.0.0.1:8765/api/product/audit
```

## Audit Events

The audit log includes:

- `kpi_refreshed`
- `change_proposed`
- `consent_decision`
- `change_applied`
- `change_rolled_back`

Each record contains the timestamp, tenant, change id, and detail.

## Current Boundaries

`applyApproved` currently only changes GHW internal state and writes an audit entry. In production a ProductAdapter must be wired in:

```
ChangeProposal
  -> ProductAdapter.validate
  -> ProductAdapter.apply
  -> ProductAdapter.verify
  -> Audit
```

This prevents the mismatch where "the audit says applied, but the host product did not actually change."
