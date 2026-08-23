---
name: tightbeam-law-minting
description: Doctrine and named design patterns for Tightbeam statutes, rails, and substrate mechanisms. Use before minting or reviewing any of them.
---

# Start with a pattern

Before you design a rail or mechanism, ask: **Which existing pattern is this?**
Use the catalog below before you mint a bespoke mechanism. If no pattern fits,
state that explicitly and explain why.

The numbered doctrine remains canonical in `wisdom.md`. This skill is its
working projection and applied vocabulary; cite the wisdom rule by number.

# Doctrine reference

## Designing a rail

- Enforce only where both condition and action leave rows. Judgment-shaped
  norms stay guidance. (wisdom 1)
- When one side lacks only a marker, mint a convention such as a prefix, flag,
  or row. Pattern-match on the convention; never ask code to comprehend prose.
  (wisdom 2)
- Climb the ladder: teach the behavior, make the right path the easiest single
  action, then rail what still drifts. Never build a threshold-guessing detector
  for evidence-free violations. (wisdom 3)
- Apply the red-tape test before shipping: stay silent when satisfied, produce
  evidence as a byproduct, name the remedy before denial, and expose outcome
  verbs only. One false positive makes the rail defective. (wisdom 4)
- Put cause and principal on every marker the mechanism writes. (wisdom 5)

## Designing a mechanism

- Let the substrate route, classify, hold, and verify. Let minds decide. Move
  every choice out of the mechanism and into inference. (wisdom 6)
- Use mechanical layers to backstop judgment layers, never replace them.
  (wisdom 7)
- Put behavior that must work without inference in substrate code, not
  guidance. (wisdom 8)
- Split mixed processes into deterministic staging, inference resolution, and
  deterministic verification. Split where mechanical merge gives up.
  (wisdom 9)
- Treat policy as org law over substrate facts. Treat existence guarantees as
  constitutional. Never hardcode a topology. (wisdom 10)
- Leave durable evidence for every failure. Record raw envelopes for
  unclassified errors, and close every incident with a catalog row, fixture, or
  statute, never only a fix. (wisdom 25)

# Pattern catalog

## 1. Obligation, not notification

If you want work to happen, create a card. Prods key on assignments; a notice
is unprodded and nobody owes it.

**Prevents:** approved work that remains unowned and unshipped.

## 2. Prod to existence

When a rail requires an obligation, prod the accountable mind until the row
exists. Stop on the row, not on a reply. Never let the substrate manufacture
the obligation or choose its holder.

**Prevents:** control logic disguised as scheduling and replies mistaken for
durable work.

## 3. Typed exit condition

Close a card only on its named fact. Never close it on an assertion that the
work is done.

**Prevents:** completion as self-report.

## 4. The inhibition seam

Give every mandatory rail a lawful, evidence-backed discharge for cases where
the rail does not apply. A no-landing declaration is one example. State the
seam before enforcement ships.

**Prevents:** the forever-prod and compelled redundant work.

## 5. Unknown is a value

When a check cannot reach its subject, record `UNKNOWN`. Never turn absence of
evidence into evidence of absence. In substrate design, reuse the existing
`unreported` sentinel instead of minting a second value.

**Prevents:** false certainty in either direction.

## 6. Observation over testimony

When others will act on a fact outside the ledger, record the exact probe, a
digest of its output, and its expiry when you observe it. Record `UNKNOWN` when
the probe cannot reach the subject.

**Prevents:** testimony laundering and later reconstruction archaeology.

## 7. Escalation ceiling

Route exhausted work to the nurse/patrol for adjudication against its casebook.
Never route it to the human except by the human's own standing law.

**Prevents:** using the human operator as a control loop.

## 8. Floor, not ceiling

Use a rail to detect pathology, never to cap legitimate work. Treat one false
positive as a defect in the rail.

**Prevents:** mechanisms that tax or suppress the honest path.

## 9. No blocking judgment

Never make a script wait for inference or for a session to answer. Stage
deterministically, hand judgment to a mind, and resume from a durable result.

**Prevents:** deterministic processes that deadlock on a mind.

## 10. Seed values as data, not constants

Store floors, ceilings, timings, and other tunable seed values as policy data
that an org can change.

**Prevents:** shipping one org's tuning as universal physics.

## 11. Replay identity

Return the original outcome when the same receipt is replayed, including after
restart, replacement, or generation change.

**Prevents:** recurrence and contradictory outcomes for one attempt.

## 12. One durable explanation per attempt

Make every mechanical attempt explainable from one durable evidence chain.
Include cause, principal, subject, outcome, and the raw failure envelope when
the failure is otherwise unclassified.

**Prevents:** unattributable machinery and duplicate explanations that drift.

## 13. Atomic consequence

Commit a fact and every mechanical consequence that depends on it in one
transaction.

**Prevents:** a fact without its consequence, or a consequence without its
fact.

## 14. Restart pickup

Persist rail state and resume it after restart. Make replay idempotent and keep
the original attempt identity.

**Prevents:** obligations that quietly die with a process.

# Anti-pattern catalog

## The bespoke mechanism

Before minting, ask whether the proposal is an instance of an existing floor or
pattern. Refuse a new subsystem when the existing pattern already supplies the
contract.

## Testimony laundering

Do not call a claim verified because the claim was copied into a row. Verify
the subject through observation and record the probe, digest, and expiry.

## The threshold-guessing detector

Do not infer an evidence-free violation from a count, duration, or guessed
threshold. Detect the event itself or leave the norm in guidance. (wisdom 3)

## The forever-prod

Do not ship a mandatory rail without its inhibition seam and typed exit
condition.
