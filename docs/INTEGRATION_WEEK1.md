# Week 1 Integration Guide — ProductIntent

> **For**: Whoever wires `ProductIntent` into the existing GHW daemon
> **Status**: Skeleton ready, integration designed but not yet merged
> **Branch**: `feature/week1-product-intent`

## What landed in Week 1

| File | Purpose | Lines |
|---|---|---|
| `src/harness/product_intent.zig` | Skeleton module with full type definitions, JSON loader, validation, and 5 unit tests | ~620 |
| `product_intent.example.crm.json` | Complete CRM SaaS example (the one referenced in our plan) | ~100 |
| `docs/PRODUCT_INTENT.md` | Schema spec (this is the source of truth for the JSON contract) | ~250 |
| `docs/INTEGRATION_WEEK1.md` | This file | you are here |

The skeleton is **self-contained** — it does not import any existing GHW
modules. That's deliberate: Week 1 is about getting the data contract right
and the validation logic solid. Wiring it into the live daemon is Week 1.5
(a half-week task) once the schema is approved.

## Where to wire it (5 integration points)

### IP-1: `examples/daemon.zig` — CLI flag + load on startup

Add a new flag:

```zig
var product_intent_path: ?[]const u8 = null;
// ...
// In parseArgs:
if (std.mem.eql(u8, arg, "--product-intent")) {
    i += 1;
    if (i >= args_list.items.len) fatal("missing path after --product-intent", .{});
    product_intent_path = args_list.items[i];
    i += 1;
    continue;
}
```

In `main`, after `var gpa = ...` and before the daemon loop:

```zig
var product_intent: ?harness.ProductIntent = null;
defer if (product_intent) |*pi| pi.deinit();

if (product_intent_path) |p| {
    product_intent = harness.ProductIntent.load(gpa.allocator(), p) catch |err| {
        std.log.err("failed to load product_intent from {s}: {s}", .{ p, @errorName(err) });
        std.process.exit(78); // EX_CONFIG
    };
    std.log.info("product_intent loaded: id={s} type={s} epoch={d}",
        .{ product_intent.?.product_id, @tagName(product_intent.?.product_type), product_intent.?.update_epoch });
}
```

### IP-2: `examples/ui_server.zig` — `App` struct field

Add to the `App` struct:

```zig
product_intent: ?harness.ProductIntent,
// ...
// In deinit:
if (self.product_intent) |*pi| pi.deinit();
```

The HTTP server reads it for `/api/product_intent` endpoint (see IP-4).

### IP-3: `src/harness/self_evolution_guard.zig` — sacrosanct → blacklist

In the existing `SelfEvolutionGuard` initialization, append the sacrosanct
patterns. **Important**: sacrosanct is product-specific, not system-level,
so it should be a separate list, not merged into the 17-pattern guard.

```zig
// New field on SelfEvolutionGuard
product_sacrosanct: []const []const u8,

// New init that takes ProductIntent
pub fn initForProduct(alloc: Allocator, product_intent: ?*const ProductIntent) !SelfEvolutionGuard {
    var guard = try initSystem(alloc);
    errdefer guard.deinit();
    if (product_intent) |pi| {
        guard.product_sacrosanct = pi.sacrosanct;
    } else {
        guard.product_sacrosanct = &.{};
    }
    return guard;
}

// In `passes()` — after the existing 17 patterns, before `return true`:
inline for (self.product_sacrosanct) |s| {
    if (std.mem.indexOf(u8, candidate, s) != null) {
        return false;
    }
}
```

### IP-4: `examples/ui_server.zig` — `/api/product_intent` endpoint

