---
name: tightbeam-skills
description: Manage the served identity skill library through the identity seam.
---

You can manage this org's skill library — the shared body of on-demand
knowledge every archetype elects from. This is the complete procedure;
no source-diving, no guessing.

WHAT SKILLS ARE HERE. The library lives at
`$TIGHTBEAM_HOME/identity/skills/<name>/SKILL.md` on the identity tree.
Elected skills are materialized per session at its exact cwd under the
reserved `tightbeam__<name>` directory. They are never replicated into a
shared home. Two shapes, one mechanism:
- A ONE-SHOT skill: one directory, its SKILL.md, any support files.
- A SUBJECT TREE: a directory whose root SKILL.md is a routing MANIFEST
  over nested technique skills ("structured concurrency →
  `concurrency/SKILL.md`"), each technique a subdirectory with its own
  SKILL.md. When AUTHORING a tree: the parent teaches nothing itself —
  it routes, with relative paths and one line on when each child
  applies.

OPERATING ON THE LIBRARY (admin verbs — run --as-user the operator who
asked):
- `tightbeam identity edit <archetype> --skill <name> --file <path>` creates
  or updates a shared body.
- `tightbeam identity edit <archetype> --skill <name> --rm` removes it and
  refuses while any archetype still elects it.
- `tightbeam identity status <archetype>` shows delivered guidance and
  staleness; `tightbeam identity apply <session>` or `--all` explicitly
  refreshes existing sessions.

ELECTION is separate from content: an archetype names its skills in its
manifest (`skills = [...]` in
`$TIGHTBEAM_HOME/identity/archetypes/<name>.toml`; omitted = the
built-in set). Election is ATOMIC at tree roots — electing a subject
takes the whole tree; nested names are invalid. Election edits are
made with `tightbeam identity edit <archetype> --manifest`. Successful edits
publish `tightbeam/live`; new sessions use them immediately, while existing
sessions remain byte-identical until explicit `identity apply`.
