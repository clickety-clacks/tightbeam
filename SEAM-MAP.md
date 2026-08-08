# Code-seam map for the completion-rail mint (spec 5daa4b0a, supersedes 2717c210)

Authored by spec-writer:completion-rail-opus (spec author + N3-gate author), verified against
this repo's lib/tightbeam. For coder:law-mint-codex. MECHANICAL mappings unless flagged
[PO DECISION].

## (a) is_producing_card — seam = lib/tightbeam/rules.ex (the fact registry/compute), NOT assignments.ex

THREE changes, all in rules.ex:

1. **Register the fact** — `@facts` map (currently L104–125): add
   `"assignment.is_producing_card" => :bool,`
   (booleans are `:bool` here, cf. `caller.is_admin`, `work_item.is_bug`.)

2. **Extend the `$assignment` loader** — `assignment_context/3` (L1377) currently SELECTs only
   `a.id, a.workItemId, a.holderKey, s.archetype, a.holderHarness, a.holderProvider` and returns
   a map WITHOUT reviewsAssignmentId. Add `a.reviewsAssignmentId` to the SELECT and
   `reviews_assignment_id: reviews_assignment_id` to the returned map. (Additive; feeds all
   assignment.* facts via `$assignment`. Without this, step 3 references a field that isn't loaded.)

3. **Add the compute clause** — near the other `assignment.*` clauses (~L1132–1146), mirroring
   `assignment.holder_archetype`:
   ```elixir
   defp compute_fact("assignment.is_producing_card", db, call, cache) do
     with_dependency("$assignment", db, call, cache, fn
       nil, cache -> {nil, cache}
       assignment, cache -> {is_nil(assignment.reviews_assignment_id), cache}
     end)
   end
   ```
   Ships-now semantics: producing = `reviewsAssignmentId IS NULL` (review cards → non-producing).
   Q1's `--non-producing` flag extends this later; not in this mint.

assignments.ex is touched ONLY for: the `:264` opener-filter drop in `commissioned_review_authors`,
and the `valid_commit_refs` relax(accept kind=verdict on review-link)/forbid(commit_refs on a
non-producing completion).

## (b) I6 dynamic deny reasons — NO engine machinery in this mint; dynamic per-branch DEFERRED

Verified: the rule struct carries ONE `text` per rule (rules.ex struct; denial uses `rule.text`
at ~L844 `question`, ~L895 `message`). There is NO per-condition text nor selection logic.

- **THIS MINT (no engine change):** set the `completion-requires-review` rule's single `text` in
  engineering.toml to a static string that ENUMERATES the sub-conditions as a self-check — honest,
  never the bare "no reviewed-clean verdict" lie. Suggested text (tune wording, keep the checklist):
  > "completion of a producing card needs an independent cross-harness reviewed-clean verdict. If
  > one seems present but is refused, check the review card: filed on a card that --reviews this
  > assignment (not directly on it)? filed by that review card's holder (not you, not a third
  > party/user)? on a different harness than yours? — the first unmet condition is the reason."
- **DEFERRED [PO DECISION — Q9]:** auto-selecting the ONE failing sub-condition as distinct text
  is a genuine ENGINE GAP — it needs a per-condition `text` on `deny_when` entries + selection in
  the deny path (~L866–900, `malfunction`/`denial_error`). Ruled deferred WITH the PO (Q9, same
  defer-not-fake class as DEGRADE). Not required to mint.

## (c) The N3 extra p3 opener sites (L309-318, L510, L809-810, L938-965) — [PO SCOPE DECISION]

My read (given to the PO): SAME opener-independence removal, IN-SCOPE — leaving any unamended =
self-contradictory canon (B1 class, what the N3 gate catches). Spec 5daa4b0a already folds all
four into the Amends (seven sites total), same reviewed direction (drop opener-independence, keep
author, cross_harness §4A). L510 is descriptive (mirror the amended computation); L938-965 (F11
tests) INVERTS a self-commissioned-R exclusion — the most substantive, worth fable's eye. Apply
from live p3, then re-run the N3 full-p3-grep → must be ZERO opener-independence contradictions.
Holds on the PO's scope ruling.
