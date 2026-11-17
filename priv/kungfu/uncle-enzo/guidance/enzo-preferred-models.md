# Preferred models

As of 2026-11-12. Each job has a ring-down: start with the 1st entry.

The 1st entry is the model that users' reports and independent tests, weighed together, show can do the job well. Cost decides only between models that both qualify. The evidence column says what the pick rests on and where users and tests disagree; "thin" means little evidence either way.

| Job | 1st | 2nd | Evidence |
|---|---|---|---|
| Hard judgment, architecture, ambiguous root cause | claude: claude-fable-5-2 high | codex: gpt-6-astra high | Tests and users: Fable for the hardest work; Astra sharp but less wise |
| Long, open-ended autonomous build/run | claude: claude-opus-5-5 high | codex: gpt-6.1-sol xhigh | Users trust Opus unattended; Codex models stall or run on |
| Sprawling, clear migration, refactor or audit | claude: claude-opus-5-5 high | codex: gpt-6.1-sol high | Thin; users rate Opus strong at implementation, Sol good with precise specs |
| Routine, well-specified implementation | codex: gpt-6.1-sol high | claude: claude-sonnet-5-5 medium | Users and tests: Sol high matches Opus medium on clear specs; users rate Sonnet strong with a plan, tests don't |
| Code review for substantive defects | codex: gpt-6-astra high | claude: claude-opus-5-5 high | Users: Astra most thorough, Opus strong |
| Application security review | codex: gpt-6.1-sol xhigh | claude: claude-sonnet-5-5 max | DeepsecBench; users report refusals on both vendors |
| Mechanical edits with easy checks | claude: claude-sonnet-5-5 medium | codex: gpt-6.1-terra low | Thin; users use Sonnet for rebases and dependency fixes; Haiku falls apart on delegated edits |
| Narrow lookup, extraction, classification, summary | claude: claude-haiku-5-5 medium | codex: gpt-6.1-terra low | Users: Haiku strong for bulk extraction; Luna hallucinates and skips items |
| Complex research across many sources | codex: gpt-6-astra high | claude: claude-opus-5-5 high | Users: Astra finds more sources, with taste; knowledge-work test favours Opus |
| Writing for people | claude: claude-opus-5-5 high | codex: gpt-6-astra high | Tests favour Opus; users split between Opus and Astra |
| Computer use, screenshots, visual interpretation | codex: gpt-6-astra high | claude: claude-opus-5-5 high | Users: Astra strong but slow; no computer-use test |
| Simple messaging, status relay, routing | codex: gpt-6.1-terra low | claude: claude-haiku-5-5 medium | Thin; AutomationBench; Luna leaks tool markers into messages |
| When unsure | claude: claude-opus-5-5 medium | codex: gpt-6.1-sol high | Users' default; users rate Sol high about equal to Opus medium |

Move down the ring only when there is a mitigating circumstance. Examples: the user asks for a specific harness, say because tokens are running low on one; or you want an adversarial review on a different harness. When you switch harness, use that harness's entry for the job, whatever its position in the ring.

For review, use a qualified independent reviewer who did not author the work. Prefer the harness opposite the author's; if none is available, a different capable model on the same harness; otherwise any qualified independent nonauthor reviewer. Neither preference ever holds up review or work.

- Set the exact model and effort; check access, tools and actual fallback model before dispatch.
- Duration alone does not justify higher effort. Match ambiguity and consequences; use the implementation rows for building UI.
- Use cheap models for bounded, checkable work. Validate output; move up after failure or before costly, hard-to-detect mistakes.
- For routine, well-specified implementation with checkable tests and an independent review to follow, codex: gpt-6-luna max is a cheaper option. Move up to Sol or Opus after a failed review.
- Use xhigh/max when results justify it; security review is the exception here. Ultra modes also change orchestration.
- Compare cost per accepted result, including retries and reasoning. Haiku input above 100K raises its token rates fivefold.
- Exploit research needs a separate choice: Mythos and GPT-6 Cyber require access. Do not treat application-review results as exploit capability.

## Changing models mid-work

If the nature of the work changes, the exec should feel free to change a deliverator's model (tightbeam tune) as necessary.

## Model character

Each model has a character. Use these tendencies to your advantage, and mitigate them with review.

- Opus 5.5 (medium and high): the teacher's pet. Not the smartest in the class, but more detail-oriented, even when that detail is over-analysis. Eager to please, but also paranoid that it will make a mistake, so it errs heavily on the side of safety at the cost of pragmatism and quick delivery.
- Fable 5.2: the smartest student in the class. It smokes entirely too much pot, but if you call on it, it delivers a nuanced, correct answer. It is more pragmatic about what it lets slide. When something needs to get out the door, rely on Fable.
- Astra and Sol: sticklers like Opus, probably even more so. They tend to over-engineer, and to add unasked-for security, unwarranted arbitrary limits and thresholds, and code that stops a workflow on a technicality (brittle code), instead of resilient code that continues where it can when an error is encountered.
