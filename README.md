# Tightbeam

Tightbeam runs an organization of AI agents on one or more machines. It gives each agent a role, passes messages between agents, records the work and enforces your rules. If an agent crashes or loses its context, it picks up from the record. Tightbeam provides:

- **Messaging between agents.** Any agent can message any other agent in the organization, across sessions and machines. Agents hand off work, ask questions and report results to each other directly.
- **Event-based waking.** Agents wake when other agents or processes have something for them to act on, such as completed work or a pull request's checks finishing. Timed waits and polling are kept to a minimum. A sleeping agent uses no model turns.
- **Guidance and skill isolation.** An "archetype" gives an agent only the guidance and skills its job needs. Its context stays focused on the work it has to do.
- **Message queue manipulation.** A sender can cancel a queued message, replace changed instructions or mark a message's urgency, so agents do not act on outdated instructions.
- **Message batching.** Messages batch so they can be handled in one turn.
- **Durable records.** Tasks, responsibilities and results are stored as records that outlast conversations. An agent that crashes, restarts or loses its context picks up from the records.
- **Observability.** Every change to a record is streamed, so reports and user interfaces can show live activity across the organization and explain what happened.
- **Decisions that come to you.** When an agent needs a product choice it is not allowed to make, it files a decision request. You get the question, the agent's recommendation and the choices. When you answer, the agent wakes with your answer.
- **Deterministic rails.** Agents sometimes ignore guidance and skills. A rail is a rule Tightbeam enforces, so agents cannot skip it. For example, a rail can require a review before any work counts as done.
- **Ordinary agent harnesses.** Agents run in ordinary harnesses such as Claude Code and Codex. Tightbeam passes your model and settings through unchanged and shows you the harness's own output, including failures.

Tightbeam is a construction set. Rules, roles and process are not built in. You and your agents decide who writes, who reviews, who decides scope and when a change counts as done. You can build a software team, a research desk, a support rotation or a one-person shop with specialists on call. Tightbeam ships with a software engineering template called a "kung fu". You can use it, change it or write your own.

A software dark factory runs one fixed process unattended. A personal agent such as OpenClaw puts many tools behind one assistant. Tightbeam runs many agents as an organization you design, and it keeps running when you are away.

## Tightbeam in detail

![How the pieces fit](docs/images/tightbeam-shape.svg)

The gateway runs a graph of agents and keeps a permanent record of what each agent is working on, what it has done and what has been checked. Agents run on any machine in your network, in the harness you choose.

## Principles

These principles decide what Tightbeam is and how it changes.

**User and agent agency.** You and your agents decide the shape of your organization, its process and its teams.

**Domain knowledge belongs in "kung fu".** A kung fu bundle supplies the roles, guidance, skills and rules for a kind of work. The core handles records, messages and agents without needing to know what a pull request, a support ticket or a research paper is. You can teach Tightbeam more than one domain.

**Only enough guidance for the job.** Each agent gets the guidance and skills it needs for the work it has to do. Its context stays focused on that job.

**Rails where you want them, agency everywhere else.** Tightbeam "rails" ensure agents behave deterministically at critical moments in your workflows. You choose the rules, such as requiring a review before work counts as done. Tightbeam applies them the same way every time. Everything else is left to the agents' judgment.

**Built for your tailnet.** Tightbeam assumes one operator on a private network, so there is no security setup to get through before you start.

**The record is the truth, not the context.** Records show what needs doing, who is responsible, what has been done and what has been checked. Agents recover their work from these records after compaction or restart. You can see why anything happened without reading chat logs.

**Wake on events.** Agents sleep until another agent or process has something for them to act on. Timed waits and polling are kept to a minimum.

**Keep the natural harness and augment it.** Each agent runs in the harness its model was built to use. Tightbeam adds the tools for agents to communicate and work together as an organization.

**Let modern models orchestrate.** Modern models can plan work, choose tools and delegate. Tightbeam gives them shared records, messages, wakes and other agents to work with. The models decide how to put those tools to use.

**Agnostic to harness and model, compatible with their features.** Claude and Codex agents run in the same organization, and each can use its own harness's features. You can change an agent's model or harness while it works.

**Tightbeam is headless.** You know best how you should interact with it. There is no required user interface. That said, we've written some great UIs for it: the [chat component](https://github.com/clickety-clacks/tightbeam-chat), the [air-traffic-control view](https://github.com/clickety-clacks/tightbeam-atc), the [tuner](https://github.com/clickety-clacks/tightbeam-tuner) and the [decisions widget](https://github.com/clickety-clacks/tightbeam-decisions-omarchy). Use them or build your own.

## The tools

**Work items, assignments and evidence.** A work item is a goal. An assignment makes one agent responsible for a part of that work, with someone expecting the result. An attest records what happened: progress, a review, completion or an explanation of why the agent cannot continue. An artifact is a recorded file with its hash. Every agent can read these records, so a coordinator recovers from them instead of from memory.

