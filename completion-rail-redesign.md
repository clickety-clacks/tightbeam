# Completion-rail redesign — condition on the right facts

Status: REVISED per the fable DELTA adversarial re-review (verdict CHANGES-REQUESTED,
att_0cd5091d, report a130f181673e/reviews/completion-rail-redesign-delta-findings.md). The
delta verified all 10 v1 findings genuinely addressed, and raised 2 BLOCKING + 4 IMPORTANT +
2 nits on the NEW text — this revision addresses all of them plus mike's §3a upgrade. NOT yet
minted: awaiting PO re-verification of this revision before mint. Spirit sign-off + structure
approval stand; the mint VALUE is Q2=REQUIRE (DEGRADE descoped to future work — D2). Law
track: goal-2 / 0.1.4. Do-not-edit-code spec. APPLY-TIME GATES: (1) re-hash the p3 pin
`87f4517a…` on an eezo-mounted session immediately before editing (gibson cannot reach the
NFS spec tree — Q6); (2) grep the FULL 1082-line p3 for other `commission`/`opener`/
`openedBySession` references and route any hit to the PO before declaring the amendment
complete (N3 — only excerpted ranges are in hand).

Canonical home: this spec belongs at `specs/tightbeam/completion-rail-redesign.md` in the
org's shared spec tree (eezo NFS). That tree is NOT mounted on gibson (this session's
host), so the working draft lives in the spec-writer's durable workdir and the canonical
placement is a handoff step for an eezo-mounted session (see Open Questions Q6). This spec
AMENDS `p3-observables-producers-v1.md`; it does not supersede or duplicate it.

Amends `p3-observables-producers-v1.md` at SEVEN coupled opener-independence sites (a partial
edit leaves the canon self-contradictory — fable B1; the missing 4 were caught by the N3
apply-gate full-p3-grep the codex minter ran). ALL apply the SAME reviewed direction — drop
the opener-independence requirement; author-independence stays; `cross_harness` is the
replacement guard per §4A — so NO new mechanism, only completeness (verbatim before→after for
sites iv-vii is applied by the minter from the live p3, which gibson cannot reach):
- (i) invariant 6b clause (b) removed, clause (a) kept (invariant 6 UNCHANGED).
- (ii) the `independent_verdict_kinds` fact-def parenthetical (L398) — drop "R not
  commissioned by A's holder".
- (iii) the §4A sanction prose (L437-442) — becomes the HOME of the independence-axis gate
  policy (fable B2; ARMS + org-selects-via-config, no value baked, D4); its "all closed by
  invariants 6, 6b" sentence corrected.
- (iv) the API-contract text (L309-318) asserting `R.openedBySession != A`-holder — drop the
  opener condition; state author-independence only.
- (v) the `commissioned_review_authors` fact DESCRIPTION (L510) — its prose must reflect the
  AMENDED computation (the opener filter `assignments.ex:264` is dropped from the fn), i.e.
  mirror the amended (ii) fact-def: author is R's holder, author ≠ A's holder; no opener clause.
- (vi) the matrix row (L809-810) "R not opened by A holder" — drop that cell's requirement;
  the matrix reflects author-independence + the §4A cross_harness gate.
- (vii) the F11/tests prose (L938-965) excluding a self-commissioned `R` — invert: a
  producer-opened (self-commissioned) `R` now COUNTS when author-independent, with
  cross_harness as the §4A gate; update the test expectations accordingly.

Also amends `kungfu/agentic-engineering/rules/engineering.toml`: the `completion-requires-review`
rule (subject gate + REQUIRE axis, value in rule CONFIG). And amends substrate code:
1. `lib/tightbeam/assignments.ex` `commissioned_review_authors` — drop the opener filter (L264).
2. `lib/tightbeam/rules.ex` (NOT assignments.ex — the FACT REGISTRY/COMPUTE SEAM; minter
   catch) — register a new `is_producing_card` fact in `@facts` (L104-121) + a `compute_fact`
   clause deriving `reviewsAssignmentId IS NULL` (mirror the existing reviewsAssignmentId
   compute at ~L1337); extended by Q1's `--non-producing` flag later.
3. `lib/tightbeam/assignments.ex` `valid_commit_refs` (L1337-1352) — RELAX to accept
   `commit_refs` on `kind = "verdict"` for review-link verdicts (§4/F5; today completion-only).
4. `lib/tightbeam/assignments.ex` `valid_commit_refs`/`commit_ref_filing_allowed` — FORBID
   `commit_refs` on a `completion` of a NON-producing card (§3a/F5 anti-poison; forbid over
   flag, wisdom 26).
And a named guidance/operating-pattern amendment (fable F8, §7). DEGRADE (Q2) and I6's
per-branch deny text (Q9) are NOT in this amendment set — both need unbuilt rule-engine
mechanisms (D2 / minter catch), deferred to PO follow-up cards.

**VERSION PIN (amend against exactly this revision).** Target file on eezo NFS:
`/Users/mike/shared-workspace/shared/specs/tightbeam/p3-observables-producers-v1.md` —
sha256 `87f4517ad4cfe04c74042c64bc73a53f33ad01cd43476b5201321c844755ca21`, 1082 lines.
Anchors at fetch (PO-authoritative): invariant 6 @ 97-106, invariant 6b @ 107-118,
weaker-axis sanction @ 441-442, fact defs @ 398-399. Specs are NFS live-edited (no git sha); this content hash IS
the pin — RE-HASH immediately before applying the amendment (excerpts fetched
2026-08-07 by product-owner:tightbeam into
`fb46fbb03fac/tightbeam-product/p3-canonical-excerpts-for-goal2.md`).

---

## Goal

Make `completion-requires-review` fire on — and only on — the completion it was minted to
guard: **a producing author declaring their own reviewable artifact done**. Two corrections,
one principle (condition on the right computable fact):

1. **Right independence fact.** The reviewer must be independent of the work's AUTHOR, not
   of the review card's OPENER. Drop the opener axis (6b clause b) per mike's ruling — a drop
   with NO canonical cover — and NAME the replacement for the anti-laundering guard it
   removes: gate on the STRONG cross-harness axis the spec already defines (ITEM-3).
2. **Right subject fact.** The rail must gate on whether a card PRODUCES a reviewable
   artifact. Only producing/build cards can satisfy "an independent reviewed-clean verdict";
   review, recon, orchestration, tracking, specimen, and product-owner intake cards are
   structurally unsatisfiable and discharge by their own terminal fact. A fast-forward merge
   whose result sha IS the reviewed sha carries the review by git lineage.

Success = the 15+ recorded specimens (PO asg_57ef8ffc, asg_fc441db5) each either pass
completion honestly or are refused with a specific, actionable reason — with no
opener-revoke workaround, no outcome-record that lies (surrendered ≠ delivered), and no
reopened laundering path.

## Non-Goals

- **Auto-staffing the reviewer (the remedy engine).** The rule's `effect = "remedy"` is
  today a no-op: `rail_remedy_episodes` has zero rows, no session is bound to bare role
  `reviewer`, and there is no role-bind verb (PO att_80db559a). Fixing auto-staffing needs
  role-bind — separate substrate work. This spec rules on remedy-vs-deny SEMANTICS (see
  Architecture §5) but does not build role-bind.
- **Opener-authority succession on retirement.** A retired opener orphans a review card's
  closure authority (PO att_c4e5840a). Real, adjacent, out of scope — and the review-card
  exemption (§3) SUBTRACTS the need for it on review cards specifically. Named, not designed
  here. Tracked separately.
- **Late-verdict marker for closed assignments.** A verdict filed after close is refused
  (`assignment_closed`), so the record can lose a real judgment (PO att_e13f055f). Adjacent
  companion; named, not designed here.
- **Verdict-vocabulary enum gap.** `verdictKind` rendering empty for non-enum strings is a
  silent-data-loss instance (PO att_83033aba); its own work item.
