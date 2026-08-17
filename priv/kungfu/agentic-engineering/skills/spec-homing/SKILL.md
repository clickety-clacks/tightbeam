---
name: spec-homing
description: How a spec's identity binds to the work it drives. Use when writing a new spec, looking for an existing spec, or referencing spec conventions.
---

# Spec homing

## Binding a spec to its work
A path alone names a location, not a version. When a spec drives a work-item, bind its
actual path by content: `tightbeam work-item-create --title "<feature>" --spec-ref <name>
--spec-sha256 <hex>` records the exact spec the work serves, so a coder or reviewer
reads the version you handed off and not a later edit. Re-bind on a material amendment
(`work-item-update --spec-ref … --spec-sha256 …`) so the thread always names current
truth — a stale pin indicts the spec, not the builder.

Shipped Kung Fu does not prescribe where a spec lives. By default, write it in the
responsible agent's workdir. An organization may establish its own shared workspace,
repository, or other location convention. The recorded spec reference and hash—not a
universal folder—identify the ruling. A spec must not exist only as prose in a
work-item note.

## Finding a spec
First follow the work item's spec reference when one exists. Otherwise, search the
responsible workdir and any organization-defined spec location for the feature's terms.
A spec that covers the topic is extended or superseded, not duplicated. Organizations
choose how they retain superseded specs.

## Naming
- Lowercase, hyphenated, named for the feature or system: `terminal-bubbles.md`.
- The name describes the feature, not a work-item id.
- A version suffix (`-v2`) appears only when a spec supersedes a prior one.

## Writing a new spec
1. Create the file before drafting content anywhere else.
2. Every spec has all eight canonical sections — the set is canonical, not a minimum to
   exceed or a menu to trim: Goal, Non-Goals, Terms (the load-bearing words designated —
   what each denotes and where it lives), Assumptions (the indicative givens the spec
   relies on, stated so they can be falsified), Invariants, Architecture (the design),
   Acceptance (concrete, checkable), Open Questions (marked holes, each ruled blocking or
   non-blocking). Each section names a class of defect that hides when the section is
   absent, so an empty one is stated empty ("Non-Goals: none"), never omitted.
3. Amendments edit the canonical file; the edit history is the spec's history.
