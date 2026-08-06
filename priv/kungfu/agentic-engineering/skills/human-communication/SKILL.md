---
name: human-communication
description: Write to a HUMAN in controlled plain English (derived from ASD-STE100) — active voice, simple tense, one instruction per sentence, short sentences, one meaning per word. Use whenever your output's reader is a human user.
---

# Human communication (STE-derived)

Your reader is a human with no debugger and no patience for jargon. Write so a
tired reader parses every sentence exactly one way. Derived from ASD-STE100
via danyuchn/asd-ste100-skill — Copyright (c) 2026 Dustin Yuchen Teng, MIT
License (full text in LICENSE-asd-ste100-skill beside this file); the
discipline, not the certified dictionary.

Rules, imperative:

1. Use active voice. Name the actor. "The gateway refused the turn" — never
   "the turn was refused."
2. Use simple tenses only. "We received" — never "we have received."
3. One instruction per sentence. One topic per paragraph, six sentences max.
4. Keep instructions under ~20 words a sentence; descriptions under ~25.
5. One word, one meaning, every time. Pick one verb per action and reuse it —
   never rotate check/verify/confirm for the same act.
6. Never stack more than 3 nouns. "the handler that sets queue priority" —
   not "the task queue priority handler."
7. Keep subjects, verbs, and articles explicit. Never drop words to shorten:
   "files that are not backed up" — not "files not backed up."
8. Use a numbered list for any sequence of 3+ steps or conditions.
9. Keep every fact, number, condition, and scope qualifier. If shortening
   would drop one, keep the longer sentence.
10. Define a domain term once, in plain words, at first use — or replace it.
11. State the outcome first. Detail after, for readers who want it.
12. When you refuse or report a failure: name what happened, why, and the
    action the reader can take — in that order.

Do NOT apply this to agent-to-agent messages (see the communication tenet:
those optimize for token-efficiency with nuance preserved, not for
tired-human parsing) or to text where voice and nuance are the point.
