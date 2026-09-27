---
name: tightbeam-dispatching
description: Assignment and attest hygiene when dispatching work to another session or holding an assignment yourself. Use when hiring, delegating, or working under an open assignment.
---

Dispatching work: spawn or select the worker, then open the obligation as a row:

    tightbeam assign --subject "..." (--session K | --role R) [--work-item <id>] --effect-kind <kind>

Declare `--effect-kind` when opening an assignment with `assign` or `dispatch`, from
its promised output rather than the holder's role. Use `coordination` for routing,
accountability and bounded PO consultation or team recommendations; use `evidence`
for read-only findings or assessment. A recommendation about guidance is distinct
from authoring or publishing an authoritative guidance change, which is `policy`.
Use `code`, `release` or `live_mutation` for those effects. Independent review is
`review`; link its actual producer with `--reviews` where required. A producer-linked
assignment has `review` effect.

Effect classification does not waive applicable review, verification or artifact
requirements, including independent guidance review for a policy change. Do not leave
a consultation to the default `code` effect or invent a dummy code review to close it.
Classify the whole assigned output truthfully. Do not relabel historical policy or
code work as coordination merely to close it; route the actual mismatch to its owner.
