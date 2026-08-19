# Preferred models (substrate)

Two parts: CAPSULES (the org's working set, the minds we actually use, characterized
once each) and the SUBSTRATE'S OWN ACTIVITIES. Kungfu-owned activities live in each
bundle's `kungfu/<name>/preferred-models.md`. The working set is deliberately small:
a model not listed here is NOT IN USE, and adding one is an intake/release-ceremony act.

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

Capsule names are the CANONICAL catalog base ids (what `tightbeam list` shows);
activity tables use the parenthetical nickname + an effort bracket; expand to
`--model <canonical-base> --effort <effort>` when you spawn (e.g. sonnet[medium] ->
`--model claude-sonnet-5 --effort medium`).

Effort brackets (claude-x[low..max], sol[low..xhigh]) tune depth within a capsule;
`tightbeam list` shows the live legal forms.

## How to read the activity tables

ONE column of minds per activity, IN ORDER: use the first qualified candidate that
the live catalog permits. A candidate is available only when its model and effort are
selectable on an allowed host, its credential can run, and it has the capability the
activity requires. If NONE is available, the work is BLOCKED. The end of the list IS
the floor; nothing off-list may do the work. `any` = no floor: any available mind may
do it.

Decide at spawn AND again whenever a mind fails you mid-work. Try each candidate once:
a refused spawn or a harness out of tokens advances you one place to the right, never
back to the same candidate. If qualification is ambiguous, stop and ask your parent to
adjudicate it; do not guess. When no mind on the list is available, follow
`model-policy.md`'s three moves: switch is off the table by definition, so have your
parent assert `work-blocked` over the affected session and report up, or surface the
credential need to the user. Never a silent stall, never a retry loop against a wall.

## Substrate activities

| Activity | Wants | Minds, in order (blocked if none) |
|---|---|---|
| General user conversation (default agent) | breadth, warmth, cheap to idle | sonnet[medium], opus[medium] |
| Onboarding / discovery conversations | judgment about people, reframing | fable[high], opus[high], sol[low] |
| Failure classification, log triage | fast pattern matching | luna[high], haiku, sonnet[low], any |
| Guidance / law authoring | wisdom-grade writing | fable[high], opus[high], sol[xhigh] |
