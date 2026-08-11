# Manual candidate packages

The `candidate package` workflow builds an exact reviewed commit on clean GitHub-hosted
Linux and macOS runners. It produces package evidence only. It does not create a release
or authorize a host action.

Repository governance trusts source at an eligible base-repository branch tip. The
workflow prevents candidate workflow or action files from replacing the trusted gate,
but it does not sandbox malicious eligible source from same-job runner state or GitHub
Actions runtime interfaces.

## Dispatch

Use the workflow from the repository default branch. Supply `source_sha` as exactly 40
lowercase hexadecimal characters. The value must be the current tip of at least one
pushed branch in `clickety-clacks/tightbeam`. Do not supply a branch, tag, abbreviated
SHA, pull request, URL, uppercase SHA, or fork commit.

The dispatching principal must have repository write access. That repository permission
is the dispatch authorization boundary. A reviewer or operator decides whether the
candidate received sufficient review; the workflow makes no review judgment.

## Refusals

- `source_sha must be exactly 40 lowercase hexadecimal characters` means the input was
  mutable, ambiguous, or malformed. Create a new dispatch with the full lowercase SHA.
- `no pushed base-repository branch tip equals` means the SHA is absent from every
  current pushed base-repository branch tip. Push or select the intended base-repository
  branch tip before a new dispatch. An ancestor-only or fork-only commit does not qualify.
- `dispatch ref ... is not the required default ref` means the workflow did not run from
  the repository default branch. Create a new dispatch from the default branch.
- `trusted checkout ... does not equal workflow SHA` or `lacks the canonical` means the
  trusted workflow revision is incomplete or mismatched. Stop and repair the repository
  workflow before another dispatch.
- An exact-checkout, dirty-tree, source-digest, platform, package-set, provenance, size,
  or digest refusal means the run did not prove the requested bytes. Do not consume any
  artifact from that run.
- `GitHub re-runs are refused` means a partial-job re-run cannot preserve one coherent
  attempt. Create a fresh dispatch with the same full SHA. The new run gets a new run ID,
  revalidates the pushed branch tip, and uses new clean runners.

## Decide whether a bundle is ready

The upload step is not the readiness event. Require the `candidate bundle` aggregation
job to have the final conclusion `success`. A visible `tightbeam-candidate-*` artifact
from a failed, cancelled, or timed-out aggregation job is partial diagnostic output.
Do not consume it.

Do not consume an artifact whose name begins with `candidate-staging-`. A staging
artifact transfers one platform result to aggregation and expires after one day.

For a successful aggregation job, download exactly this artifact:

```text
tightbeam-candidate-<full-sha>-run-<run-id>-attempt-1
```

The artifact expires after 90 days. Retention does not turn it into a release. If the
artifact expires or any proof is uncertain, create a fresh dispatch instead of rebuilding
on a local or fleet host.

## Verify the downloaded bundle

Perform these checks before any separately authorized handoff:

1. Require exactly two `.tgz` files, `SHA256SUMS`, and
   `candidate-provenance.json`. Reject every extra or missing file.
2. Require one `linux-x86_64` package and one `darwin-aarch64` package. Require both
   names to end with the same seven-character candidate suffix.
3. Run `shasum -a 256 -c SHA256SUMS` from the downloaded directory. Require both
   package checks to pass.
4. Compare the manifest repository, requested SHA, resolved SHA, qualifying pushed ref,
   trusted workflow SHA, workflow ref, run ID, run attempt, actors, and run URL with the
   successful GitHub Actions run.
5. Compare the source-tree digest, trusted gate blob, trusted setup blob, filenames,
   byte sizes, and package SHA-256 values with the manifest and downloaded bytes.
6. Treat values below each `observed_by_package_job` object as package-job observations.
   They record the runner image and toolchains but are not independent attestations and
   cannot replace the authority-checked source, run, or package fields.

Stop on any mismatch. The workflow makes no release-ready, installed, compatible, or
proof-passed judgment.

## Separately authorized host handoff

Clean GitHub-hosted CI is the only candidate build, test, and package substrate. This
repository workflow stops after the verified bundle. A later lane needs separate owner
authority before it downloads or changes anything on a host.

| Location | Only candidate role |
| --- | --- |
| Clean GitHub-hosted CI | Build, test, and package both candidate artifacts. |
| EEZO | Clawline client/simulator only; no Tightbeam build, package install, gateway, provider preflight, smoke, or switch proof. |
| Shrdlu | Existing in-place installed Linux proof target; no isolation install or local build. |
| TARS | Packaged macOS target only; no candidate install, gateway, provider preflight, smoke, or switch proof. |
| Gibson | Production-only evidence history; no candidate action. |

Across EEZO, Shrdlu, TARS, and Gibson the handoff creates no alternate root or base,
copied home, side gateway, parallel install, local or test-host build, or credential
transfer. Existing credentials remain on their existing hosts.

Only a separately authorized Shrdlu lane can use the normal in-place install policy.
Before overwrite, that lane requires this clean-CI provenance, a verified matching
rollback package, reconciled canonical service custody, an owner-named restart target,
and pre-overwrite evidence. It stops on a mismatch. It uses the existing account's
global npm prefix, installed package, base, home, service account, port, service
definition, and host-local credentials. It does not create an isolation install, copied
home, side gateway, parallel install, alternate root, alternate base, or local build.

Shrdlu restarts the existing service only when its existing runbook requires a restart.
The downstream proof tests the actual installed Shrdlu instance. TARS receives the
macOS package as a package-only target and receives no install or proof action. EEZO
remains Clawline client/simulator-only. Gibson receives no candidate action.

The normal `ci.yml` main and version-tag ceremony remains the only package release and
GitHub Release path. A candidate bundle never becomes a release asset by itself.