- **Changing what a reviewer's judgment MEANS.** The substrate records independence facts;
  whether a review is a rubber stamp is a mind's call (wisdom 6). This spec never asks the
  substrate to judge review quality.
- **The review-rounds doorbell.** Staged-not-armed in engineering.toml; unrelated.
- **Building the merge-gate rail.** Fable F6 confirmed NO merge-gate exists as machinery
  (only destructive-git statutes). §3a's rung-3 ("code enters main only via a gated merge") is
  therefore process-enforced, not physics. Minting a substrate merge-gate would harden it, but
  is its own work item; named here, not designed. The §3a exemption is sound on rungs 1-2
  regardless.

## Terms

- **completion-requires-review** — the rule in
  `kungfu/agentic-engineering/rules/engineering.toml` (L5-22). On `attest kind=completion`
  it denies unless `assignment.independent_verdict_kinds` contains `reviewed-clean`.
- **producing / build card** — an assignment whose deliverable is a reviewable artifact
  (code, spec). The only card class the rail is meant to gate. Contrast the exempt classes
  below.
- **review card** — an assignment carrying `reviewsAssignmentId` (assignments.ex:49). Its
  deliverable is a VERDICT on another assignment, not reviewable code.
- **recon / diagnosis card** — an assignment whose deliverable is a `diagnosed` verdict
  (see `refix-requires-diagnosis`, engineering.toml L28-47), not reviewable code.
- **orchestration / tracking card** — an assignment coordinating work (merge coordination,
  first-boot, huddles) with no reviewable artifact of its own.
- **specimen card** — a debugging-regime card recording substrate behavior; no reviewable
  artifact.
- **is_producing_card** — the computable BOOLEAN the rail gates on: does this card produce a
  reviewable artifact? THE new load-bearing fact (Architecture §2). Fixed at OPEN time by the
  opener, default true; never self-declared by the holder at close time. The rail needs only
  this boolean, not a class enum (subtraction, §2).
- **invariant 6** — canonical p3 L97-106, "Anti-laundering: independence is only ever
  established through the typed review link." A verdict filed DIRECTLY on producer `A`
  never counts toward any independence fact; independence reads only verdicts on a separate
  assignment `R` with `reviewsAssignmentId = A.id`. UNCHANGED by this redesign; load-bearing
  because it is what makes the review-LINK the sole independence channel.
