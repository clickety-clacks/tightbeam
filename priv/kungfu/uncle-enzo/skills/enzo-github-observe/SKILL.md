---
name: enzo-github-observe
description: Observe exact GitHub subjects and record linked evidence.
---

When a watched event will affect assigned work, register a bounded wait with the full event name and canonical scope. Read the subject immediately after subscribing to cover a transition that preceded the subscription. Recheck the repository, target and revision when consuming the result. A replayed fact can predate a new subscription. Follow the exact read even when the observer is disabled.

Use `uncle-enzo/github-watch/` with `pr.checks-completed`, `pr.merged`, `pr.closed`, `pr.settled`, `branch.check-failed`, `tag.observed` or `release.published`. The scope for a PR is its HTTPS GitHub URL. For branches and tags use the HTTPS API ref locator, for example `https://api.github.com/repos/example/widget/git/ref/heads/release%2F2.x`. For a release by tag use `https://api.github.com/repos/example/widget/releases/tags/v2.3.1`. Encode a ref or tag as one percent-encoded path component, retaining its case.

The observation has scope, revision and a JSON string with source details. Read the known fields and preserve unfamiliar members if retaining the original. A checks-completed fact means the observer resolved a nonempty requirement set and found terminal results for every requirement. Failure is terminal. Unknown requirements and a confirmed empty set produce no fact. Apply the repository's elected required checks and review policy separately, and compare observations to the exact checked commit. Merge-queue group checks and PR head checks may use different commits. Polling can miss transient states. A broad subscription can receive matching facts produced for someone else's concrete demand.

Explicitly identify the work item or assignment before recording evidence using your existing CLI identity. Use one string per value and preserve current entries when setting a many-valued memento.

- `uncle-enzo/github-target` is compact JSON such as `{"ref":"refs/heads/main","repo":"github.com/example/widget"}`.
- `uncle-enzo/github-pr` is a canonical PR URL.
- `uncle-enzo/github-revision` is a canonical commit URL on an assignment or attest.
- `uncle-enzo/github-integration` is compact JSON with `oid`, `ref`, `repo` and the optional `pr` number.
- `uncle-enzo/github-evidence` is a URL or recorded artifact ID.

Use sorted keys for JSON strings and retain additional members on round-trip. Each name holds at most 32 values, each 1–1024 bytes. On work or assignment rows use `tightbeam memento-set --record work_item:<id> --name uncle-enzo/github-pr --value <url>` with repeated `--value` for the full intended set. Use inline `--memento name=value` on an attest when evidence belongs to that attest. Work-item closure and a separate memento set have separate outcomes.
