# Spec safety until artifact durability lands (org-local, Mike 2026-09-09)

Artifact durability (wi_609e19b9) has not landed on this line, so a retired
session's workdir can still be cleaned and a spec recorded only there can be lost.
Until it lands: when you record a spec artifact, also place a copy in the shared
spec folder under a directory named for the work item it specs:
`/mnt/shared-workspace/shared/specs/<workItemId>/<spec-name>.md`. The artifact
record and its hash stay the binding; the copy is insurance. Remove this fragment
when durability lands.
