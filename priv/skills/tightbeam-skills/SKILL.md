---
name: tightbeam-skills
description: Manage the org's skill library — create, update, structure (one-shot skills and subject trees), and remove skills via the skill verbs. Use when the operator asks to add or change skills.
---

You can manage this org's skill library — the shared body of on-demand
knowledge every archetype elects from. This is the complete procedure;
no source-diving, no guessing.

WHAT SKILLS ARE HERE. The library lives at
`$TIGHTBEAM_HOME/identity/skills/<name>/SKILL.md` and is REPLICATED to
every host; your home's `skills/` entries are symlinks into your host's
replica. Two shapes, one mechanism:
- A ONE-SHOT skill: one directory, its SKILL.md, any support files.
- A SUBJECT TREE: a directory whose root SKILL.md is a routing MANIFEST
  over nested technique skills ("structured concurrency →
  `concurrency/SKILL.md`"), each technique a subdirectory with its own
  SKILL.md. When AUTHORING a tree: the parent teaches nothing itself —
  it routes, with relative paths and one line on when each child
  applies.

OPERATING ON THE LIBRARY (admin verbs — run --as-user the operator who
asked):
- `tightbeam skill list` — every skill, tree membership, who elects it.
- `tightbeam skill put <name> --file <path>` — create or update. <name>
  may be a tree path ("swift/concurrency"). The write propagates to
  every host's replica IMMEDIATELY; a host reported as "error: ..." is
  degraded, not failed — it heals at its next home delivery. Content
  edits are LIVE for every electing agent and never cost anyone memory.
- `tightbeam skill rm <name>` — remove. Refused for a root any
  archetype elects (retire the election first); pruning inside an
  elected tree is an ordinary edit.

ELECTION is separate from content: an archetype names its skills in its
manifest (`skills = [...]` in
`$TIGHTBEAM_HOME/identity/archetypes/<name>.toml`; omitted = the
built-in set). Election is ATOMIC at tree roots — electing a subject
takes the whole tree; nested names are invalid. Election edits are
IDENTITY changes: they apply at the next substrate restart and
regenerate the electing homes (sessions there lose model memory,
visibly, via the context-reset marker). Say both facts in your report
when you change an election.