```sh
tightbeam work-item-create --title "Fix the login timeout"
tightbeam dispatch --session <key> --subject "..." --work-item <id> --brief "..."
tightbeam attest <assignmentId> --kind progress --note "..."
tightbeam artifact-record --kind report --title "..." --path ./report.md --work-item <id>
```

**The agent graph.** Spawn a session under yourself with an archetype, a harness, a model and a machine. Move it to another parent, retire it, or ask the gateway who reports to whom. Each session carries its own conversation, identity and work directory. A failed turn is carried to a parent who can act on it.

```sh
tightbeam spawn --display "<Role>: login timeout" --name <function>:login-timeout \
  --archetype <archetype> --harness codex --model <model> --host <host>
tightbeam retire --session <key>
```

**Archetypes.** An archetype is the identity a session wakes up with: who it is, what it owns, how it works, which skills it has. Archetypes live in a git repository the gateway serves to every session, so a change to one applies to every agent built from it. Edit them with `tightbeam identity edit`, or write new ones.

**Skills and guidance built from basic tools.** Guidance is prose an agent reads and weighs. Skills are procedures it can load when the work calls for them. Both are files in the identity repository. Subtree guidance applies a note to a whole branch of the organization, or to some archetypes within it. A kung fu is a bundle that defines a domain-specific organization: its archetypes, skills, guidance and rules. Tightbeam learns a kung fu to work in that domain. The shipped kung fu, agentic-engineering, is a software engineering organization: archetypes that own the product's intent, plan the work, write the contracts, build, review independently and watch pull requests until their checks finish, with rules such as "a completion needs an independent review" wired in as rails. You can change its archetypes, delete its rules or write a kung fu for different work.

```sh
tightbeam learn agentic-engineering
tightbeam subtree-guidance set release-freeze --archetype <archetype>,<archetype> --file freeze.md
```

**Rails.** A rail is a rule Tightbeam enforces. Agents cannot weigh it and skip it. There are two kinds. One guards records: when an agent tries to mark work complete, Tightbeam checks the rule first, and if the rule is not met the agent is told which rule stopped it and what is missing. The shipped template has rails such as "completion requires review" and "a repeated fix carries a diagnosis". The other kind guards commands and is called a statute. A statute names a command pattern no agent may run, such as pushing to main or rewriting git history. When an agent tries, the harness refuses the command before it runs and shows the agent the statute that refused it. You write both as small configuration files, and you can have none.

**Decisions that come to you.** An agent that needs a product choice it is not allowed to make files a decision request naming you. You see the question, the recommendation and the choices in the phone app, a desktop bar widget or chat. When you answer, the agent wakes with the answer. Until then, it keeps working on anything that does not depend on it.

```sh
tightbeam operator-ask --question "..." --note "..." --assignment <id>
tightbeam decision-requests
```

**Wakes triggered by facts.** When an agent ends its turn, it can ask to be woken at a time, on a repeating schedule, when a named fact arrives, or when another agent's assignment reaches a state it describes. Anything that can run the CLI can record a fact, including a script with no agent behind it. The shipped pull request watcher records a fact when every required check on a pull request has finished, so an agent can sleep until its checks are green instead of asking every minute.

```sh
tightbeam wake --session <key> --after 30m --prompt "re-read the card"
tightbeam wake --session <key> --when-fact pr.checks-completed \
  --when-scope owner/repo#42 --fallback-after 2h --prompt "checks finished"
tightbeam condition --kind deploy.finished --scope prod
```

**Model and harness switching.** Change a running agent's model, effort or speed and it keeps its conversation. Change its harness and it starts a fresh engine context while keeping its place, role and work in the organization. You can run Claude and Codex agents together and move an agent from one to the other.

```sh
tightbeam tune --session <key> --model <model>
tightbeam tune --session <key> --harness claude --model <model>
```

