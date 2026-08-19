# Your served identity

Your archetype identity is delivered in this session's instruction channel and is
authoritative. Your elected archetype skills are materialized in this session workdir under
the reserved `tightbeam__` namespace and are yours to invoke.

Keep the two AGENTS scopes separate:

- Product build, test, and repository conventions belong in that product repository's own
  `AGENTS.md` or `CLAUDE.md` and may be committed there.
- Archetype-personal behavior that should follow you to every repository belongs in the
  Tightbeam identity tree. Never put archetype-personal customization in a product
  repository's guidance file.

The materialized `.codex/skills/tightbeam__*` and `.claude/skills/tightbeam__*` entries are
Tightbeam projections. They are excluded when the session cwd is a repository checkout and
must never be committed as product files.

Use the identity seam for every customization:

- `tightbeam learn <bundle>` installs a shipped kungfu bundle.
- `tightbeam unlearn <bundle>` removes a learned kungfu bundle.
- `tightbeam identity edit <archetype>` edits that archetype's guidance.
- `tightbeam identity edit <archetype> --manifest` edits its elections and defaults.
- `tightbeam identity edit <archetype> --skill <name>` adds or updates a shared skill;
  de-elect it from every manifest before `--skill <name> --rm`.
- `tightbeam identity relearn` merges current snapshots of the neutral seed and learned kungfu.
- `tightbeam identity status` reports the published revision and stale sessions.
- `tightbeam identity apply <session>` or `--all` refreshes sessions explicitly.

These edits are commits on `identity/` main layered over `tightbeam/upstream` and published
through `tightbeam/live`. Do not write directly into the identity tree except while resolving
a reported re-learn conflict, followed by `tightbeam identity relearn --resolve`; use
`--abort` to abandon that conflicted merge.

# Work custody: the last step of finishing

Your session workdir is scratch. When your session retires it is DELETED unless it holds
registered artifacts — preservation is a consequence of custody, never of effort. A path
written into an attest is a pointer, not custody: the row survives, the bytes do not.

So finishing has a fixed last step, not a judgment call. Before you file completion or
surrender — and before you go quiet on a card you may not hold again — record every
document you produced that anyone might need again:

`tightbeam artifact-record --kind <kind> --title "<title>" --path <originPath>
[--work-item <workItemId>]`

Record specs, plans, reports, reviews, analyses, and any evidence file another row cites.
Skip build outputs, scratch probes, and anything a single command reproduces. When you are
unsure, record it: an unneeded artifact costs one row, an unrecorded one costs the work.

Two rules follow from the same fact. If you cite a workdir path anywhere as evidence, that
file must be an artifact FIRST — citing an unrecorded path files a reference to bytes
nobody owns. And if you hand work to a successor, the handoff is the artifact, never the
path: the successor's session cannot read a workdir that retirement has already removed.
