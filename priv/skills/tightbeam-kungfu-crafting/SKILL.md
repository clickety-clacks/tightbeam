---
name: tightbeam-kungfu-crafting
description: What a kungfu bundle must ship and how to author each part. Use when creating a new kungfu or auditing an existing one for completeness.
---

A kungfu is a practiced way-of-working an org adopts: guidance + skills + rails +
the bundle artifacts below. Author each with its governing skill; cite wisdom N.

A complete bundle ships:
1. **Archetypes** — role kernels + elections, matured with
   tightbeam-archetype-cultivation (never accreted bullets).
2. **Guidance & skills** — per tightbeam-guidance-authoring (tiering, grounding,
   directives).
3. **Rails** — org law for the bundle's norms, per tightbeam-law-minting; shipped
   statutes live in the bundle's rails/ and land at identity/rails/*.toml.
4. **`kungfu/<name>/capabilities.md`** — the capability matrix: what adopting this
   bundle gives an org + conversation watch-fors per capability (readable without
   election; the general agent offers capabilities from it).
5. **`kungfu/<name>/preferred-models.md`** — the ACTIVITY table: each activity the
   bundle's roles perform -> what it demands -> capsule+effort from the org's working
   set -> ladder -> floor. Capsules themselves live in the substrate's
   guidance/preferred-models.md; archetype preferences derive from these rows.
6. **`kungfu/<name>/intake.md`** — the operational questions only the operator can
   answer, each naming where its answer lands (preferred-models rows, producer
   commands, workspace roots, stances). Learning the bundle = install + walking the
   operator through intake; not operational until complete-or-deferred.
7. **`manifest.toml`** — what the general agent reads to know this bundle exists and
   whether to offer it. It carries two required fields and one optional field: the
   things nobody can see by looking at the folder.
   - **purpose** — what capability adopting this bundle gives an org, in plain language
     a user would recognize from describing their own work. Not an inventory of the
     bundle's parts: "turn field observations and instrument readings into validated
     findings, with tracked work, independent review, and verification" is a purpose; "7 archetypes,
     13 guidance fragments" is a contents listing. The general agent matches a user's
     stated goal against this, so write it the way a user would say it.
   - **phrases** — short, natural things a USER would say that mean this bundle would
     help. Written from their side, describing the problem or the wish, never our
     capability names. THEY MUST DISCRIMINATE: if a bundle from a different domain could
     honestly claim the same phrase, it is too generic and buys nothing. "I keep losing
     track of what I asked for" fits every bundle ever written; "I want my code reviewed
     before it merges" could only be this one. Test each phrase by asking whether a
     biosciences or legal kungfu could claim it — if yes, rewrite it.

   - **root_archetype** — the archetype everyday sessions should default to once this
     kungfu is the org's way of life. Name it in capabilities.md and intake.md, then
     apply it with `tightbeam config set default-archetype <name>-role`.
   Everything else about the bundle is DISCOVERABLE BY LOOKING — archetypes/, skills/,
   rails/, rules/ are right there on disk. Do not restate contents in the manifest;
   a list that can drift from what shipped is worse than no list. If the agent needs to
   know something it cannot see by looking, add that field here and document it in this
   step.

Audit rule: a bundle missing any of 4-7 is not adoptable law, it is a folder of
opinions — the general agent cannot offer it, learn cannot intake it, and its
recommendations bind nothing.
