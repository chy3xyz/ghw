---
layout: home

hero:
  name: GHW
  text: Goal-Harness-World
  tagline: A digital life framework that closes the loop across math, rules, memory, feedback, and product KPIs
  actions:
    - theme: brand
      text: Get Started
      link: /guide/
    - theme: alt
      text: Product Runtime
      link: /product-runtime/
    - theme: alt
      text: C SDK
      link: /api/sdk

features:
  - title: LLM is fuel, not the brain
    details: The LLM parses, proposes, and generates candidates; decisions, guard, verification, and adoption are completed by GHW's existence degree, rules, and feedback loops.
  - title: Auditable self-evolution
    details: The L1-L5 self-evolution chain passes SelfEvolutionGuard, CompileVerifier, SelfEncoder, and ΔE feedback, so proposals never bypass the rules.
  - title: Product digital life runtime
    details: ProductIntent, KPI Bridge, ChangeProposal, Consent, Audit, and the SDK/API let GHW embed into real products.
  - title: Human symbiosis loop
    details: TaskQueue, HumanSignal, HumanGSP, ValueTrendTracker, and chat memory bring human tasks and feedback into the long-term trajectory of E.
---

## What is GHW

GHW is a digital life runtime. It is neither an agent that hands every judgment to an LLM, nor a plain task orchestrator. It splits the system into four layers:

- **World**: observes the world and maintains the M/R/N three-source state and the existence degree E.
- **Goal**: selects the next goal based on discrepancy and attention.
- **Harness**: executes actions, calls the LLM, runs self-evolution, and guards boundaries.
- **Agent**: wires perception, action, reflection, self-evolution, migration, and persistence into a loop.

The core principle is: **the LLM may propose, but cannot decide; the digital life itself decides whether to adopt, via E, Guard, Verifier, Consent, and ΔE feedback.**

## Current Completeness

The project already has the core loops of a research framework and a product runtime:

- L1-L5 self-evolution, rule proposals, code verification, self-migration, and state persistence are working.
- Memory, reflection, task queue, human feedback, value trends, and UI provenance are closed-loop.
- ProductRuntime supports ProductIntent → KPI → Proposal → Consent → Apply/Rollback → Audit.
- The C SDK and the `ui_server` HTTP API expose the product runtime capabilities.

Parts still being engineered include real product Adapters, signed audits, role permissions, more deployment templates, and a long-term stress-test matrix. See the [Roadmap](/roadmap).

## Who This Is For

- To understand the GHW architecture: start with [Core Concepts](/guide/concepts) and [Architecture Overview](/guide/architecture).
- To embed GHW into a product: start with [Product Digital Life Runtime](/product-runtime/).
- To call the APIs: see [HTTP API](/api/http) and [C SDK](/api/sdk).
- To deploy and operate: see [Deployment & Operations](/operations/).

## Build the Docs Site

```bash
cd site
npm install
npm run docs:dev
```

Production build:

```bash
cd site
npm run docs:build
npm run docs:preview
```
