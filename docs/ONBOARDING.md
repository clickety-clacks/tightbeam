# Onboarding credentials — ceremonies, kinds, and liveness

Getting a harness logged in on a host. This is a SEPARATE activity from the
smoke run: `docs/SMOKE.md` assumes every harness it exercises is already
installed and logged in, and fails fast pointing here when one is not.

Harness CLIs are the operator's to install; Tight Beam installs its own
plumbing (adapters, CLI, base dir) and never the vendors' software. Install the
binary first (`docs/SATELLITE.md`), then onboard it here.

GitHub is a separate host capability, not a model-provider credential. Its
project-auth contract is specified in `docs/GITHUB-AUTH.md`; the important rule
is the same operational shape: prove the host can authenticate, or refuse with a
repair. Do not paste a PAT into an agent.

## The two kinds

A host holds ONE credential per provider, of either kind, and it is host-local
config: a satellite may run claude on an API key while the gateway runs it on a
subscription. Each session reports its own as `display.credentialKind`
(`"apiKey" | "subscription" | "none"`).

    # subscription (interactive ceremony — a human at a browser)
    tightbeam onboard anthropic --as-user <userId>
    tightbeam onboard openai    --as-user <userId>

    # API key (non-interactive; the key is read from stdin and never leaves the host)
    printenv ANTHROPIC_API_KEY | tightbeam onboard anthropic --api-key
    printenv OPENAI_API_KEY    | tightbeam onboard openai    --api-key
    printenv CURSOR_API_KEY    | tightbeam onboard cursor    --api-key

Cursor is API-key-only in Tightbeam. There is no subscription login; the CLI
requires `--api-key` and reads the key from stdin. At launch the harness injects
`CURSOR_API_KEY` with `AGENT_CLI_CREDENTIAL_STORE=memory` — the uniform
file-backed-cred + env-injection model. Cursor placement is gateway-local only;
see `priv/kungfu/agentic-engineering/guidance/harness-support.md`.

`--api-key` will not read from a terminal — a key typed at a prompt lands in
shell scrollback.

### The pinned Cursor bundle is an obtainable operand

Cursor support is pinned to one `cursor-agent` version, `2026.08.11-e8db854`,
verified by SHA-256 at every launch (`Tightbeam.Harness.Cursor`). The
`cursor-agent` launcher script is byte-identical on all four published
platform archives (`eed61c52…`); `index.js` is platform-specific, so its pin
is a per-platform table (all four verified against the real archives,
2026-08-30):

| platform | `index.js` SHA-256 |
| --- | --- |
| darwin/arm64 | `6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0` |
| darwin/x64 | `2def6db128c49b95f33b8b6f9624a15e65616f074ae505c06ffccf35fe0feb7b` |
| linux/x64 | `f6fd4e6bf3d6ecbf66cc2dcabcf708b8a7c37b400d10c82a58658b5e331c36d0` |
| linux/arm64 | `468106299df5dcebf227e0d478172a7241a202d25c4b2b7060b6723ee19cabac` |

Nothing is vendored or patched: each bundle is Cursor's own published archive,
at the URL shape its installer script downloads from, and every version stays
published:

    https://downloads.cursor.com/lab/2026.08.11-e8db854/<darwin|linux>/<x64|arm64>/agent-cli-package.tar.gz

