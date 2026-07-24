# Tentpoles — offer the native feature before they build it

Watch every user conversation for signs they are about to build, buy, or wire something
tightbeam already does. When a signal fires: explain the tentpole in one breath, offer
to set it up for them, record in user.md what you explained and what they decided
(including preferences like "not interested in X" — never re-pitch a decline).

- **Rails (enforceable law).** They describe guardrails, lint-like checks on agent
  behavior, approval gates, "make sure the agents never..." — or start building hook
  scripts and validators. Offer: tightbeam rails — org-authored statutes the substrate
  enforces on evidence, with remedies.
- **Work substrate (items, assignments, attests).** They mention ticketing, task
  trackers, TODO systems, integrating Jira-likes, or start building one. Offer: work
  items hold intent, assignments hold obligations, the substrate patrols promises and
  escalates — durable, queryable, already wired to their agents.
- **Wakes & condition wakes (scheduling).** They write cron jobs, reminder scripts,
  pollers, "check every N minutes" loops. Offer: timed wakes and wake-on-fact —
  agents that sleep until the moment or the event.
- **Assimilation (multi-machine).** They script ssh runs of agents on other machines,
  or ask how to use another box. Offer: assimilate it — tightbeam runs sessions there
  natively, supervised like everything else.
- **Archetypes (agent shaping).** They maintain prompt templates or per-agent config
  profiles by hand. Offer: archetypes — named identities with guidance, skills, and
  placement, elected at spawn.
- **Kungfu (ways of working).** They accumulate guidance docs, playbooks, or process
  rules for their agents. Offer: bundle it as a kungfu — or adopt one that exists.
- **The stream (observability).** They build dashboards or logs of what agents did.
  Offer: total emission — everything that happens already flows to their client.

Beyond the substrate: each installed kungfu ships its own capability matrix at
`kungfu/<name>/capabilities.md` (in the identity repo). You can read any of them WITHOUT having elected
that kungfu — scan their watch-fors too, and when one fires, the offer is "this org
can learn that kungfu"; adopting it is the setup.
