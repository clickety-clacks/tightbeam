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

`--api-key` will not read from a terminal — a key typed at a prompt lands in
shell scrollback.

Both paths validate against the provider BEFORE banking. A rejection names the
provider, the host and the kind, and leaves the existing credential untouched.
An `onboarded` result from the CLI is therefore a claim about the ceremony, not
proof the credential works; prove liveness separately (below) before trusting
it.

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
process groups — names what it killed, and leaves the credential store
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

## What a credential looks like on disk

Credentials are store rows, not loose files. Each provider needs all three:

- the store backing file — `auth/codex/auth.json`, claude
  `auth/claude/.credentials.json`;
- the home symlink `homes/<machine>/<harness>/…` → store file;
- the metadata row `auth/<harness>/.tightbeam/credential.json` with
  `"onboarded": true` AND `"kind": "subscription" | "api_key"`.

The KIND is what every credential seam dispatches on; a row without one is not
usable, because nothing infers it from the file. Under a subscription, the
claude backing file is Claude Code's OAuth record with a refresh token; it is
linked into the harness home so Claude Code can rotate it in place. Under an
API key, that same filename holds the bare secret, which is still injected
through `ANTHROPIC_API_KEY`. The filename is NOT evidence of the kind.

The openai path does not populate `expires_at` or `subscription_status` even on
a fresh write; they are null by design there, not stale.

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
