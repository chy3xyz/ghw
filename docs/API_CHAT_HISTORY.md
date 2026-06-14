# /api/chat/history — HTTP Endpoint Spec (v1)

> **Status**: Week 3 of Phase 1 (GHW-as-CRM). The handler
> implementation in `examples/ui_server.zig` is deferred — that
> file lives in the main GHW repo, not in this worktree.

## Request

```
GET /api/chat/history?limit=20
```

Optional query params:

| Param | Type | Default | Description |
|---|---|---|---|
| `limit` | u32 | 50 | Max messages to return. Capped at 200. |
| `since` | u64 (unix) | 0 | Only messages after this timestamp. |
| `trigger` | string | (none) | Filter by trigger name (`e_saturated`, etc.). |
| `channel` | string | (none) | Filter by destination channel name. |

## Response (200 OK)

```json
{
  "messages": [
    {
      "msg_id": 42,
      "trigger": "e_saturated",
      "channel": "admin_dashboard",
      "text": "[mock:e_saturated] E is 0.85, KPI composite is 0.7. I am alive and paying attention.",
      "created_at": 1749860000,
      "delivered": false,
      "delivery_attempts": 0
    }
  ],
  "total": 1,
  "next_cursor": null
}
```

## Response (500 Internal)

```json
{
  "error": "outbound_ring_unavailable",
  "message": "the UserChannel outbound ring was not initialized"
}
```

## Implementation notes

The handler reads from the `OutboundRing` (in
`src/harness/user_channel.zig`) — *not* the JSONL persistence
file. The in-memory ring is the source of truth for the UI; the
JSONL file is for audit and crash recovery.

```zig
fn handleGetChatHistory(
    allocator: std.mem.Allocator,
    app: *App,
    request: *const HttpRequest,
) ![]u8 {
    const limit = parseLimit(request.query, 50);
    const iter = app.user_channel.outbound.iter();
    var json_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&json_buf);
    try w.print("{{\"messages\":[", .{});
    for (iter, 0..) |msg, i| {
        if (i >= limit) break;
        if (i > 0) try w.print(",", .{});
        try w.print(
            \\{{"msg_id":{d},"trigger":"{s}","channel":"{s}","text":{f},"created_at":{d}}}
        ,
            .{ msg.msg_id, @tagName(msg.trigger), msg.channel, msg.payload_json, msg.created_at },
        );
    }
    try w.print("],\"total\":{d}}}", .{iter.len});
    return app.makeHttpResponse(allocator, 200, w.buffered());
}
```

The `{f}` format spec is a custom JSON-string-literal formatter
(defined in `src/harness/json_string.zig`, Week 3.5 deliverable)
that escapes `\`, `"`, and control characters in the message
text.

## Test plan (Week 3.5)

1. Push 3 OutboundMsg to the ring with different triggers.
2. Call `handleGetChatHistory(50)`.
3. Parse the response JSON.
4. Assert: 3 messages returned, fields match.

## What this endpoint does NOT do (deferred)

- Streaming via Server-Sent Events (SSE) — Week 4 deliverable.
- Pagination via cursor — only `limit` for now.
- Filtering on `delivered` flag — always returns all.
- Reading from JSONL persistence file — only the in-memory ring.