- **invariant 6b** — canonical p3 L107-118, "Commissioned-reviewer-only." A review-link
  verdict counts toward an independence fact only when BOTH: **(a) AUTHOR axis** — its author
  is the holder of review assignment `R` (and ≠ `A`'s holder); **(b) OPENER axis** — `R` was
  NOT commissioned by `A`'s holder ("the producer cannot open its own reviewer"). This
  redesign amends clause **(b) only**.
- **author-independence** — the verdict's author session = `R`'s holder (6b clause a,
  `v.bySession = r.holderKey`, assignments.ex:263) AND ≠ the produced work's holder session
  (`v.bySession != producer`, assignments.ex:265). NB (fable N2): canonically the "≠ A's
  holder" condition lives in the fact-def parenthetical (excerpt L56), not in clause (a)'s
  prose; the amended 6b makes it explicit in-clause. KEPT — the permanent floor.
- **opener/commissioner-independence (6b clause b)** — the review card's opener session ≠
  the produced work's holder session. Deployed as assignments.ex:264
  (`r.openedBySession IS NULL OR r.openedBySession != producer`). THE line to drop; it has
  NO canonical cover for its removal (the L437-442 sanction is a DIFFERENT axis — see below).
- **the two orthogonal axes / the item-3 trap** — 6b encodes the OPENER axis (clause b);
  SEPARATELY, §4A (L437-442) offers the HARNESS/cross-model axis: an org gates on
  `cross_harness_verdict_kinds` (strong, cross-model) or `independent_verdict_kinds` (weaker,
  author-only-not-cross-model) — "its choice." These are DIFFERENT axes. The L437-442
  sanction covers dropping the CROSS-MODEL requirement; it does NOT sanction dropping the
  OPENER axis. Conflating them is the item-3 trap (PO adjudication, excerpt L74-78).
- **independent_verdict_kinds** — assignment fact (p3 L398): DISTINCT `verdict_kind` over
  `commissioned_review_authors/3` (author is `R`'s holder, `R` not commissioned by `A`'s
  holder, author ≠ `A`'s holder). The WEAK (author-only, non-cross-model) axis. What the rail
  reads TODAY.
- **cross_harness_verdict_kinds** — assignment fact (p3 L399): DISTINCT `verdict_kind` over
  the same `commissioned_review_authors/3` rows whose stamped `by_harness` ≠ the assignment's
  `holderHarness` (both non-null). The STRONG (cross-model) axis. Already exists — the item-3
  replacement gates the rail on THIS instead (Architecture §1).
- **FF-lineage close** — a completion satisfied because the merge-result sha equals the
  independently-reviewed branch sha (fast-forward identity: bit-identical artifact), a
  computable git fact feeding the gate's CHOSEN independence axis (§4A; `cross_harness_verdict_kinds`
  under the shipped REQUIRE value) — Architecture §4 (fable delta N4).

## Assumptions

Indicative givens this design relies on; each is falsifiable, and a false one is a hole.

- **A1.** `commissioned_review_authors` (assignments.ex:253-274) is the sole producer of
  `independent_verdict_kinds`; the rail reads no other independence source. (Grounded:
  read L253-274 on checkout 043e7d3e5880; PO att_0435dae9 confirmed by experiment that
  direct verdict rows on the target are NOT consulted.)
- **A2.** The query already SELECTs `v.byHarness, v.byProvider` (L258), so
  producer-vs-reviewer harness/provider comparison needs no new column read. (Grounded: read
  L258.)
- **A3.** `reviewsAssignmentId` exists on every assignment row (assignments.ex:49) and is
  set at open time by `assign --reviews`/`--reviews-assignment-id`. It is the one non-producing
  signal that ships WITHOUT a new field. (Grounded: read L49, L839-848.)
- **A4.** For non-review exempt classes (recon, orchestration, tracking, specimen) there is
  today NO computable class marker — no `--produces`/`--class` field is recorded at open
  time. The general kind-aware gate therefore requires a NEW declared fact (Q1).
- **A5.** FF-ness and sha identity are computable git facts available to whatever process
  evaluates the rail against a merge (PO att_32a48269 states the distinction is "mechanical,
  a git fact"). If the rule engine cannot reach git state at evaluation time, §4 needs a
  producing step that records the lineage as a fact (Q3).
- **A6.** The verbatim canonical excerpt is IN HAND (fetched by the PO,
  `fb46fbb03fac/tightbeam-product/p3-canonical-excerpts-for-goal2.md`, read 2026-08-07): 6b
  mandates BOTH the author axis (a) and the opener axis (b); the L437-442 sanction is the
  SEPARATE cross-model axis and does NOT cover dropping the opener axis. Q4 is now CLEARED
  (verbatim amendment written in §1b). The only residual is re-hashing the p3 file
  immediately before applying the edit (pin may drift; excerpt L8).
- **A7.** Clause 6b(b) lives inside `commissioned_review_authors/3`, which feeds BOTH
  `independent_verdict_kinds` AND `cross_harness_verdict_kinds` (p3 L398-399). Dropping
  assignments.ex:264 therefore changes BOTH facts — the amendment and its verification must
  cover both (PO adjudication, excerpt L89-92). (Grounded: excerpt fact defs L54-57.)

## Invariants

- **I1 (substrate/product separation).** The rail conditions only on substrate-owned,
  computable facts: session identity, harness/provider, `reviewsAssignmentId`, declared card
  class, git sha lineage. It never conditions on a holder's self-declaration made at close
  time, and never on a judgment about review quality. (wisdom 6, 10; subtraction: the wrong
  thing stays unrepresentable.)
- **I2 (self-review unrepresentable).** A completion can NEVER be satisfied by a verdict
  whose author session equals the produced work's holder session. Author-independence
  (assignments.ex:265) is the permanent hard floor; nothing in this redesign relaxes it.
- **I3 (no lying record; the HOLDER can close delivered work).** Every card reaches a
  terminal state that TELLS THE TRUTH about its outcome, filable BY ITS HOLDER. A
  done-and-nothing-to-review card completes as completed — never opener-revoked-as-if-
  withdrawn and never surrendered-as-abandoned (both corrupt outcome: surrendered ≠
  delivered, PO att_e13f055f and the live intake-card denial). The one who delivered must be
  able to close their own delivered card; forcing an opener/admin-only revoke or a
  false surrender to escape the rail is itself the defect.
- **I4 (`is_producing_card` is open-time-fixed and immutable).** The fact is set at open time
  and cannot be changed at close time; the rail keys on a row fixed before the work, not on a
  holder's close-time self-declaration. The design does NOT require opener ≠ holder — a
  self-opened card's class is a self-declaration, just an open-time one (fable F7). That is
  SAFE not because a distinct principal wrote it, but because mislabeling ships nothing
  (§3a rungs 1-2): the worst a mislabeled non-producing card does is close an accountability
  row without shipping an artifact. Open-time-fixity + immutability is the real guarantee;
  principal-distinctness is not claimed. (wisdom 2, 5.)
- **I5 (guard named, never silently dropped).** Dropping opener-independence (6b clause b)
  removes the self-commissioned-review anti-laundering guard; its replacement — gating the
  completion rail on the strong `cross_harness_verdict_kinds` axis, atop the permanent
  author-independence floor (I2) — is named in law, and the reopened path and residual risk
  are stated (§1c). No canonical cover is claimed for the drop. (wisdom 4, 5; ITEM-3.)
- **I6 (specific refusal, and "none" ≠ "none qualifying").** The deny must not emit the
  generic "needs reviewed-clean" that cost a team a day of misdiagnosis (PO att_df6af790);
  above all it may NOT report "no reviewed-clean verdict" when one PHYSICALLY EXISTS but fails
  6/6b (unlinked, or author-not-R's-holder) — false, and it sends the reader hunting for a
  review sitting right there, mislinked (PO relay #2, live specimen asg_f0220808/att_c277579a).
  **Mechanism reality (minter catch): the rule engine has ONE `text` per rule (rules.ex
  struct, `rule.text`) — there is NO per-condition text selection.** So TRUE per-branch deny
  text is unrepresentable without rule-engine work and is DEFERRED (Q9). SHIPPED FORM: a
  single static `text` that ENUMERATES the sub-conditions the reader must self-check (linked?
  filed by R's holder? not by you? cross-harness?) — one text, but honest and pointed, never
  the bare "no verdict" lie. This preserves I6's spirit within one-text; auto-selecting the
  one failing branch waits on the engine (Q9). Same class as remedy-named-before-deny
  (wisdom 4, 5).

## Architecture

The redesign is four coordinated changes plus one refusal-text requirement. §1 is Defect 1
(independence axis); §2-§4 are Defect 2 (subject class); §5 rules the remedy-vs-deny
question the no-op remedy forces; §6 is the refusal text; §7 is the guidance amendment it
teaches. §0 states the whole redesigned rule in one place; §1-§7 give the detail.

### §0 — The unified rule statement

`completion-requires-review`, redesigned, in one statement (detail in §1-§6):

> On an `attest` of `kind = completion` against a **producing card** (`is_producing_card =
> true`; review, recon, orchestration, tracking, specimen, and PO-intake cards are EXEMPT and
> discharge by their own terminal fact — §2-§3), the substrate DENIES the completion unless an
> **independent `reviewed-clean` verdict qualifies** under invariants 6/6b as amended:
> filed on a card LINKED via `reviewsAssignmentId` (inv 6), BY that review card's holder
> (6b clause a), whose session ≠ the producer (author-independence, I2), and — per the §4A
> gate policy, SHIPPED VALUE REQUIRE (set in rule config) — on a HARNESS ≠ the producer's
> (`cross_harness_verdict_kinds`, the ITEM-3 replacement for the dropped opener guard). A
> fast-forward merge whose result sha equals the reviewer-recorded reviewed sha satisfies this
> by LINEAGE (§4); a non-FF merge does not.
> The **opener axis** (6b clause b, "the producer cannot open its own reviewer") is DROPPED
> (§1). When the rule denies, the refusal ENUMERATES the specific surviving sub-condition
> that failed — genuinely-no-verdict / changes-requested-open / unlinked / author-not-holder
> / author-is-producer / same-harness / null-harness — and NEVER reports a blanket "no
> reviewed-clean verdict" when one exists but does not qualify (§6, I6; wisdom 5: a refusal
> names its rule).

### §1 — Independence axis: drop the opener axis, close the exposed path with cross-harness (Part A + ITEM-3)

**Change 1a (code).** In `commissioned_review_authors` (assignments.ex), DROP line 264
`AND (r.openedBySession IS NULL OR r.openedBySession != ?2)`. KEEP line 265
`AND v.bySession != ?2` (author-independence, I2). A producer MAY now open the review card
that commissions its independent reviewer; the reviewer's verdict counts as long as the
reviewer session ≠ the producer. **This one line feeds BOTH `independent_verdict_kinds` AND
`cross_harness_verdict_kinds` (A7) — both facts widen to admit producer-opened review cards;
the amendment's verification MUST exercise both.**

**Change 1b (canonical spec) — verbatim amendment of invariant 6b.** Invariant 6 (L97-106,
link-only anti-laundering) and 6b clause (a) (author axis) are UNCHANGED. Amend 6b to remove
clause (b) as a REQUIREMENT and name where the exposed path is re-closed. Pin: p3 sha
`87f4517a…` (re-hash before applying).

Current 6b (L107-118), verbatim in full (no elision — fable N1; the tail sentence is
REPLACED, not kept):

> 6b. **Commissioned-reviewer-only.** A review-link verdict counts toward an independence
> fact only when **both** hold: (a) its author is the **holder** of the review assignment
> `R` — the commissioned reviewer filing on its own review assignment; a *third* session's
> verdict on `R`, and any **user** verdict on `R`, never count (users rule by escalation, not
> review); and (b) `R` was **not commissioned by `A`'s holder** — the producer cannot open
> its own reviewer (the commissioner is the remedy principal, the owner, or another
> non-producer). Without (a) a producer colludes by planting a linked "shell" review
> assignment and filing on it from a second session; without (b) the producer commissions a
> friendly reviewer. `R`'s creator is its existing `openedBySession`/`openedByUser` opener
> (attest-v1 — no new column needed); `A`'s holder is `holderKey`.

Amended 6b (clause (b) removed; author axis + shell-path protection retained; gate policy
does NOT live here — fable B2). This 6b states ONLY the counting rule (which verdicts count
toward the independence fact); which fact the completion gate READS is §4A's job:

> 6b. **Commissioned-reviewer, author-independent.** A review-link verdict counts toward an
> independence fact only when its author is the **holder** of the review assignment `R` (the
> commissioned reviewer filing on its own review assignment) **and is not `A`'s holder**; a
> *third* session's verdict on `R`, and any **user** verdict on `R`, never count (users rule
> by escalation, not review). Without this, a producer would collude by planting a linked
> "shell" review assignment and filing on it from a second session — closed here and by
> invariant 6. **The producer MAY commission its own reviewer** (`R` may be opened by `A`'s
> holder): the former opener condition (clause b) is dropped org-wide per the completion-rail
> ruling (wi_bd0728d7), making this fact author-only. The friendly-reviewer exposure this
> creates is addressed at the COMPLETION GATE by the independence-axis choice (§4A), not by
> this counting rule. `A`'s holder is `holderKey`; `R`'s holder is `R.holderKey`.

**Change 1b-ii (canonical spec) — the `independent_verdict_kinds` fact-def (L398), fable
B1.** Current parenthetical (excerpt L56): "(invariants 6, 6b: author is `R`'s holder, `R`
not commissioned by `A`'s holder, author ≠ `A`'s holder; user and third-session verdicts
excluded)". Amend to drop the removed opener filter: "(invariants 6, 6b: author is `R`'s
holder, author ≠ `A`'s holder; user and third-session verdicts excluded)". Otherwise the
table describes a filter the function no longer applies.

**Change 1b-iii (canonical spec) — the §4A sanction prose (L437-442) becomes the gate-policy
home, fable B1+B2.** Current prose (excerpt L47-52) falsely claims the self-commissioned-
review path "is all closed (invariants 6, 6b)" — after the amendment 6b no longer closes it.
Replace with the gate policy (which is where "which axis an org's gate reads" belongs — the
prose already frames "same rule shape, weaker axis, its choice"):

> §4A gate policy — the completion gate's independence axis. With 6b now author-only, the
> self-commissioned-review path is closed not by the invariants but at the COMPLETION GATE by
> the axis the ORG SELECTS IN RULE CONFIG (the value is config, not law text — so a change is
> a config edit, never a canon re-amendment). Two arms:
> - **REQUIRE:** the gate reads `cross_harness_verdict_kinds` → the self-review,
>   same-family-review, direct-on-`A`, and shell-assignment paths stay closed by invariants
>   6/6b, AND the self-commissioned-review path is closed by requiring the commissioned
>   reviewer to be a harness the producer does not control.
> - **RECORD:** the gate reads `independent_verdict_kinds` (author-only) and SURFACES
>   `cross_harness_verdict_kinds` (surfaces = the fact is QUERYABLE on the assignment; no stamp
>   is written on an allowed completion — RECORD needs no record-and-allow effect, unlike the
>   deferred DEGRADE) — the self-commissioned-review path is an openly-recorded residual, not
>   closed. Same rule shape, weaker axis, its choice.

**Change 1c — ITEM-3, the NAMED replacement (non-negotiable), homed at the GATE not the
invariant (fable B2).** Per the PO mandate (excerpt L80-87), in three parts — the replacement
lives in the §4A gate policy (Change 1b-iii), NOT in 6b:

1. **What is removed.** Clause 6b(b) — "the producer cannot open its own reviewer" — is
   REMOVED (1a drops assignments.ex:264; 1b drops the clause). NO canonical cover: the
   L437-442 sanction is the cross-model axis, a DIFFERENT axis (the item-3 trap).
2. **What path reopens.** "The producer commissions a friendly reviewer." Author-independence
   alone (reviewer ≠ producer session) does not stop a producer-spawned, scripted puppet.
3. **The replacement (SHIPPED VALUE = REQUIRE).** The completion gate reads the STRONG axis
   `cross_harness_verdict_kinds` (already exists, p3 L399) — a producer-commissioned reviewer
   counts only on a **different harness** it does not control. PO's sufficiency argument
   (excerpt L84-87). No new machinery — it re-weights which existing sanctioned axis the gate
   reads. The value REQUIRE lives in the rule CONFIG (not canon, D4).

**The availability collision — why REQUIRE ships and DEGRADE is DEFERRED (fable delta D2).**
Unconditional REQUIRE is a hostage to harness onboarding: tonight's empty-cred fix had an
opus-5 coder + opus-4-8 reviewer on the SAME claude harness (codex then un-onboarded), so
`cross_harness_verdict_kinds` was necessarily empty and completion could never pass. The
clean resolution is DEGRADE (REQUIRE while ≥2 harnesses onboarded org-wide, else
author-independence-recorded-visibly). BUT the fable delta found DEGRADE needs TWO substrate
mechanisms that DO NOT EXIST: (1) an org onboarded-harness-count FACT (rules.ex has an
org-scoped precedent `org.live_sessions_owned_by_caller` but no onboarded-harness-count, and
"onboarded org-wide" needs a precise row-level definition); (2) a record-and-allow rail
EFFECT to stamp the "degraded" marker on an ALLOWED completion (the rails grammar has only
deny/remedy/escalate — no `notice`/record-and-allow; per the staged review-rounds-doorbell
comment, engineering.toml L71-78). Teach only what exists (wisdom 20): **this law ships
REQUIRE** (works today — codex is onboarded org-wide), keeps RECORD selectable, and DEFERS
DEGRADE to a PO follow-up that builds the two mechanisms. Boundary to state (fable D2):
exhaustion/unavailability ≠ un-onboarded — under REQUIRE an exhausted second harness makes
completion BLOCK (work-blocked escalation, intended), NOT degrade; the un-onboarded predicate
is an operator ceremony a producer has no verb to trigger, so DEGRADE (when built) is
ungameable except for an opportunistic single-harness TIMING window, which its conspicuous
marker makes auditable.

**The determined-puppet residual.** Cross-harness is a proxy, not proof of independent
judgment — the substrate cannot verify a mind is not scripted (wisdom 6). A producer could
spawn a scripted cross-harness session. Cross-harness makes the cheap same-harness attack
unrepresentable — the honest substrate ceiling.

**Q2 status — RESOLVED: ship REQUIRE, defer DEGRADE (fable delta D2, PO 2026-08-07).** The
spec commits the category-correct STRUCTURE (counting rule in 6b; axis policy + config
selection in §4A). The shippable VALUE is REQUIRE (existing machinery). DEGRADE is the
intended end-state but is descoped to a follow-up pending its two unbuilt mechanisms above
(PO is carding them); it is DOCUMENTED here as future work, NOT a live arm. mike holds the
config value (a config flip, not a canon re-amendment — D4). The B2 category fix applies
regardless of the value.

### §2 — Card class: the right subject fact (the throughline for Parts B, C, D)

**The general scope principle (the root behind every non-producer specimen).**
`completion-requires-review` must apply ONLY to cards that PRODUCE a reviewable artifact
(producer/coder work). Every non-producer card — review cards (§3a), recon/diagnosis,
coordination/orchestration, tracking, specimen, AND product-owner intake cards — is OUTSIDE
the rail's scope and needs an honest, HOLDER-FILABLE reviewer-less completion ("delivered, no
independent review applicable"), NOT a forced revoke (opener/admin-only) or surrender (which
records delivered work as ABANDONED — a provenance lie, I3). The review-card exemption
(item-6 / §3a) is a SPECIAL CASE of this one principle; so is the live PO-intake-card denial
(delivered work, no reviewable artifact, no reviewer possible or warranted) that surrendered
falsely tonight. One scope gate covers them all.

The rail treats every completion as a producing author's completion. That was always its
intended SUBJECT (it guards produced code from unreviewed self-completion); the rule merely
failed to SAY so and defaulted to all completions. Correct the subject: gate the rail on one
computable BOOLEAN — `assignment.is_producing_card`. The rail needs no finer taxonomy; a
richer class enum (which archetype, what discharge) is other consumers' concern, not this
rail's, and minting one here would be accretion the rail does not need (subtraction). The
boolean's laundering-safety is the SAME invariant as §3a: mislabeling a card non-producing
ships nothing, because completing a card merges no code (§3a safety invariant) — the code
still enters main only through an independently-gated merge.

- **Rule change:** the amended `completion-requires-review.deny_when` combines the subject
  gate (this §) and the §4A axis policy. Resulting clauses:
  - `{ fact = "attest.kind", op = "eq", value = "completion" }` (unchanged),
  - `{ fact = "assignment.is_producing_card", op = "eq", value = true }` (NEW, this §), and
  - the independence-axis clause, whose FACT is set by the §4A config value. SHIPPED VALUE
    REQUIRE reads
    `{ fact = "assignment.cross_harness_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }`;
    the RECORD arm reads `independent_verdict_kinds` (config flip, no code change). DEGRADE is
    deferred (D2 — needs the onboarded-count fact + a record-and-allow effect, neither built).

  The rail then fires only on producing cards that lack a qualifying independent
  reviewed-clean; every exempt class is simply never denied (silent-when-satisfied, wisdom 4).
- **Source of `is_producing_card` (I4) — and the honest phasing (fable F4):** fixed at open
  time by the opener; default `true` (producing). Two tiers:
  - **Ships now (derived, no new field):** `is_producing_card` is minted immediately as
    `reviewsAssignmentId IS NULL` — a card carrying `reviewsAssignmentId` is non-producing →
    exempt (§3, §3a). Nil `$assignment` → nil (rule does not fire). This clears the largest
    specimen group now (the reviewing-card regress, 12+; recon remedy-opened cards also carry
    `reviewsAssignmentId` per engineering.toml L46, so are covered too — fable t5).
  - **Needs the declared flag (Q1):** orchestration, tracking, specimen, and producer-less
    PO-intake cards have NO computable non-producing marker today (A4). Q1 EXTENDS
    `is_producing_card` to also read an opener-set `--non-producing` flag (immutable after
    open). **HONEST INTERIM (fable F4): until Q1 ships, these cards remain BLOCKED by the live
    rail** — the holder-filable completion in §3 is NOT executable pre-Q1, because the derived
    fact defaults them producing. Interim disposition for a genuinely-done such card is an
    explicit per-card opener waiver recorded truthfully (NOT surrender-as-abandoned), pending
    Q1. The spec does not claim an interim it cannot execute.

### §3 — Exempt-class discharge (Part B + the reviewer/recon/orchestration/specimen specimens)

Each exempt class discharges by its OWN terminal fact, not by being re-reviewed (kills the
infinite regress, I3):

- **review card** — the exemption UNBLOCKS the rail; it does not force closure on any
  verdict. The holder completes the card when its review obligation is discharged — a
  `reviewed-clean` verdict discharges it; a `changes-requested` verdict keeps the obligation
  open by the reviewer's own logic (a standing re-review), not the rail's. No recursion
  either way. (Part B: exempt `reviewsAssignmentId` rows — the adjudicated sub-rule §3a.)
- **recon/diagnosis card** — the holder completes it once its `diagnosed`/`not-proven`
  verdict is filed (a verdict-bearing exempt card, like a review card).
- **orchestration/tracking/specimen/PO-intake card** — no reviewable artifact; the HOLDER
  files a "delivered, no independent review applicable" completion, which completes the card
  truthfully (I3: completes as completed). This is a REQUIREMENT of the redesign, not an
  option: surrender records delivered work as ABANDONED (provenance lie) and revoke is
  opener/admin-only (strands the holder, and orphans on opener retirement, att_c4e5840a).
  The holder — the one who delivered — must be able to close their own delivered card.
- **Honest terminal state (elevated from interim to requirement; Q5 is now the substrate
  HOW, not a WHETHER).** The redesign REQUIRES a holder-filable reviewer-less completion
  outcome for non-producer cards. Whether that is the plain `completed` state or a
  distinguished "delivered, no-review-applicable" outcome value is the substrate detail (Q5),
  but SOME honest holder-filable close MUST exist. **Phasing (fable F4):** the holder-filable
  close for review/recon cards works NOW (they are non-producing via the derived fact); for
  orchestration/tracking/specimen/intake it is UNAVAILABLE until Q1's `--non-producing` flag
  ships — pre-Q1 those cards stay blocked, and a genuinely-done such card takes the one
  executable interim path (fable D6/R1; no "waiver" verb exists — wisdom 21): the holder (or
  opener) first files a `progress` attest on the still-open card recording
  delivered-not-withdrawn, and the OPENER then runs `revoke-assignment` — two rows, because
  the revoke verb carries no note and a revoked close has no closing attest (assignments.ex:62,
  1073-1109). (The PO did exactly this two-row close on the delta reviewer's v1 card.) This
  lives with the I3 tension the spec already admits — a bare revoke reads as withdrawn unless
  the preceding progress row says otherwise — and is strictly interim until Q1's
  `--non-producing` flag lets the holder close honestly. The requirement is firm; only its
  reach is phased.

**Subtraction check for §2-§3.** (1) ADD the class fact — chosen. (2) DELETE the surface:
stop opening completion-tracked assignments for non-producing work — rejected: the org
tracks orchestration/review/recon as assignments throughout; deleting that surface is a
larger redesign and loses the accountability the rows provide. (3) ACCEPT via opener-revoke
— rejected: it corrupts the outcome record (I3) and orphans on opener retirement
(att_c4e5840a). The class fact is not accretion; it supplies a predicate the rail always
needed but omitted.

#### §3a — Review-card exemption sub-rule (Part B), adjudicated and laundering-verified

**The defect (universal self-completion regress) — UNSATISFIABLE BY CONSTRUCTION, so the
exemption is NECESSARY, not merely preferable (mike, 2026-08-07).** In mike's words:

> A reviewing card (reviewsAssignmentId non-null) is not just under-scoped by the rail — it
> is UNSATISFIABLE BY CONSTRUCTION unless something is explicitly assigned to review the
> reviewer, which would be infinite regress.

This upgrades the justification from "gating a review card is the wrong scope" (a preference)
to a PROOF: `completion-requires-review` on `R` can NEVER be satisfied — the holder's own
verdict on `R` is not independent-of-`R`'s-holder, so the only path to a qualifying verdict is
a reviewer-of-the-reviewer, ad infinitum. A rail requiring a logically-unsatisfiable condition
is a DEFECT BY CONSTRUCTION; exempting `R` is therefore forced, not chosen. This is the crisp
statement behind all 15+ review-card specimens on record (source: mike, resolving
reviewer:turn-timeout-code's blocked card, same pattern). Absent the exemption, only the
opener can close `R` (by revoke), which CONTRADICTS reviewer-archetype guidance ("file
completion on the card you hold") and strands `R` in limbo (accountability rule 14). Live
datum: reviewer s_cac63ba9 on asg_aa45fd87, verdict att_14f755a8.

**The deepest stakes — the misapplication BIASES REVIEWERS TOWARD APPROVAL (clawline opus-5
reviewer; the strongest "why").** The trap is not verdict-neutral. Across the 15+ live
specimens the pattern is asymmetric: a reviewer who concludes REVIEWED-CLEAN sees the review
round close and their card with it, while a reviewer who files CHANGES-REQUESTED is left
holding a card the rail will not let them close (no reviewed-clean can ever exist on it).
Whatever the exact closure path, the incentive gradient points one way — filing "pass" clears
your board, filing "fail" traps you. So the misapplied rail applies APPROVAL PRESSURE to the
one archetype built to RESIST it: it does not merely annoy (a regress), it CORRUPTS REVIEW
INTEGRITY. That is the real cost the exemption removes — gating a review card does not just
demand eyes-on-eyes forever, it quietly rewards reviewers for passing. (Changes no mechanism;
strengthens the "why". The asymmetry's exact closure step is workflow-level — the rail itself
leaves `independent_verdict_kinds(R) = []` for every verdict — so this is stated as the
observed incentive gradient, not a claimed code mechanic.)

**The adjudication — fix (b) EXEMPT is FORCED, not chosen.** Given the unsatisfiable-by-
construction proof above, the only real question is HOW to exempt, not WHETHER. Two shapes:
(a) formalize "the opener closes the review card"; (b) EXEMPT `--reviews`-linked cards
(`reviewsAssignmentId != null`) from `completion-requires-review` entirely. (b), because it
addresses the defect at its root — the rail must not gate a card that cannot satisfy it — and
makes the regress UNREPRESENTABLE by construction (wisdom 26), restoring the reviewer guidance
instead of contradicting it and keeping `R` out of limbo (rule 14). (a) only patches the
symptom: it leaves `R` gated-but-uncompletable and dependent on the opener — the retired-opener
orphan (att_c4e5840a) and the lying-outcome revoke (I3) both recur under (a). (b) wins. This
exemption is the `reviewsAssignmentId` tier of the §2 `is_producing_card` gate, stated here as
its own sub-rule per the PO.

**Laundering-safety — the rungs, stated honestly (fable F6; say which rung you took,
tenets).** Exempting `R` opens no code path — but the guarantee stands on TWO rungs of
different strength, and the spec must not overclaim the weaker as "verified in code":
1. **[PHYSICS, code-verified] A review card cannot carry shippable code past the gate by
   relabeling.** `reviewsAssignmentId` is set ONLY on the `assign` verb, at open time
   (L839-840) — never at completion; immutable after open (I4). It MUST reference an existing
   assignment `A` (L842-844, `UnknownReviewTarget`) whose work item matches (L850-851). A
   producer cannot flip their own code card into an exempt "review card" at close time.
2. **[PHYSICS, code-verified] Completing a card ships nothing.** A completion attest writes a
   `state=completed` row (L1013-1038), cancels the effort check-in, and arms the owner slate
   wake (work_items.ex:458-488) — no merge. `commit_refs` are only existence-checked via
   `git cat-file` (L1378-1389), never merged. Fable confirmed NO merge machinery exists in
   product code (only destructive-git statutes; there is no merge-gate rail).
3. **[PROCESS, NOT substrate-verified — the honest caveat] The produced code stays gated at
   `A`.** The code that needs review lives in `A` (`R.reviewsAssignmentId`), which the rail
   still gates on `A`'s independent verdict. But "code enters main only through an
   independently-gated merge" is enforced by PROCESS/guidance, because no merge-gate exists as
   machinery (rung 2's finding). Supporting datum (clawline): the producer's gate keys on
   VERDICT-EXISTENCE not `R`'s closure, so (b) is downstream-free.
- **Closure (fable F6/F5/delta D1 — decision made): commit_refs on a NON-PRODUCING completion
  are FORBIDDEN** (not merely flagged — make the poison unrepresentable, wisdom 26). Otherwise
  a completed exempt card carrying a verified-existing sha reads downstream as delivered code
  and can poison an FF-lineage source (§4/F5). This is a `valid_commit_refs`/
  `commit_ref_filing_allowed` change, now in the Amends list (code change 4).

**Safety invariant this rests on (state it so it can be falsified).** Completing an
assignment must remain a pure accountability act that merges no code [rungs 1-2, PHYSICS,
verified today]; and code must enter main only through an independently-gated merge [rung 3,
PROCESS — currently guidance, NOT machinery: no merge-gate rail exists]. If rung 1-2 ever
ceases to hold — if completing a card could itself ship an artifact — this exemption reopens
a hole. Rung 3 is the softer leg: until a merge-gate rail exists, "unreviewed code can't
reach main" is process-enforced, and this spec says so rather than claiming physics it does
not have. Building the merge-gate rail is out of scope (named, Non-Goals-adjacent).

**Interaction with ITEM-3 — orthogonal.** Item-3 (§1) drops the OPENER-independence guard
on WHICH verdicts on `R` count toward `A`. §3a is about whether `R` ITSELF is gated. Neither
touches the other: after item-3, `A` still needs a qualifying (author-independent, and under
Q2 cross-harness) verdict on `R`; §3a merely lets `R`'s holder close `R` by filing that
verdict. Together they restore the reviewer's normal close path without shipping unreviewed
code.

### §4 — FF-lineage close (Part C, wi_f89ac9ec)

For a fast-forward merge whose resulting main sha IS the independently-reviewed branch sha,
the branch's `reviewed-clean` satisfies completion — zero unreviewed content exists; a
second review reviews nothing and teaches that review is ritual (PO att_32a48269).

- **Where the reviewed sha comes from (fable F5 — provenance, made computable).** "The
  reviewed branch sha" must be a RECORDED fact, not an inferred one. Specify: the sha a
  reviewer reviewed is the `commit_refs` recorded ON THE REVIEW-LINK VERDICT itself (the
  `reviewed-clean` attest on the card whose `reviewsAssignmentId = A.id`) — the same attest
  the independence facts already read. FF-lineage compares `main`'s post-merge HEAD sha to
  THAT verdict-recorded sha. **Exclusion (anti-poison, ties F6):** only a QUALIFYING (under
  6/6b + the §4A axis) review-link verdict's `commit_refs` may source the lineage — NEVER
  `commit_refs` on a completion attest of any card (which are legal on exempt cards and thus
  poisonable, §3a closure). A holder
  cannot self-declare the lineage (I1, I4); it is the reviewer's recorded verdict sha or
  nothing.
- **REQUIRED code change (fable delta D1 — the mechanism is refused today):** `valid_commit_refs`
  (assignments.ex:1337-1352) accepts `commit_refs` on `kind = "completion"` ONLY; a verdict
  carrying them errors "commitRefs are only valid on completion attests." So this mechanism is
  UNREPRESENTABLE until `valid_commit_refs` is RELAXED to accept `commit_refs` on a review-link
  `kind = "verdict"`. That relaxation, and the reciprocal FORBID of `commit_refs` on a
  non-producing completion (the anti-poison closure), are BOTH now in the Amends list (code
  changes 3-4). Until they ship, §4/AC5 cannot be constructed — so §4 rides the same amendment,
  not a separate later one.
- **Mechanism:** the computable fact — post-merge `main` HEAD sha == the review-link
  verdict's recorded reviewed sha (FF identity) — feeds the SAME independence predicate the
  rail reads (§4A axis). The reviewed-clean it carries is the branch's own commissioned
  review, so its harness/independence strength travels with the lineage.
- **Non-FF merges keep full current semantics:** the merge commit is new code no reviewer
  saw; re-gate on the merged result + independent verdict (PO ruling, att_32a48269). FF-ness
  is a git fact, so the wrong thing stays unrepresentable.
- If the rule engine cannot reach git state at evaluation time (A5), a deterministic
  producing step records the lineage as a fact before the completion is evaluated (Q3).

### §5 — Remedy vs deny (forced by the no-op remedy)

Today `effect = "remedy"` but the remedy never fires (0 episodes, unbound `reviewer` role,
no role-bind verb — att_80db559a). So the rail is a DENY dressed as a remedy, and its denial
text never says whether a reviewer was staffed. Ruling for this redesign: the rule's stated
INTENT (auto-staff a reviewer) is retained as the target, but because auto-staffing does not
exist (Non-Goals), the DENY path MUST carry the named manual sanctioned path NOW (§6), and
the aspirational auto-staffing is marked dependent on role-bind. Teach only what exists
(wisdom 20): the guidance and refusal describe the manual path that works today, not the
remedy that doesn't. Whether to relabel `effect` to `deny` until role-bind ships is Q7.

### §6 — Deny-message honesty (folded specimens att_df6af790 + PO relay #2)

**Shipping form (minter catch, I6/Q9): the rule engine has one `text` per rule — no
per-condition selection.** So the branches below are NOT seven separate rule texts today;
they are the CONTENT the single shipped `text` enumerates (a checklist the reader
self-applies), and the future per-branch AUTO-selection is deferred to Q9. The list is
authoritative for both: what the one static text must name now, and what the deferred
per-branch text will key on later.

The deny path names the ACTUAL surviving unmet sub-condition and its remedy — never the
generic "needs reviewed-clean" (I6). The core distinction (relay #2): the rail denies when
the QUALIFYING set (`independent_verdict_kinds` / `cross_harness_verdict_kinds`) lacks
`reviewed-clean`, and that set can be empty for two very different reasons — no verdict at
all, or a verdict that exists but fails 6/6b. The message MUST tell them apart. Branches
(evaluated against the completing producing card `A`):

- **genuinely no verdict** — no verdict row on any card linked to `A` → "no independent
  review found — have a reviewer file a verdict on a card that `--reviews` this assignment."
- **linked review is CHANGES-REQUESTED, round open (fable F3, the most common real deny)** —
  a linked review card carries a `changes-requested` verdict, not `reviewed-clean` → "the
  linked review's verdict is changes-requested — the review round is open; address the
  findings, then have the reviewer re-file reviewed-clean." (Every producer re-attesting
  mid-round hits this; it matches none of the other branches.)
- **verdict exists but UNLINKED (invariant 6)** — a `reviewed-clean` exists directly on `A`,
  or on a card whose `reviewsAssignmentId` is null/points elsewhere → "a reviewed-clean
  verdict exists but is not on a review card linked to this assignment (`reviewsAssignmentId`
  is missing); re-file it on a card that `--reviews` this assignment." (This is the live
  specimen asg_f0220808 / att_c277579a.)
- **verdict author is not R's holder (6b clause a, SURVIVES)** — the linked card's verdict
  was filed by a third session or a user → "the verdict on the review card was not filed by
  its holder (a third-party or user verdict is not a commissioned review)."
- **verdict author IS the producer (author-independence, I2, SURVIVES)** → "a review by the
  work's own author is not independent."
- **review is same-harness (the shipped REQUIRE value — §4A)** — a qualifying
  author-independent verdict exists but on the producer's own harness → "the review is
  same-harness; this org requires cross-harness independence — commission a reviewer on a
  different harness." (When the deferred DEGRADE arm ships, a genuine single-harness state
  would instead pass with the degraded marker — not part of this amendment.)
- **null-harness under REQUIRE (fable F3)** — a qualifying author-independent verdict exists
  but `by_harness` or `holderHarness` is unstamped (null), so `cross_harness_verdict_kinds`
  excludes it (both must be non-null, p3 L399) — distinct from same-harness → "the review's
  harness is unstamped; re-file the verdict from a harness-stamped session (or re-stamp) so
  cross-harness independence can be evaluated."

**Non-producer cards produce NO deny at all (3rd deny-honesty datum).** The tonight
PO-intake denial ("requires a reviewed-clean verdict" for delivered work with no reviewer
possible or warranted) is doubly misleading — no verdict is possible AND none is warranted.
Its fix is NOT better message text but the §2 scope gate: a non-producer card is exempt, so
the rail never fires and there is no message to get wrong. Deny-message honesty (below)
governs PRODUCING-card denials; the scope gate eliminates the non-producer misfires entirely.

**Interaction with ITEM-3 (relay #2).** After the opener-drop (§1), "review card is
producer-opened" STOPS being a disqualifier, so it is NOT a deny branch. The authoritative
branch list is the one above (§0 mirrors it); this note does not re-enumerate it (fable delta
D3 — a second, stale enumeration here contradicted it; deleted per one-concept-one-home).

### §7 — Guidance / operating-pattern amendment (fable F8; what this teaches)

Per guidance-authoring ("for every ratified capability spec, answer what pattern it teaches"),
this redesign changes operating practice and MUST land a guidance amendment with it — not
"none". Two teachings, homed by frequency:

- **Orchestrators — EXACT FILE `priv/kungfu/agentic-engineering/guidance/orchestrator.md`
  (minter catch):** under the shipped REQUIRE value, a producer dispatch must staff a reviewer
  on a DIFFERENT harness than the producer; a same-harness review no longer clears completion
  (and, until the deferred DEGRADE arm ships, a genuine single-harness window blocks completion
  — work-blocked, not a silent pass). This replaces the old third-party-opener dance (deleted
  by the opener-drop) with a cross-harness-reviewer expectation. (orchestrator.md already
  references completion-requires-review, so the teaching co-locates there.)
- **All openers — same file `orchestrator.md`** (openers are orchestrators): non-producing
  cards (review/recon auto-derived; orchestration/tracking/specimen/intake need it) are
  declared `assign --non-producing` (Q1) so holders close them honestly; do NOT surrender
  delivered work or revoke-as-withdrawn to escape the rail.
- **Reviewer/coder-facing note:** the reviewer kernel
  `priv/kungfu/agentic-engineering/guidance/reviewer.md` already says "file completion on the
  card you hold"; §3a makes that TRUE (review cards now close on their verdict), so no edit is
  required there unless it references the old regress — grep-and-check at apply.

The exact guidance edit TEXT is a guidance-authoring deliverable, batched with the code per
wisdom 22, NOT drafted here (teach only what exists — the text lands the day the commands
ship, wisdom 20). It is authored via the identity/kungfu seam, not guessed by the code-minter:
the minter should land the code + spec + rule mint, and the guidance-author (spec-writer or
PO) writes orchestrator.md's edit to co-land — the minter flags if it expects the guidance in
the same branch and I will draft it.

## Acceptance

Concrete Given/When/Then checks. A synthetic repro (open card, self-review, attempt
completion — 3 commands, PO att_524db76b) replaces the released live fixture pair.

- **AC1 (producer-opened review passes; Part A opener-drop).** Given a producing card held
  by session P (harness=claude) and a review card `--reviews` it, OPENED BY P, whose
  `reviewed-clean` verdict is filed by an independent CROSS-HARNESS session R
  (R≠P, harness=codex). When P attests completion. Then completion PASSES — the producer-as-
  opener no longer excludes (opener axis dropped), and the cross-harness gate is satisfied.
  [Fails today for a different reason — opener==P excludes: att_e7c83569.]
- **AC2 (self-review still blocked; I2).** Given a producing card held by P and a
  `reviewed-clean` verdict filed by P. When P attests completion. Then completion is DENIED
  with the "review by the work's own author is not independent" text (§6).
- **AC3 (cross-harness gate closes the friendly-reviewer path; ITEM-3/§4A REQUIRE, ≥2
  harnesses).** Given ≥2 harnesses onboarded, a producing card held by P (harness=claude), and
  a producer-opened review card whose `reviewed-clean` verdict is filed by a SAME-HARNESS
  independent session R (R≠P, harness=claude). When P attests completion. Then
  `cross_harness_verdict_kinds` is empty and completion is DENIED with the "review is
  same-harness; requires cross-harness independence" text (§6). [Q2 record-only: PASSES,
  `same-harness` surfaced.]
- **AC3b (SHIPPED REQUIRE blocks single-harness honestly; §4A).** Given ONLY one harness
  onboarded (codex un-onboarded), a producing card held by P (opus-5, claude) and a
  same-harness `reviewed-clean` from R (opus-4-8, claude). When P attests completion. Then
  under the SHIPPED REQUIRE value it is DENIED "same-harness; requires cross-harness
  independence" (§6) — an honest block, surfaced as work-blocked, NOT a silent pass.
- **AC3b-future (DEFERRED — DEGRADE, not part of the shipped law).** The same Given, once
  DEGRADE and its two mechanisms (onboarded-count fact + record-and-allow effect, D2) ship:
  completion PASSES with a conspicuous "degraded: single-harness" marker. This is tonight's
  empty-cred scenario; it is the DEFERRED end-state, listed so the follow-up carries an
  acceptance check — NOT a check against this amendment.
- **AC4 (verdict-bearing exempt cards complete; Part B, §3a).** Given a review card
  (reviewsAssignmentId set) whose holder has filed a `reviewed-clean` verdict — OR a recon
  card whose holder has filed a `diagnosed` verdict. When the holder attests completion. Then
  completion PASSES without demanding a review-of-the-review/diagnosis. And given a review
  card whose holder filed `changes-requested`, when the holder chooses to keep it open, then
  the rail does not force its closure (§3). [Fails today: 12+ specimens, incl.
  asg_aa45fd87 / att_14f755a8; recon variant recon:wake-corruption.]
- **AC4b (review-card exemption is laundering-safe; §3a safety invariant).** Given a
  producer opens a card X (reviewsAssignmentId → a real producer `A`) and completes X under
  the exemption. When X completes. Then NO artifact merges to main by that completion (it is
  a `state=completed` row only), AND `A`'s own completion still DEMANDS its independent
  verdict — so no unreviewed code ships. And given an attempt to set reviewsAssignmentId at
  COMPLETION time (not open), then it is rejected/ignored (it is an `assign`-time,
  opener-set, immutable field).
- **AC5 (FF-lineage close; Part C, provenance per F5 — constructible ONCE the D1 code
  changes ship).** Given the `valid_commit_refs` relaxation (Amends code-change 3) so a
  review-link `reviewed-clean` VERDICT can record reviewed sha X via its `commit_refs`, and
  main fast-forwarded so HEAD == X. When completion is attested. Then it PASSES via FF-lineage
  (HEAD sha == verdict-recorded sha). And given a NON-FF merge commit Y≠X, completion still
  DEMANDS an independent verdict on Y. And given a completed EXEMPT card carrying `commit_refs`
  (now FORBIDDEN, code-change 4) — the poison path is closed by construction. NB: this AC is
  unconstructible against TODAY's substrate (commit_refs on a verdict error) — it becomes
  decidable when code-changes 3-4 ship in the same amendment (D1).
- **AC9 (deny names changes-requested-open; F3/I6).** Given a producing card with a linked
  review card carrying only a `changes-requested` verdict. When the producer attests
  completion. Then it is DENIED naming "the linked review's verdict is changes-requested — the
  round is open," NOT "no reviewed-clean verdict."
- **AC10 (deny names null-harness under REQUIRE; F3/I6).** Given ≥2 harnesses and a qualifying
  author-independent `reviewed-clean` whose `by_harness` is unstamped (null). When completion
  is attested. Then it is DENIED naming the "unstamped harness" sub-condition — distinct from
  same-harness.
- **AC6 (non-producer holder-close honest; Part D + intake).** Given an orchestration,
  tracking, specimen, or PO-intake card with no reviewable artifact, classed non-producing at
  open. When its HOLDER attests completion. Then it completes AS COMPLETED / "delivered,
  no-review-applicable" (I3, §3) — the rail never fires, and the holder is NOT forced into
  opener-revoke or a false surrender. [Live scars: goal-10 card asg_28b57697
  (att_524db76b, att_9abf9ada); the tonight PO-intake denial that surrendered delivered work.]
- **AC7 (specific refusal; I6).** Given each distinct failure in §6. When denied. Then the
  refusal names that specific unmet condition and its path — not the generic text.
- **AC7b ("none" ≠ "none qualifying"; I6, relay #2 live specimen).** Given a producing card
  `A` and a genuine independent `reviewed-clean` verdict that exists but does NOT qualify —
  filed on a producer-opened card whose `reviewsAssignmentId` is null (the asg_f0220808 /
  att_c277579a shape). When completion is attested. Then it is DENIED, and the refusal names
  the UNLINKED sub-condition ("a reviewed-clean exists but is not on a linked review card")
  — NOT "no reviewed-clean verdict." [Fails today: message conflates the two.]
- **AC8 (unrepresentable self-exemption; I1/I4).** Given a producing card, when its holder
  attempts to self-declare a non-producing class or an FF-exemption at close time. Then it
  has no effect — class is opener-set-immutable and FF-ness is a git fact.

## Open Questions

- **Q1 (NON-BLOCKING) — the `is_producing_card` declaration.** The rail needs ONE opener-set
  boolean, not a class enum. Exact shape: a new `assign --non-producing` flag (opener-set,
  default producing, immutable), or derive it from an existing signal (holderRole, remedy
  `produces`)? Recommendation: an explicit opener-set boolean, default producing (I4;
  role-derivation is a spoofable proxy). If other consumers later need a finer class
  taxonomy, that is a separate concern — this rail must not mint it. Parts A/B/C ship without
  this on existing facts (reviewsAssignmentId, git lineage); Part D's general case waits on
  it. Route to PO for the substrate-cost call.
- **Q2 (RESOLVED 2026-08-07; REVISED at fable delta D2) — ship REQUIRE, defer DEGRADE.** The
  spec commits the category-correct STRUCTURE (counting rule in 6b; axis policy + config
  selection in §4A). The PO first selected DEGRADE, but the delta found DEGRADE needs two
  unbuilt substrate mechanisms (Q8); so the SHIPPED VALUE is REQUIRE (existing machinery,
  practical now with codex onboarded), RECORD stays config-selectable, and DEGRADE is DEFERRED
  to a PO follow-up. The value lives in rule CONFIG (a flip is a config edit, not a canon
  re-amendment — D4). B2 category fix applied regardless.
- **Q8 (DEFERRED — DEGRADE prerequisites, PO carding).** DEGRADE is out of THIS amendment; it
  needs two mechanisms that do not exist (delta D2): (1) an org **onboarded-harness-count
  fact** in rules.ex (precedent `org.live_sessions_owned_by_caller`; "onboarded org-wide"
  needs a precise row-level definition — what row makes a harness onboarded), and (2) a
  **record-and-allow rail effect** (the grammar has only deny/remedy/escalate; the marker must
  stamp on an ALLOWED completion — grow a `notice` effect or stamp in the attest path). Rule
  SHAPE recommendation (for the follow-up): single rule, harness-count guard, OBJECTIVE
  org-onboarded-count predicate (NOT per-work availability — exhaustion ≠ un-onboarded, so a
  producer cannot induce degrade; residual opportunistic single-harness TIMING is made
  auditable by the marker). The PO is carding both mechanisms.
- **Q9 (DEFERRED — per-branch deny text, minter catch, PO to card).** I6's per-branch refusal
  text (a distinct message auto-selected for the one failing sub-condition) is unrepresentable
  today: the rule engine carries ONE `text` per rule (rules.ex struct; `rule.text` is the only
  denial string) with no per-condition selection. SHIPPED NOW: a single static `text` that
  enumerates the sub-conditions as a self-check (I6/§6) — honest, never the "no verdict" lie,
  but not auto-pointed. DEFERRED: true per-branch text needs rule-engine work (per-condition
  text, or a templated denial keyed on the failing `deny_when` clause). Same defer-not-fake
  class as DEGRADE (Q8). Route to PO to card with the DEGRADE mechanisms.
- **Q3 (NON-BLOCKING) — git reachability at rule eval.** Can the rule engine read git sha
  state when evaluating §4, or must a deterministic step record the FF-lineage fact first?
  (Distinct from F5, now resolved: WHICH sha was reviewed is the review-link verdict's
  recorded `commit_refs` — §4. Q3 is only about the engine reaching `main`'s HEAD.)
  Determines whether §4 is a pure rule change or rule + a producing step. Route to the coder
  during build; interim is the producing step (safe).
- **Q4 (CLEARED 2026-08-07) — canonical excerpt.** The verbatim p3 invariant 6/6b (L107-118),
  invariant 6 (L97-106), the L437-442 sanction and fact defs (L398-399) are IN HAND
  (`fb46fbb03fac/tightbeam-product/p3-canonical-excerpts-for-goal2.md`) and the amendment is
  written against them in §1b. Only residual: RE-HASH the p3 file (pin sha `87f4517a…`)
  immediately before applying the edit, and ask product-owner:tightbeam for any range beyond
  the excerpt rather than guessing.
- **Q5 (NON-BLOCKING — now a HOW, not a WHETHER) — holder-filable reviewer-less completion
  outcome.** The redesign REQUIRES that a non-producer card's HOLDER can close it truthfully
  (§3, I3). The only open detail is the substrate vocabulary: is it the plain `completed`
  state, or a distinguished "delivered, no-review-applicable" outcome value that preserves
  provenance (delivered ≠ reviewed-and-cleared)? Recommendation: a distinguished outcome so a
  reader can tell a reviewer-less close from a reviewed one. Confirm the value with the PO.
  Until it lands, holder-attests-completion held truthfully (never surrender/opener-revoke).
- **Q6 (operational, not a design hole) — canonical homing.** This draft cannot be placed at
  its canonical eezo-NFS path from gibson. Placement is a handoff step for an eezo-mounted
  session (PO or a spec-writer sibling). Not blocking the design.
- **Q7 (NON-BLOCKING) — relabel effect to deny?** Until role-bind makes the remedy real
  (Non-Goals), should `completion-requires-review.effect` be `deny` (honest) instead of
  `remedy` (aspirational no-op)? Recommendation: keep `remedy` as recorded intent but ensure
  the deny path carries the manual sanctioned path now (§5, §6). PO ruling.
