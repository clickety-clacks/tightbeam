# OAuth Main recovery wake — redacted proof

## Verdict

PASS against binding specification `art_e675c607`, SHA-256
`032ffdfd25ef3dfb6d850e429edb7c352ae058098f4f8a3c0784f7531527a6ce`.

The implementation schedules one immediate native-Main wake only after a
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

The accepted disposable organization was created once at
`/tmp/oauth-main-proof-54626d3c-root5.8HlKSH`. Credentials remained
file-backed with mode 0600 and were never printed or copied into this report.

The isolated source-mode gateway projected Tightbeam CLI 0.2.0 with SHA-256
`fce48625145081c98fd0d976e939c8fa357814d4fd8ae34f337c7ced704ef4fd`.
Its catalog contained the shipped engineering bundle and the two exact proof
bundles:

- `oauth-proof-product`: root archetype `product-owner`, manifest SHA-256
  `bf1af7666a56b3c7e336aafecb991cbd93fac1ce5316e49efd909490b36c1005`
- `oauth-proof-coder`: root archetype `coder`, manifest SHA-256
  `8952d596b64b7d2945eabdb8482681cab626b4e5bdbb06a7b1ccecac8b6f9b6f`

Both bundles were learned through the real admin gateway path. Both
`installed.toml` receipts existed. Identity revision
`9c0fd30163c33e86b0d96ca44e42961b8d974feb` was clean, was equal at `main`
and `tightbeam/live`, and was carried by Main, product-owner, and coder. The
unrelated reviewer remained at seed revision
`14d9d10d` and received zero OAuth recovery notifications.

One authenticated OpenAI subscription finish produced exactly one recovery
wake, `w_3161047e-f57f-4027-a985-157b1bb2720c`, with:

- native Main session `agent:main:clawline:oauth-proof:main`
- origin `process:tightbeam`
- consumer `prompt`
- state `fired`
- `targetGate=1`
- no role target, condition, or re-resolution
- one delivered Codex turn using `gpt-5.6-sol`, effort `medium`

The stored and delivered prompt was unchanged:

> The OAuth token for openai on gibson was refreshed. Read the manifests for every installed or learned Kung Fu. Read each manifest's declared main archetype. Find live agents with those archetypes. Notify each that the OAuth token was refreshed, and require each to inspect and resume any stalled agent graph.

## Real Main-turn proof

Main read the installed manifests, reduced their declarations to the two
distinct roots `product-owner` and `coder`, and resolved the live session
roster. It delivered one immediate recovery instruction to each matching
session:

- `agent:oauth-proof-product`, wake
  `w_055de387-c681-4998-8156-25371c04c5fa`
- `agent:oauth-proof-coder`, wake
  `w_392e02aa-900e-4338-a7e9-552a01262e02`

Each instruction stated that the OpenAI OAuth token was refreshed and required
the agent to inspect its full graph and resume stalled work. Both turns reached
`delivered` with no error. The unrelated live reviewer
`agent:oauth-proof-unrelated` received zero Main recovery notifications.

## Excluded incident evidence

Roots one through four and all pre-stop/raced attempts remain preserved only as
substrate incident evidence. They are not used as proof. The accepted verdict
depends solely on the fresh root-five run and the fresh repository gates listed
above.
