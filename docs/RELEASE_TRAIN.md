# Maintenance release procedure

This file is the authoritative procedure for 0.1 maintenance releases. The
`release-maintenance-lines.md` file in the tightbeam-specs repository is superseded
historical context. Do not implement its former branch convention.

The maintenance line is the highest `0.1.*` branch (currently `0.1.9`). Each
version branch is a protected scratchpad. Reviewed work accumulates there until that
version quits. A release-candidate branch is temporary transport for one exact proof run.
The version tag and proof at that SHA are the durable release record. Delete the candidate
branch after the tag exists.

## Superseded convention — MUST NOT IMPLEMENT

The former procedure used one rolling maintenance branch for all 0.1 releases. It also
retained release-candidate branches as read-only history after tagging. Mike's 2026-08-15
ruling superseded both behaviors. Do not recreate a rolling maintenance branch. Do not
retain a candidate after the immutable tag and proof name the same SHA.

## Prepare the candidate

Use a clean worktree. Store the preparation manifest outside that worktree.

1. Fetch every `0.1.*` branch and all reviewed feature commits.
2. Resolve the highest `0.1.*` branch with `scripts/highest_0_1_branch.sh`.
3. Record that branch's exact SHA as the protected base.
4. Order every commit in the exclusive base-to-candidate range.
5. Run the preparation script with the candidate branch, base, and ordered commits.
6. Inspect the canonical JSON manifest that the script prints.
7. Push the new candidate branch without force.

Example:

```sh
git fetch --no-tags origin '+refs/heads/0.1.*:refs/remotes/origin/0.1.*'
protected_ref=$(sh scripts/highest_0_1_branch.sh)
base=$(git rev-parse "$protected_ref")
scripts/release_candidate.sh \
  release-candidate/<version>-r1 \
  "$base" \
  <reviewed-feature-sha-1> \
  <reviewed-feature-sha-2> \
  > ../tightbeam-<version>-candidate-input.json
git push origin refs/heads/release-candidate/<version>-r1
```

The helper sorts version components numerically. The highest `0.1.*` branch (currently
`0.1.9`) will become `0.1.10` when that branch exists.
The preparation script refuses a dirty worktree. It also refuses an existing local or
remote candidate branch. It refuses missing, duplicate, reordered, extra, and
non-ancestral commits. It creates one branch at the final reviewed commit. It does not
create or rewrite a commit.

Do not redirect the manifest into the worktree. The shell creates the output file before
the script checks the worktree.

## Prove the candidate

The release-candidate workflow starts only for a `release-candidate/**` branch push or an
explicit dispatch. A tag never starts this workflow.

For an explicit dispatch, enter the existing candidate branch and its exact 40-hex head.
The workflow refuses a branch or SHA mismatch.

The workflow performs these operations:

1. It checks out the exact candidate SHA.
2. It resolves the highest `0.1.*` branch and reproduces the ordered commit range.
3. It runs the authoritative Elixir and Rust gates on Linux and macOS.
4. It runs `packaging/assemble.sh` on Linux x86_64 and macOS arm64.
5. It hashes both native packages and both toolchain records.
6. It verifies the complete manifest against Git and the downloaded files.
7. It uploads the 90-day proof artifact after every required job passes.

The workflow uses one-day staging artifacts to move files between jobs. A staging artifact
is not candidate proof. The final artifact is named `release-candidate-proof-<sha>`.

## Review boundary

Freeze the candidate branch after its proof run starts. Do not add a commit to the branch.
Do not force-push the branch.

Give the reviewer these exact values:

- The repository and candidate branch.
- The full candidate SHA.
- The successful workflow run.
- The final proof artifact.
- The canonical manifest and `SHA256SUMS` file from that artifact.

The reviewer must review that exact SHA. A review of an earlier branch head does not cover a
later head.

## Advance the version scratchpad

Advance only the reviewed and proved candidate SHA. Do not rebuild packages during
promotion.

1. Fetch every `0.1.*` branch and the candidate branch again.
2. Resolve the highest `0.1.*` branch again.
3. Verify that the remote candidate branch still names the proved SHA.
4. Verify that the version branch still names the manifest base.
5. Advance the version branch through an authorized fast-forward or clean merge.
6. Verify that the remote version branch names the exact proved candidate SHA.

Example readback:

```sh
git fetch --no-tags origin \
  '+refs/heads/0.1.*:refs/remotes/origin/0.1.*' \
  '+refs/heads/release-candidate/<version>-r1:refs/remotes/origin/release-candidate/<version>-r1'
protected_ref=$(sh scripts/highest_0_1_branch.sh)
test "$(git rev-parse refs/remotes/origin/release-candidate/<version>-r1)" = <candidate-sha>
test "$(git rev-parse "$protected_ref")" = <protected-base-sha>
# Use the authorized fast-forward or clean merge path here.
git fetch --no-tags origin '+refs/heads/0.1.*:refs/remotes/origin/0.1.*'
protected_ref=$(sh scripts/highest_0_1_branch.sh)
test "$(git rev-parse "$protected_ref")" = <candidate-sha>
```

Stop if the version branch moved before promotion. Do not merge extra commits into the
proved candidate. Prepare and prove a new candidate instead.

## Tag when the version quits

Create the immutable version tag only after the exact version-branch readback succeeds.
The tag must target the proved candidate SHA.

1. Fetch tags and every `0.1.*` branch.
2. Refuse the operation if the tag already exists locally or remotely.
3. Resolve the highest `0.1.*` branch again.
4. Verify that the version branch names the proved candidate SHA.
5. Verify that the proof manifest names the same source SHA.
6. Create one annotated version tag at that SHA.
7. Push the tag once.
8. Read the remote tag target and verify the exact SHA.

Never update or delete a release tag. The release-candidate workflow has no tag trigger.

## Delete the candidate branch

Delete the candidate branch only after the version tag and its proof name the same exact
SHA.

1. Verify the remote tag target again.
2. Verify the proof manifest's source SHA again.
3. Delete the remote candidate branch.
4. Delete the local candidate branch.
5. Read the remote candidate ref and verify that it is absent.

The tag and proof retain the release record. Do not retain candidate branches as history.

## Prevent duplicate work

Use one candidate branch name for one candidate. Do not reuse a candidate branch name.
Use the existing proof when the candidate SHA and all manifest hashes match.

Do not create a second proof to repair missing evidence. A missing package, toolchain
record, or hash makes the proof incomplete. Fix the cause and prepare a new candidate.

## Roll back

Before promotion, cancel the candidate without moving its branch backward. Do not reuse its
name.

After promotion, select an earlier proved package by its exact digest for an installed test
host. Do not rebuild that package.

For a source rollback, create and review a revert commit on the highest `0.1.*`
branch. Then prepare a new candidate from that branch. Never move a version branch, a
candidate branch, or a release tag backward.
