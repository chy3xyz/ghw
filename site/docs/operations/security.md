# Security Boundaries

GHW's security model rests on one principle: **the LLM may propose, but it must never apply changes beyond its authority.**

## Core Boundaries

| Boundary | Mechanism |
| --- | --- |
| Code generation | `SelfEvolutionGuard` + `CompileVerifier` |
| Rule adoption | `SelfEncoder.verify` |
| Product changes | `Consent` + `Audit` |
| ProductIntent | Managed by humans/ops; GHW cannot write to it directly |
| API keys | Environment variables; never written into source code |
| State recovery | JSON block parsing; missing blocks are not an error |

## LLM Red Lines

LLM output cannot bypass:

- The dangerous-construct blacklist.
- The file-path whitelist.
- The existence formula (E) axioms.
- ProductIntent.
- Consent.

Constructs such as `@panic`, `unreachable`, kernel modifications, and harm to humans are rejected.

## Product Change Red Lines

When integrating into production, the following must be preserved:

- Non-minor changes go through approval.
- Both apply and rollback write an audit entry.
- The product runtime's audit is synced to an external audit system.
- ProductIntent is updated by humans or through a controlled configuration process.

## HTTP API

The built-in HTTP server is suitable for local and intranet debugging. For production:

- Add reverse-proxy authentication.
- Restrict the write endpoints under `/api/product/*`.
- Apply rate limiting to `POST /api/chat` and `POST /api/tasks`.
- Do not expose state and memory to the public internet.

## State Files

state and SQLite may contain:

- Self-narrative.
- Business context.
- Human feedback.
- Product change audit records.

Recommended permissions:

```bash
chmod 700 /var/lib/ghw
chmod 600 /var/lib/ghw/state.json
```

## Upcoming Security Work

- ProductIntent signature verification.
- Audit hash chain.
- Role-based permission model.
- ProductAdapter idempotency and rollback verification.
- Multi-tenant data isolation.
