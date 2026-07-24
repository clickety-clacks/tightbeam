---
name: spec-homing
description: Where specs live, how to find one, how to name one, and how a spec's identity binds to the work it drives. Use when writing a new spec, looking for an existing spec, or referencing spec conventions.
---

# Spec homing

## Canonical location
Every spec lives in the org's shared spec workspace, in one tree readable by every
session: `specs/<project>/<name>.md`. The canonical path is the spec's identity;
conversations, assignments, and reviews reference the spec by that path.

Specs do not live in scratch directories, in a session's workdir, or as prose inside a
work-item note. A copy synced into a source repository is a mirror; the
shared-workspace file is the source of truth, and edits happen there. The shared spec
tree is the spec-writer's workspace; the own-worktree rule governs repository code,
not specs.

## Binding a spec to its work
A path alone names a location, not a version. When a spec drives a work-item, bind it
by content: `tightbeam work-item-create --title "<feature>" --spec-ref <name>
--spec-sha256 <hex>` records the exact spec the work serves, so a coder or reviewer
reads the version you handed off and not a later edit. Re-bind on a material amendment
(`work-item-update --spec-ref … --spec-sha256 …`) so the thread always names current
truth — a stale pin indicts the spec, not the builder.

## Finding a spec
Search the spec tree before writing a new spec: list `specs/*/` and grep the tree for
the feature's terms. A spec that covers the topic is extended or superseded, not
duplicated. Superseded specs move to `specs/<project>/archive/`.

## Naming
- Lowercase, hyphenated, named for the feature or system: `terminal-bubbles.md`.
- The name describes the feature, not a work-item id.
- A version suffix (`-v2`) appears only when a spec supersedes a prior one; the prior
  one moves to `archive/`.

## Writing a new spec
1. Create the file at the canonical path before drafting content anywhere else.
2. Every spec has all eight canonical sections — the set is canonical, not a minimum to
   exceed or a menu to trim: Goal, Non-Goals, Terms (the load-bearing words designated —
   what each denotes and where it lives), Assumptions (the indicative givens the spec
   relies on, stated so they can be falsified), Invariants, Architecture (the design),
   Acceptance (concrete, checkable), Open Questions (marked holes, each ruled blocking or
   non-blocking). Each section names a class of defect that hides when the section is
   absent, so an empty one is stated empty ("Non-Goals: none"), never omitted.
3. Amendments edit the canonical file; the edit history is the spec's history.
