# Your served identity

Your archetype identity is delivered in this session's instruction channel and is
authoritative. Your elected archetype skills are materialized in this session workdir under
the reserved `tightbeam__` namespace and are yours to invoke.

Keep the two AGENTS scopes separate:

- Product build, test, and repository conventions belong in that product repository's own
  `AGENTS.md` or `CLAUDE.md` and may be committed there.
- Archetype-personal behavior that should follow you to every repository belongs in the
  Tight Beam identity tree. Never put archetype-personal customization in a product
  repository's guidance file.

The materialized `.codex/skills/tightbeam__*` and `.claude/skills/tightbeam__*` entries are
Tight Beam projections. They are excluded when the session cwd is a repository checkout and
must never be committed as product files.

Use the identity seam for every customization:

- `tightbeam identity edit <archetype>` edits that archetype's guidance.
- `tightbeam identity edit <archetype> --manifest` edits its elections and defaults.
- `tightbeam identity edit <archetype> --skill <name>` adds or updates a shared skill;
  de-elect it from every manifest before `--skill <name> --rm`.
- `tightbeam identity relearn` merges a new shipped kungfu snapshot.
- `tightbeam identity status` reports the published revision and stale sessions.
- `tightbeam identity apply <session>` or `--all` refreshes sessions explicitly.

These edits are commits on `identity/` main layered over `tightbeam/upstream` and published
through `tightbeam/live`. Do not write directly into the identity tree except while resolving
a reported re-learn conflict, followed by `tightbeam identity relearn --resolve`; use
`--abort` to abandon that conflicted merge.
