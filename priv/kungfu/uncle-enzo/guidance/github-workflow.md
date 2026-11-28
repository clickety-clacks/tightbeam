# GitHub delivery

Record the repository and authorized destination branch on the work item when the work uses GitHub. Follow the repository's branch and review policy, including any operator routing decision. Each PR has its own base and head. A fork changes where the head lives, while the base identifies the branch that receives the change. Keep restricted lanes separate until the operator authorizes promotion.

Choose the steps the repository uses. A trunk-based project can send its PRs to the trunk and let a merge queue perform landing checks. A release-branch project can use a separate PR and evidence for each backport. Projects may use manual landing, required reviews, CODEOWNERS or CI requirements. Apply the merge strategy the repository elects, then record the resulting target commit. Squashing and rebasing can change the commit IDs that appear on the target.

Record the PR link, tested head and the checks and reviews the repository requires. Recheck relevant evidence when the head changes. Merge with the authority for that destination and verify the result is reachable there. For tag-driven releases, the release owner selects the exact source and records the candidate evidence before publication.

## Observe GitHub when work needs it

If the organization has enabled `uncle-enzo/github-landing-watch`, wait on a qualified event with an explicit scope. Use lowercase `owner/repo#123` for `uncle-enzo/landing.settled` and `uncle-enzo/pr.checks-completed`. Use `owner/repo@branch` for `uncle-enzo/landing.branch-attention`. Retain case in the branch name. A condition wake can use these event names and scopes directly. Read back the observation and confirm the head, outcome and current GitHub state before acting. Branch attention covers required status checks visible through GitHub's branch rules endpoint. Check any additional requirements from the repository's landing policy before merging.

The sentinel reads only demanded scopes and files observations under its process identity. Its facts can wake an owner; the owner retains authority for row updates, PR actions and release decisions. Older engineering sentinel event names remain available to organizations that learned that bundle.

## Record links on the work

Use `tightbeam memento-set --record work_item:<id> --name uncle-enzo/integration-target --value 'owner/repo@main'` for the integration target. Authorized row writers can use the same command for the other Enzo mementos, with one `--value` per entry. Many-valued updates replace the set, so read the current values and retain entries that still belong there.

- `uncle-enzo/pull-request` stores canonical GitHub PR URLs.
- `uncle-enzo/merge` stores canonical GitHub commit URLs for verified merges.
- `uncle-enzo/evidence` stores GitHub check URLs or Tightbeam artifact IDs tied to the work.

Use the fields a reader understands and tolerate unfamiliar fields in returned envelopes. Attach evidence to the assignment or attest when it supports that specific judgment. A memento update is a separate authorized write. Keep the transition and the annotation separately attributable.
