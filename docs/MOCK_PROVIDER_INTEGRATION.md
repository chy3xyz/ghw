# Mock Provider Integration (Week 3 placeholder)

> **Status**: Week 3 ships the mock provider *module*. The wiring
> into `LlmDriver.callProvider` is deferred to the integration step
> (Week 3.5) — it touches existing code and needs a careful diff.

## How MockProvider will be wired

`LlmDriver.callProvider` is currently a stub:

```zig
fn callProvider(self: *LlmDriver, request: Request) anyerror!Response {
    _ = self;
    _ = request;
    return error.LlmProviderNotWired;
}
```

The intended Week 3.5 patch is:

```zig
fn callProvider(self: *LlmDriver, request: Request) anyerror!Response {
    _ = self;
    return switch (self.config.provider) {
        .mock => mock_provider.call(/* a real allocator */, request),
        .anthropic, .openai, .deepseek => return error.LlmProviderNotWired, // Week 4
        .none => return error.LlmProviderNotWired,
    };
}
```

This is a one-line change but it requires:

1. A real allocator to be threaded through `LlmDriver`. Currently
   `LlmDriver` does not own an allocator — the `dispatch()` caller
   passes strings that the LLM call would need to copy. This is a
   design decision (allocator-in-driver vs caller-allocated).

2. The decision is **non-trivial** because:
   - Allocator-in-driver: simpler LLM call, but LlmDriver must
     deinit, and the dispatcher may need to recover from a mid-call
     failure.
   - Caller-allocated: more complex LLM call signature, but
     LlmDriver stays stateless, matching docs/LLM_DRIVER.md §3
     Invariant 5.

The current design (LLM call returns a `Response` with **borrowed**
string slices into a request-bound buffer) is closer to
caller-allocated. We will resolve this in Week 3.5.

## Why this is OK for Week 3

The Week 3 deliverable is:
- `docs/CHANNEL.md` (the spec)
- `src/harness/user_channel.zig` (the rings + e_saturated trigger)
- `src/harness/mock_provider.zig` (the LLM-side templates)
- 10 unit tests in user_channel verifying the e_saturated fire
  flow against `provider=none` (which correctly hard-fails for
  MANDATORY roles).

The fallback path (when LLM is unavailable) is the production
default for embedded use, and it is **fully tested** in Week 3.
Real provider wiring is Week 4.
