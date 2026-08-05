# Model policy

The org's tunable default for which mind takes which class of work. The ORG owns
this table — retune it through an identity edit, not by deference to whoever wrote
it. Capsule characterizations and effort brackets live in `preferred-models.md`.

| Task class | Model (effort) |
| --- | --- |
| Hard problems, novel patterns, critical-path work | claude-opus-5 [high] |
| Well-bounded work following an established pattern | gpt-5.6-sol [medium] |
| Spec review | claude-fable-5 |
| Quick mechanical checks | the cheapest available tier |

## When your model is unavailable

Not configured, out of tokens, refused — you have exactly three legal moves:

1. SWITCH: take another model from the table, if the task class permits it.
2. BLOCK: assert `work-blocked` over the affected session (condition verb, scope =
   the session key) and report the situation to your parent or the user.
3. SURFACE: tell the user a credential or account needs re-onboarding.

Never wait silently; never retry-loop against a wall.

The substrate does not read this document. Model choice is judgment, and judgment
is inference's (spec production-machine-v1).