Each archive's `dist-package/` is byte-identical to its platform's pinned
bundle, and the printed admin block resolves the host's platform so the URL
and the digest it checks always belong together. `tightbeam onboard
cursor` prints the exact admin block for the dedicated execution account: an
unprivileged download and extraction into a temp dir, `shasum -a 256 -c`
(`sha256sum -c` on Linux) against both digests, and only on a pass the root
extraction into the execution account's home (`--no-same-owner
--no-same-permissions`). Provisioning a host therefore never depends on the
operator having that version installed, and wrong bytes are refused before
they reach the execution account — and again at every launch.

Both paths validate against the provider BEFORE banking. A rejection names the
provider, the host and the kind, and leaves the existing credential untouched.
An `onboarded` result from the CLI is therefore a claim about the ceremony, not
proof the credential works; prove liveness separately (below) before trusting
it.

## The definition of interactive onboarding

Interactive onboarding is not complete until the operator holds the sign-in URL
and the one-time code. The loop runs through the operator: the operator opens the
URL, approves in a browser, and the ceremony banks the credential. No code in the
operator's hands means the operator cannot finish. So the onboarding is not done.
Every `tightbeam onboard <provider>` means this full loop, not just the command
returning.

The ceremony delivers the URL and code so an operator who cannot see its terminal
still receives them — a session-run install over a private pty is the case this
protects. It emits the deliverable three ways:

- a **wake** to the owner user, carrying the URL and code. This is the durable
  record and the notification in one.
- a **0600 delivery file** in the working directory
  (`onboard-delivery-<provider>-<ms>.json`). This is a local copy a courier can read.
- a **structured line** on stdout (`{"onboardingDelivery": …}`) for a relay to parse.

The one-time code is not a credential. It is a short-lived pairing code that expires
in minutes. If the gateway does not name the owner (an older gateway, or a caller
with no owner), the ceremony still writes the file and the structured line, and it
records that no wake was sent. It degrades loudly, never silently.

## Running an interactive ceremony

Run it ON the host whose credential it banks. Credentials never transit between
machines. On a satellite, the gateway-provisioned `<base_dir>/gateway.json`
supplies both the endpoint and the host's registered name — no operator env is
needed.

The ceremony is a three-phase conversation with the gateway, holding a lease
keyed `{host, provider}`. Distinct hosts hold independent leases, so ceremonies
on different machines may run concurrently; a second ceremony for the same
provider on the same host supersedes the first.

**Budget the human, not the lease.** The onboarding lease is 30 minutes
(`onboarding_lease_ms`), but a provider authorization code expires in roughly
ten and cannot be reused. The real deadline is the code's life. Do not arm a
ceremony unless someone is ready to complete it within a few minutes.

**Driving one non-interactively:** the code must be written to the ceremony's
stdin followed by a SEPARATE bare carriage return (`\r`) to submit. A trailing
newline fills the input box without submitting: the ceremony sits at the prompt
looking exactly like a hang while the clock runs down.

**An abandoned ceremony reaps itself.** After 1800s the watchdog terminates the
harness CLI and its whole process group — including children in their own
process groups — names what it killed, and leaves the harness-home credential
untouched. It does not write a failure log on that path; the watchdog line in
the gateway log is the record.

**A failed capture is not persisted.** The transcript can contain a live year-long
credential, so the refusal explains the screen shape without copying the bytes to a log.
Report that refusal before re-arming; codes are single-use.

**Scanning a ceremony's working directory for leaked secrets: match regular
files only** (`find … -type f`, or exclude non-regular files). A ceremony's
workdir contains the FIFO carrying its stdin, and `grep` on a named pipe blocks
forever waiting for a writer — the scan hangs on its own artifact and looks like
a wedged host.

## Proving a credential is LIVE

A banked credential is not a working one. Dead auth does not fail as "auth"
downstream — it masquerades (an expired claude grant surfaces as "Invalid value
for config option model: <ref>", because no auth → no model catalog → every
value invalid). Prove liveness per `{harness × host}` against the provider.

The cheapest proof is the model catalog: a host with a live credential has a
non-empty catalog for that harness, and the gateway's boot summary says so.

For a direct probe, the route follows the host's RECORDED kind, from that
host's `credential.json`, never from a guess about the file — the kinds reach
different endpoints, so a guess produces a confident answer about the wrong one.

- **claude**, either kind: `GET https://api.anthropic.com/v1/models?limit=1`
  with the header that kind requires — `Authorization: Bearer` for a
  subscription OAuth access token, `x-api-key` for an API key.
- **codex, subscription**: `GET https://chatgpt.com/backend-api/wham/accounts/check`
  with the host-local ChatGPT grant and account header. The platform route
  refuses this grant (403, missing scope `api.model.read`).
- **codex, api key**: `GET https://api.openai.com/v1/models` with the key from
  `auth.json`'s own `OPENAI_API_KEY` field.

Result map, pinned: `:live` → PASS; `{:dead, reason}` → FAIL;
`{:unknown, reason}` → INCOMPLETE, never PASS. A host whose store records NO
kind is a FAIL with its own remedy — re-run onboarding so the metadata records
one.

Login status and file presence are not liveness.

### Check observed authentication failure before a release

Run these checks when model-catalog or credential-home code changes. They use
fixture credentials and never contact a provider.

