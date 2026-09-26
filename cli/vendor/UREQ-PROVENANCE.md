# Pinned ureq transport observations

`ureq-2.12.1/` is the complete 54-file crates.io archive for ureq 2.12.1.
Archive SHA-256:
`02d1a66277ed75f640d608235660df48c8e3c19f3b4edb6a263315626cc3c01d`.
The upstream manifest, versions, features, licenses and other files are unchanged.
The CLI's Cargo patch selects this local source; the lockfile's registry source
and checksum are removed only for that package.

Only four upstream files are changed:

| File | Additive observation |
| --- | --- |
| `src/error.rs` | Closed phase/route metadata and prior-exchange flag on Transport; original Display, Debug, kind, message, URL and source retained. |
| `src/lib.rs` | Re-export the three observation types. |
| `src/stream.rs` | Annotate existing resolver, TCP, post-connect setup, CONNECT and TLS error returns. |
| `src/unit.rs` | Annotate existing pool, send and response error returns; mark failures after the existing redirect/recycled-stream retry paths. |

The patch does not add a retry, change a deadline, replace a transport or change
existing error/source text. An annotation identifies the failing operation,
not gateway acceptance or listener identity. In particular, reaching a proxy
does not establish a usable gateway channel. SOCKS observations are deliberately
absent. Existing CONNECT-write panic behavior is untouched; it produces no
Transport metadata. Body-read errors after returned headers remain caller-owned.

The B classifier rejects absent observations and failures after a prior exchange.
It also leaves pool-check, proxy-handshake and forward-proxy post-connect results
unclassified. A configured route alone never establishes domain acceptance.

Separately, the Tightbeam gateway's fresh Agent explicitly uses `redirects(0)`
under PDO authorization. Other agents retain the upstream redirect/replay policy.
This confines gateway request identity to one exchange; the dependency metadata
does not invent identities for hidden exchanges elsewhere.

To audit provenance, compare each regular archive member after stripping its
`ureq-2.12.1/` prefix with the corresponding vendored file. Exactly the four files
above may differ; no archive member may be missing or replaced. The isolated
four-file diff is also frozen in the assignment's precursor report.

`cli/tests/timeout_attempt.rs` contains real loopback phase, redirect, pool, TLS,
proxy and lease fixtures. These require a full owned clone on an authorized
non-Gibson host. Their presence is not a passing test receipt. Actual typed
attempt/receipt call-site integration and CLI/R9 acceptance remain a separate,
serial fidelity handoff; do not infer them from the boundary tests.
