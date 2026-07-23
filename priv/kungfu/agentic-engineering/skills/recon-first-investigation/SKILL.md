---
name: recon-first-investigation
description: Establish the truth before anyone fixes — reproduce, enumerate competing hypotheses, disconfirm rather than confirm, and find a regression's provenance before proposing a fix. Use when investigating a symptom or root cause.
---

# Recon-first investigation

Establish the truth before anyone fixes. A fix dispatched on a guess costs a wrong-fix
iteration; the recon step is cheaper than that iteration.

1. Take the symptom, not a theory. Investigate what is reported — the observed
   behavior, the failing surface, the inputs — without inheriting the reporter's
   hypothesis. The framing you were handed is one hypothesis among several; a compliant
   investigation that starts from the presumed cause confirms it. Fresh eyes are the
   value of the recon session.
2. Quit thinking and look, then make it fail. Read the evidence — code, logs, runtime
   traces, commit history, the spec's intended behavior — and reproduce the symptom
   under your own control before explaining it. Go to where the phenomenon actually
   occurs; do not reason over a secondhand description. A symptom you cannot reproduce
   is itself the first finding.
3. Enumerate competing hypotheses, then disconfirm. List all the plausible explanations
   up front. Weigh each piece of evidence by whether it DISCRIMINATES between them —
   evidence "consistent with" your leading theory is usually consistent with the rivals
   too and carries almost no weight. The answer is the hypothesis with the least
   evidence AGAINST it; reach it by trying to break each theory, not by piling up
   support for the favorite. Falsify the losers explicitly and record it, so a
   falsified theory is not re-investigated.
4. For a regression — behavior that previously worked — find the change that introduced
   it before proposing any fix. Temporal coincidence is a hypothesis, not a cause: a
   change is the cause only when you can make the symptom appear and disappear by
   toggling it.
   - state the boundary: what worked, what is broken now, the last known-good evidence;
   - identify the most specific provenance available: the commit or change window, a
     merge boundary, a deploy or build boundary, a dependency or config shift, a spec
     amendment, or the test gap that let it through;
   - "probably caused by" is not provenance. When provenance cannot be proven, report
     provenance unproven, name the missing evidence, and state the next proof action.
5. Beware the single causal chain. Walking one "why → why → why" line finds one root
   cause and bottoms out early at "human error"; real failures often have several
   contributing causes. Branch the tree, do not follow one thread to a comfortable
   stop.
6. Cite everything: every finding names a file and line, a log line, or a commit, and
   keeps observed fact separate from your inference about it. A finding without a
   citation is a guess and is labeled as one.
7. Produce the root-cause report: the cause, its citations, the reproduction, the
   provenance for a regression, and the narrowest fix the evidence supports. Attest it:
   `tightbeam attest <assignmentId> --kind progress --note "<root cause + citations>"`.
8. The fix dispatches from the confirmed finding, not the original suspicion — and the
   fix is scoped to the identified cause, preserving unrelated behavior.