**One stream for everything.** The firehose is a WebSocket feed of every record change. The bundled [chat component](https://github.com/clickety-clacks/tightbeam-chat), the [air-traffic-control view](https://github.com/clickety-clacks/tightbeam-atc), the [tuner](https://github.com/clickety-clacks/tightbeam-tuner) and the [decisions widget](https://github.com/clickety-clacks/tightbeam-decisions-omarchy) all read it. So can your own scripts.

## Is Tightbeam for you?

Tightbeam suits you if you want to run your own software factory, or any other kind of agent organization, on machines you control. It suits you if you want to decide which models run, where your code goes and what counts as done. It suits you if no vendor's defaults fit your process and you want to write the rules yourself.

It is not for you if you want one assistant in one window. It is not for you if you want a software-as-a-service agent such as Devin. Devin lets you pick its model, steer it with prompts and playbooks, and run its workspace on your own hardware, but its agent loop runs in Cognition's cloud and its way of working is Cognition's. Tightbeam can also be hosted anywhere. The difference is that you decide how it works.

## Install

Install Tightbeam from a published release package, and check the package against the checksums that ship with it. Do not install from a git checkout. A checkout is for working on Tightbeam itself.

Run it on a private network such as a tailnet. You also need a machine that stays on to run the gateway, and these on that machine:

- At least one harness CLI on PATH, `claude` or `codex` or both.
- node and npm. The release is an npm package, and the gateway installs its adapters with npm.
- git, for the identity repository.

Install a harness first if you have not:

```sh
npm install -g @anthropic-ai/claude-code
claude --version
```

```sh
npm install -g @openai/codex
codex --version
```

Download the package for your platform from the [releases page](https://github.com/clickety-clacks/tightbeam/releases). Each release ships packages for darwin-aarch64 and linux-x86_64, a `SHA256SUMS` file and a `release-provenance.json` naming the exact commit and workflow run that produced them. Verify before you install:

```sh
sha256sum -c SHA256SUMS --ignore-missing    # Linux
shasum -a 256 -c SHA256SUMS --ignore-missing # macOS
```

```sh
npm install -g ./tightbeam-<version>-<os>-<arch>-<commit>.tgz
tightbeam --version
tightbeam-gateway
```

The first boot creates the base directory, sets up the identity repository and starts serving. It cannot run a turn yet, so it prints a NOT READY summary naming each gap and the command that closes it. Leave it running and finish from another terminal.

Pair a client first. The first client to pair creates the admin user and that user's built-in Main session. Then, as that admin, give Tightbeam a credential for each provider you will use. Tightbeam keeps its own credential and does not read your vendor login:

```sh
tightbeam onboard anthropic --as-user <userId>
tightbeam onboard openai --as-user <userId>
```

Have Tightbeam learn the shipped kung fu, or skip this and build your own:

```sh
tightbeam learn agentic-engineering --as-user <userId>
```

Open Main in your client and send a message. A reply means turns are working.

The last required step is installing the gateway as a service, so it survives logout and reboot and restarts on failure. This needs root. Unit files for systemd and launchd, and the full step by step including the Linux sandbox setup, are in [docs/INSTALL.md](docs/INSTALL.md). Run `tightbeam doctor` at any point to see what is still missing.

Upgrading an existing installation has its own review in [docs/UPGRADE.md](docs/UPGRADE.md). Back up before you do: [docs/BACKUP.md](docs/BACKUP.md).

## Connect agents and clients

Your agents reach the gateway through the `tightbeam` CLI, which ships in the same package as the gateway so the two never disagree about versions. A session spawned by the gateway already has its identity. An agent you run outside Tightbeam, such as a terminal session on your desk, gets the same CLI and a skill that teaches it the commands.

Clients read the firehose and send turns. The ones that exist today are open source and in sibling repositories:

- [tightbeam-chat](https://github.com/clickety-clacks/tightbeam-chat), an embeddable chat component for talking to one session.
- [tightbeam-atc](https://github.com/clickety-clacks/tightbeam-atc), a live three-dimensional view of the whole organization that shows how active it is.
- [tightbeam-tuner](https://github.com/clickety-clacks/tightbeam-tuner), a desktop and iOS browser of the agent tree that opens tightbeam-chat on any agent.
- [tightbeam-decisions-omarchy](https://github.com/clickety-clacks/tightbeam-decisions-omarchy), a desktop bar widget for ruling on decision requests.

[harklight-app](https://github.com/clickety-clacks/harklight-app) is different: it does not read the firehose. An agent sends you a notice, a question or a decision through its [agent CLI](https://github.com/clickety-clacks/harklight-agent), the [server](https://github.com/clickety-clacks/harklight-server) pushes it to your phone, and your reply goes back to the agent that asked.

To add a machine so agents can run on it, see [docs/SATELLITE.md](docs/SATELLITE.md). One ssh-reachable host becomes part of the organization with `tightbeam assimilate`.

## Operating

- [docs/SMOKE.md](docs/SMOKE.md), the manual acceptance runbook after an install.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), the shape of the gateway and its records.
- [docs/firehose.md](docs/firehose.md), the change stream clients read.
- [docs/statutes.toml.example](docs/statutes.toml.example), the format for your own statutes.
- [docs/SATELLITE.md](docs/SATELLITE.md), adding a machine.
- [docs/BACKUP.md](docs/BACKUP.md) and [docs/UPGRADE.md](docs/UPGRADE.md).

## Developing Tightbeam

The gateway is Elixir and the CLI is Rust. Source builds, the test suite and how a release gets cut are in [CONTRIBUTING.md](CONTRIBUTING.md). A source build is for working on Tightbeam, not for running it.
