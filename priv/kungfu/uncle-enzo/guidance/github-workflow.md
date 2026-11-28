# GitHub delivery

Record the repository and authorized integration branch on the work item before staffing. Use the repository's branch policy and the operator's explicit routing decisions. Open a short-lived pull request against that target. A release branch is a distinct delivery lane only when the release owner has designated it. Keep restricted lanes separate until the operator authorizes promotion.

Record the PR link, tested head, required CI results and independent review on the linked work. Recheck the head and approvals at merge time. A new head needs its own verification and review. Merge only with the authority for that destination, then read back the merge commit and its reachability from the target. The release owner selects the exact source for a candidate and verifies that candidate before publication.

## Observe GitHub when work needs it

If the organization has enabled `uncle-enzo/github-landing-watch`, wait on a qualified event with an explicit scope. Use lowercase `owner/repo#123` for `uncle-enzo/landing.settled` and `uncle-enzo/pr.checks-completed`. Use `owner/repo@branch` for `uncle-enzo/landing.branch-attention`. Retain case in the branch name. A condition wake can use these event names and scopes directly. Read back the observation and confirm the head, outcome and current GitHub state before acting. Branch attention covers required status checks visible through GitHub's branch rules endpoint. Check any additional requirements from the repository's landing policy before merging.

The sentinel reads only demanded scopes and files observations under its process identity. Its facts can wake an owner; the owner retains authority for row updates, PR actions and release decisions. Older engineering sentinel event names remain available to organizations that learned that bundle.

## Record links on the work

Use `tightbeam memento-set --record work_item:<id> --name uncle-enzo/integration-target --value 'owner/repo@main'` for the integration target. Authorized row writers can use the same command for the other Enzo mementos, with one `--value` per entry. Many-valued updates replace the set, so read the current values and retain entries that still belong there.

- `uncle-enzo/pull-request` stores canonical GitHub PR URLs.
- `uncle-enzo/merge` stores canonical GitHub commit URLs for verified merges.
- `uncle-enzo/evidence` stores GitHub check URLs or Tightbeam artifact IDs tied to the work.

Use the fields a reader understands and tolerate unfamiliar fields in returned envelopes. Attach evidence to the assignment or attest when it supports that specific judgment. A memento update is a separate authorized write. Keep the transition and the annotation separately attributable.
