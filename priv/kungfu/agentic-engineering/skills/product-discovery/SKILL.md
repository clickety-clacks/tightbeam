---
name: product-discovery
description: Drive an undefined or fuzzy product to a written spirit — elicit the real problem behind asks, reframe, deconflict, and land it in the spec's Spirit section. Use when spirit is missing, thin, or contradicted.
---

The goal is a Spirit section the user recognizes as THEIR intent, sharper than they
said it. Conversational, not interrogation; a few questions per exchange, never a
form.

1. Start from the problem, not the solution: whatever they asked for, find what it is
   FOR — "what does that get you?" / "what happens today without it?" Walk the whys
   until the answer is a situation in their world, not a feature in yours.
2. Watch for the XY trap: an ask for X that serves unstated Y. When you suspect it,
   name it gently — "you asked for X; it sounds like the underlying need is Y — is
   that right?" The reframe-and-confirm loop is the core move: your words, their
   correction, repeat until they say "yes, that's it."
3. Decompose fuzzy wants into outcomes: "how would you know this worked?" Concrete
   success signs become the outcomes list; things they explicitly don't care about
   become non-goals (ask for those too — non-goals prevent more waste than goals).
3b. WALK THE QUALITY AXES, lightly (ISO 25010's nine, plain words): correctness (does
   the right thing), performance, compatibility (plays well with what they have), UX /
   interaction, reliability (keeps working), security, maintainability, flexibility
   (moves to new environments), safety — plus observability (can you see what it's
   doing), which matters extra for agent-built software. For each: does this product
   care a lot, a little, or not at all? STANCES land in the Spirit section;
   don't-cares become non-goals. Never promise below a LAW floor (correctness,
   security, and similar gates are kungfu rails no product's taste may waive — say so
   if asked).

4. Deconflict: when two asks (or two stakeholders' asks) contradict, surface the
   conflict plainly and let the user choose or rank; never average silently.
5. WRITE AS YOU LEARN: every confirmed understanding lands in the spec's Spirit
   section immediately, in their words where possible. End every discovery
   conversation with the Spirit section better than you found it — and read it back
   at the end: "here's the spirit as I now have it."
5b. RUMINATE OUT OF TURN — conversation pacing is wrong for deep work, and you only
   run when woken, so SCHEDULE your thinking. The triggers are concrete — schedule a
   digest turn when, in the turn just ending, ANY of these happened: (a) you changed
   the Spirit section; (b) the user corrected one of your reframes (your model was
   wrong somewhere — assume more wrongness nearby); (c) you parked a contradiction or
   open question instead of resolving it; (d) a hand-off to an orchestrator is next.
   None of them -> no digest; do not ruminate recreationally. Wake yourself
   (`tightbeam wake --role <your-role> --prompt "digest: <product> spirit — re-read the Spirit section and the recent conversation; hunt contradictions, redundancy,
   and questions not yet asked" --after 15m`). The `digest:` prompt prefix is LAW-VISIBLE convention — keep
   it exactly, so the substrate can verify digests happened before hand-offs. In that
   turn, think — then return to
   the user with a DIGEST of realizations and conflicts, not just in-the-moment
   reactions. In-conversation you listen and reframe; out-of-turn you analyze.

6. Know when to stop: when new questions stop changing the Spirit section, build.
   Discovery serves definition; it is not a substitute for shipping.
