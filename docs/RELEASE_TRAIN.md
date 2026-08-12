# Release candidate procedure

This procedure builds packages from one exact candidate branch commit. It does not publish
a release. It does not create a tag.

The candidate branch name must start with `release-candidate/`. The branch contains the
exact ordered set of reviewed commits after one protected `main` commit.

## Prepare the candidate

Use a clean worktree. Store the preparation manifest outside that worktree.

1. Fetch the protected branch and all reviewed feature commits.
2. Record the exact `origin/main` SHA as the protected base.
3. Order every commit in the exclusive base-to-candidate range.
4. Run the preparation script with the branch, base, and ordered commits.
5. Inspect the canonical JSON manifest that the script prints.
6. Push the new candidate branch without force.

Example:

```sh
git fetch --no-tags origin main
base=$(git rev-parse refs/remotes/origin/main)
scripts/release_candidate.sh \
  release-candidate/0.1.8 \
  "$base" \
  <reviewed-feature-sha-1> \
  <reviewed-feature-sha-2> \
  > ../tightbeam-0.1.8-candidate-input.json
git push origin refs/heads/release-candidate/0.1.8
```

The script refuses a dirty worktree. It also refuses an existing local or remote candidate
branch. It refuses missing, duplicate, reordered, extra, and non-ancestral commits. It
creates one branch at the final reviewed commit. It does not create or rewrite a commit.

Do not redirect the manifest into the worktree. The shell creates the output file before
the script checks the worktree.

## Prove the candidate

The release-candidate workflow starts only for a `release-candidate/**` branch push or an
explicit dispatch. A tag never starts this workflow.

For an explicit dispatch, enter the existing candidate branch and its exact 40-hex head.
The workflow refuses a branch or SHA mismatch.

The workflow performs these operations:

1. It checks out the exact candidate SHA.
2. It reproduces the protected base and ordered commit range.
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

## Promote to protected main

Promote only the reviewed and proved candidate SHA. Do not rebuild packages during
promotion.

1. Fetch `main` and the candidate branch again.
2. Verify that the remote candidate branch still names the proved SHA.
3. Verify that protected `main` still names the manifest base.
4. Advance `main` through the repository's protected review path.
5. Verify that remote `main` names the exact proved candidate SHA.

Example readback:

```sh
git fetch --no-tags origin main release-candidate/0.1.8
test "$(git rev-parse refs/remotes/origin/release-candidate/0.1.8)" = <candidate-sha>
test "$(git rev-parse refs/remotes/origin/main)" = <protected-base-sha>
# Use the protected pull-request or merge path here.
git fetch --no-tags origin main
test "$(git rev-parse refs/remotes/origin/main)" = <candidate-sha>
```

Stop if `main` moved before promotion. Do not merge extra commits into the proved candidate.
Prepare and prove a new candidate instead.

## Create the immutable tag

Create the version tag only after the exact-main readback succeeds. The tag must target the
proved candidate SHA.

1. Fetch tags and `main`.
2. Refuse the operation if the tag already exists locally or remotely.
3. Verify that `main` names the proved candidate SHA.
4. Create one annotated version tag at that SHA.
5. Push the tag once.
6. Read the remote tag target and verify the exact SHA.

Never update or delete a release tag. The release-candidate workflow has no tag trigger.

## Prevent duplicate work

Use one candidate branch name for one candidate. The preparation script refuses a reused
branch name. Use the existing proof when the branch SHA and all manifest hashes match.

Do not create a second proof to repair missing evidence. A missing package, toolchain
record, or hash makes the proof incomplete. Fix the cause and prepare a new candidate.

## Roll back

Before promotion, cancel the candidate and retain its branch and proof as read-only history.
Do not move the branch backward. Do not reuse its name.

After promotion, select an earlier proved package by its exact digest for an installed test
host. Do not rebuild that package.

For a source rollback, create and review a revert commit on `main`. Then prepare a new
candidate from the new protected `main` state. Never move `main`, a candidate branch, or a
release tag backward.
