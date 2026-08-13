# Base synchronization trigger

Before the first goal edit of a source-changing assignment, load and complete the
elected `base-synchronization` skill. Do the same after every durable
`changes-requested` verdict and before the first edit for that rework round. Fetching,
integrating, and resolving integration conflicts belong to the gate; goal edits do
not start until its outcome is `released`.

The assignment opener records an authorized base declaration before waking the
worker. The worker runs and records the gate for each pass. The reviewer loads the
skill and rejects missing, stale, contradictory, or false gate evidence. Use the
skill's source-less classification when an implementation-looking assignment changes
no source.
