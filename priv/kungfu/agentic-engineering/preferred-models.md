# Preferred models — engineering kungfu

The single model catalog, selection, and ring-down source for this engineering kungfu.
The org owns this table; retune it through an identity edit, not by deference to
whoever wrote it. There is no separate policy table.

## Working set (capsules)
<!-- machine-read: mix tightbeam.catalog.diff parses each capsule id from the
     leading "- **<id>**" of these bullets; keep that shape when editing. -->

- **claude-fable-5**: deepest judgment and breadth; load-bearing rulings, adversarial
  whole-system review, wisdom-level authoring. Expensive; reserve for what needs it.
- **claude-opus-4-8**: strong general reasoning and composition; coordination,
  drafting under rulings, reviewing another model's code.
- **claude-sonnet-5**: the everyday mind for conversation, general agency, and light
  analysis; the org default. Not for adversarial depth.
- **claude-haiku-4-5-20251001** (nickname: haiku): fast and cheap classification,
  extraction, and mechanical transforms. Never judgment.
- **gpt-5.6-sol**: the implementer. Focused greenfield goals with invariants stated
  up front; adversarial spec review at high effort. Pauses on underspecification
  (virtue). Never orchestrates; stalls on rework-in-place.
- **gpt-5.3-codex-spark**: utility intelligence. Summarization and
  deterministic-but-loose transforms that still need inference. Cheap, fast.
- **gpt-5.6-luna** (nickname: luna): straightforward-task workhorse at high/xhigh
  effort for classification, triage, and other non-load-bearing work that still
  needs inference. Not for judgment that carries weight.

Capsule names are the canonical catalog base ids (what `tightbeam list` shows).
Activity rows use the parenthetical nickname plus an effort bracket; expand to the
canonical catalog base plus effort when spawning. Effort brackets tune depth within a
capsule; `tightbeam list` shows the live legal forms.

## Activity table

| Activity                                        | Wants                              | Minds, in order (blocked if none)                                                |
| ----------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------- |
| Product ownership / spirit discovery            | reframing, long-horizon judgment   | fable[high], opus[xhigh]                                                         |
| Spec drafting (under rulings)                   | faithful composition               | opus[high], sonnet[high]                                                         |
| Spec adversarial review                         | hostile depth, hole-hunting        | sol[xhigh] (xhigh whole-lattice), fable[high], opus[high]                        |
| Orchestration (flow, dispatch, tracking)        | reliability, judgment-on-facts     | fable[high]; fable when contested, sol[high]                                     |
| Implementation — NEW patterns, critical code, tough bugs | architectural judgment while coding | opus[high], fable[high] when load-bearing |
| Implementation — straightforward, well-specced, well-bounded goal | precision, pause-on-gap | sol[medium], sonnet[high] |
| Implementation — established patterns (the default once a pattern exists) | faithful extension | sol[medium], sonnet[high] |
| Code review of a review-required effect         | independent judgment + rigor       | opus[high], fable[high], sol[high]                                                |
| Recon / investigation                           | evidence discipline, cheap breadth | sol[high], opus[high]                                                            |
| Mechanical sweeps (renames, fixtures)           | speed                              | terra[low], sonnet[low], any                                                     |
| General user conversation (default agent)        | breadth, warmth, cheap to idle      | sonnet[medium], opus[medium]                                                     |
| Onboarding / discovery conversations             | judgment about people, reframing    | fable[high], opus[high], sol[low]                                                |
| Failure classification, log triage               | fast pattern matching               | luna[high], haiku, sonnet[low], any                                              |
| Guidance / law authoring                         | wisdom-grade writing                | fable[high], opus[high], sol[xhigh]                                             |

For code review, independence means a fresh session with the capability required by
the effect. A same-model, same-provider, or same-harness reviewer remains qualified
when it is the first permitted candidate left in this ordered row; those differences
are useful selection evidence, not gates on the verdict.

## How to read this table

ONE column of minds per activity, IN ORDER: use the first qualified candidate that
the live catalog permits. A candidate is available only when its model and effort are
selectable on an allowed host, its credential can run, and it has the capability the
activity requires. If NONE is available, the work is BLOCKED. The end of the list IS
the floor; nothing off-list may do the work. `any` = no floor: any available mind may
do it.

Decide at spawn AND again whenever a mind fails you mid-work. Try each candidate once:
a refused spawn or a harness out of tokens advances you one place to the right, never
back to the same candidate. If qualification is ambiguous, pause for adjudication; do
not guess. When no mind on the list is available, the list has produced a named
capability block: record the attempted rungs and evidence on the affected assignment,
keep separable work moving, and schedule a re-check. Do not report up merely because
the list ended; Main is never a model fallback. A responsible owner surfaces a real
credential need to the user only through the normal exception path. Never a silent
stall, never a retry loop against a wall.