```zig
fn handleGetProductIntent(allocator, app, request) ![]u8 {
    const pi = app.product_intent orelse return app.makeHttpResponse(allocator, 404, "{\"error\":\"no product_intent loaded\"}");
    // Serialize the in-memory ProductIntent back to JSON for the dashboard
    // (so ops can verify what the daemon actually loaded).
    var buf: [4096]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf,
        \\{{"schema_version":{d},"product_id":"{s}","product_type":"{s}","version":"{s}",
        \\  "update_epoch":{d},"north_star_kpi":"{s}","sacrosanct_count":{d},
        \\  "kpi_evaluation_window":"{s}","value_weights":{{"user_satisfaction":{d},"retention":{d},"revenue":{d},"safety":{d}}}}}
    , .{
        pi.schema_version, pi.product_id, @tagName(pi.product_type), pi.version,
        pi.update_epoch, pi.north_star_kpi, pi.sacrosanct.len,
        @tagName(pi.kpi_evaluation_window),
        pi.value_weights.user_satisfaction, pi.value_weights.retention,
        pi.value_weights.revenue, pi.value_weights.safety,
    });
    return app.makeHttpResponse(allocator, 200, out);
}
```

Register the handler in the URL routing table.

### IP-5: `src/agent/params.zig` (or similar) — store `update_epoch` in state

The E formula and LoopEngine need to know *which ProductIntent epoch*
they are computing under. Append `update_epoch` to the existing state
serialization (the function that writes `state.json`).

```zig
// In saveState (or whatever writes state.json)
try writer.print(",\"product_intent_epoch\":{d}", .{app.product_intent.?.update_epoch});

// In loadState
// (Skip if not yet wired in Week 1 — just leave the field absent; Week 2
// will read it.)
```

**Don't** read it in Week 1. Just write it. That way state.json is forward-
compatible.

## What is *not* in Week 1 (deferred by design)

| Deferred to | Why |
|---|---|
| E formula ρ term | Week 2 owns the E formula. Touching it before the schema is stable would be wasted work. |
| LLM proposer system prompt injection | Needs the LLM module to be touched. Week 2 will do it. |
| Hot-reload of product_intent.json | Currently restart-required. v0.5 will add SIGHUP-style reload. |
| Signed manifests | v0.5. Documented in PRODUCT_INTENT.md §2. |
| Multi-manifesto (per product_type) | v0.5. Documented in PRODUCT_INTENT.md §7. |

## Validation checklist (run before merging)

1. `zig build-obj src/harness/product_intent.zig` compiles cleanly.
2. `zig test src/harness/product_intent.zig` passes 5/5 tests.
3. `python3 -c "import json; json.load(open('product_intent.example.crm.json'))"` parses.
4. `python3` script from PRODUCT_INTENT.md §5 (in repo) — all 9 failure modes
   correctly rejected by both the Python schema and the Zig parser.
5. Loading a malformed file produces a log message with the offending field
   name (or with file:line for JSON errors).

## Estimated effort to wire up (Week 1.5)

- IP-1 (daemon CLI + load): 30 min
- IP-2 (App struct field): 10 min
- IP-3 (sacrosanct to guard): 1 hour (needs careful design around LLM regex escape)
- IP-4 (HTTP endpoint): 30 min
- IP-5 (state.json epoch): 15 min
<<<<<<< HEAD
- Total: ~2.5 hours

Should land cleanly in a single commit after Week 1 review.

=======
- IP-6 (LlmDriver init + chat handler dispatch): 1.5 hours (see below)
- Total: ~4 hours

Should land cleanly in a single commit after Week 1 review.

## IP-6: LlmDriver init + chat handler dispatch (Week 1.5, second commit)

> **New in this commit** — see `docs/LLM_DRIVER.md` for full spec.

### IP-6.1: Wire LlmDriver into the App

In `examples/ui_server.zig` (or wherever `App` lives), add:

```zig
llm_driver: harness.LlmDriver,
```

Initialize after `product_intent` is loaded:

