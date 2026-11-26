# Agents, archetypes, and settings

A Tightbeam session has an address, a harness, and a working identity. It can receive messages, wake on events, and hold assignments. Work items record intended outcomes, assignments record who owes a result, and attests record progress, verdicts, and completion. These records outlast the conversations that produced them. See [Architecture](ARCHITECTURE.md) for the gateway and its records.

Starting with 0.1.17, switching harnesses keeps the session, conversation history, and assignments. The destination harness receives working context in its first prompt. Tightbeam fits that context to the destination's available budget.

## Archetypes and kungfu

An archetype supplies guidance and skills for an agent's job. A kungfu bundle can supply archetypes, guidance, skills, and rails for a domain. Rails enforce a condition, such as requiring a review before an assignment can be completed.

Main starts with a neutral identity. Uncle Enzo is the primary shipped kungfu. It uses a mostly flat delivery structure. An executive holds your intent and talks to you, deliverators each own delivery of a feature or concern, and generic agents do the work with briefs tailored to their assignments. Use `tightbeam kungfu list` to see the bundles available in your version. Learning or unlearning a bundle does not transfer responsibility for existing assignments or change provider credentials.

## Models and gateway settings

Configure model, effort, and context window as separate fields. The model and any chosen effort or context tier must be available for the selected harness. Provider credentials are managed by Tightbeam. See [Onboarding](ONBOARDING.md) for adding a provider credential after installation.

| Setting | Meaning |
| --- | --- |
| `TIGHTBEAM_BASE_DIR` | The gateway's state directory, including its database, identity, harness homes, and work directories. Falls back to `TIGHTBEAM_HOME`, then `~/.tightbeam`. |
| `TIGHTBEAM_LOCAL_HOST_NAME` | The name used in the harness homes tree. It defaults to the OS hostname. Use a stable name where the OS hostname can change so the gateway can locate existing homes. |
| `TIGHTBEAM_PORT` | The gateway's listening port. The CLI discovers the gateway through `gateway.json` in the base directory. |
| `TIGHTBEAM_ADVERTISED_URL` | The address clients are told to connect to. |
| `TIGHTBEAM_DEFAULT_MODEL` | The default model for new sessions. Use a model available in the default harness. |
| `TIGHTBEAM_DEFAULT_EFFORT` | The default reasoning effort for models with effort tiers. |
| `TIGHTBEAM_DEFAULT_CONTEXT` | The default context-window variant where the model offers a choice. |
| `TIGHTBEAM_SUPERVISION_INTERVAL_MS` | The assignment inactivity reminder interval. Defaults to 30 minutes. Set to `off` to disable these reminders. |
| `TIGHTBEAM_COORDINATOR_HOLD_DECISIONS` | Set to `false` to suppress decision requests when usage limits or harness holds stop all active coordinators. |

Use a separate base directory and port for each gateway on the same machine. See [Satellite hosts](SATELLITE.md) to add a machine to an existing gateway and [Feature flags](feature-flags.md) for controls on shipped features.

## Working from outside Tightbeam

Tightbeam ships two skills for external agents. [tightbeam-cli](../priv/skills/tightbeam-cli/SKILL.md) is for an agent holding an assignment and a Tightbeam session credential in its worktree. [tightbeam-operator](../priv/skills/tightbeam-operator/SKILL.md) is for an agent acting on behalf of a user.

Run `tightbeam skill install` to install the versions carried by your CLI into existing Claude Code and Codex skill directories. Use `--skill <name>` to select a skill or `--dir <directory>` to choose a destination. Start a fresh agent session to discover the installed skills.
