---
name: model-release-intake
description: Ceremony for taking in a newly released (or retired) model — detect the catalog drift, characterize the new mind, sweep every archetype's preferences and quality floors, update the guidance, and attest. Trigger is a human noticing a release, or `mix tightbeam.catalog.diff` reporting drift.
---

# Model release intake

A new model shipped, or an old one vanished, and the catalog no longer matches the judgment
the org has written down. This is a rare, deliberate ceremony — not automation. You run it
when a human notices a release or when the drift detector flags it. The goal is that every
model an agent can be handed is a model someone has characterized, and every characterization
still names a model that exists.

## When to run

- `mix tightbeam.catalog.diff` exits nonzero (uncharacterized live refs, or characterized
  refs that have vanished from the live inventory), OR
- a human learns a model was released, renamed, retired, or repriced.

## Steps

1. **Detect.** Run the diff and read it as the worklist:

   ```
   mix tightbeam.catalog.diff        # human report; nonzero exit on drift
   mix tightbeam.catalog.diff --json # machine-readable, same exit contract
   ```

   - UNCHARACTERIZED live refs → new minds to characterize (steps 2-4).
   - VANISHED characterized refs → retired minds to remove or re-point (step 5).

2. **Characterize each new model.** Add an entry to `preferred-models.md` in the org's
   guidance, in the established format: what the model is FOR; what it is NOT for; its cost
   posture; when to PREFER or AVOID it relative to its neighbors. Base the judgment on the
   model's real strengths, not marketing — where you are unsure, say so and pick a
   conservative quality-floor placement. A characterization is a judgment on the record, so
   the next agent adjudicates against it instead of guessing.

3. **Place it in the capability ladder.** Decide where the new mind sits relative to the
   existing ones for the quality-floor logic: which jobs it clears, which it does not. The
   floor is the least capable mind you would accept for a job; the new entry must be
   orderable against its neighbors or the floor logic cannot use it.

4. **Sweep every archetype's model preferences + quality floors.** For each archetype
   (`identity/archetypes/*.toml`), reconsider its declared model preference order and its
   floors now that the roster changed: should the new model enter any archetype's preferred
   order? Does it raise or lower any floor? Do NOT leave an archetype pointing only at a
   vanished ref.

5. **Handle vanished refs.** For each characterized-but-gone model: remove its
   characterization (and any archetype preference that names it) OR re-point it to its
   successor if the release was a rename. Never leave an archetype whose only preference is a
   ref the live catalog no longer serves — that is a guaranteed refused spawn.

6. **Re-run the detector to zero.** `mix tightbeam.catalog.diff` must exit zero: the
   characterized set now exactly covers the live set, no vanished refs remain.

7. **Attest.** Record the intake — what model was taken in (or retired), the characterization
   judgment, the archetypes swept, and the diff-clean result — as an attest on the work, so
   the change to the org's model judgment is on the record and not a silent edit.

## Notes

- This is DEV-time intake: it runs against the live catalog with no gateway required (the
  detector starts the fetchers standalone). Long-lived orgs additionally get the same diff
  promoted into the catalog refresh heartbeat (a `model-added` condition fact + steward
  wake); that runtime path is separate from this human/CI ceremony.
- The merge gate runs the externally-tagged coverage test (`mix test --only external`) so an
  uncharacterized model is caught loudly at the choke point, not in production.
