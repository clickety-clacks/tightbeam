# Preferred models — substrate

Two parts: CAPSULES (the org's working set — the minds we actually use, characterized
once each) and the SUBSTRATE'S OWN ACTIVITIES. Kungfu-owned activities live in each
bundle's `kungfu/<name>/preferred-models.md`. The working set is deliberately small:
a model not listed here is NOT IN USE — adding one is an intake/release-ceremony act.

## Working set (capsules)

- **claude-fable-5** — deepest judgment and breadth; load-bearing rulings, adversarial
  whole-system review, wisdom-level authoring. Expensive; reserve for what needs it.
- **claude-opus-5** — strong general reasoning and composition; coordination,
  drafting under rulings, reviewing another model's code.
- **claude-sonnet-5** — the everyday mind: conversation, general agency, light
  analysis; the org default. Not for adversarial depth.
- **claude-haiku-4-5-20251001** (nickname: haiku) — fast and cheap: classification, extraction, mechanical
  transforms. Never judgment.
- **gpt-5.6-sol** — the implementer: focused greenfield goals with invariants stated
  up front; adversarial spec review at high effort. Pauses on underspecification
  (virtue). Never orchestrates; stalls on rework-in-place.
- **gpt-5.3-codex-spark** — utility intelligence: summarization and
  deterministic-but-loose transforms that still need inference. Cheap, fast.
- **gpt-5.6-luna** (nickname: luna) — straightforward-task workhorse at high/xhigh effort: classification,
  triage, and other non-load-bearing work that still needs inference. Not for
  judgment that carries weight.

Capsule names are the CANONICAL catalog base ids (what `tightbeam list` shows);
activity tables use the parenthetical nickname + an effort bracket — expand to
`<canonical-base>[effort]` when you spawn (e.g. sonnet[medium] -> claude-sonnet-5[medium]).

Effort brackets (claude-x[low..max], sol[low..xhigh]) tune depth within a capsule;
`tightbeam list` shows the live legal forms.

## How to read the activity tables

ONE column of minds per activity, IN ORDER: use the first available, step rightward
if it is not. If NONE is available, PARK the work until one recovers — the end of the
list IS the floor; nothing off-list may do the work. `any` = no floor: any available
mind may do it.

## Substrate activities

| Activity | Wants | Minds, in order (park if none) |
|---|---|---|
| General user conversation (default agent) | breadth, warmth, cheap to idle | sonnet[medium], opus[medium] |
| Onboarding / discovery conversations | judgment about people, reframing | fable[high], opus[high], sol[low] |
| Adjudication briefs (owner ruling) | fast sound judgment over facts | the owner's own mind — no swap; opus-class or sol[low] if re-staffed |
| Failure classification, log triage | fast pattern matching | luna[high], haiku, sonnet[low], any |
| Guidance / law authoring | wisdom-grade writing | fable[high], opus[high], sol[xhigh] |
