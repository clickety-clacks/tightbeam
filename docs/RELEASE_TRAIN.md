# Release train

This document describes the current release path. `main` is the only
long-lived development branch. Release changes land through reviewed pull
requests to `main`, and each release candidate is built from the exact current
`main` commit.

## Prepare the release commit

Set the release version in `cli/Cargo.toml` as part of the reviewed source
change. In that change, re-check each external-agent skill shipped by
`tightbeam skill install` (listed in `cli/src/skills.rs`) against the updated
`tightbeam --help` output and update its `Written for Tightbeam <version>.` line.
Pull request CI runs `scripts/verify_external_skills.py`; the existing push
checks for `0.1.*` branches remain for compatibility.

## Build the final unpublished candidate

1. Select the reviewed commit at the current `main` tip and record its full
   40-character SHA.
2. Manually dispatch `.github/workflows/release-candidate.yml` on `main`, using
   `candidate_branch=main` and that exact SHA.
3. The workflow checks that the dispatched SHA is the current `main` tip, runs
   the full Linux and macOS release test gates, builds both native packages,
   verifies the candidate evidence, and uploads the proof artifact
   `release-candidate-proof-<sha>`. The artifact contains the canonical
   manifest, `SHA256SUMS`, package files, and supporting build evidence.
4. Treat the candidate as unpublished. No GitHub Release or release tag is
   created by this workflow.

The publisher accepts only a successful manual candidate run from `main`.
Legacy candidate-branch runs are not eligible for publication. Keep `main` at
the candidate SHA until publication. If `main` advances first, build and prove a
new candidate from the new tip.

A failed check does not produce an eligible candidate. Fix the source through
a reviewed change to `main`, then dispatch a new candidate for the new exact
SHA. Never repair or reuse a failed candidate run.

## Approve, install, and soak the exact candidate

After the user separately approves installing that exact candidate SHA,
install those bytes and complete the soak on the maintainers' production
deployment. Every candidate or release installation requires the user's exact
approval. Keep the full candidate SHA in the approval and soak records. A
`healthy` outcome applies only to the bytes identified by that SHA. The soak
is the final check; other testing stays in CI and isolated environments.

If the soak fails or finds a defect, do not publish the candidate. Fix the
source through a reviewed change to `main` and build a fresh candidate. The
failed candidate remains unpublished.

## Publish the same bytes

After a `healthy` soak, manually dispatch `.github/workflows/publish-release.yml`
from `main` with these values:

- The successful candidate workflow run ID and exact candidate SHA.
- The release tag, matching the version in `cli/Cargo.toml`.
- The candidate SHA that received separate install approval.
- `healthy` as the soak outcome and the exact soaked SHA.

The publisher requires the approval SHA and soaked SHA to equal the candidate
SHA. It verifies that the selected run completed successfully as a manual
dispatch from `main`, and checks the run, source SHA, proof manifest, and
`SHA256SUMS`. It downloads the proof artifact from that exact run, copies the
verified package files into the release payload without rebuilding them, and
rechecks the payload before creating the GitHub Release. The provenance records
the candidate run, source SHA, proof-manifest hash, approval SHA, `healthy` soak,
and publication run. The published assets include the same native package
bytes, candidate manifest, checksums, and provenance.

Use an unused tag exactly in the form
`v<major>.<minor>.<patch>+<build>`. Its version must match
`cli/Cargo.toml`; <build> is `git rev-list --count <candidate-sha>`. The tag
must point to the exact current `main` tip. The publisher validates these
conditions and creates the release tag and GitHub Release together. Do not
create the tag separately. Never update, delete, or reuse a release tag.

## Failed and defective releases

A failed candidate or unhealthy soak is never published. After a source fix,
prepare a new candidate from the new `main` tip and repeat the exact-commit
checks, separate install approval, and soak.

Retain a broken published release in the release list. Put a do-not-install warning at the top
of its notes naming the failure and safe replacement, and mark it prerelease
so it cannot be latest. Delete a release only for a leaked secret or a legal
problem. For a source rollback, use a reviewed revert on `main` and cut a new
release from a fresh candidate. Never move an earlier tag backward.
