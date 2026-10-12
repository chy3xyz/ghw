# Core Concepts

The key to GHW is not "making the LLM smarter", but putting the LLM back in its proper place: **the LLM proposes, the digital life decides**.

## M/R/N Three Sources

GHW describes the state of a digital life along three dimensions:

- **M Material**: action, execution, resources, actual results.
- **R Representation**: modeling, understanding, beliefs, knowledge structures.
- **N Nature**: self-narrative, meaning, internal consistency.

The existence degree `E` is not a simple score, but an aggregation of three-source state, product KPIs, symbiosis relations, and relational emergence. The current mainline uses the weighted power mean / CES as the basis of three-source aggregation, so that "shortfall-first" and "imbalance penalty" emerge from the properties of the formula rather than from after-the-fact patches.

## LLM as Fuel

In GHW, the LLM can:

- Parse natural language, world snapshots, and chat messages into features.
- Propose goals, rules, code variants, or explanations.
- Generate candidate code and candidate rules.

The LLM cannot:

- Decide whether its own proposals are adopted.
- Modify the E axioms, the blacklist, or the ProductIntent.
- Bypass the Guard, the Verifier, Consent, or the ΔE feedback.

## Self-Evolution L1-L5

| Level | Meaning | Typical Output |
| --- | --- | --- |
| L1 | Parameter tuning | Coefficient, weight, and rhythm adjustments |
| L2 | epsilon variants | Search/perturbation strategies |
| L3 | Learn new methods | `src/goal/methods/l3_*.zig` |
| L4 | Optimize algorithms | Goal selection, reflection, scheduling strategies |
| L5 | Self-encoded rules | Verifiable rules, guard strategies |

L3-L5 must all pass through `SelfEvolutionGuard` and `CompileVerifier`. L5 additionally enters `SelfEncoder.verify`.

## Human Symbiosis

A product-grade digital life cannot optimize only for itself. GHW adds a human symbiosis layer:

- `TaskQueue` accepts tasks from humans, the LLM, the system, and the balancer.
- `HumanSignal` records explicit ratings and feedback.
- `HumanGSP` tracks human trust and interaction quality.
- `ValueTrendTracker` tracks the trend of the human value score.
- `chat_reply` injects autobiographical memory and relevant past episodes into replies.

These signals do not directly "command" the agent; instead, they change subsequent behavior through task bias, value trends, and rule proposals.

## Product Digital Life Foundation

The product foundation adds one more closed loop:

```
ProductIntent
  -> KPI Bridge
  -> ProductEvolutionRuntime
  -> ChangeProposal
  -> Consent
  -> Apply / Rollback
  -> Audit
  -> E feedback
```

This lets GHW be more than "self-growing" — it can become the long-term evolution kernel of a product.

## Security Principles

- The ProductIntent is managed by humans/ops; GHW can only propose, not modify it directly.
- Non-minor product changes must go through approval.
- Both apply and rollback are written to the audit log.
- Rule and code candidates must pass the blacklist, formal verification, and compile verification.
- API keys come from environment variables and are never hardcoded in the source.
