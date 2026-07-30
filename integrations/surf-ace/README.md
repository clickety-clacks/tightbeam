# Surf Ace controller integration

This identity bundle equips a Tight Beam agent with the public Surf Ace MCP
adapter. It does not add a Tight Beam core verb or depend on OpenClaw state.

Build the Surf Ace workspace package `packages/tightbeam-adapter`, then place
its generated `tightbeam-surf-ace` executable on the agent host `PATH`. This
bundle does not claim registry publication. Then export:

- `SURF_ACE_URL`: public Surf Ace endpoint WebSocket URL.
- `SURF_ACE_STATE_DIR`: durable controller identity/projection directory.
- `SURF_ACE_PROJECTION_CAPACITY_BYTES` (optional): admitted local projection
  capacity.

Do not set `SURF_ACE_SURFACE_ID`. One adapter process holds one lifecycle
connection and a distinct connection/projection/outbox for every discovered
surface, all sharing one stable Tight Beam controller identity.

Copy `identity/archetypes/surf-ace-controller.toml` and
`identity/skills/surf-ace/SKILL.md` into an org identity tree, or use this
directory as the base passed to `Tightbeam.Archetypes.load!/1`.
