# Subscription OAuth recovery proof

## Verdict

PASS against the accepted binding specification.

The implementation schedules one immediate native Main wake only after a
successful OpenAI or Anthropic subscription OAuth finish. API-key completion
does not schedule the recovery wake.

## Source and gate basis

- Owned branch: `coder/oauth-main-recovery-current-main`
- Base: `8eeccbd6dfd221fe9d105783459637fb7a17ea83`
- Frozen candidate `003e38cccda136bdd9296bdcdeaf0d228f2ed977` was used only as a reference.
- Fresh current-main baseline: 9 doctests, 1684 tests, 0 failures, 11 skips.
- Focused OAuth and credential regressions: 32 tests, 0 failures. This includes
  seven focused controls for exact prompt delivery, API-key exclusion, failed
  begin/finish paths, Main retirement, and typed credential-recovered partial
  success.
- Fresh final repository gate: 9 doctests, 1691 tests, 0 failures, 11 skips.
- No identity, archetype, Kung Fu, rule, rail, skill, or standing-guidance
  source file changed.

## Stored wake proof

The accepted disposable organization was created once in an isolated temporary
base. Credentials remained file-backed with mode 0600 and were never printed
or copied into this report.

The isolated source-mode gateway projected the 0.2.0 CLI and catalog with
the shipped engineering bundle and two proof bundles: one rooted at
`product-owner` and one at `coder`. Both bundles were learned through the real
admin gateway path, and both installation receipts existed. The identity
revision was clean, equal at source and installation, and carried by Main and
both proof sessions. An unrelated reviewer received no OAuth recovery
notification.

One authenticated OpenAI subscription finish produced exactly one immediate
recovery wake for the native Main session. Its origin was `process:tightbeam`,
its consumer was `prompt`, its state was `fired`, and `targetGate=1`. It had no
role target, condition, or re-resolution. One Codex turn was delivered with
`gpt-5.6-sol` at `medium` effort.

The stored and delivered prompt matched exactly. It instructed Main to read
the installed bundle manifests, find live sessions with the declared main
archetypes, notify them of the OAuth refresh, and require each to inspect and
resume stalled work.

## Real Main-turn proof

Main read the installed manifests, reduced their declarations to the two
distinct roots `product-owner` and `coder`, and resolved the live session
roster. It delivered one immediate recovery instruction to each matching
session. Both turns reached `delivered` with no error. The unrelated live
reviewer received no Main recovery notification.

## Excluded incident evidence

Earlier disposable roots and pre-stop or raced attempts remain incident
evidence. They are not used as proof. The accepted verdict depends solely on
the fresh isolated run and the repository gates listed above.
