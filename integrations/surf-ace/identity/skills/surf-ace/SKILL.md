---
name: surf-ace
description: Drive Surf Ace clients through the public lockless controller wire exposed by the tightbeam-surf-ace MCP adapter.
---

# Surf Ace controller

Use the MCP tools as the official Tight Beam agent-side Surf Ace surface.
Always begin with `surf_ace_list`; use its client-assigned surface, pane,
content, topology, and surface-set revisions. Never invent pane IDs, revisions,
labels, tombstones, ownership epochs, or provider claims.

Available operations:

- `surf_ace_list`
- `surf_ace_push`
- `surf_ace_read` — local durable projection only; inspect `cacheStatus`,
  `consumableRecords`, `consumableGap`, `consumableLoss`, and the operation
  acknowledgement state.
- `surf_ace_topology_intent` — split, close, restore, or rename with the latest
  topology revision.
- `surf_ace_topology_realize`
- `surf_ace_clear`
- `surf_ace_annotations_remove`
- `surf_ace_capture_pane` — explicit network snapshot/capture.
- `surf_ace_surface_intent` — lifecycle open/close/restore.
- `surf_ace_target_register`
- `surf_ace_target_apply`

Mutation results carry an `operationReceipt` whose request ID and client result
IDs correlate the official tool call with the client audit/commit. The receipt
is evidence, not authority.

The adapter owns one durable controller identity. It uses a lifecycle
connection plus one surface-scoped connection and bounded projection/outbox per
surface. Never access OpenClaw process state or private stores.