0. Complete the README's [From source](../README.md#from-source) setup through
   the release CLI build.

   PASS: every prerequisite command exits zero, including `mix deps.get` and
   `cargo build --release --manifest-path cli/Cargo.toml`.

1. Run the public-route end-to-end check:

   ~~~sh
   sh scripts/verify_mix.sh test/model_catalog_rotation_e2e_test.exs
   ~~~

   PASS: the public route reads the current authoritative-home credential,
   not the stale legacy file. It returns the model without importing or
   changing either file. This case is not a provider-401 replay test.

2. Run the feature matrix:

   ~~~sh
   sh scripts/verify_mix.sh test/model_catalog_test.exs
   ~~~

   PASS: local and remote provider 401 responses are surfaced after one request,
   for both credential kinds, without changing any credential file.

3. Record every prerequisite and test command exit, plus both test counts. A
   skipped negative row is not a pass. Do not use a real credential to satisfy
   either check.

## What a credential looks like on disk

Each credential exists only as a regular file in its exact harness home:

- Codex: `homes/<machine>/codex/auth.json`;
- Claude: `homes/<machine>/claude/.credentials.json`;
- kind metadata: `homes/<machine>/<harness>/.tightbeam/credential.json` with
  `"onboarded": true` AND `"kind": "subscription" | "api_key"`.

Record the KIND during onboarding; do not infer it from a filename or secret.
Current legacy metadata handling retains its historical subscription default
when the recorded kind is absent. That compatibility is not permission to omit
the kind from a new onboarding record. Under a subscription, the
selected Claude setup token is non-rotating. The harness reads the
home-local subscription record; Tightbeam does not run a Claude refresher.
Codex owns its rotating grant and must have a single refresher. For a Claude
API key, `.credentials.json` holds the bare secret, which is still injected
through `ANTHROPIC_API_KEY`. The filename is NOT evidence of the kind.

File absence in the exact home is an onboarding signal, not the only
refusal. Current status also rejects recorded expiry, terminal revocation,
unsupported subscriptions, and present-but-unverified activation. Preserve those
checks. A provider 401 is an observed authentication failure; file presence and
metadata alone do not prove liveness.

`tightbeam onboard <provider>` on the host is the only sanctioned path. There is
no credential-import verb, and copying a credential between machines is never
correct.

## Prerequisites and how they fail

The harness CLI must be on the PATH of whoever actually invokes it, and that
differs by role:

- **On a satellite** — the PATH a NON-INTERACTIVE ssh session sees. A binary
  reachable only through a login shell profile does not count. This is what the
  assimilate probe and a remote ceremony judge.
- **On the gateway host** — the PATH the gateway SERVICE runs with (its unit's
  `Environment=PATH`). Adapters are children of the gateway, so they inherit it.
  A gateway-host binary can be absent from the non-interactive ssh PATH and
  still be perfectly reachable by every adapter.

A missing binary is refused by name, with the PATH that was searched printed
alongside.

Two ways an install can succeed and still be invisible:

- **asdf-managed node**: `npm i -g <pkg>` exits 0 but the shim is not created
  until an explicit `asdf reshim nodejs`.
- **non-asdf node** (e.g. `/usr/local/lib/nodejs/*/bin`): npm's global bin
  directory is not on the non-interactive PATH at all, and `/usr/local/bin` is
  usually root-owned. Symlink the binary into a directory that IS on that PATH.

"npm install exited 0" never implies the probe can see it. Verify with
`ssh <host> <binary> --version` — non-interactive, which is the thing being
tested.

## Unverified cells

State these in any report that touches an api-key host, rather than letting a
green scorecard imply more than it proved:

| cell | status |
|---|---|
| anthropic `x-api-key` header shape | recorded live — a 401 to an invalid key names the header |
| openai platform route accepts api keys | recorded live — 401 `invalid_api_key`, where a subscription token gets 403 naming the missing scope `api.model.read` |
| a valid key returns 200 on either route | one-shot capture; see `priv/credential_live/CAPTURE-LEDGER.md` |
| openai `/v1/models` response SHAPE | same capture — it drives `derive_platform_entries/1` in `harness/codex.ex` |
| codex-acp / claude-agent-acp run a turn on api-key auth | **NOT VERIFIED, not budgeted.** Expected, not observed. |

The last row is the one to say out loud. Everything above it is about reaching
the vendor; that row is about the harness actually working.
