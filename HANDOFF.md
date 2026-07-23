# Spinup conformance handoffs

## Clause 3 — org CLI detect/ensure/deploy

Blocker: the ruling `spinup-detection-v1.md` requires Spinup to ensure the org CLI, but `session-tokens-v1.md` §Rollout says “Spinup does not deploy the CLI; assimilate's CLI step is the only delivery path,” and `probe-v1.md` §Rollout repeats that Spinup never refreshes the shipped CLI. The Spinup spec also limits host data to SSH/base-directory addressing and does not define the CLI source artifact, destination path, target-triple compatibility rule, local-host behavior, or deployment command. Implementing any choice in `lib/tightbeam/spinup.ex` would invent behavior across a binding spec conflict.

Required change: reconcile the three specs and define one owner for CLI delivery. If Spinup remains the owner, amend the governing spec with the source artifact, remote and local destination paths, target-triple policy, presence/post-deploy checks, exact deployment action, and lifecycle detail, then authorize the corresponding full present/missing/failure/post-check matrix in `test/spinup_test.exs`. If assimilate remains the only owner, remove the org-CLI requirement from spinup clause 3.

## Clause 13 — proof for failure-specific denial remedies

Blocker: production remedy selection is implemented in the lane-owned `lib/tightbeam/spinup.ex`, including a real `:enotdir` correction (“remove or rename the non-directory component”) and a corrective adapter post-check action (“reinstall”). The required proof file `test/spinup_test.exs` is outside this lane's explicit ownership boundary. Its current local-directory test still asserts only the verifier-rejected generic permissions substring, and its post-deploy test still asserts only the verifier-rejected diagnostic substring, so neither can honestly prove the corrected implementation under the anti-stub contract.

Required cross-lane change: authorize the test-owning lane to replace those weak assertions with exact failure-specific messages and observable remedy proof. For the local `:enotdir` case, create the conflicting file, assert the remove/rename remedy exactly, apply that remedy, rerun readiness, and assert the work path becomes a directory. For the adapter post-deploy case, assert the reinstall-and-executable-path correction exactly. Retain exact assertions for remote permission denial, npm-not-found, connection-refused, local-adapter-missing, and credential-missing so the complete denial-branch matrix fails if any remedy selector or corrective message is removed.
