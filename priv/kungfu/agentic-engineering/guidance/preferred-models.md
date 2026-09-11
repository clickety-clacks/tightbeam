# Preferred models

Own model selection through this guidance and the installed kungfu's activity table.
Keep canonical names, selection mechanics and substrate activities here. Engineering
activities live in `kungfu/agentic-engineering/preferred-models.md`.

## Working set (capsules)

- **gpt-6-astra** — (nickname: astra): deep product, architecture, planning and review judgment. Use high or higher reasoning for sustained work.
- **gpt-5.6-sol** — (nickname: sol): general engineering and delivery orchestration; increase effort for sustained or coupled work. Can commission a stronger planner.
- **gpt-5.6-terra** — (nickname: terra): bounded engineering implementation and mechanical work with an inspectable contract.
- **gpt-5.6-luna** — (nickname: luna): default well-scoped engineering coder at xhigh; lower effort for bounded factual or mechanical tasks. Escalate consequential uncertainty.
- **claude-fable-5** — (nickname: fable): deep product judgment, difficult planning, implementation and whole-system review.
- **claude-opus-5** — (nickname: opus): sustained engineering, orchestration, specification and independent review. This policy explicitly replaces the previous Opus 4.8 mapping.
- **claude-sonnet-5** — (nickname: sonnet): bounded orchestration, specification and implementation under an understood contract.
- **claude-haiku-4-5-20251001** — (nickname: haiku): narrow factual extraction and classification with inspectable evidence. No effort setting is assumed.

## Select and recover

Choose the activity for the actual outcome, expected duration, uncertainty and
consequences. These activities are options, not required workflow stages. An
orchestrator may select a stronger activity, commission planning or keep deep
judgment in its own session within its authority and budget. Do not over-specify a
job merely to fit it to a cheaper coder. Judge savings across planning, context,
supervision, rework and review as well as the worker's tokens.

Determine the permitted model families from the organization's instructions. Support
mixed, Codex-only and Claude-only operation. Filter a row by that restriction before
fallback, retaining its order. An outage does not authorize crossing the restriction.
Every essential responsibility must remain possible within the selected mode.

Use the first qualified available candidate in the resulting row. Qualification
requires the activity's capability floor, an allowed host and harness, a supported
model and effort, and runnable access. Catalog presence alone does not prove access.
Expand a nickname to the exact canonical model above. Pass model, effort and the
matching permitted harness explicitly when spawning; do not rely on an inherited
model to implement this policy. Verify supported settings rather than inventing a
similarly named model. Archetype model-preference metadata is not automatic spawn
fallback or a transfer of selection responsibility from the orchestrator.

For independent review in mixed mode, prefer the other provider family than the
producer among the qualified candidates in the applicable review row. Keep each
family's internal order. Thus ordinary review of Codex-produced code starts with
Opus; ordinary review of Claude-produced code starts with Sol. Use the deeper review
row for consequential interactions. When both families materially produced the work,
retain the row's order and use an independent reviewer. A fresh capable same-family
reviewer remains eligible when preferred alternatives are unavailable; single-family
operation uses its permitted row. Provider diversity is a selection preference, never
an additional acceptance gate. Preserve independent session and judgment.

Availability fallback may cost more. A refused model/host/harness route or exhausted
access advances to the next qualified candidate. Do not retry a known unavailable
route without new evidence. If none qualifies, keep the affected obligation owned,
record the capability block and continue separable work. Reframe, select another
applicable activity or propose a policy change through the responsible owner. Main
is not a fallback worker. Routine fallback does not require an approval request or
an upward report of each attempt.

A poor result requires diagnosis of the ask, inputs, context, dependencies and
approach. Increase effort, use a stronger activity or seek planning according to the
cause. Do not blindly demote by list position or repeat an uncertain external effect.
Preserve usable work and custody when replacing a holder or changing its harness.

Scale reasoning to expected task length and complexity. Astra low is not for
sustained work. Start sustained difficult work at high or xhigh rather than waiting
for a low-effort failure. More reasoning can produce a shorter plan; max or ultra is
not a default requirement. Report material product impact, budget issues or access
decisions through ordinary ownership, not every successful staffing choice.

## Substrate activities

| Activity | Wants | Minds, in order (blocked if none) |
|---|---|---|
| General user conversation | breadth and proportionate judgment | sol[medium], sonnet[medium], opus[medium], astra[high], fable[high] |
| Onboarding or product discovery | intent and constraints | astra[high], fable[high], sol[high], opus[high] |
| Narrow failure classification or log triage | inspectable factual evidence | luna[low], haiku, terra[low], sol[medium], sonnet[medium] |
| Guidance or law authoring | coherent authority and composed behavior | astra[high], fable[high], sol[xhigh], opus[xhigh] |
