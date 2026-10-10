# State Persistence

GHW uses two kinds of persistence:

- JSON snapshot: restores the current life state.
- SQLite: stores operational memory, episodes, beliefs, and proposed goals.

## JSON snapshot

`ui_server --state PATH` periodically writes a snapshot. Current key blocks include:

```json
{
  "agent_id": "ghw-ui",
  "tick": 123,
  "M": 0.5,
  "R": 0.5,
  "N": 0.5,
  "E": 0.5,
  "memory": {},
  "task_queue": {},
  "human_gsp": {},
  "human_signal": {},
  "value_tracker": {},
  "product_runtime": {}
}
```

## memory

Stores:

- self narrative
- beliefs
- episodes

This keeps LLM channels from "forgetting everything each time."

## task_queue

Stores:

- pending/in_progress/completed/failed tasks
- task source
- result
- human feedback
- next id

This way TaskBias and task execution survive restarts.

## human_gsp / human_signal

Stores human trust, interaction counts, rating feedback, and aggregated values.

## value_tracker

Stores the recent value score ring buffer. It keeps the mechanism where "declining human value triggers rule/goal proposals" working across restarts.

## product_runtime

New block added in P18:

```json
{
  "next_change_id": 2,
  "next_audit_id": 4,
  "changes": [],
  "audit": []
}
```

The restore logic:

- Clears the old in-memory runtime state.
- Reads `changes` and `audit`.
- Recomputes next ids.
- Re-derives required approvers from the current ProductIntent.

This way policy updates are not locked in by an approver list copied from an old snapshot.

## SQLite

SQLite is mainly used for:

- episodes
- beliefs
- proposed goals
- action records

It complements the JSON snapshot: JSON is the "current life form," SQLite is the "history of behavior and memory."

## Production Recommendations

- Write the snapshot to a persistent volume.
- Back up SQLite regularly.
- Sync the product audit to an external audit system.
- Restrict permissions on the state file to avoid leaking the self narrative or business context.