```zig
var driver_cfg = harness.LlmDriver.Config{
    .provider = .anthropic,  // or read from CLI flag
    .model = "claude-3-5-sonnet",
    .timeout_seconds = 5,
    .fallback_on_failure = true,
    .audit_prompts = true,
    .audit_responses = true,
};
app.llm_driver = harness.LlmDriver.init(gpa.allocator(), driver_cfg);
```

### IP-6.2: Replace the existing chat LLM call

Find the existing chat handler that calls LLM directly (it lives in
`examples/ui_server.zig` or `src/harness/llm/http_llm.zig`). Replace the
direct LLM call with an `LlmDriver.dispatch()` call:

```zig
// OLD:
const reply = try httpLlm.complete(alloc, user_message);

// NEW:
const resp = try app.llm_driver.dispatch(.{
    .role = .write_user_message,
    .audit_tag = try std.fmt.allocPrintSentinel(alloc, "user_msg:{d}", .{msg_id}, 0),
    .payload = .{ .write_user_message = .{
        .trigger = "user_chat",
        .context_json = try serializeContext(alloc, msg),
        .tone_hint = .customer_facing_polite,
        .max_length = 500,
    } },
});
defer alloc.free(resp.audit_tag);
const reply = resp.result.write_user_message.text;
```

This swap is **mandatory** — direct LLM calls bypass the FORBIDDEN/MANDATORY
boundary checks and would let a future bug grant a sacrosanct exception
through code that forgot to go through LlmDriver.

### IP-6.3: Wire the L4 proposal rationale

The existing `Reflection` / `SelfEvolver` modules call the LLM to generate
L4 proposals. Replace those direct calls with `LlmDriver.dispatch()` for
`role = .write_evolution_rationale`. The *proposal itself* (the L4
parameter values) stays in the math/protocol layer; only the *rationale*
goes through LlmDriver.

### IP-6.4: Unit-test coverage at integration

Add a test in the daemon that:

1. Boots with `provider = .mock`
2. Dispatches each of the 11 roles
3. Verifies the response shape (typed fields, no missing variants)
4. Verifies the forbidden role returns the hardcoded refusal
5. Verifies the mandatory roles fail-fast when `provider = .none`

This test will fail loudly if someone later adds a 12th role but forgets
to wire the dispatch path.

### IP-6.5: Audit log writer

The LlmDriver is already calling `std.log.warn` on failure as a placeholder.
In Week 2, replace this with a real audit log writer that:

- Appends every (role, audit_tag, prompt, response, used_llm, timestamp) tuple
- Signs each entry with the daemon's key (HMAC at minimum, ed25519 in v0.5)
- Streams to a WAL file, rotated daily, retained per `audit_log.retention_days`

This is a separate concern from LlmDriver itself; the contract is
"call this hook on every dispatch result." Week 2 will define the
hook.

>>>>>>> f94a2a2 (week 1.5: LLMDriver boundary (semantic vs math/protocol))
## Open questions for the user

1. **Should `manifesto` be size-limited?** (LLM context window concern.)
   Current schema has no limit. Recommend: cap at 4 KB (enough for 1 page of
   dense Markdown). Open to feedback.
2. **Should we validate `manifesto` against LLM prompt-injection patterns?**
   E.g. "ignore previous instructions" inside the manifesto. Lean yes —
   23-blacklist could grow a new category for this. Tabled for Week 4.
3. **How should we handle a `product_intent.json` that exists but has an
   older `update_epoch` than the one in `state.json`?** Current plan: refuse
   to start. Alternative: log warning, use state.json's epoch. Lean refuse.
<<<<<<< HEAD
=======
4. **Provider=none in production — safe or footgun?** The current design
   treats `provider=none` as a hard failure for mandatory roles. The user
   can opt into "templates-only mode" by setting the *individual* roles
   to fallback. Should we ban `provider=none` in production manifests?
   Lean yes (require explicit opt-in via config flag).

>>>>>>> f94a2a2 (week 1.5: LLMDriver boundary (semantic vs math/protocol))
